#Requires -Version 7
<#
.SYNOPSIS
    The dotnet part of the local pre-flight: the build with the analyzers, the tests with coverage and
    the coverage ratchet, and the SonarCloud opt-in.

.DESCRIPTION
    Invoke-Preflight.ps1 in the ai-sdlc-gates skill runs this script, because dotnet-gates/gates.json
    names it as the dotnet preflight. It returns one row per check, with Check, Status and Detail, and
    the core script folds the rows into its report and its receipt decision.

    It reads the solution, the run settings and the coverage baseline from aisdlc.json (paths.solution,
    paths.runSettings, paths.coverageBaseline), and the SonarCloud project key and organization from
    sonarcloud.projectKey and sonarcloud.organization.

      - Build: dotnet build of the solution in Release. The SonarAnalyzer rules run inside the build, so
        a warning on a changed file is a SonarCloud finding to clear. On a scoped run (-ScopeFiles) it
        builds only the projects that the change reaches, and their test projects.
      - Tests and coverage: dotnet test with the run settings, the coverage files merged with
        dotnet-coverage, then the C04 ratchet (Check-Coverage.ps1, blocking). When dotnet-coverage is
        missing, or the test run wrote no coverage file, the row is a FAIL that names the fix, because
        a ratchet that did not run proves nothing. On a scoped run it runs only the test projects that
        the change reaches, and the ratchet row is N/A.
      - SonarCloud quality gate: only with -IncludeSonar. It needs a token and uploads a real analysis.
        The usual token is AISDLC_SONAR_MCP_TOKEN, set once with
        pwsh .claude/skills/sonarcloud-mcp/scripts/Set-SonarMcpToken.ps1. SONAR_TOKEN, then
        SONARCLOUD_TOKEN, still come first when they are set.

.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script.

.PARAMETER ChangedFiles
    The changed source files the core script found, so a build warning on one of them is flagged.

.PARAMETER ScopeFiles
    The files of the change, committed or not. Invoke-Preflight.ps1 passes it only on a scoped run, never
    with -Full. With it the build and the tests cover only what the change can reach, as
    DotnetTestScope.psm1 works out from the project references. The build and the tests then run on a
    temporary solution filter (.slnf) of those projects, which is removed after the run. A change that
    reaches no .NET project builds and tests nothing, and both rows are N/A. A scoped test run measures
    only part of the code, so it collects no coverage and the C04 ratchet row is N/A. A change to a file
    that every project reads, such as Directory.Packages.props, runs everything.

.PARAMETER Full
    Run everything even when -ScopeFiles is given. A run in GitHub Actions (GITHUB_ACTIONS or CI is true)
    is full too, because the pull request build must run every test.

.PARAMETER SkipTests
    Skip the tests and coverage step.

.PARAMETER IncludeSonar
    Run dotnet-sonarscanner against SonarCloud and poll the quality gate. Needs SONAR_TOKEN or
    AISDLC_SONAR_MCP_TOKEN; uploads.

.EXAMPLE
    pwsh .claude/skills/dotnet-gates/scripts/Invoke-DotnetPreflight.ps1 -SkipTests
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string[]]$ChangedFiles = @(),
    [string[]]$ScopeFiles,
    [switch]$Full,
    [switch]$SkipTests,
    [switch]$IncludeSonar
)

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

$ErrorActionPreference = 'Continue'
$config = Get-AiSdlcConfig -RepoRoot $RepoRoot

function New-Row([string]$Check, [string]$Status, [string]$Detail) {
    [pscustomobject]@{ Check = $Check; Status = $Status; Detail = $Detail }
}

if (-not $config.paths.solution) {
    New-Row 'Build (compiler + SonarAnalyzer)' 'SKIP' 'aisdlc.json names no paths.solution'
    return
}
$sln = Join-Path $RepoRoot $config.paths.solution

