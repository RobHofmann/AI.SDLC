#Requires -Version 7
<#
.SYNOPSIS
    Defines the setup checks that Install-AiSdlc.ps1, Update-AiSdlc.ps1, New-AiSdlcUpdatePullRequest.ps1
    and tools/Add-AiSdlcConsumer.ps1 share: the GitHub CLI login, the knowledge folder, the hint for a
    failed apm install, the executable bit of the git hooks, and the AI.SDLC pins in apm.yml.

.DESCRIPTION
    Each rule lives here once, so the scripts that set up or update a repository give the same advice.
    Dot-source the file, the way WindowsLongPaths.ps1 is dot-sourced:

    Test-GitHubLogin
        Returns $null when the GitHub CLI (gh) is installed and gh auth status passes, because the
        skills open pull requests and read issues with gh. Otherwise it returns one line that says
        what to run. The check is advisory: a missing login never stops apm install.

    Get-KnowledgeFolderHint -RepoRoot <path>
        Returns $null when the folder in paths.knowledgeRoot of aisdlc.json exists. Otherwise it returns
        one advisory line, with the gh repo clone command when knowledge.repository is set.

    Get-ApmInstallFailureHint -ExitCode <n>
        Returns the message for a failed apm install: its exit code and the two usual causes, a private
        AI.SDLC source without a token and Windows long paths that are off.

    Set-GitHookExecutable -RepoRoot <path>
        Marks each git hook under .claude/skills/ai-sdlc-hooks/githooks as executable in the git index,
        because APM does not keep the executable bit. Only a hook that git tracks can be marked, so a
        caller stages the hooks first. It returns the paths it marked.

    Get-AiSdlcPin -RepoRoot <path>
        Reads apm.yml. The AI.SDLC source is the git: URL of the first "- git:" dependency with path:
        core. It returns that Url, the refs (Current) its dependencies pin, the Lines of apm.yml, its
        Newline, and every git: Dependency with its Url, Path and the index of its ref: line (RefLine,
        -1 when it has none). It throws when apm.yml or the core dependency is missing.

    Get-AiSdlcReleaseTag -Url <git url> [-IncludePreRelease]
        Returns the newest tag vX.Y.Z on the source, read with git ls-remote. A tag with a suffix, such
        as v1.2.0-rc.1, counts only with -IncludePreRelease. It throws when there is none.

.EXAMPLE
    . (Join-Path $PSScriptRoot 'AiSdlcSetup.ps1')
    $advice = Test-GitHubLogin
    if ($advice) { Write-Host $advice }

.EXAMPLE
    . (Join-Path $PSScriptRoot 'AiSdlcSetup.ps1')
    apm install
    if ($LASTEXITCODE -ne 0) { throw (Get-ApmInstallFailureHint -ExitCode $LASTEXITCODE) }
#>

$script:GitHookFolder = '.claude/skills/ai-sdlc-hooks/githooks'

function Test-GitHubLogin {
    [CmdletBinding()]
    param()

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        return 'The GitHub CLI (gh) is missing, and the skills open pull requests and read issues with it. Install it, then run gh auth login.'
    }
    gh auth status *> $null
    if ($LASTEXITCODE -eq 0) { return $null }
    return 'The GitHub CLI has no valid login, and the skills open pull requests and read issues with it. Run gh auth login, then gh auth status to check it.'
}

function Get-KnowledgeFolderHint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $module = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts' 'AiSdlcConfig.psm1'
    if (-not (Test-Path -LiteralPath $module -PathType Leaf)) { return $null }
    Import-Module $module -Force
    $config = Get-AiSdlcConfig -RepoRoot $RepoRoot
    $root = [string]$config.paths.knowledgeRoot
    if (-not $root) { return $null }
    $full = if ([IO.Path]::IsPathRooted($root)) { $root } else { Join-Path $RepoRoot $root }
    if (Test-Path -LiteralPath $full -PathType Container) { return $null }
    $hint = "The knowledge folder $root is not there, so the skills search only the docs of this repository."
    if ($config.knowledge.repository) { return "$hint Clone it with: gh repo clone $($config.knowledge.repository) $root" }
    return "$hint Set knowledge.repository in aisdlc.json to name the repository to clone there."
}

