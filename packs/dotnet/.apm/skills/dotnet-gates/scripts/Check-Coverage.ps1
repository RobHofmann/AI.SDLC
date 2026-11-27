#Requires -Version 7
<#
.SYNOPSIS
    Enforces constitution clause C04 locally: overall line coverage must not drop below the recorded
    baseline. The 80% target itself is enforced by the SonarCloud quality gate on new code.

.DESCRIPTION
    This gate is a RATCHET, not a fixed bar. It reads a coverage XML, computes overall line coverage,
    and fails when that figure has dropped below the baseline recorded in the repository. It also fails
    when coverage is one point or more above the baseline file and the change did not raise that file.
    A gain of less than a point passes and prints the new figure, so the baseline can be raised later.
    The ratchet exists because overall coverage is a debt figure that takes years to move: a fixed 80%
    on the total could never pass, so it was set to advisory and stopped being read. The rise rule keeps
    a gain from being given back: without it, the baseline stays low and a later change can lose the
    coverage that this one added.

    The baseline file counts as raised when the change touches it and its value is above the value at
    the base, or the file is new there. The change comes from ChangedFiles.psm1 in the ai-sdlc-gates
    skill: CHANGED_FILES in the pull request action, else the commits since the merge base with
    origin/<github.trunk>. A baseline given with -Baseline has no file to raise, so the rise rule does
    not apply to it. To raise the baseline, set lineCoveragePercent in the baseline file to the figure
    the gate prints, and commit the file with the change.

    The 80% ambition lives where it is achievable: SonarCloud's "coverage on new code" condition,
    which judges only the lines a pull request changed. This script reports the distance to that
    target for information but never gates on it.

    WHAT IS MEASURED: only the assemblies we own, and only once the run settings (paths.runSettings in
    aisdlc.json) are passed to the test run (`dotnet test --settings`). Without them the collector
    instruments every loaded assembly that has symbols, so third-party packages and the test assemblies
    land in the report and this script's total describes something other than the repository's code.

    Two report formats are supported:

    [OpenCover format - root <CoverageSession>]
    Coverage is read from <CoverageSession>/<Summary>: line coverage is computed from
    numSequencePoints / visitedSequencePoints (the authoritative counts). If those counts are absent
    the sequenceCoverage attribute is used as a fallback. Per-module figures come from each
    <Module>/<Summary>.

    [dotnet-coverage XML format - root <results>]
    Coverage is read from <results><modules><module> elements. Overall line coverage is
    lines_covered / (lines_covered + lines_partially_covered + lines_not_covered), summed across all
    modules - consistent with the line_coverage attribute the tool writes per module. This is the
    format the CI "Merge code coverage files" step produces, despite the .opencover.xml file name.

    Sibling of Check-DocLineCitations.ps1 (C02) and Check-DocEmDashes.ps1 (C06): same house style, one
    rule per script, run locally and in CI.

    Exit codes: 0 at or above the baseline, 1 below it or a gain of a point or more that the change left
    out of the baseline file, 2 when the coverage file is missing or when a gain of a point or more
    meets a change that cannot be listed (could not check, with a FIX line).

.PARAMETER CoverageFile
    Path to a coverage XML in OpenCover format (<CoverageSession> root) or dotnet-coverage XML format
    (<results> root). In the pull request workflow this is the file that the coverage-file input of
    the ai-sdlc-pr composite action names; a test step before it merges the coverage with
    dotnet-coverage into coverage.xml.

.PARAMETER BaselineFile
    Path to the JSON file holding the recorded baseline. Defaults to paths.coverageBaseline in aisdlc.json
    under the repository root. The file must contain a numeric lineCoveragePercent property.

.PARAMETER Baseline
    Explicit baseline percent, overriding BaselineFile. Used by the Pester tests and for one-off runs.

.PARAMETER Tolerance
    Percentage points of slack below the baseline that still pass, absorbing small run-to-run wobble
    without letting a real regression through. Defaults to 0.25.

.PARAMETER Target
    The eventual ambition, reported as distance-to-target only and never gated on here. Defaults to 80.

.PARAMETER RepoRoot
    Optional repository root, used to resolve the default BaselineFile and to render the coverage file
    path relative to the repository in output. Defaults to the folder that holds aisdlc.json, found from this script.

