#Requires -Version 7
<#
.SYNOPSIS
    Run every pull-request pipeline check that can run from a shell, locally, before pushing, and report
    honestly on the ones that cannot.

.DESCRIPTION
    The pull request workflow of a repository (paths.codeAnalysisPipeline in aisdlc.json) runs the shared
    composite action ai-sdlc-pr and the build and test jobs the repository adds. This script runs the
    parts a shell can run, plus more scanners, and prints a coverage map.

    The core part always runs: the gates through Invoke-LocalGates.ps1, the test command of the repository,
    gitleaks, the security scanners when they are present, and the receipt. The test command is
    commands.test in aisdlc.json. It starts beside the gates, and its output follows theirs. It runs when it is set, unless a pack pre-flight that takes -SkipTests
    runs the tests itself, as the dotnet pack does; then the tests do not run twice. It does not run the self-tests of the shared gate scripts: no pull request job of a
    consumer runs them, and AI.SDLC tests them in its own pipeline before a release. A gitleaks finding that
    gitleaks-baseline.json does not hold is a FAIL row, so it stops the receipt, as the secret scan of
    the shared pull request action stops the build. Both scans use the same pinned rule set from
    gitleaks-rules.json (GitleaksConfig.psm1). Each package that runs (the core and
    every pack apm.yml lists) can name a "preflight" script in its gates.json. This script runs it,
    and folds the result rows it returns into the same report and the same receipt decision. The dotnet
    pack adds the build with the analyzers, the tests with coverage and the SonarCloud opt-in
    (Invoke-DotnetPreflight.ps1); the github-issues pack adds the PR-story contract
    (Invoke-IssuePreflight.ps1).

    A preflight script takes the parameters it needs from this set: -RepoRoot, -TargetBranch,
    -ChangedFiles, -SkipTests, -IncludeSonar, -SkipScanners. It returns objects with Check, Status and
    Detail. A FAIL row fails the run and writes no receipt, like a failing core check.

    Attempted when its prerequisite is present, else reported with what it needs (never silently skipped):
      - SonarCloud quality gate: needs SONAR_TOKEN and uploads to SonarCloud (the gate is server-side, not
        offline). Opt in with -IncludeSonar.
      - Trivy / Checkov / Semgrep: run if the tool (or Docker) is available. No shipped pipeline runs them,
        so the pre-flight is the one place they run.

.PARAMETER TargetBranch
    Branch the PR targets; scopes the changed-file set and the gitleaks commit range. Defaults to origin/main.

.PARAMETER SkipTests
    Skip the tests: commands.test and the test step of each pack (they are on by default).

.PARAMETER IncludeSonar
    Run dotnet-sonarscanner against SonarCloud and poll the quality gate. Requires SONAR_TOKEN; uploads.

.PARAMETER SkipScanners
    Skip Trivy/Checkov/Semgrep even if available (they are attempted by default).

.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script.

.PARAMETER ReceiptRoot
    Where the pre-flight receipt is written. Defaults to paths.preflightReceipts in aisdlc.json, which is
    temp/preflight under the repository root. A full run that passes on a clean working tree writes
    <tree hash of HEAD>.json there, and the push hook Deny-IncompletePush.ps1 refuses a push whose commit
    has no such receipt. A -SkipTests run or a run on uncommitted changes writes none, and says so.
#>
[CmdletBinding()]
param(
    [string]$TargetBranch = 'origin/main',
    [switch]$SkipTests,
    [switch]$IncludeSonar,
    [switch]$SkipScanners,
    [string]$RepoRoot,
    [string]$ReceiptRoot
)

Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PreflightReceipt.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }
if (-not $ReceiptRoot) { $ReceiptRoot = Join-Path $RepoRoot (Get-AiSdlcConfig -RepoRoot $RepoRoot).paths.preflightReceipts }

$ErrorActionPreference = 'Continue'
$results = [System.Collections.Generic.List[object]]::new()
function Add-Result([string]$Check, [string]$Status, [string]$Detail) {
    $results.Add([pscustomobject]@{ Check = $Check; Status = $Status; Detail = $Detail })
}

$includeExt = @('.cs', '.razor', '.cshtml', '.bicep', '.yml', '.yaml', '.ps1', '.psm1', '.py', '.toml', '.json', '.md')
$excludeNames = @('packages.lock.json', 'package-lock.json')

