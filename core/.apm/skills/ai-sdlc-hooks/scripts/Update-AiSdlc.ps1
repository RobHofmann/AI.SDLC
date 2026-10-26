#Requires -Version 7
<#
.SYNOPSIS
    Takes a new version of the shared AI-SDLC in one step: moves the AI.SDLC refs in apm.yml to the new
    tag, installs it, and stages the result for one commit.

.DESCRIPTION
    Taking a new version by hand is seven steps, and a missed one fails the pull request build. This
    script does them in order and stops at the first one that fails:

    1. It switches Windows long paths on when they are off. A public AI.SDLC source needs no login. A
       private source needs a token in GITHUB_APM_PAT, which APM reads; the script does not check it.

    When apm.yml is already on the tag, it says so and changes nothing. Otherwise it checks that apm is
    on the PATH before it changes a file, and names Install-Apm.ps1 -AddToPath when it is not.

    2. It sets the ref: of each AI.SDLC dependency in apm.yml to the new tag. The AI.SDLC source is the
       git: URL of the first "- git:" dependency with path: core; every dependency with that same URL
       moves. A dependency from any other source keeps its ref.
    3. It runs apm install, which resolves the changed refs and writes apm.lock.yaml. Then it runs
       apm audit --ci, which fails when the lock, apm.yml and the installed files do not agree.
    4. It stages apm.yml, apm.lock.yaml and the installed files under .claude/, and marks the git hooks
       executable, which APM does not keep.
    5. It writes the shared parts of AGENTS.md with Sync-AgentsFile.ps1 and stages the file. When the
       root CLAUDE.md only imports AGENTS.md, Sync-AgentsFile.ps1 moves that import to .claude/CLAUDE.md
       and stages the move. Claude Code reads both places, and GitHub Copilot then reads AGENTS.md once.
       It also writes the allow rules of the installed packages into .claude/settings.json with
       Sync-AllowRules.ps1, and stages that file.
    6. It runs Find-RetiredSkillNames.ps1 of the new version. That lists each line in the repository's
       own files that still uses a skill name a release retired, with the new name. It is advice only:
       the person fixes those lines, and the script changes none of them.
    7. It runs the blocking gates, so a gate that the new version adds fails here and not in the build.

    Nothing is committed or pushed. The script prints the commit to make on a story branch.

.PARAMETER Ref
    The AI.SDLC tag to take, for example v1.2.0. Defaults to the newest tag without a suffix on the
    AI.SDLC source that apm.yml names.

.PARAMETER IncludePreRelease
    With no -Ref, also consider tags with a suffix, such as v1.2.0-rc.1.

.PARAMETER RepoRoot
    The repository root. Defaults to the git root of this script.

.PARAMETER NoGates
    Do not run the blocking gates at the end.

.PARAMETER SkipLongPaths
    Leave Windows long paths alone. By default the script switches them on when they are off, the same
    way Install-AiSdlc.ps1 does (WindowsLongPaths.ps1), because apm install needs them.

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-hooks/scripts/Update-AiSdlc.ps1

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-hooks/scripts/Update-AiSdlc.ps1 -Ref v1.2.0
#>
[CmdletBinding()]
param(
    [string]$Ref,
    [switch]$IncludePreRelease,
    [string]$RepoRoot,
    [switch]$NoGates,
    [switch]$SkipLongPaths
)

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = (git -C $PSScriptRoot rev-parse --show-toplevel).Trim() }
$gatesScripts = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
. (Join-Path $PSScriptRoot 'WindowsLongPaths.ps1')
. (Join-Path $PSScriptRoot 'AiSdlcSetup.ps1')
$pin = Get-AiSdlcPin -RepoRoot $RepoRoot
$longPathProblem = Enable-WindowsLongPath -Skip:$SkipLongPaths
if ($longPathProblem) { throw $longPathProblem }

$apmPath = $pin.Path
$newline = $pin.Newline
$apmLines = $pin.Lines
$dependencies = @($pin.Dependencies)
$url = $pin.Url
$current = @($pin.Current)
if (-not $Ref) { $Ref = Get-AiSdlcReleaseTag -Url $url -IncludePreRelease:$IncludePreRelease }