.PARAMETER BaseRef
    The ref the change is measured against, to see whether the baseline file was raised. Defaults to
    origin/<github.trunk> from aisdlc.json (Get-AiSdlcMainBranch).

.PARAMETER ChangedFiles
    Explicit repo-relative paths of the change, bypassing git. Falls back to the CHANGED_FILES
    environment variable that the shared pull request action sets.

.EXAMPLE
    ./Check-Coverage.ps1 -CoverageFile "$(Agent.TempDirectory)/coverage.opencover.xml"

.EXAMPLE
    ./Check-Coverage.ps1 -CoverageFile ./coverage.opencover.xml -Baseline 42
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$CoverageFile,

    [string]$BaselineFile,

    [Nullable[double]]$Baseline,

    [double]$Tolerance = 0.25,

    [double]$Target = 80,

    [string]$RepoRoot,

    [string]$BaseRef,

    [string[]]$ChangedFiles
)

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $aiSdlcGates 'ToolOutput.psm1') -Force

$script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture


function Get-LineCoveragePercent {
    param([System.Xml.XmlElement]$Summary)

    if ($null -eq $Summary) { return $null }

    $numAttr = $Summary.GetAttribute('numSequencePoints')
    $visitedAttr = $Summary.GetAttribute('visitedSequencePoints')

    $num = 0
    $visited = 0
    $haveCounts = [int]::TryParse($numAttr, [ref]$num) -and [int]::TryParse($visitedAttr, [ref]$visited)

    if ($haveCounts -and $num -gt 0) {
        return [math]::Round(($visited / $num) * 100, 2)
    }

    if ($haveCounts -and $num -eq 0) {
        return $null
    }

    $seqCov = 0.0
    if ([double]::TryParse($Summary.GetAttribute('sequenceCoverage'), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$seqCov)) {
        return [math]::Round($seqCov, 2)
    }

    return $null
}

function Resolve-Baseline {
    param(
        [Nullable[double]]$Explicit,
        [string]$File,
        [string]$Root
    )

    if ($null -ne $Explicit) {
        return [pscustomobject]@{ Percent = [double]$Explicit; Source = 'the -Baseline parameter'; RecordedOn = $null }
    }

    $path = $File
    if ([string]::IsNullOrWhiteSpace($path)) {
        if (-not $script:BaselineRel) {
            return [pscustomobject]@{ Percent = $null; Source = 'aisdlc.json'; Error = 'baseline file not found: aisdlc.json names no paths.coverageBaseline (the file is usually coverage-baseline.json)' }
        }
        $path = Join-Path $Root $script:BaselineRel
    }

    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{ Percent = $null; Source = $path; Error = "baseline file not found at '$path'" }
    }

    try {
        $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    }
    catch {
        return [pscustomobject]@{ Percent = $null; Source = $path; Error = "failed to parse '$path' as JSON: $($_.Exception.Message)" }
    }

    $percent = 0.0
    if (-not [double]::TryParse([string]$json.lineCoveragePercent, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$percent)) {
        return [pscustomobject]@{ Percent = $null; Source = $path; Error = "'$path' has no numeric lineCoveragePercent property" }
    }

    return [pscustomobject]@{ Percent = $percent; Source = $path; RecordedOn = $json.recordedOn }
}

if (-not (Test-Path -LiteralPath $CoverageFile)) {
    Write-Host "C04 coverage gate: coverage file not found at '$CoverageFile', so nothing was checked." -ForegroundColor Yellow
    Write-Host "A missing coverage report means tests or coverage collection did not run." -ForegroundColor Yellow
    Write-Host "FIX: Run the tests with coverage collection first (the dotnet pre-flight does this), or pass -CoverageFile with the merged coverage XML of the test run (the coverage-file input of the ai-sdlc-pr action in the pull request workflow)." -ForegroundColor Yellow
    exit 2
}

