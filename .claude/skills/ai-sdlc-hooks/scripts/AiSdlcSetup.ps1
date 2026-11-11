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

    Test-AiSdlcNetworkPath -RepoRoot <path>
        Returns $true when the repository is on a network share: git prints its root as //host/share,
        also for a mapped drive letter. The pre-push hook uses the same rule.

    Invoke-ApmInstall -RepoRoot <path> [-Arguments <apm arguments>]
        Runs apm (install by default) for the repository and returns its exit code. On a network share
        it runs apm in a temporary local git worktree of HEAD, with the working copies of apm.yml,
        apm.lock.yaml, aisdlc.json, .mcp.json and .claude/settings.json. Then it copies each file of the new
        lock that differs from the share, and removes each file that only the old lock listed. On a share,
        APM 0.31.0 left changed skill folders empty. The environment variable AISDLC_APM_LOCAL_INSTALL=1
        forces the worktree, and =0 turns it off.

    Get-ApmDeployedFile -LockPath <apm.lock.yaml>
        Returns the paths under deployed_files in an APM lock: the files and folders APM installed.

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

function Test-AiSdlcNetworkPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)

    # The same rule as is_network_path in the pre-push hook: git prints the root of a repository on a share
    # as //host/share/..., also for a mapped drive letter.
    $top = try { [string](git -C $RepoRoot rev-parse --show-toplevel 2>$null) } catch { '' }
    $top = $top.Trim()
    return $top.StartsWith('//') -or $top.StartsWith('\\')
}

function Get-ApmDeployedFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LockPath)

    if (-not (Test-Path -LiteralPath $LockPath -PathType Leaf)) { return @() }
    $paths = [Collections.Generic.List[string]]::new()
    $inList = $false
    foreach ($line in [IO.File]::ReadAllLines($LockPath)) {
        if ($line -match '^\s*deployed_files:\s*$') { $inList = $true; continue }
        if (-not $inList) { continue }
        if ($line -match '^\s*-\s+(\S.*?)\s*$') { $paths.Add($Matches[1].Trim([char[]]"'`"")); continue }
        $inList = $false
    }
    return @($paths | Select-Object -Unique)
}

function Invoke-ApmInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string[]]$Arguments = @('install'),
        # When given, apm audit --ci runs after a good install, in the same folder, and its exit code goes here.
        # On a share that folder is the worktree: only there does apm_modules exist, so an audit on the share
        # itself fails on a good install.
        [ref]$AuditCode
    )

    $want = $env:AISDLC_APM_LOCAL_INSTALL
    $useLocal = if ($want -eq '1') { $true } elseif ($want -eq '0') { $false } else { Test-AiSdlcNetworkPath -RepoRoot $RepoRoot }

    if (-not $useLocal) {
        Push-Location -LiteralPath $RepoRoot
        try {
            apm @Arguments | Out-Host
            $code = $LASTEXITCODE
            if ($code -eq 0 -and $AuditCode) {
                apm audit --ci | Out-Host
                $AuditCode.Value = $LASTEXITCODE
            }
        }
        finally { Pop-Location }
        return $code
    }

    # On a share, APM 0.31.0 reported a good install but left the changed skill folders empty, and its lock
    # listed those folders instead of their files, so a second run skipped them. The same install on a local
    # disk was correct. So APM runs in a local git worktree of HEAD, with the working copies of the files it
    # reads or merges into. Then the files of the new lock are carried back where they differ from the share,
    # and the files that only the old lock listed are removed. The share's working copy can differ from HEAD,
    # so the comparison is with the share itself, not with HEAD.
    $own = @('apm.yml', 'apm.lock.yaml', 'aisdlc.json', '.mcp.json', '.claude/settings.json')
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('aisdlc-apm-' + [guid]::NewGuid().ToString('n'))
    $worktree = Join-Path $temp 'wt'
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    try {
        git -C $RepoRoot worktree add --quiet --detach $worktree HEAD 2>$null
        if ($LASTEXITCODE -ne 0) { throw "git worktree add failed with exit code $LASTEXITCODE, so apm install did not run." }
        foreach ($name in $own) {
            $source = Join-Path $RepoRoot $name
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }
            $copy = Join-Path $worktree $name
            New-Item -ItemType Directory -Path (Split-Path -Parent $copy) -Force | Out-Null
            Copy-Item -LiteralPath $source -Destination $copy -Force
        }
        $before = @(Get-ApmDeployedFile -LockPath (Join-Path $RepoRoot 'apm.lock.yaml'))
        Write-Host "apm runs in a local worktree, because the repository is on a network share: $worktree"
        Push-Location -LiteralPath $worktree
        try {
            apm @Arguments | Out-Host
            $code = $LASTEXITCODE
            if ($code -eq 0 -and $AuditCode) {
                apm audit --ci | Out-Host
                $AuditCode.Value = $LASTEXITCODE
            }
        }
        finally { Pop-Location }
        if ($code -ne 0) { return $code }
        # A failed audit leaves the share as it was, so the caller can stop with nothing changed.
        if ($AuditCode -and $AuditCode.Value -ne 0) { return 0 }
        $after = @(Get-ApmDeployedFile -LockPath (Join-Path $worktree 'apm.lock.yaml'))

        foreach ($path in @($after + $own | Select-Object -Unique)) {
            $source = Join-Path $worktree $path
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }
            $target = Join-Path $RepoRoot $path
            if ((Test-Path -LiteralPath $target -PathType Leaf) -and
                (Get-FileHash -LiteralPath $target).Hash -eq (Get-FileHash -LiteralPath $source).Hash) { continue }
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            Copy-Item -LiteralPath $source -Destination $target -Force
        }
        foreach ($path in @($before | Where-Object { $_ -notin $after })) {
            $target = Join-Path $RepoRoot $path
            if (Test-Path -LiteralPath $target -PathType Leaf) { Remove-Item -LiteralPath $target -Force }
        }
        return 0
    }
    finally {
        git -C $RepoRoot worktree remove --force $worktree 2>$null | Out-Null
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
        git -C $RepoRoot worktree prune 2>$null | Out-Null
    }
}
