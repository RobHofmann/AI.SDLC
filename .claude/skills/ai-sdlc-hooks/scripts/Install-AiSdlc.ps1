#Requires -Version 7
<#
.SYNOPSIS
    Sets up a clone of this repository once: checks the prerequisites, installs APM, installs the shared
    AI-SDLC, and runs its setup.

.DESCRIPTION
    It ships in the core package, like every other AI-SDLC file. A fresh clone can still run it
    before APM is on the machine, because the repository commits the installed files under .claude/.
    Only a repository that has never installed the AI-SDLC lacks it; tools/Add-AiSdlcConsumer.ps1 in
    AI.SDLC sets that one up.

    1. It switches Windows long paths on when they are off (one administrator prompt), because APM
       fails on a deep path with WinError 3. It also gives two advisory rows that never stop the
       install: the GitHub CLI login (gh auth status), which the skills use for pull requests and
       issues, and the knowledge folder (paths.knowledgeRoot), with the gh repo clone command when
       knowledge.repository is set.
    2. It installs APM when it is missing, at the version that apm-version.json in the ai-sdlc-gates
       skill pins: Install-Apm.ps1 downloads the release asset for this machine, checks its SHA-256,
       and puts APM on the PATH. A failed install is reported, and apm install is skipped. When APM
       is already there, it compares apm --version with the pin, and warns with both versions when
       they differ. The warning says to take the pinned one with Install-Apm.ps1 -AddToPath.
    3. It runs apm install --frozen when apm.lock.yaml exists. That installs exactly the commits the
       lock records, and never rewrites the lock: it fails when apm.lock.yaml does not match apm.yml.
       It does not compare the content of the installed files with the lock; apm audit --ci in the
       pull request pipeline does that. With no apm.lock.yaml yet, it runs apm install, which writes one.
       A failed long-path check or APM install skips apm install: the script says so and exits 1.
    4. It runs Initialize-AiSdlc.ps1 from the installed core, which sets the git hooks and runs the
       setup of each installed pack.

    Update-AiSdlc.ps1 is the script that moves the lock to a new version on purpose.

.PARAMETER SkipApm
    Do not install APM or run apm install; only run the setup of the installed core.

.PARAMETER Minimal
    Passed to Initialize-AiSdlc.ps1: the git hooks and the checks; each pack setup runs but skips its installs.

.PARAMETER SkipRestore
    Passed to Initialize-AiSdlc.ps1: do not restore the NuGet packages.

.PARAMETER SkipGraphify
    Passed to Initialize-AiSdlc.ps1: skip the code graph setup of the dotnet pack.

.PARAMETER SkipGlobalGitConfig
    Passed to Initialize-AiSdlc.ps1: do not change the global git config.

.PARAMETER SkipLongPaths
    Leave Windows long paths alone. By default, on Windows, the script switches them on when they are
    off: it sets LongPathsEnabled to 1 under HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem, and asks
    once for administrator approval when the terminal is not elevated. It never asks in CI
    (GITHUB_ACTIONS or CI set). The setting holds for every process that starts after it.

.PARAMETER EnableLongPaths
    Kept so older instructions still work. Long paths are switched on by default now.

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-hooks/scripts/Install-AiSdlc.ps1

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-hooks/scripts/Install-AiSdlc.ps1 -SkipLongPaths

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-hooks/scripts/Install-AiSdlc.ps1 -SkipApm -Minimal
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$SkipApm,
    [switch]$Minimal,
    [switch]$SkipRestore,
    [switch]$SkipGraphify,
    [switch]$SkipGlobalGitConfig,
    [switch]$SkipLongPaths,
    [switch]$EnableLongPaths
)

$ErrorActionPreference = 'Stop'
$repoRoot = (git -C $PSScriptRoot rev-parse --show-toplevel).Trim()
$core = Join-Path $PSScriptRoot 'Initialize-AiSdlc.ps1'

$installApm = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts' 'Install-Apm.ps1'

$problems = [System.Collections.Generic.List[string]]::new()
. (Join-Path $PSScriptRoot 'WindowsLongPaths.ps1')
. (Join-Path $PSScriptRoot 'AiSdlcSetup.ps1')
$longPathProblem = Enable-WindowsLongPath -Skip:$SkipLongPaths
if ($longPathProblem) { $problems.Add($longPathProblem) }
foreach ($p in $problems) { Write-Host "Setup check: $p" -ForegroundColor Yellow }
foreach ($advice in @((Test-GitHubLogin), (Get-KnowledgeFolderHint -RepoRoot $repoRoot))) {
    if ($advice) { Write-Host "Setup advice: $advice" -ForegroundColor Yellow }
}