$apmOnRef = $current.Count -eq 1 -and $current[0] -eq $Ref -and $pin.AllPinned
if ($apmOnRef) {
    Write-Host "Already on $Ref; nothing to update."
    exit 0
}

if (-not (Get-Command apm -ErrorAction SilentlyContinue)) {
    throw 'APM is not on the PATH, so apm install cannot run. Nothing is changed. Run pwsh .claude/skills/ai-sdlc-gates/scripts/Install-Apm.ps1 -AddToPath, open a new terminal, then run this again.'
}

Write-Host "Updating the shared AI-SDLC from $($current -join ', ') to $Ref."
$moved = 0
foreach ($dependency in @($dependencies | Where-Object { $_.Url -eq $url })) {
    if ($dependency.RefLine -lt 0) {
        Write-Host "A dependency on $url has no ref:, so APM takes its default branch. Add ref: $Ref to it by hand." -ForegroundColor Yellow
        continue
    }
    $apmLines[$dependency.RefLine] = $apmLines[$dependency.RefLine] -replace '^(\s+ref:\s*)[^\s#]+', "`${1}$Ref"
    $moved++
}
[IO.File]::WriteAllText($apmPath, ($apmLines -join $newline), [Text.UTF8Encoding]::new($false))
Write-Host "Moved $moved AI.SDLC ref(s) in apm.yml to $Ref; the refs of other sources stay as they are."

Push-Location $RepoRoot
try {
    apm install
    if ($LASTEXITCODE -ne 0) { throw (Get-ApmInstallFailureHint -ExitCode $LASTEXITCODE) }
    apm audit --ci
    if ($LASTEXITCODE -ne 0) {
        throw "apm audit --ci failed with exit code $LASTEXITCODE, so apm.yml, apm.lock.yaml and the installed files under .claude/ do not agree. Read its output above. Nothing is staged yet."
    }
    foreach ($p in @('apm.yml', 'apm.lock.yaml', '.claude')) {
        if (Test-Path -LiteralPath (Join-Path $RepoRoot $p)) { git add -- $p }
    }
    Set-GitHookExecutable -RepoRoot $RepoRoot | Out-Null

    $sync = Join-Path $gatesScripts 'Sync-AgentsFile.ps1'
    if (Test-Path -LiteralPath $sync) {
        pwsh -NoProfile -File $sync -RepoRoot $RepoRoot
        if ($LASTEXITCODE -ne 0) { throw "Sync-AgentsFile.ps1 failed with exit code $LASTEXITCODE." }
        git add -- AGENTS.md
    }

    $allow = Join-Path $gatesScripts 'Sync-AllowRules.ps1'
    if (Test-Path -LiteralPath $allow) {
        pwsh -NoProfile -File $allow -RepoRoot $RepoRoot
        if ($LASTEXITCODE -ne 0) { throw "Sync-AllowRules.ps1 failed with exit code $LASTEXITCODE." }
        git add -- .claude/settings.json
    }

    $finder = Join-Path $PSScriptRoot 'Find-RetiredSkillNames.ps1'
    if (Test-Path -LiteralPath $finder) { pwsh -NoProfile -File $finder -RepoRoot $RepoRoot }

    $gatesFailed = $false
    if (-not $NoGates) {
        $runner = Join-Path $gatesScripts 'Invoke-LocalGates.ps1'
        if (Test-Path -LiteralPath $runner) {
            pwsh -NoProfile -File $runner -RepoRoot $RepoRoot -BlockingOnly
            $gatesFailed = $LASTEXITCODE -ne 0
        }
    }
}
finally { Pop-Location }

Write-Host ''
Write-Host "Staged the shared AI-SDLC at $Ref."
if ($gatesFailed) {
    Write-Host 'A blocking gate failed on the new version. Fix what it names before you commit; a gate that is new in this version may need a change in this repository.' -ForegroundColor Yellow
    exit 1
}
Write-Host "Next: commit on a story branch, for example: git commit -m `"Take the shared AI-SDLC at $Ref`", then run the pre-flight and open a pull request."
exit 0