$scope = $null
$inPipeline = ($env:GITHUB_ACTIONS -eq 'true') -or ($env:CI -eq 'true')
if ($PSBoundParameters.ContainsKey('ScopeFiles') -and -not $Full -and -not $inPipeline) {
    Import-Module (Join-Path $PSScriptRoot 'DotnetTestScope.psm1') -Force
    $scope = Get-DotnetTestScope -RepoRoot $RepoRoot -Files $ScopeFiles
    if ($scope.All) { Write-Host "dotnet scope: every project, because $($scope.Reason)." -ForegroundColor Cyan; $scope = $null }
}

# The filter lives in the temp folder so it never dirties the working tree. Its project paths are
# relative to the solution file, and it works for .sln and .slnx files alike.
function New-SolutionFilter([string[]]$Projects) {
    $slnFolder = Split-Path $sln -Parent
    $filter = Join-Path ([System.IO.Path]::GetTempPath()) ('preflight-' + [guid]::NewGuid().ToString('N') + '.slnf')
    $relative = @($Projects | ForEach-Object { [System.IO.Path]::GetRelativePath($slnFolder, (Join-Path $RepoRoot $_)) })
    @{ solution = @{ path = [System.IO.Path]::GetFullPath($sln); projects = $relative } } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $filter -Encoding utf8
    return $filter
}

$buildTarget = $sln
$buildFilter = $null
if ($scope -and @($scope.Projects).Count -eq 0) {
    New-Row 'Build (compiler + SonarAnalyzer)' 'N/A' 'the change touches no .NET project, so nothing was built; -Full and the pull request build run everything'
}
elseif (Get-Command dotnet -ErrorAction SilentlyContinue) {
    if ($scope) {
        $buildFilter = New-SolutionFilter -Projects @(@($scope.Projects) + @($scope.TestProjects) | Sort-Object -Unique)
        $buildTarget = $buildFilter
        Write-Host "dotnet build of the $(@($scope.Projects).Count) project(s) the change touches and their $(@($scope.TestProjects).Count) test project(s) (SonarAnalyzer = SonarCloud rules)..." -ForegroundColor Cyan
    }
    else { Write-Host "dotnet build (SonarAnalyzer = SonarCloud rules)..." -ForegroundColor Cyan }
    $buildLog = & dotnet build $buildTarget -c Release --nologo 2>&1
    $buildFailed = ($LASTEXITCODE -ne 0)
    $warnings = $buildLog | Select-String -Pattern '\bwarning\s+[A-Z]+\d+' | ForEach-Object { $_.Line.Trim() }
    $changedNames = @($ChangedFiles | ForEach-Object { [System.IO.Path]::GetFileName($_) })
    $changedWarnings = @($warnings | Where-Object { $line = $_; ($changedNames | Where-Object { $line -match [regex]::Escape($_) }).Count -gt 0 })
    if ($buildFailed) { New-Row 'Build (compiler + SonarAnalyzer)' 'FAIL' 'dotnet build failed; see output above' }
    else {
        New-Row 'Build (compiler + SonarAnalyzer)' ($(if ($changedWarnings.Count -gt 0) { 'REVIEW' } else { 'PASS' })) "$($warnings.Count) total warning(s); $($changedWarnings.Count) on changed files (the SonarCloud rule findings to clear)"
        $changedWarnings | Select-Object -Unique | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow }
    }
}
else { New-Row 'Build (compiler + SonarAnalyzer)' 'SKIP' 'dotnet not installed' }
if ($buildFilter) { Remove-Item -LiteralPath $buildFilter -ErrorAction SilentlyContinue }