if (-not $SkipApm) {
    if (-not (Get-Command apm -ErrorAction SilentlyContinue) -and $PSCmdlet.ShouldProcess('APM', 'install the pinned release')) {
        $installProblem = $null
        if (-not (Test-Path -LiteralPath $installApm -PathType Leaf)) {
            $installProblem = "APM is missing, and so is the installer $installApm. Run apm install from a machine that has APM, or install the version in apm-version.json by hand."
        }
        else {
            try { & $installApm -AddToPath | ForEach-Object { Write-Host $_ } }
            catch { $installProblem = "APM could not be installed: $($_.Exception.Message)" }
        }
        if (-not $installProblem -and -not (Get-Command apm -ErrorAction SilentlyContinue)) {
            $installProblem = 'APM is still not found on the PATH after the install. Open a new terminal and run this script again.'
        }
        if ($installProblem) {
            $problems.Add($installProblem)
            Write-Host "Setup check: $installProblem" -ForegroundColor Yellow
        }
        else { Write-Host 'APM is installed.' }
    }
    $pinFile = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts' 'apm-version.json'
    if ((Get-Command apm -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $pinFile -PathType Leaf)) {
        $pinned = ((Get-Content -LiteralPath $pinFile -Raw | ConvertFrom-Json).version -replace '^v', '')
        $reported = (apm --version 2>&1 | Out-String)
        $installed = [regex]::Match($reported, '\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?').Value
        $takePin = "Take the pinned one with pwsh .claude/skills/ai-sdlc-gates/scripts/Install-Apm.ps1 -AddToPath, then open a new terminal."
        if (-not $installed) {
            Write-Host "Setup check: apm --version gave no version, so it is not known whether APM matches the pinned $pinned in apm-version.json. $takePin" -ForegroundColor Yellow
        }
        elseif ($installed -ne $pinned) {
            Write-Host "Setup check: APM $installed is on the PATH, but apm-version.json pins APM $pinned. $takePin" -ForegroundColor Yellow
        }
    }
    if ((Get-Command apm -ErrorAction SilentlyContinue) -and $problems.Count -eq 0 -and $PSCmdlet.ShouldProcess('apm install', 'run')) {
        $frozen = Test-Path -LiteralPath (Join-Path $repoRoot 'apm.lock.yaml') -PathType Leaf
        [string[]]$installArgs = if ($frozen) { @('install', '--frozen') } else { @('install') }
        if (-not $frozen) { Write-Host 'No apm.lock.yaml yet, so apm install resolves apm.yml and writes one. Commit it.' -ForegroundColor Yellow }
        Push-Location $repoRoot
        try { apm @installArgs } finally { Pop-Location }
        if ($LASTEXITCODE -ne 0) {
            $hint = Get-ApmInstallFailureHint -ExitCode $LASTEXITCODE
            if ($frozen) { $hint += ' With --frozen it also fails when apm.lock.yaml does not match apm.yml; take a new version with Update-AiSdlc.ps1, which moves both.' }
            throw $hint
        }
    }
}
$apmSkipped = -not $SkipApm -and -not $WhatIfPreference -and $problems.Count -gt 0
if ($apmSkipped) { Write-Host 'apm install did not run, because of the setup checks above. Fix them and run this script again.' -ForegroundColor Yellow }

if (-not (Test-Path -LiteralPath $core)) { throw "The installed core is missing: $core. Run apm install." }
$coreArgs = @{}
foreach ($name in 'Minimal', 'SkipRestore', 'SkipGraphify', 'SkipGlobalGitConfig') { if ($PSBoundParameters.ContainsKey($name)) { $coreArgs[$name] = $true } }
if ($WhatIfPreference) { $coreArgs['WhatIf'] = $true }
& $core @coreArgs
$coreExit = $LASTEXITCODE
Write-Host 'Next: start Claude Code or GitHub Copilot in the root folder of this repository. In Copilot, trust this folder when it asks: Copilot runs the agent hooks only in a trusted folder, and only in a session that starts in the root folder.'
exit $(if ($apmSkipped -and $coreExit -eq 0) { 1 } else { $coreExit })