function Get-ApmInstallFailureHint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ExitCode)

    return ("apm install failed with exit code $ExitCode. Read its output above: 'Authentication failed' on a private AI.SDLC source needs a token in GITHUB_APM_PAT; " +
        'WinError 206 or WinError 3 means Windows long paths are off, so set LongPathsEnabled to 1 under ' +
        'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem as administrator and open a new terminal.')
}

function Get-AiSdlcDependency {
    [CmdletBinding()]
    param([string[]]$Lines)

    $items = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $start = [regex]::Match($Lines[$i], '^(?<indent>\s*)-\s+git:\s*(?<url>[^\s#]+)')
        if (-not $start.Success) { continue }
        $indent = $start.Groups['indent'].Value.Length
        $item = [pscustomobject]@{ Url = $start.Groups['url'].Value.Trim('''', '"'); Path = $null; RefLine = -1 }
        for ($j = $i + 1; $j -lt $Lines.Count; $j++) {
            $line = $Lines[$j]
            if ($line.Trim() -and ($line.Length - $line.TrimStart().Length) -le $indent) { break }
            $key = [regex]::Match($line, '^\s+(?<key>path|ref):\s*(?<value>[^\s#]*)')
            if (-not $key.Success) { continue }
            if ($key.Groups['key'].Value -eq 'path') { $item.Path = $key.Groups['value'].Value.Trim('''', '"') }
            else { $item.RefLine = $j }
        }
        $items.Add($item)
    }
    return $items
}

function Get-AiSdlcPin {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $apmPath = Join-Path $RepoRoot 'apm.yml'
    if (-not (Test-Path -LiteralPath $apmPath)) { throw "No apm.yml in $RepoRoot. Add the AI-SDLC first with tools/Add-AiSdlcConsumer.ps1 in AI.SDLC." }
    $apm = Get-Content -LiteralPath $apmPath -Raw
    $lines = [string[]]($apm -split "`r?`n")
    $dependencies = @(Get-AiSdlcDependency -Lines $lines)
    $core = @($dependencies | Where-Object { $_.Path -eq 'core' }) | Select-Object -First 1
    if (-not $core) { throw 'apm.yml has no "- git:" dependency with path: core, so the AI.SDLC source is not known. Nothing is changed.' }
    $pinned = @($dependencies | Where-Object { $_.Url -eq $core.Url -and $_.RefLine -ge 0 })
    $current = @($pinned | ForEach-Object { ([regex]::Match($lines[$_.RefLine], 'ref:\s*(?<v>[^\s#]+)').Groups['v'].Value).Trim('''', '"') } | Select-Object -Unique)
    return [pscustomobject]@{
        Path         = $apmPath
        Url          = $core.Url
        Current      = $current
        Lines        = $lines
        Newline      = if ($apm -match "`r`n") { "`r`n" } else { "`n" }
        Dependencies = $dependencies
        AllPinned    = $pinned.Count -eq @($dependencies | Where-Object { $_.Url -eq $core.Url }).Count
    }
}

function Get-AiSdlcReleaseTag {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url, [switch]$IncludePreRelease)

    $tags = @(git ls-remote --tags --refs $Url 2>$null | ForEach-Object { ($_ -split 'refs/tags/')[-1] } | Where-Object { $_ -match '^v\d+\.\d+\.\d+' })
    if (-not $IncludePreRelease) { $tags = @($tags | Where-Object { $_ -notmatch '-' }) }
    $tag = $tags | Sort-Object { [version](($_ -replace '^v', '') -replace '-.*$', '') }, { $_ } | Select-Object -Last 1
    if (-not $tag) { throw "No release tag found on $Url. Pass -Ref, or -IncludePreRelease for a pre-release." }
    return $tag
}

function Set-GitHookExecutable {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $folder = Join-Path $RepoRoot $script:GitHookFolder
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { return @() }
    $present = @(Get-ChildItem -LiteralPath $folder -File | ForEach-Object { "$($script:GitHookFolder)/$($_.Name)" })
    if ($present.Count -eq 0) { return @() }
    $tracked = @(git -C $RepoRoot ls-files -- @present)
    if ($tracked.Count -eq 0) { return @() }
    if (-not $PSCmdlet.ShouldProcess(($tracked -join ', '), 'mark executable in the git index')) { return @() }
    git -C $RepoRoot update-index --chmod=+x -- @tracked
    if ($LASTEXITCODE -ne 0) { throw "git update-index --chmod=+x failed with exit code $LASTEXITCODE for $($tracked -join ', ')." }
    return $tracked
}
