#Requires -Version 7
<#
.SYNOPSIS
    Writes the allow rules of the installed packages into .claude/settings.json, or checks that they are there.

.DESCRIPTION
    The skills run their own scripts and a few commands, such as the gates, git and gh. Each command the
    agent may run without a prompt is an allow rule in permissions.allow of .claude/settings.json. The
    package that owns the command lists it, so every repository that installs the package gets the same
    rules, and a repository gets no rule for a package it does not install.

    A skill lists its commands in the "allow" array of its gates.json. An entry is a command pattern, such
    as "git status *". The script writes it twice, as Bash(<pattern>) and PowerShell(<pattern>), because
    the agent runs commands through both shells. An entry that already names its shell, such as
    "PowerShell(./script.ps1 *)", is written as it is. The script reads the core and every pack that
    apm.yml lists, through Get-AiSdlcPackage.

    Each gate in the "gates" array of a gates.json also gets its own rules, so every gate runs without a
    prompt as its entry runs it: pwsh .claude/skills/<skill>/scripts/<Script>.ps1 with the exact
    arguments of the entry, such as -Check, and the same with -NoProfile -File. The rule has no star.
    So Sync-AllowRules.ps1 -Check runs without a prompt, but the form that writes .claude/settings.json
    still asks a person.

    A rule must name its script exactly. A rule with a star glued to a path under .claude/skills, such as
    scripts/Check-*, scripts/Run.ps1* or skills/*/scripts, would also let a new or changed script run
    without a person seeing a prompt. A rule that opens a whole shell, such as Bash(*) or pwsh *, is just
    as wide. The script never writes such an entry from a package; it prints it as "Allow rule not
    written". It removes a wildcard rule over a scripts folder from .claude/settings.json, because an
    older release wrote it there, and -Check reports it as drift.

    It adds rules and removes only those wildcard rules. A rule the repository added itself stays, and so
    does a rule of a package that is no longer installed; remove those by hand. The rest of
    .claude/settings.json, such as the hooks APM writes, is never changed.

    Without -Check it also lets the agent read the knowledge repository. When the folder in
    paths.knowledgeRoot exists, its absolute path goes into permissions.additionalDirectories of
    .claude/settings.local.json. In a linked git worktree, a relative knowledgeRoot that is not there
    is resolved against the main checkout as well. That file is per machine and untracked, because the
    path differs per machine; the script never writes it into .claude/settings.json. The rest of
    settings.local.json stays as it is.

    The folder must be below the parent folder of the repository, such as the ../Knowledge sibling. In
    a linked worktree, the parent folder of the main checkout counts too. No folder on the way may be
    a link. The parent folder itself, a folder elsewhere such as \\contoso\share, and a folder reached
    through a link are skipped with a FIX line, because aisdlc.json must not open a folder elsewhere to
    the agent. The exit code stays 0.

    With -Check it writes nothing. It exits 1 when a rule of an installed package is missing, or when a
    rule ends in a wildcard over a scripts folder. The knowledge folder is not checked, because CI never
    has it.

    Exit codes follow the gate contract: 0 in sync (or written), 1 a rule missing or a wildcard rule over
    a scripts folder, 2 could not check, 3 not applicable (no installed package part).

.PARAMETER RepoRoot
    The repository root. Defaults to the folder that holds aisdlc.json, found from the current location.

.PARAMETER SkillsRoot
    The folder the packages are installed in. Defaults to <RepoRoot>/.claude/skills.

.PARAMETER Check
    Compare only. Exit 1 when a rule of an installed package is missing.

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Sync-AllowRules.ps1

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Sync-AllowRules.ps1 -Check
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$SkillsRoot,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force

try {
    $config = Get-AiSdlcConfig -RepoRoot $RepoRoot
    $RepoRoot = $config.repoRoot
    if (-not $SkillsRoot) { $SkillsRoot = Join-Path $RepoRoot '.claude' 'skills' }
    $packages = @(Get-AiSdlcPackage -RepoRoot $RepoRoot -SkillsRoot $SkillsRoot)
}
catch {
    Write-Host "Could not check: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host 'FIX: Run the gate in a repository with an aisdlc.json and an apm.yml that lists its packages, and run apm install first.' -ForegroundColor Yellow
    exit 2
}

function Protect-LocalSetting {
    $inside = git -C $RepoRoot rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -ne 0 -or $inside -ne 'true') { return }
    git -C $RepoRoot check-ignore -q --no-index -- .claude/settings.local.json 2>$null
    if ($LASTEXITCODE -eq 0) { return }
    $exclude = [IO.Path]::GetFullPath(([string](git -C $RepoRoot rev-parse --git-path info/exclude 2>$null)).Trim(), $RepoRoot)
    New-Item -ItemType Directory -Path (Split-Path -Parent $exclude) -Force | Out-Null
    $text = if (Test-Path -LiteralPath $exclude -PathType Leaf) { [IO.File]::ReadAllText($exclude) } else { '' }
    if ($text -and -not $text.EndsWith("`n")) { $text += "`n" }
    [IO.File]::WriteAllText($exclude, $text + "/.claude/settings.local.json`n", [Text.UTF8Encoding]::new($false))
    Write-Host 'Knowledge folder: added /.claude/settings.local.json to .git/info/exclude, so that file is never committed.'
}

function Test-KnowledgeRootAllowed {
    # aisdlc.json is repository content, so it may name any folder or share. Only a folder below the
    # parent folder of the repository, such as the ../Knowledge sibling, gets read access (#32). In a
    # linked worktree, Get-AiSdlcKnowledgeRoot may resolve against the main checkout, so the parent
    # folder of that checkout counts too. A path check alone does not follow links, and a repository
    # can commit a symlink that points at a share. So no folder below the parent folder may be a link.
    param([string]$Path)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $separator = [IO.Path]::DirectorySeparatorChar
    $target = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).ProviderPath).TrimEnd('\', '/')
    $repos = @($RepoRoot, (Get-AiSdlcMainCheckoutRoot -RepoRoot $RepoRoot)) | Where-Object { $_ }
    foreach ($repo in $repos) {
        $repo = [IO.Path]::GetFullPath($repo).TrimEnd('\', '/')
        $parent = [IO.Path]::GetDirectoryName($repo)
        # A repository at a drive or share root has no parent folder, and its scope would be the whole
        # drive. So it gets no knowledge folder at all.
        if (-not $parent) { continue }
        $scope = $parent.TrimEnd('\', '/') + $separator
        # The parent folder itself is refused: it would open every other repository next to this one.
        if (($target + $separator).Length -le $scope.Length) { continue }
        if (-not ($target + $separator).StartsWith($scope, $comparison)) { continue }
        $linked = $false
        for ($folder = $target; $folder -and ($folder + $separator).Length -gt $scope.Length; $folder = [IO.Path]::GetDirectoryName($folder)) {
            if ((Get-Item -LiteralPath $folder -Force).LinkType) { $linked = $true; break }
        }
        if (-not $linked) { return $true }
    }
    return $false
}

function Sync-KnowledgeDirectory {
    $root = $config.paths.knowledgeRoot
    if (-not $root) { return }
    $full = Get-AiSdlcKnowledgeRoot -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        Write-Host "Knowledge folder: $root is not there, so the agent gets no read access to it. Clone the knowledge repository there to add it."
        return
    }
    if (-not (Test-KnowledgeRootAllowed -Path $full)) {
        Write-Host "Knowledge folder: $root is outside the parent folder of this repository, or reached through a link, so the agent gets no read access to it. A repository must not open a folder elsewhere on this machine or on a network share." -ForegroundColor Yellow
        Write-Host 'FIX: Clone the knowledge repository next to this repository and point paths.knowledgeRoot there. Or, when you trust the folder, add it by hand to permissions.additionalDirectories in .claude/settings.local.json.' -ForegroundColor Yellow
        return
    }
    # ProviderPath: .Path keeps the FileSystem:: prefix on a UNC path, which breaks the allow rule (#29).
    $full = (Resolve-Path -LiteralPath $full).ProviderPath.Replace('\', '/')
    $localPath = Join-Path $RepoRoot '.claude' 'settings.local.json'
    $local = [ordered]@{}
    if (Test-Path -LiteralPath $localPath -PathType Leaf) {
        $raw = Get-Content -LiteralPath $localPath -Raw
        if ($raw -and $raw.Trim()) {
            try { $local = $raw | ConvertFrom-Json -AsHashtable }
            catch {
                Write-Host "Knowledge folder: .claude/settings.local.json is not valid JSON, so the knowledge folder was not added: $($_.Exception.Message)" -ForegroundColor Yellow
                return
            }
        }
    }
    if (-not $local['permissions']) { $local['permissions'] = [ordered]@{} }
    $directories = @(if ($local['permissions']['additionalDirectories']) { $local['permissions']['additionalDirectories'] })
    if ($directories -contains $full) {
        Write-Host "Knowledge folder OK: .claude/settings.local.json lets the agent read $full."
        Protect-LocalSetting
        return
    }
    $local['permissions']['additionalDirectories'] = @($directories) + $full
    New-Item -ItemType Directory -Path (Split-Path -Parent $localPath) -Force | Out-Null
    $localJson = (ConvertTo-Json -InputObject $local -Depth 20) -replace "`r`n", "`n"
    [IO.File]::WriteAllText($localPath, "$localJson`n", [Text.UTF8Encoding]::new($false))
    Write-Host "Knowledge folder added: .claude/settings.local.json now lets the agent read $full. That file stays on this machine."
    Protect-LocalSetting
}

# A star glued to a path under .claude/skills, such as scripts/Check-*, scripts/Run.ps1* or
# skills/*/scripts, also matches a script that nobody reviewed, so such a rule is never allowed (#103).
$scriptsWildcard = '\.claude[\\/]skills[\\/]\S*\*'
# A rule that opens a whole shell, such as Bash(*) or pwsh *, is never written from a package either.
$wholeShell = '^(?:(?:Bash|PowerShell)\(\s*\*\s*\)|(?:(?:Bash|PowerShell)\()?\s*(?:pwsh|powershell|bash|sh|cmd)(?:\.exe)?\s+\*\s*\)?)$'

function ConvertTo-GateCommandArgument {
    # The arguments exactly as the gate entry passes them, so the rule allows that one command and no
    # other. A script that also writes files, such as Sync-AllowRules.ps1 without -Check, then still asks.
    param($Arguments)

    $parts = foreach ($key in @($Arguments.Keys | Sort-Object)) {
        if ($key -notmatch '^\w+$') { return $null }
        $value = $Arguments[$key]
        if ($value -is [bool]) { if ($value) { "-$key" }; continue }
        $items = @($value | ForEach-Object { [string]$_ })
        if (@($items | Where-Object { $_ -notmatch '^[\w./-]+$' }).Count -gt 0) { return $null }
        "-$key $($items -join ',')"
    }
    return (@($parts) -join ' ')
}

function ConvertTo-ShellRule {
    # A package entry becomes a Bash and a PowerShell rule, unless it already names its shell.
    param([string]$Entry)
    if ($Entry -match '^(Bash|PowerShell)\(.+\)$') { return @($Entry) }
    return @("Bash($Entry)", "PowerShell($Entry)")
}

$wanted = [System.Collections.Generic.List[string]]::new()
$wantedAsk = [System.Collections.Generic.List[string]]::new()
$retiredRules = [System.Collections.Generic.List[string]]::new()
$refused = [System.Collections.Generic.List[string]]::new()
# A rule that a release retired is never written again, also when an older pack still lists it (#108).
foreach ($package in $packages) {
    foreach ($entry in @($package.RetiredAllow)) {
        foreach ($rule in (ConvertTo-ShellRule -Entry ([string]$entry))) { if (-not $retiredRules.Contains($rule)) { $retiredRules.Add($rule) } }
    }
}
foreach ($package in $packages) {
    $entries = [System.Collections.Generic.List[string]]::new()
    # Each gate runs without a prompt, as its gate entry runs it: the exact script and the exact
    # arguments, with no star.
    if ($package.Skill -match '^[\w.-]+$') {
        foreach ($gate in @($package.Gates)) {
            $gateScript = ([string]$gate.script).Replace('\', '/')
            if ($gateScript -notmatch '^scripts/[\w.-]+\.ps1$') { continue }
            $arguments = if ($gate.args) { ConvertTo-GateCommandArgument -Arguments $gate.args } else { '' }
            if ($null -eq $arguments) { continue }
            $command = (".claude/skills/$($package.Skill)/$gateScript " + $arguments).TrimEnd()
            $entries.Add("pwsh -NoProfile -File $command")
            $entries.Add("pwsh $command")
        }
    }
    foreach ($entry in @($package.Allow)) { $entries.Add([string]$entry) }
    foreach ($entry in $entries) {
        if ($entry -match $scriptsWildcard -or $entry -match $wholeShell) {
            if (-not $refused.Contains($entry)) { $refused.Add($entry) }
            continue
        }
        foreach ($rule in (ConvertTo-ShellRule -Entry $entry)) {
            if (-not $wanted.Contains($rule) -and -not $retiredRules.Contains($rule)) { $wanted.Add($rule) }
        }
    }
    # An ask rule prompts even where an allow rule matches, so it narrows a wide allow rule, such as the
    # push of a story branch, back to the one form that is safe.
    foreach ($entry in @($package.Ask)) {
        foreach ($rule in (ConvertTo-ShellRule -Entry ([string]$entry))) { if (-not $wantedAsk.Contains($rule)) { $wantedAsk.Add($rule) } }
    }
}
foreach ($entry in $refused) {
    Write-Host "Allow rule not written: '$entry' holds a wildcard over a scripts folder or opens a whole shell. Name the script exactly, as in scripts/Run.ps1 *." -ForegroundColor Yellow
}

$settingsPath = Join-Path $RepoRoot '.claude' 'settings.json'
$settings = [ordered]@{}
if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
    $raw = Get-Content -LiteralPath $settingsPath -Raw
    if ($raw -and $raw.Trim()) {
        try { $settings = $raw | ConvertFrom-Json -AsHashtable }
        catch {
            Write-Host "Could not check: .claude/settings.json is not valid JSON: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host 'FIX: Correct the JSON in .claude/settings.json, then run the gate again.' -ForegroundColor Yellow
            exit 2
        }
    }
}
$allowed = @(if ($settings['permissions'] -and $settings['permissions']['allow']) { $settings['permissions']['allow'] })
$asked = @(if ($settings['permissions'] -and $settings['permissions']['ask']) { $settings['permissions']['ask'] })
$missing = @($wanted | Where-Object { $_ -cnotin $allowed })
$missingAsk = @($wantedAsk | Where-Object { $_ -cnotin $asked })
# Only a shell rule runs a script, so a Read or Edit rule under .claude/skills is left alone.
$wildcards = @($allowed | Where-Object { [string]$_ -match '^(?:Bash|PowerShell)\(' -and [string]$_ -match $scriptsWildcard })
$retiredFound = @($allowed | Where-Object { [string]$_ -cin $retiredRules })

# A rule that names the folder of a skill a release retired, .claude/skills/<old>/, runs a script that is
# gone. The installed sync manifest lists the retired names. A folder of that name that is still there
# keeps its rules.
$retiredSkills = @()
$manifestPath = Join-Path $SkillsRoot 'ai-sdlc-gates' 'sync-manifest.json'
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
        if ($manifest.Contains('retired') -and $manifest['retired']) { $retiredSkills = @($manifest['retired'].Keys) }
    }
    catch { Write-Host "Rules of retired skills not checked: $manifestPath is not valid JSON." -ForegroundColor Yellow }
}
$stale = @($allowed | Where-Object {
        $rule = [string]$_
        $rule -cnotin $wanted -and @([regex]::Matches($rule, '\.claude/skills/(?<skill>[A-Za-z0-9_.-]+)/') | Where-Object {
                $_.Groups['skill'].Value -in $retiredSkills -and -not (Test-Path -LiteralPath (Join-Path $SkillsRoot $_.Groups['skill'].Value))
            }).Count -gt 0
    })

