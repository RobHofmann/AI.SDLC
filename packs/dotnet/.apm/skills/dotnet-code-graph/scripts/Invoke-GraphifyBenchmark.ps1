#Requires -Version 7
<#
.SYNOPSIS
    Scores the local Graphify code graph on a committed set of questions with known-correct answers,
    so a version bump that degrades resolution is visible instead of silent.

.DESCRIPTION
    This measures ACCURACY, not cost. The tool ships its own `graphify benchmark`, which reports token
    reduction against reading the whole corpus. That number says the graph is cheap to consult. It says
    nothing about whether the answer is right, and a tool that is cheap and wrong is worse than grep.
    This script answers the other half.

    Each case in the question set (dotnet.graphifyBenchmarkCases in aisdlc.json) carries a question, the arguments that ask it, the
    symbols a correct answer must contain, and symbols it must not. The expected answers were derived
    from this codebase and are committed, so the set is re-runnable rather than a one-off comparison.

    Two case types:

    [cli]      Runs the graphify command and scores its output for expected and forbidden symbols.
               This exercises the real user-facing path rather than a reimplementation of it.

    [absence]  Asserts that no file of the given extensions appears in the graph. These cases pin a
               documented blind spot. They are expected to pass today, and a failure means the tool
               gained coverage and the documentation that tells readers to keep grepping is now wrong.

    Advisory by default: it reports and exits 0 so it can run without blocking anyone. Pass
    -FailOnRegression to make it exit non-zero on any failed case, which is what a future gate would do
    once the value is established.

    The question boundary: .claude/skills/dotnet-code-graph/references/code-graph.md.

.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script.

.PARAMETER CaseFile
    Path to the question set. Defaults to dotnet.graphifyBenchmarkCases in aisdlc.json. Every case in it
    must ask one of the read-only queries in $script:AllowedSubcommand; a case naming any other
    subcommand is refused before the tool is invoked, because `extract` is the path that can reach a
    model backend and its arguments are guarded by Invoke-GraphifyIndex.ps1, not here.

.PARAMETER GraphPath
    Path to graph.json, used by the absence cases. Defaults to graphify-out/graph.json under RepoRoot.

.PARAMETER GraphifyCommand
    The executable to invoke for cli cases. Defaults to 'graphify'. Used by the Pester tests to feed
    canned output.

.PARAMETER FailOnRegression
    Exit 1 when any case fails. Off by default so the benchmark reports without blocking.

.EXAMPLE
    ./Invoke-GraphifyBenchmark.ps1

.EXAMPLE
    ./Invoke-GraphifyBenchmark.ps1 -FailOnRegression
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,

    [string]$CaseFile,

    [string]$GraphPath,

    [string]$GraphifyCommand = 'graphify',

    [switch]$FailOnRegression
)

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }
if (-not $CaseFile) {
    $caseRel = (Get-AiSdlcConfig -RepoRoot $RepoRoot).dotnet.graphifyBenchmarkCases
    if (-not $caseRel) {
        Write-Host 'Could not run: aisdlc.json names no dotnet.graphifyBenchmarkCases, and no -CaseFile was passed.' -ForegroundColor Yellow
        exit 2
    }
    $CaseFile = Join-Path $RepoRoot $caseRel
}

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'CodeGraph.psm1') -Force
Import-Module (Join-Path $aiSdlcGates 'ToolOutput.psm1') -Force

$script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture


function Test-CliCase {
    param(
        [Parameter(Mandatory)]$Case,
        [Parameter(Mandatory)][string]$Output
    )

    $missing = @()
    foreach ($symbol in @($Case.expectSymbols)) {
        if ($Output -notmatch [regex]::Escape($symbol)) { $missing += $symbol }
    }

    $forbidden = @()
    foreach ($symbol in @($Case.forbidSymbols)) {
        if ($Output -match [regex]::Escape($symbol)) { $forbidden += $symbol }
    }

    $expected = @($Case.expectSymbols).Count
    $found = $expected - $missing.Count

    return [pscustomobject]@{
        Passed    = ($missing.Count -eq 0 -and $forbidden.Count -eq 0)
        Found     = $found
        Expected  = $expected
        Missing   = $missing
        Forbidden = $forbidden
    }
}

function Test-AbsenceCase {
    param(
        [Parameter(Mandatory)]$Case,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Node
    )

    $present = @()
    foreach ($extension in @($Case.absentExtensions)) {
        $hit = @($Node | Where-Object {
                $file = [string]$_.source_file
                $file -and ([System.IO.Path]::GetExtension($file).ToLowerInvariant() -eq $extension.ToLowerInvariant())
            })
        if ($hit.Count -gt 0) { $present += "$extension ($($hit.Count) node(s))" }
    }

    return [pscustomobject]@{
        Passed    = ($present.Count -eq 0)
        Found     = 0
        Expected  = 0
        Missing   = @()
        Forbidden = $present
    }
}

if (-not $GraphPath) {
    $GraphPath = Join-Path $RepoRoot 'graphify-out' 'graph.json'
}

if (-not (Test-Path -LiteralPath $CaseFile)) {
    Write-Host "No question set at '$CaseFile'." -ForegroundColor Red
    exit 1
}