Push-Location $RepoRoot
try {
    $changed = @(git diff --name-only --diff-filter=AM "$TargetBranch...HEAD" 2>$null |
        Where-Object { $_.Trim() } |
        Where-Object { $includeExt -contains [System.IO.Path]::GetExtension($_) } |
        Where-Object { $excludeNames -notcontains [System.IO.Path]::GetFileName($_) })
    Write-Host "Changed source files ($TargetBranch...HEAD): $($changed.Count)" -ForegroundColor Cyan

    $packages = @(Get-AiSdlcPackage -RepoRoot $RepoRoot | Where-Object { $_.Preflight })
    $packTests = @($packages | Where-Object { (Test-Path -LiteralPath $_.Preflight) -and (Get-Command -Name $_.Preflight).Parameters.ContainsKey('SkipTests') } | ForEach-Object Skill)
    $testCommand = [string](Get-AiSdlcConfig -RepoRoot $RepoRoot).commands.test
    $testJob = $null
    if ($testCommand.Trim() -and -not $SkipTests) {
        if ($packTests.Count -gt 0) {
            Write-Host "`nTests: commands.test is left to the $($packTests -join ', ') pre-flight, which runs the tests." -ForegroundColor Cyan
        }
        else {
            Write-Host "`nTests (commands.test) start now, beside the gates: $testCommand" -ForegroundColor Cyan
            $testJob = Start-ThreadJob -ScriptBlock {
                param([string]$Command, [string]$Root)
                Set-Location -LiteralPath $Root
                & pwsh -NoProfile -NonInteractive -Command $Command 2>&1 | ForEach-Object { "$_" }
                "TESTS-EXIT:$LASTEXITCODE"
            } -ArgumentList $testCommand, $RepoRoot
        }
    }

    # 1. Deterministic gates, the same ones the shared pull request job runs.
    Write-Host "`n[1] Deterministic gates (Invoke-LocalGates)..." -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot 'Invoke-LocalGates.ps1') -RepoRoot $RepoRoot
    Add-Result 'Gates (Invoke-LocalGates)' ($(if ($LASTEXITCODE -eq 0) { 'PASS' } else { 'FAIL' })) 'Invoke-LocalGates.ps1'

    $step = 2
    if ($testJob) {
        Write-Host "`n[$step] Tests (commands.test): $testCommand" -ForegroundColor Cyan
        $step++
        $testLines = @(Receive-Job -Job $testJob -Wait -AutoRemoveJob)
        $testLines | Where-Object { $_ -notmatch '^TESTS-EXIT:' } | ForEach-Object { Write-Host $_ }
        $testExit = [int](($testLines | Where-Object { $_ -match '^TESTS-EXIT:' } | Select-Object -Last 1) -replace '^TESTS-EXIT:', '')
        Add-Result 'Tests (commands.test)' ($(if ($testExit -eq 0) { 'PASS' } else { 'FAIL' })) "exit $testExit"
    }

    $packageArgs = @{
        RepoRoot     = $RepoRoot
        TargetBranch = $TargetBranch
        ChangedFiles = $changed
        SkipTests    = [bool]$SkipTests
        IncludeSonar = [bool]$IncludeSonar
        SkipScanners = [bool]$SkipScanners
    }
    foreach ($package in $packages) {
        Write-Host "`n[$step] $($package.Skill) pre-flight ($($package.Package))..." -ForegroundColor Cyan
        $step++
        if (-not (Test-Path -LiteralPath $package.Preflight)) {
            Add-Result "$($package.Skill) pre-flight" 'FAIL' "the preflight script $($package.Preflight) named in $($package.Manifest) does not exist"
            continue
        }
        $accepted = (Get-Command -Name $package.Preflight).Parameters.Keys
        $callArgs = @{}
        foreach ($key in $packageArgs.Keys) { if ($accepted -contains $key) { $callArgs[$key] = $packageArgs[$key] } }
        foreach ($row in @(& $package.Preflight @callArgs)) {
            if ($row -and $row.PSObject.Properties['Check'] -and $row.PSObject.Properties['Status']) { Add-Result $row.Check $row.Status $row.Detail }
        }
    }

    # Gitleaks, scoped to the branch's new commits. The shared pull request action scans too, and fails on
    # a finding outside the baseline, so a finding here is a FAIL row as well.
    Write-Host "`n[$step] gitleaks (branch commits, repo baseline)..." -ForegroundColor Cyan
    $step++
    Import-Module (Join-Path $PSScriptRoot 'GitleaksConfig.psm1') -Force
    $rulesPin = Get-GitleaksRulesPin
    $rulesFile = Join-Path ([System.IO.Path]::GetTempPath()) ('gitleaks-rules-' + [guid]::NewGuid().ToString('n') + '.toml')
    if (-not (Get-Command gitleaks -ErrorAction SilentlyContinue)) { Add-Result 'Gitleaks (secret scan)' 'SKIP' 'gitleaks not installed' }
    elseif (-not $rulesPin) { Add-Result 'Gitleaks (secret scan)' 'FAIL' 'gitleaks-rules.json pins no URL and SHA-256 for the default rule set' }
    elseif (-not $(try { Invoke-WebRequest -Uri $rulesPin.Url -OutFile $rulesFile -UseBasicParsing -ErrorAction Stop; $true } catch { $false })) {
        Add-Result 'Gitleaks (secret scan)' 'SKIP' "the pinned $($rulesPin.Name) rules could not be downloaded from $($rulesPin.Url); CI still scans with them"
    }
    elseif (-not (Test-GitleaksRulesFile -Path $rulesFile -Pin $rulesPin)) {
        Remove-Item -LiteralPath $rulesFile -ErrorAction SilentlyContinue
        Add-Result 'Gitleaks (secret scan)' 'FAIL' "the downloaded $($rulesPin.Name) rules do not match the SHA-256 in gitleaks-rules.json; nothing was scanned"
    }
    else {
        $baseline = Join-Path $RepoRoot 'gitleaks-baseline.json'
        $reportPath = Join-Path ([System.IO.Path]::GetTempPath()) ('preflight-gitleaks-' + [guid]::NewGuid().ToString('n') + '.json')
        $range = (git rev-parse --verify --quiet "$TargetBranch" 2>$null) ? "$TargetBranch..HEAD" : 'HEAD~1..HEAD'
        # The pinned rules of CI plus the allowlist of the AI-SDLC: the blob hashes in sync-manifest.json look like keys.
        $glConfig = New-GitleaksConfig -Path (Join-Path ([System.IO.Path]::GetTempPath()) ('gitleaks-ai-sdlc-' + [guid]::NewGuid().ToString('n') + '.toml')) -RulesPath $rulesFile
        $glArgs = @('git', '--no-banner', '--redact', '--config', $glConfig, '--report-format', 'json', '--report-path', $reportPath, '--log-opts', $range)
        if (Test-Path -LiteralPath $baseline) { $glArgs += @('--baseline-path', $baseline) }
        Remove-Item -LiteralPath $reportPath -ErrorAction SilentlyContinue
        & gitleaks @glArgs 2>&1 | Out-Null
        $glExit = $LASTEXITCODE
        Remove-Item -LiteralPath $glConfig, $rulesFile -ErrorAction SilentlyContinue
        # gitleaks writes the report only on a completed scan and exits 0 (clean) or its leak code (findings);
        # any other exit, or a missing report, means the scan itself failed and must not read as a pass.
        if (-not (Test-Path -LiteralPath $reportPath)) {
            Add-Result 'Gitleaks (secret scan)' 'FAIL' "gitleaks did not produce a report (exit $glExit); the scan did not complete"
        }
        else {
            $leakCount = @(Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json).Count
            if ($leakCount -eq 0) { Add-Result 'Gitleaks (secret scan)' 'PASS' "0 findings over $range (exit $glExit)" }
            else { Add-Result 'Gitleaks (secret scan)' 'FAIL' "$leakCount finding(s) over $range that gitleaks-baseline.json does not hold. Remove the secret from the branch commits; add a false positive to the baseline with Create-GitleaksBaseline.ps1" }
            Remove-Item -LiteralPath $reportPath -ErrorAction SilentlyContinue
        }
    }

    # Trivy / Checkov / Semgrep: attempted if available. No shipped pipeline runs them; the configs are best-effort.
    if (-not $SkipScanners) {
        Write-Host "`n[$step] Security scanners (not in the pull request pipeline)..." -ForegroundColor Cyan
        $dockerUp = $false
        if (Get-Command docker -ErrorAction SilentlyContinue) { docker info *> $null; $dockerUp = ($LASTEXITCODE -eq 0) }
        # Each scanner's output is left visible and its status is gated on the exit code: findings or an error
        # read as REVIEW, never a blind RAN. --exit-code 1 (trivy) and --error (semgrep) make findings non-zero.
        # Trivy: filesystem misconfig/vuln scan.
        if (Get-Command trivy -ErrorAction SilentlyContinue) {
            & trivy fs --quiet --exit-code 1 --scanners misconfig,vuln $RepoRoot
            Add-Result 'Trivy (fs misconfig/vuln)' ($(if ($LASTEXITCODE -eq 0) { 'PASS' } else { 'REVIEW' })) "exit $LASTEXITCODE (see output above)"
        }
        elseif ($dockerUp) {
            & docker run --rm -v "${RepoRoot}:/src" aquasec/trivy fs --quiet --exit-code 1 --scanners misconfig,vuln /src
            Add-Result 'Trivy (fs misconfig/vuln)' ($(if ($LASTEXITCODE -eq 0) { 'PASS' } else { 'REVIEW' })) "exit $LASTEXITCODE via docker (see output above)"
        }
        else { Add-Result 'Trivy (fs misconfig/vuln)' 'NOT-AVAIL' 'install trivy or start Docker; no pipeline runs it' }
        # Checkov: IaC (Bicep/YAML) misconfig. Exits non-zero on a failed check.
        if (Get-Command checkov -ErrorAction SilentlyContinue) {
            & checkov -d $RepoRoot --quiet --compact
            Add-Result 'Checkov (IaC misconfig)' ($(if ($LASTEXITCODE -eq 0) { 'PASS' } else { 'REVIEW' })) "exit $LASTEXITCODE (see output above)"
        }
        else { Add-Result 'Checkov (IaC misconfig)' 'NOT-AVAIL' 'pip install checkov (or Docker); no pipeline runs it' }
        # Semgrep: SAST. Local tokenless form is 'scan --config auto'.
        if (Get-Command semgrep -ErrorAction SilentlyContinue) {
            & semgrep scan --config auto --error --quiet $RepoRoot
            Add-Result 'Semgrep (SAST)' ($(if ($LASTEXITCODE -eq 0) { 'PASS' } else { 'REVIEW' })) "exit $LASTEXITCODE, local --config auto"
        }
        elseif ($dockerUp) {
            & docker run --rm -v "${RepoRoot}:/src" -w /src semgrep/semgrep semgrep scan --config auto --error --quiet /src
            Add-Result 'Semgrep (SAST)' ($(if ($LASTEXITCODE -eq 0) { 'PASS' } else { 'REVIEW' })) "exit $LASTEXITCODE via docker"
        }
        else { Add-Result 'Semgrep (SAST)' 'NOT-AVAIL' 'pip install semgrep or start Docker; no pipeline runs it' }
    }
    else { Add-Result 'Security scanners (Trivy/Checkov/Semgrep)' 'SKIP' '-SkipScanners set; no pipeline runs them' }
}
finally {
    Pop-Location
}