$aiSdlc = Get-AiSdlcConfig -RepoRoot $RepoRoot
$script:BaselineRel = [string]$aiSdlc.paths.coverageBaseline
$runSettingsRel = if ($aiSdlc.paths.runSettings) { $aiSdlc.paths.runSettings } else { 'the run settings file' }
$baselineName = if ($script:BaselineRel) { $script:BaselineRel } else { 'the baseline file in paths.coverageBaseline' }
$resolved = Resolve-Baseline -Explicit $Baseline -File $BaselineFile -Root $RepoRoot
if ($null -eq $resolved.Percent) {
    Write-Host "C04 coverage gate: $($resolved.Error)." -ForegroundColor Red
    Write-Host "Without a baseline this gate cannot tell a regression from the status quo, so it fails closed." -ForegroundColor Red
    Write-Host "Record one by running the suite with $runSettingsRel and writing the measured figure to $baselineName." -ForegroundColor Red
    exit 1
}

$floor = $resolved.Percent

try {
    [xml]$doc = Get-Content -LiteralPath $CoverageFile -Raw
}
catch {
    Write-Host "C04 coverage gate: failed to parse '$CoverageFile' as XML: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$relFile = $CoverageFile
try {
    $resolvedPath = (Resolve-Path -LiteralPath $CoverageFile).Path
    $relFile = [IO.Path]::GetRelativePath($RepoRoot, $resolvedPath).Replace('\', '/')
}
catch { }

$session = $doc.CoverageSession
$results = $doc.results

if ($null -ne $session) {
    Write-Host "C04 coverage ratchet (overall line coverage, OpenCover): $relFile"

    $overall = Get-LineCoveragePercent -Summary $session.Summary
    if ($null -eq $overall) {
        Write-Host "C04 coverage gate: could not read overall line coverage from <CoverageSession>/<Summary> in '$CoverageFile'." -ForegroundColor Red
        Write-Host "Expected numSequencePoints / visitedSequencePoints (or a sequenceCoverage attribute)." -ForegroundColor Red
        exit 1
    }

    $modules = @($session.Modules.Module)
    if ($modules.Count -gt 0) {
        Write-Host "Per-module line coverage:"
        foreach ($m in $modules) {
            if ($null -eq $m) { continue }
            $name = $m.ModuleName
            if ([string]::IsNullOrWhiteSpace($name)) { $name = $m.FullName }
            $modCov = Get-LineCoveragePercent -Summary $m.Summary
            if ($null -eq $modCov) {
                Write-Invariant -Template '  {0,7}  {1}' -Values @('n/a', $name)
            }
            else {
                Write-Invariant -Template '  {0,6:N2}%  {1}' -Values @($modCov, $name)
            }
        }
    }
}
elseif ($null -ne $results) {
    Write-Host "C04 coverage ratchet (overall line coverage, dotnet-coverage XML): $relFile"

    $modules = @($results.modules.module)
    $totalLines = 0
    $coveredLines = 0

    Write-Host "Per-module line coverage:"
    foreach ($m in $modules) {
        if ($null -eq $m) { continue }

        $lc = 0; $lp = 0; $ln = 0
        $lcOk = [int]::TryParse($m.lines_covered, [ref]$lc)
        $lpOk = [int]::TryParse($m.lines_partially_covered, [ref]$lp)
        $lnOk = [int]::TryParse($m.lines_not_covered, [ref]$ln)
        if (-not ($lcOk -and $lpOk -and $lnOk)) {
            Write-Host "C04 coverage gate: malformed line-count attributes in module '$($m.name)' of '$CoverageFile'; cannot compute coverage." -ForegroundColor Red
            exit 1
        }
        $moduleTotal = $lc + $lp + $ln
        $totalLines += $moduleTotal
        $coveredLines += $lc

        $modCovVal = 0.0
        if ($moduleTotal -gt 0 -and [double]::TryParse($m.line_coverage, [System.Globalization.NumberStyles]::Float, $script:Invariant, [ref]$modCovVal)) {
            Write-Invariant -Template '  {0,6:N2}%  {1}' -Values @([math]::Round($modCovVal, 2), $m.name)
        }
        else {
            Write-Invariant -Template '  {0,7}  {1}' -Values @('n/a', $m.name)
        }
    }

    if ($totalLines -eq 0) {
        Write-Host "C04 coverage gate: could not read overall line coverage from '$CoverageFile': no lines recorded across all modules." -ForegroundColor Red
        exit 1
    }

    $overall = [math]::Round(($coveredLines / $totalLines) * 100, 2)
}
else {
    Write-Host "C04 coverage gate: '$CoverageFile' has an unrecognized root element; expected <CoverageSession> (OpenCover) or <results> (dotnet-coverage XML)." -ForegroundColor Red
    exit 1
}

$recorded = if ($resolved.RecordedOn) { " recorded $($resolved.RecordedOn)" } else { '' }
Write-Invariant -Template 'Overall line coverage: {0:N2}%. Baseline {1:N2}%{2} from {3}, tolerance {4:N2} points.' -Values @($overall, $floor, $recorded, $resolved.Source, $Tolerance)
Write-Invariant -Template 'Distance to the {0:N2}% ambition: {1:N2} points. That target is gated by SonarCloud on new code, not here.' -Values @($Target, ($Target - $overall))

if ($overall -lt ($floor - $Tolerance)) {
    Write-Invariant -Template 'C04 coverage gate FAILED: {0:N2}% has dropped below the {1:N2}% baseline.' -Values @($overall, $floor) -ForegroundColor Red
    Write-Host "FIX: Add tests for what this change touched until coverage is back at the baseline. If the drop is meant, lower $baselineName in the same commit and say why in the pull request (clause C04)." -ForegroundColor Red
    Write-Host "If the drop is deliberate, say so in the pull request and lower the baseline in the same commit so the decision is reviewed." -ForegroundColor Red
    exit 1
}

if ($null -eq $Baseline -and ($overall - $floor) -ge 1) {
    Import-Module (Join-Path $aiSdlcGates 'ChangedFiles.psm1') -Force
    if (-not $BaseRef) { $BaseRef = Get-AiSdlcMainBranch -RepoRoot $RepoRoot }
    $change = Get-AiSdlcChange -RepoRoot $RepoRoot -BaseRef $BaseRef -Explicit $ChangedFiles
    $gain = [string]::Format($script:Invariant, '{0:N2}', ($overall - $floor))
    if (-not $change.Readable) {
        Write-Host "Could not check: C04 coverage is $gain points above the baseline, and $($change.Reason), so the gate cannot tell whether this change raised the baseline." -ForegroundColor Yellow
        Write-Host "FIX: Fetch the base branch, or pass -BaseRef with a ref that exists, then run the gate again." -ForegroundColor Yellow
        exit 2
    }
    $baselineRel = [IO.Path]::GetRelativePath($RepoRoot, [IO.Path]::GetFullPath($resolved.Source)).Replace('\', '/')
    $raised = $false
    if ($change.Files -contains $baselineRel) {
        $raised = $true
        if ($change.Base) {
            $old = (& git -C $RepoRoot show "$($change.Base):$baselineRel" 2>$null) -join "`n"
            if ($LASTEXITCODE -eq 0) {
                $oldPercent = $null
                try { $oldPercent = [double]((ConvertFrom-Json $old).lineCoveragePercent) } catch { $oldPercent = $null }
                if ($null -ne $oldPercent) { $raised = $floor -gt $oldPercent }
            }
            $global:LASTEXITCODE = 0
        }
    }
    if (-not $raised) {
        Write-Invariant -Template 'C04 coverage gate FAILED: {0:N2}% is {1} points above the {2:N2}% baseline, and this change did not raise the baseline file.' -Values @($overall, $gain, $floor) -ForegroundColor Red
        Write-Invariant -Template 'FIX: Set lineCoveragePercent to {0:N2} in {1} and commit the file with this change, so the gain is kept.' -Values @($overall, $baselineRel) -ForegroundColor Red
        exit 1
    }
}

if ($overall -gt ($floor + $Tolerance)) {
    Write-Invariant -Template 'C04 OK: overall line coverage {0:N2}% is above the {1:N2}% baseline.' -Values @($overall, $floor) -ForegroundColor Green
    Write-Invariant -Template 'Ratchet it up: set lineCoveragePercent to {0:N2} in {1} so this run becomes the new floor.' -Values @($overall, $resolved.Source) -ForegroundColor Green
    exit 0
}

Write-Invariant -Template 'C04 OK: overall line coverage {0:N2}% holds the {1:N2}% baseline.' -Values @($overall, $floor) -ForegroundColor Green
exit 0