# Tests + coverage, on by default. Mirrors CI: collect "Code Coverage" scoped by
# the run settings, merge to the XML with dotnet-coverage, then run the C04 ratchet (blocking).
if (-not $SkipTests -and -not (Get-Command dotnet -ErrorAction SilentlyContinue)) { New-Row 'Tests + coverage (C04)' 'SKIP' 'dotnet not installed' }
elseif (-not $SkipTests -and $scope) {
    if (@($scope.TestProjects).Count -eq 0) {
        New-Row 'Tests (the change only)' 'N/A' 'the change reaches no test project, so no test ran; -Full and the pull request build run them all'
    }
    else {
        Write-Host "`ndotnet test of the $(@($scope.TestProjects).Count) test project(s) the change reaches..." -ForegroundColor Cyan
        $testFilter = New-SolutionFilter -Projects @($scope.TestProjects)
        $testArgs = @('test', $testFilter, '-c', 'Release', '--nologo')
        if ($config.paths.runSettings) { $testArgs += @('--settings', (Join-Path $RepoRoot $config.paths.runSettings)) }
        & dotnet @testArgs | Out-Host
        $testExit = $LASTEXITCODE
        Remove-Item -LiteralPath $testFilter -ErrorAction SilentlyContinue
        New-Row 'Tests (the change only)' ($(if ($testExit -eq 0) { 'PASS' } else { 'FAIL' })) "$(@($scope.TestProjects).Count) test project(s) that the change reaches: $(@($scope.TestProjects | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) }) -join ', ')"
    }
    New-Row 'Coverage ratchet (C04)' 'N/A' 'a run of part of the tests measures only part of the code; -Full and the pull request build run the ratchet'
}
elseif (-not $SkipTests) {
    Write-Host "`ndotnet test + coverage (C04)..." -ForegroundColor Cyan
    $covDir = Join-Path ([System.IO.Path]::GetTempPath()) ("preflight-cov-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $covDir -Force | Out-Null
    $testArgs = @('test', $sln, '-c', 'Release', '--nologo', '--results-directory', $covDir, '--collect', 'Code Coverage')
    if ($config.paths.runSettings) { $testArgs += @('--settings', (Join-Path $RepoRoot $config.paths.runSettings)) }
    & dotnet @testArgs | Out-Host
    if ($LASTEXITCODE -ne 0) { New-Row 'Tests + coverage (C04)' 'FAIL' 'dotnet test failed; see output above' }
    else {
        if (-not (Get-Command dotnet-coverage -ErrorAction SilentlyContinue)) { dotnet tool install --global dotnet-coverage *> $null }
        $covFiles = @(Get-ChildItem -Path $covDir -Recurse -Filter *.coverage -ErrorAction SilentlyContinue)
        if (-not (Get-Command dotnet-coverage -ErrorAction SilentlyContinue)) {
            New-Row 'Tests + coverage (C04)' 'FAIL' 'tests passed, but C04 did not run: dotnet-coverage is not installed. Run Initialize-AiSdlc.ps1, or dotnet tool install --global dotnet-coverage, then run the pre-flight again'
        }
        elseif ($covFiles.Count -eq 0) {
            New-Row 'Tests + coverage (C04)' 'FAIL' 'tests passed, but C04 did not run: the test run wrote no coverage file. Make the run settings (paths.runSettings) keep the Code Coverage collector, then run the pre-flight again'
        }
        else {
            $merged = Join-Path $covDir 'coverage.opencover.xml'
            & dotnet-coverage merge --output $merged --output-format xml @($covFiles.FullName) *> $null
            if (Test-AiSdlcGateOff -RepoRoot $RepoRoot -Script 'Check-Coverage.ps1') {
                New-Row 'Tests + coverage (C04)' 'SKIP' 'tests passed; the coverage gate is Off, so Check-Coverage.ps1 did not run'
            }
            else {
                & (Join-Path $PSScriptRoot 'Check-Coverage.ps1') -CoverageFile $merged -RepoRoot $RepoRoot | Out-Host
                New-Row 'Tests + coverage (C04)' ($(if ($LASTEXITCODE -eq 0) { 'PASS' } else { 'FAIL' })) 'tests passed; C04 ratchet against the recorded baseline (blocking)'
            }
        }
    }
    Remove-Item -LiteralPath $covDir -Recurse -Force -ErrorAction SilentlyContinue
}
else { New-Row 'Tests + coverage (C04)' 'SKIP' '-SkipTests set' }

# SonarCloud server quality gate: opt-in, uploads, needs a token. The gate itself is server-side.
if ($IncludeSonar) {
    Write-Host "`nSonarCloud scan + quality gate (upload)..." -ForegroundColor Cyan
    # An empty variable counts as not set. AISDLC_SONAR_MCP_TOKEN, which Set-SonarMcpToken.ps1 stores
    # once, is the last fallback (#84).
    $sonarToken = @($env:SONAR_TOKEN, $env:SONARCLOUD_TOKEN, $env:AISDLC_SONAR_MCP_TOKEN) | Where-Object { $_ } | Select-Object -First 1
    $sonarKey = $config.sonarcloud.projectKey
    $sonarOrg = $config.sonarcloud.organization
    if (-not $sonarKey -or -not $sonarOrg) { New-Row 'SonarCloud quality gate' 'SKIP' 'aisdlc.json names no sonarcloud.projectKey and sonarcloud.organization' }
    elseif (-not $sonarToken) { New-Row 'SonarCloud quality gate' 'NEEDS-TOKEN' 'set AISDLC_SONAR_MCP_TOKEN once: run pwsh .claude/skills/sonarcloud-mcp/scripts/Set-SonarMcpToken.ps1 in your own terminal (SONAR_TOKEN still comes first); this uploads a real analysis to SonarCloud (server-side gate, not offline)' }
    elseif (-not (Get-Command dotnet-sonarscanner -ErrorAction SilentlyContinue)) { New-Row 'SonarCloud quality gate' 'SKIP' 'dotnet-sonarscanner not installed (dotnet tool install --global dotnet-sonarscanner)' }
    else {
        # The scanner reads SONAR_TOKEN from the environment; never pass it as a command-line argument
        # (process args are visible to other processes). Check each step before continuing so a failed
        # begin or build is not hidden behind the end step's exit code.
        # SONAR_TOKEN goes back to what it was after the scan, so a fallback token does not stay set
        # for the later steps of the pre-flight.
        $hadSonarToken = Test-Path -LiteralPath Env:SONAR_TOKEN
        $previousSonarToken = $env:SONAR_TOKEN
        $env:SONAR_TOKEN = $sonarToken
        try {
            & dotnet-sonarscanner begin /k:"$sonarKey" /o:"$sonarOrg" /d:sonar.host.url="https://sonarcloud.io" /d:sonar.qualitygate.wait=true 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { New-Row 'SonarCloud quality gate' 'FAIL' "sonarscanner begin failed (exit $LASTEXITCODE)" }
            else {
                & dotnet build $sln -c Release --nologo 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { New-Row 'SonarCloud quality gate' 'FAIL' "build under the scanner failed (exit $LASTEXITCODE)" }
                else {
                    & dotnet-sonarscanner end 2>&1 | Out-Null
                    New-Row 'SonarCloud quality gate' ($(if ($LASTEXITCODE -eq 0) { 'PASS' } else { 'REVIEW' })) "scanner uploaded; sonar.qualitygate.wait returns the server verdict (exit $LASTEXITCODE)"
                }
            }
        }
        finally {
            if ($hadSonarToken) { $env:SONAR_TOKEN = $previousSonarToken }
            else { Remove-Item -LiteralPath Env:SONAR_TOKEN -ErrorAction SilentlyContinue }
        }
    }
}
else { New-Row 'SonarCloud quality gate' 'OPT-IN' 'run with -IncludeSonar (needs SONAR_TOKEN or AISDLC_SONAR_MCP_TOKEN; uploads to SonarCloud; the gate is server-side, not offline)' }
