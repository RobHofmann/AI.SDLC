#Requires -Version 7
<#
.SYNOPSIS
    Runs the gates of the installed AI-SDLC packages and of the repository locally, and prints a single
    pass/fail summary.

.DESCRIPTION
    A developer convenience: one command to check a change against every gate before pushing, instead
    of waiting for CI. Blocking gates (structure, docs, house-style) fail this run on a violation;
    advisory gates are reported but never fail the local run, matching CI behaviour.

    The gates run side by side, one thread per processor core, because no gate depends on another.
    The output of each gate is printed after the run, in the order of the list, so two gates never mix
    their lines.

    The runner does not hold a list of gates itself. Each installed package declares its gates in a
    gates.json file in one of its skills, for example ai-sdlc-gates/gates.json for the core. The runner
    reads every <SkillsRoot>/*/gates.json and runs the gates of the core and of each pack that
    apm.yml lists. A pack that is installed but not listed runs no gate, and a repository with no
    .NET solution never runs a .NET gate. The repository's own gates come from "repoGates" in aisdlc.json.

    A gates.json entry names the script relative to its skill folder:

        { "package": "core", "gates": [
            { "name": "C06 no em-dash characters", "script": "scripts/Check-DocEmDashes.ps1",
              "clause": "C06", "mode": "Blocking", "args": { } } ] }

    A "repoGates" entry has the same fields, with the script relative to the repository root. An entry
    with "requires": "CoverageFile" runs only when -CoverageFile is passed, and gets it as an argument.

    A gates.json can also name three hooks for the core scripts, each relative to its skill folder.
    The gate list may then be empty, for a package that only needs a hook:

        "setup": "scripts/Initialize-Dotnet.ps1"
            Initialize-AiSdlc.ps1 runs it for each package that runs.
        "preflight": "scripts/Invoke-DotnetPreflight.ps1"
            Invoke-Preflight.ps1 runs it for each package that runs, and folds its result rows into
            the same report and receipt decision.
        "postEdit": { "extensions": [".cs", ".razor"], "script": "scripts/Invoke-DotnetPostEdit.ps1" }
            Invoke-PostEditCheck.ps1 runs it for an edited file with one of those extensions.

    With -IncludeToolTests the runner runs the Pester tests in the scripts folder of every package
    that runs, and in the folder of each repository gate.

    Where a gate runs follows from its mode. The pre-push git hook runs the Blocking gates
    (-BlockingOnly), unless a passing pre-flight receipt covers the tip commit of each pushed ref. The
    shared pull request action (assets/actions/ai-sdlc-pr) and a local run run every gate; an Advisory
    gate reports but never fails either one. -List prints this for each gate. A
    repository gate that runs Pester tests can use Invoke-PesterGate.ps1 from this folder as its script.

    In GitHub Actions (GITHUB_ACTIONS is true) the runner reports each gate the way Invoke-Gate.ps1
    does, through GateAnnotation.psm1: an error for a Blocking gate that failed or stopped, and a
    warning for an Advisory gate that found issues and for a gate that could not check (exit 2). It
    also adds the summary table to the job summary ($GITHUB_STEP_SUMMARY). The result is the exit code:
    1 when a Blocking gate failed, else 0. A gate script that stops with an error fails the run as a
    fault in the gate, in a local run too, instead of stopping the runner.

.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from the current location.

.PARAMETER SkillsRoot
    Where the packages are installed. Defaults to <RepoRoot>/.claude/skills.

.PARAMETER CoverageFile
    Optional path to a merged coverage report, for the gates that need one.

.PARAMETER IncludeToolTests
    Also run the Pester tests of the gate scripts of every package that runs.

.PARAMETER SkipTests
    Leave out the gates that run Pester tests: a gate whose script is Invoke-PesterGate.ps1 or
    Invoke-PesterParallel.ps1. The summary lists them as SKIP. wrap-up uses it for its quick check,
    because the pre-flight runs those tests on the commit.

.PARAMETER BlockingOnly
    Run only the blocking gates, as the pre-push hook does.

.PARAMETER List
    Print the gates that would run, with their package, mode and clause and where each one runs
    (pre-push, pull request, local run), and run none. It also lists a gate that needs -CoverageFile.

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1 -IncludeToolTests
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$SkillsRoot,
    [string]$CoverageFile,
    [switch]$IncludeToolTests,
    [switch]$BlockingOnly,
    [switch]$SkipTests,
    [switch]$List
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'GateAnnotation.psm1') -Force

$config = Get-AiSdlcConfig -RepoRoot $RepoRoot -StartPath (Get-Location).Path
$RepoRoot = $config.repoRoot
if (-not $SkillsRoot) { $SkillsRoot = Join-Path $RepoRoot '.claude' 'skills' }
$inPipeline = $env:GITHUB_ACTIONS -eq 'true'

$gates = [System.Collections.Generic.List[object]]::new()
$testFolders = [System.Collections.Generic.List[string]]::new()

function Add-Gate {
    param($Entry, [string]$Package, [string]$Base)

    $needsCoverage = $Entry.requires -eq 'CoverageFile'
    if ($needsCoverage -and -not $CoverageFile -and -not $List) { return }
    $gateArgs = @{ RepoRoot = $RepoRoot }
    if ($Entry.args) { foreach ($key in $Entry.args.Keys) { $gateArgs[$key] = $Entry.args[$key] } }
    if ($needsCoverage -and $CoverageFile) { $gateArgs['CoverageFile'] = $CoverageFile }
    $gates.Add([pscustomobject]@{
            Name          = $Entry.name
            Package       = $Package
            Script        = Join-Path $Base $Entry.script
            Args          = $gateArgs
            Mode          = if ($Entry.mode) { $Entry.mode } else { 'Blocking' }
            Clause        = if ($Entry.clause) { [string]$Entry.clause } else { $Package }
            NeedsCoverage = $needsCoverage
        })
}

function Get-GateStage {
    param($Gate)

    if ($Gate.NeedsCoverage) { return 'only with -CoverageFile: the dotnet pre-flight, and the pull request action with coverage-file' }
    if ($Gate.Mode -eq 'Blocking') { return 'pre-push, pull request, local run' }
    return 'pull request (as a warning), local run'
}

$manifests = @(Get-AiSdlcPackage -RepoRoot $RepoRoot -SkillsRoot $SkillsRoot -All)

foreach ($manifest in @($manifests | Where-Object { $_.Runs })) {
    foreach ($entry in $manifest.Gates) { Add-Gate -Entry $entry -Package $manifest.Package -Base $manifest.SkillFolder }
    $scripts = Join-Path $manifest.SkillFolder 'scripts'
    if (Test-Path -LiteralPath $scripts) { $testFolders.Add([IO.Path]::GetFullPath($scripts)) }
}

foreach ($entry in @($config.repoGates)) {
    if (-not $entry) { continue }
    Add-Gate -Entry $entry -Package 'repo' -Base $RepoRoot
    $folder = [IO.Path]::GetFullPath((Split-Path (Join-Path $RepoRoot $entry.script) -Parent))
    if ((Test-Path -LiteralPath $folder) -and -not $testFolders.Contains($folder)) { $testFolders.Add($folder) }
}

if ($BlockingOnly) {
    $kept = @($gates | Where-Object { $_.Mode -eq 'Blocking' })
    $gates.Clear()
    foreach ($g in $kept) { $gates.Add($g) }
}

if ($List) {
    Write-Host 'Where a gate runs: the pre-push git hook runs the Blocking gates (Invoke-LocalGates.ps1 -BlockingOnly).'
    Write-Host 'The pull request action (ai-sdlc-pr) and a local run run all of them; an Advisory gate never fails either one.'
    Write-Host ''
    foreach ($g in $gates) {
        Write-Host ("{0,-13} {1,-9} {2,-12} {3}" -f $g.Package, $g.Mode, $g.Clause, $g.Name)
        Write-Host ("{0,-13} runs in: {1}" -f '', (Get-GateStage -Gate $g))
    }
    Write-Host ''
    Write-Host ("{0} gate(s) from {1} package manifest(s), apm.yml and aisdlc.json." -f $gates.Count, $manifests.Count)
    exit 0
}

$results = [System.Collections.Generic.List[object]]::new()
$testGates = @('Invoke-PesterGate.ps1', 'Invoke-PesterParallel.ps1')
$skipped = @()
if ($SkipTests) {
    $skipped = @($gates | Where-Object { (Split-Path -Leaf $_.Script) -in $testGates })
    $kept = @($gates | Where-Object { (Split-Path -Leaf $_.Script) -notin $testGates })
    $gates.Clear()
    foreach ($g in $kept) { $gates.Add($g) }
}

$runs = @($gates | ForEach-Object -ThrottleLimit ([Math]::Max(1, [Environment]::ProcessorCount)) -Parallel {
        $ErrorActionPreference = 'Stop'
        $g = $_
        $run = [pscustomobject]@{ Name = $g.Name; Lines = [System.Collections.Generic.List[object]]::new(); Code = 0; Error = $null }
        if (Test-Path -LiteralPath $g.Script -PathType Leaf) {
            $gateArgs = $g.Args
            $global:LASTEXITCODE = 0
            try {
                & $g.Script @gateArgs *>&1 | ForEach-Object { $run.Lines.Add($_) }
                $run.Code = $LASTEXITCODE
            }
            catch { $run.Error = $_ }
        }
        $run
    })

foreach ($g in $gates) {
    Write-Host ""
    Write-Host ("===== {0} ({1}, {2}) =====" -f $g.Name, $g.Package, $g.Mode) -ForegroundColor Cyan
    $howToRepeat = Get-GateRepeatCommand -Script $g.Script -RepoRoot $RepoRoot
    $run = @($runs | Where-Object Name -EQ $g.Name)[0]
    if (-not (Test-Path -LiteralPath $g.Script -PathType Leaf)) {
        Write-Host ("Could not check: the gate script {0} does not exist." -f $g.Script) -ForegroundColor Yellow
        if ($inPipeline) {
            Write-GateAnnotation -Lines @("The gate script $($g.Script) does not exist; install the package that ships it.") -ExitCode 2 -Clause $g.Clause -What $g.Name -Mode $g.Mode -HowToRepeat $howToRepeat | Out-Null
        }
        $results.Add([pscustomobject]@{ Gate = $g.Name; Mode = $g.Mode; Status = 'UNVERIFIED' })
        continue
    }
    $lines = @($run.Lines)
    $lines | ForEach-Object { Write-Host $_ }
    if ($run.Error) {
        Write-Host ("The gate script stopped before it could report, so nothing was checked: {0}" -f $run.Error.Exception.Message) -ForegroundColor Red
        if ($inPipeline) { Write-GateCrashAnnotation -Clause $g.Clause -Script $g.Script -ErrorRecord $run.Error -HowToRepeat $howToRepeat | Out-Null }
        $results.Add([pscustomobject]@{ Gate = $g.Name; Mode = $g.Mode; Status = 'CRASHED' })
        continue
    }
    $code = $run.Code
    $status = if ($code -eq 0) { 'PASS' } elseif ($code -eq 2) { 'UNVERIFIED' } elseif ($g.Mode -eq 'Advisory') { 'ADVISORY' } else { 'FAIL' }
    if ($inPipeline) { Write-GateAnnotation -Lines $lines -ExitCode $code -Clause $g.Clause -What $g.Name -Mode $g.Mode -HowToRepeat $howToRepeat | Out-Null }
    $results.Add([pscustomobject]@{ Gate = $g.Name; Mode = $g.Mode; Status = $status })
}

foreach ($g in $skipped) { $results.Add([pscustomobject]@{ Gate = $g.Name; Mode = $g.Mode; Status = 'SKIP' }) }

$toolTestsFailed = $false
if ($IncludeToolTests -and $testFolders.Count -gt 0) {
    Write-Host ""
    Write-Host "===== Gate-script Pester tests =====" -ForegroundColor Cyan
    $pester = Invoke-Pester -Path $testFolders.ToArray() -PassThru -Output Detailed
    if ($pester.FailedCount -gt 0) { $toolTestsFailed = $true }
    $results.Add([pscustomobject]@{ Gate = "Gate-script tests ($($pester.PassedCount)/$($pester.TotalCount))"; Mode = 'Blocking'; Status = $(if ($toolTestsFailed) { 'FAIL' } else { 'PASS' }) })
    if ($toolTestsFailed -and $inPipeline) { Write-GateCommand -Type error -Title 'Gate-script tests' -Message ("AI-SDLC: {0} of the {1} gate-script tests failed." -f $pester.FailedCount, $pester.TotalCount) }
}

Write-Host ""
Write-Host "===== Summary =====" -ForegroundColor Cyan
$results | Format-Table -AutoSize | Out-String | Write-Host
if ($inPipeline -and $env:GITHUB_STEP_SUMMARY) {
    $table = @('### AI-SDLC gates', '', '| Gate | Mode | Status |', '| --- | --- | --- |') +
        @($results | ForEach-Object { '| {0} | {1} | {2} |' -f ($_.Gate -replace '\|', '/'), $_.Mode, $_.Status })
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value (($table + '') -join "`n") -Encoding utf8
}

$blockingFailures = @($results | Where-Object { $_.Status -in 'FAIL', 'CRASHED' })
if ($blockingFailures.Count -gt 0) {
    $crashed = @($blockingFailures | Where-Object { $_.Status -eq 'CRASHED' }).Count
    $detail = if ($crashed) { " ($crashed of them stopped before they could report)" } else { '' }
    Write-Host ("{0} blocking gate(s) failed{1}." -f $blockingFailures.Count, $detail) -ForegroundColor Red
    exit 1
}

$unverified = @($results | Where-Object { $_.Status -eq 'UNVERIFIED' })
if ($unverified.Count -gt 0) {
    Write-Host ("{0} gate(s) could not check at all (exit 2). That is neither a pass nor a violation; read the reason each one printed." -f $unverified.Count) -ForegroundColor Yellow
}

$advisories = @($results | Where-Object { $_.Status -eq 'ADVISORY' })
if ($advisories.Count -gt 0) {
    Write-Host ("All blocking gates pass. {0} advisory gate(s) reported issues (not blocking)." -f $advisories.Count) -ForegroundColor Yellow
}
elseif ($unverified.Count -eq 0) {
    Write-Host "All gates pass." -ForegroundColor Green
}
exit 0