Write-Host "`n===== Pre-flight summary =====" -ForegroundColor Cyan
$results | Format-Table -AutoSize -Wrap | Out-String | Write-Host
$blocking = @($results | Where-Object { $_.Status -eq 'FAIL' })
if ($blocking.Count -gt 0) {
    Write-Host "$($blocking.Count) locally-reproducible check(s) failing. Fix, then re-run." -ForegroundColor Red
    exit 1
}
Write-Host "Deterministic checks pass. Review the REVIEW/NEEDS-*/OPT-IN rows before pushing." -ForegroundColor Green

if ($SkipTests) {
    Write-Host "No pre-flight receipt: -SkipTests left the tests out. Run without it before the push." -ForegroundColor Yellow
}
elseif (-not (Test-CleanTree -RepoRoot $RepoRoot)) {
    Write-Host "No pre-flight receipt: the working tree has uncommitted changes. Commit, then run again so the receipt names the commit you push." -ForegroundColor Yellow
}
else {
    $tree = Get-HeadTree -RepoRoot $RepoRoot
    $commit = ([string](git -C $RepoRoot rev-parse HEAD 2>$null)).Trim()
    $checks = @($results | Where-Object { $_.Status -eq 'PASS' } | ForEach-Object { $_.Check })
    $receipt = Write-PreflightReceipt -ReceiptRoot $ReceiptRoot -Tree $tree -Status PASS -Commit $commit -Checks $checks
    Write-Host "Pre-flight receipt written for commit $($commit.Substring(0, 8)): $receipt. The push hook accepts this commit." -ForegroundColor Green
}
exit 0