$suite = Get-Content -LiteralPath $CaseFile -Raw -Encoding utf8 | ConvertFrom-Json
$cases = @($suite.cases)

if ($cases.Count -eq 0) {
    Write-Host "The question set at '$CaseFile' has no cases." -ForegroundColor Red
    exit 1
}

$graphNode = @()
if (@($cases | Where-Object { $_.type -eq 'absence' }).Count -gt 0 -and -not (Test-Path -LiteralPath $GraphPath)) {
    Write-Host "No graph at '$GraphPath'. Build it with Invoke-GraphifyIndex.ps1 first." -ForegroundColor Red
    exit 1
}
if (Test-Path -LiteralPath $GraphPath) {
    $graphNode = @((Get-GraphIndex -GraphPath $GraphPath).Nodes.Values)
}

Write-Invariant -Template 'Graphify accuracy benchmark: {0} case(s) from {1}' -Values @($cases.Count, (Split-Path -Leaf $CaseFile))
$trackedVersion = $suite.graphifyVersion
if (-not $trackedVersion) {
    $pinFile = Join-Path $PSScriptRoot 'graphify-version.json'
    if (Test-Path -LiteralPath $pinFile) { $trackedVersion = (Get-Content -LiteralPath $pinFile -Raw -Encoding utf8 | ConvertFrom-Json).graphifyVersion }
}
Write-Invariant -Template 'Question set was written against graphify {0}.' -Values @($trackedVersion)
Write-Host ''

$script:AllowedSubcommand = @('affected', 'explain', 'path')

foreach ($case in ($cases | Where-Object { $_.type -ne 'absence' })) {
    $subcommand = @($case.arguments)[0]
    if ($script:AllowedSubcommand -ccontains $subcommand) { continue }
    Write-Host "Refused case '$($case.id)': '$subcommand' is not one of the read-only queries this benchmark asks." -ForegroundColor Red
    Write-Host "Allowed: $($script:AllowedSubcommand -join ', '). 'extract' is the path that can reach a model backend," -ForegroundColor Red
    Write-Host 'and it belongs to Invoke-GraphifyIndex.ps1, which guards its arguments.' -ForegroundColor Red
    exit 1
}

$needsCli = @($cases | Where-Object { $_.type -ne 'absence' }).Count -gt 0
if ($needsCli -and -not (Get-Command $GraphifyCommand -ErrorAction SilentlyContinue)) {
    Write-Host "'$GraphifyCommand' is not on PATH, and this question set asks it questions." -ForegroundColor Red
    Write-Host 'Install it first, or run Invoke-GraphifyIndex.ps1 which prints the pinned install command.' -ForegroundColor Red
    exit 1
}

$results = [System.Collections.Generic.List[object]]::new()

foreach ($case in $cases) {
    if ($case.type -eq 'absence') {
        $verdict = Test-AbsenceCase -Case $case -Node $graphNode
    }
    else {
        $arguments = @($case.arguments)
        $output = (& $GraphifyCommand @arguments 2>&1 | Out-String)
        $verdict = Test-CliCase -Case $case -Output $output
    }

    $results.Add([pscustomobject]@{
            Id        = $case.id
            Question  = $case.question
            Passed    = $verdict.Passed
            Found     = $verdict.Found
            Expected  = $verdict.Expected
            Missing   = $verdict.Missing
            Forbidden = $verdict.Forbidden
        })

    $mark = if ($verdict.Passed) { 'PASS' } else { 'FAIL' }
    $colour = if ($verdict.Passed) { 'Green' } else { 'Red' }
    $score = if ($verdict.Expected -gt 0) { [string]::Format($script:Invariant, ' ({0}/{1} symbols)', $verdict.Found, $verdict.Expected) } else { '' }

    Write-Invariant -Template '[{0}] {1}{2}' -Values @($mark, $case.id, $score) -ForegroundColor $colour
    Write-Invariant -Template '       {0}' -Values @($case.question)

    if ($verdict.Missing.Count -gt 0) {
        Write-Invariant -Template '       missing: {0}' -Values @(($verdict.Missing -join ', ')) -ForegroundColor Yellow
    }
    if ($verdict.Forbidden.Count -gt 0) {
        Write-Invariant -Template '       must not appear, but did: {0}' -Values @(($verdict.Forbidden -join ', ')) -ForegroundColor Yellow
    }
}

$passed = @($results | Where-Object { $_.Passed }).Count
$total = $results.Count

Write-Host ''
Write-Invariant -Template 'Accuracy: {0} of {1} case(s) pass.' -Values @($passed, $total) -ForegroundColor $(if ($passed -eq $total) { 'Green' } else { 'Red' })

if ($passed -ne $total) {
    Write-Host 'A failure here means the graph stopped answering a question it used to answer, or gained' -ForegroundColor Yellow
    Write-Host 'coverage the docs still describe as a blind spot. Either way the code-graph page of the' -ForegroundColor Yellow
    Write-Host 'dotnet-code-graph skill and the pinned version in graphify-version.json need revisiting before anyone trusts it.' -ForegroundColor Yellow

    if ($FailOnRegression) { exit 1 }
}

exit 0
