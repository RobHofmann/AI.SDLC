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

    It only adds rules. A rule the repository added itself stays, and so does a rule of a package that
    is no longer installed; remove those by hand. The rest of .claude/settings.json, such as the hooks
    APM writes, is never changed.

    Without -Check it also lets the agent read the knowledge repository. When the folder in
    paths.knowledgeRoot exists, its absolute path goes into permissions.additionalDirectories of
    .claude/settings.local.json. That file is per machine and untracked, because the path differs per
    machine; the script never writes it into .claude/settings.json. The rest of settings.local.json
    stays as it is.

    With -Check it writes nothing. It exits 1 when a rule of an installed package is missing. The
    knowledge folder is not checked, because CI never has it.

    Exit codes follow the gate contract: 0 in sync (or written), 1 a rule missing, 2 could not check.

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

function Sync-KnowledgeDirectory {
    $root = $config.paths.knowledgeRoot
    if (-not $root) { return }
    $full = if ([IO.Path]::IsPathRooted($root)) { $root } else { Join-Path $RepoRoot $root }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        Write-Host "Knowledge folder: $root is not there, so the agent gets no read access to it. Clone the knowledge repository there to add it."
        return
    }
    $full = (Resolve-Path -LiteralPath $full).Path.Replace('\', '/')
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

$wanted = [System.Collections.Generic.List[string]]::new()
foreach ($package in $packages) {
    foreach ($entry in @($package.Allow)) {
        $rules = if ($entry -match '^(Bash|PowerShell)\(.+\)$') { @($entry) } else { @("Bash($entry)", "PowerShell($entry)") }
        foreach ($rule in $rules) { if (-not $wanted.Contains($rule)) { $wanted.Add($rule) } }
    }
}

$settingsPath = Join-Path $RepoRoot '.claude' 'settings.json'
$settings = [ordered]@{}
if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
    $raw = Get-Content -LiteralPath $settingsPath -Raw
    if ($raw -and $raw.Trim()) {
        try { $settings = $raw | ConvertFrom-Json -AsHashtable }
        catch {
            Write-Host "Could not check: .claude/settings.json is not valid JSON: $($_.Exception.Message)" -ForegroundColor Yellow
            exit 2
        }
    }
}
$allowed = @(if ($settings['permissions'] -and $settings['permissions']['allow']) { $settings['permissions']['allow'] })
$missing = @($wanted | Where-Object { $_ -notin $allowed })

if (-not $Check) { Sync-KnowledgeDirectory }

if ($missing.Count -eq 0) {
    Write-Host "Allow rules OK: .claude/settings.json holds the $($wanted.Count) rule(s) of $($packages.Count) installed package part(s)."
    exit 0
}

if ($Check) {
    Write-Host "Allow rules: .claude/settings.json misses $($missing.Count) rule(s) of the installed packages:" -ForegroundColor Red
    foreach ($rule in $missing) { Write-Host "  $rule" }
    Write-Host 'FIX: Run pwsh .claude/skills/ai-sdlc-gates/scripts/Sync-AllowRules.ps1 and commit .claude/settings.json.' -ForegroundColor Red
    exit 1
}

if (-not $settings['permissions']) { $settings['permissions'] = [ordered]@{} }
$settings['permissions']['allow'] = @($allowed) + $missing
New-Item -ItemType Directory -Path (Split-Path -Parent $settingsPath) -Force | Out-Null
$json = (ConvertTo-Json -InputObject $settings -Depth 20) -replace "`r`n", "`n"
[IO.File]::WriteAllText($settingsPath, "$json`n", [Text.UTF8Encoding]::new($false))
Write-Host "Allow rules written: added $($missing.Count) rule(s) of the installed packages to .claude/settings.json. Commit that file."
exit 0