if (-not $Check) { Sync-KnowledgeDirectory }

if ($packages.Count -eq 0) {
    Write-Host "Allow rules: not applicable, there is no installed package part, so there is no rule to hold .claude/settings.json against."
    exit 3
}

$drift = $missing.Count + $missingAsk.Count + $wildcards.Count + $retiredFound.Count
if ($drift -eq 0 -and $stale.Count -eq 0) {
    Write-Host "Allow rules OK: .claude/settings.json holds the $($wanted.Count) allow rule(s) and $($wantedAsk.Count) ask rule(s) of $($packages.Count) installed package part(s), no retired rule, and no rule that ends in a wildcard over a scripts folder."
    exit 0
}

if ($Check) {
    if ($missing.Count -gt 0) {
        Write-Host "Allow rules: .claude/settings.json misses $($missing.Count) rule(s) of the installed packages:" -ForegroundColor Red
        foreach ($rule in $missing) { Write-Host "  $rule" }
    }
    if ($missingAsk.Count -gt 0) {
        Write-Host "Allow rules: permissions.ask in .claude/settings.json misses $($missingAsk.Count) ask rule(s), so an allow rule next to them lets a wider command run without a prompt:" -ForegroundColor Red
        foreach ($rule in $missingAsk) { Write-Host "  $rule" }
    }
    if ($wildcards.Count -gt 0) {
        Write-Host "Allow rules: .claude/settings.json holds $($wildcards.Count) rule(s) that end in a wildcard over a scripts folder, so a new script there runs without a prompt:" -ForegroundColor Red
        foreach ($rule in $wildcards) { Write-Host "  $rule" }
    }
    if ($retiredFound.Count -gt 0) {
        Write-Host "Allow rules: .claude/settings.json holds $($retiredFound.Count) retired rule(s) that let a wide command run without a prompt, such as a push to the main branch:" -ForegroundColor Red
        foreach ($rule in $retiredFound) { Write-Host "  $rule" }
    }
    if ($stale.Count -gt 0) {
        Write-Host "Allow rules: .claude/settings.json also holds $($stale.Count) rule(s) of retired skills, which a run without -Check removes:"
        foreach ($rule in $stale) { Write-Host "  $rule" }
    }
    if ($drift -eq 0) { exit 0 }
    Write-Host 'FIX: Run pwsh .claude/skills/ai-sdlc-gates/scripts/Sync-AllowRules.ps1 and commit .claude/settings.json.' -ForegroundColor Red
    exit 1
}

if (-not $settings['permissions']) { $settings['permissions'] = [ordered]@{} }
$settings['permissions']['allow'] = @($allowed | Where-Object { $_ -cnotin $wildcards -and $_ -cnotin $retiredFound -and $_ -cnotin $stale }) + $missing
if ($wantedAsk.Count -gt 0 -or $asked.Count -gt 0) { $settings['permissions']['ask'] = @($asked) + $missingAsk }
New-Item -ItemType Directory -Path (Split-Path -Parent $settingsPath) -Force | Out-Null
$json = (ConvertTo-Json -InputObject $settings -Depth 20) -replace "`r`n", "`n"
[IO.File]::WriteAllText($settingsPath, "$json`n", [Text.UTF8Encoding]::new($false))
Write-Host ("Allow rules written: added $($missing.Count) allow rule(s) and $($missingAsk.Count) ask rule(s) of the installed packages to .claude/settings.json. " +
    "It removed $($wildcards.Count) rule(s) that end in a wildcard over a scripts folder, $($retiredFound.Count) retired rule(s) and $($stale.Count) rule(s) of retired skills. Commit that file.")
exit 0
