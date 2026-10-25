#Requires -Version 7
<#
.SYNOPSIS
    Gate: a change that alters behaviour also moves its tests and its documentation.
.DESCRIPTION
    The deterministic half of the wrap-up flow. It answers the only question that needs no
    judgement, "did source change while tests and docs stood still", so a model is never spent on
    detection and the answer is the same for every tool and every developer.

    The changed-file set holds the commits since the base ref, the staged and unstaged edits and the
    new files git does not ignore. wrap-up runs this check before it commits, so a new page counts.

    Two checks, both computed from that changed-file set:

      1. TESTS. If a changed file under the source root carries behaviour and not one file under
         the test root changed, that is reported. This is deliberately NOT a mirrored-test-per-file
         rule: a DTO, an interface, a record, generated code and application startup legitimately
         have no test of their own, and a gate that demanded one would fire on dozens of correct
         files and be answered with empty tests. Whether the tests that exist are good enough is a
         coverage question, which Check-Coverage.ps1 (C04) and the SonarCloud quality gate already
         answer.

      2. DOCUMENTATION. If a source area changed and neither its mapped documentation area nor an
         ADR moved, that is reported. An ADR counts for any area, because recording a decision is
         the documentation for a change that rests on one.

    ADVISORY by default: it reports and returns 0. Pass -Strict to make it fail, which is what the
    pre-push hook and CI use once the team has seen the false-positive rate.

    NO-OP when nothing under the source root changed, so a documentation-only or pipeline-only change is
    never blocked by it.
.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script. The source
    root, the test root, the source file types and the map from source areas to doc areas come from
    paths.sourceRoot, paths.testRoot, paths.sourceExtensions and paths.sourceDocMap in aisdlc.json.
    With no source root configured, nothing counts as behaviour and the check is a no-op.
.PARAMETER BaseRef
    The ref the change is measured against. Defaults to origin/main.
.PARAMETER ChangedFiles
    Explicit repo-relative paths, bypassing git. Used by the tests. Falls back to the newline-separated
    CHANGED_FILES environment variable, which the pipeline sets from the pull request diff, because a
    CI checkout has no base branch to diff against.
.PARAMETER Strict
    Report the finding through the exit code (1) instead of only printing it. The pre-push deny hook,
    Invoke-LocalGates and the CI step all pass it; whether a finding then blocks is decided by the
    caller, which for CI is Invoke-LocalGates.ps1 (through GateAnnotation.psm1) in Advisory or Blocking
    mode.
.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Check-ChangeCompleteness.ps1
.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Check-ChangeCompleteness.ps1 -Strict -BaseRef origin/main
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$BaseRef = 'origin/main',
    [string[]]$ChangedFiles,
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

$script:Config = Get-AiSdlcConfig -RepoRoot $RepoRoot
$script:SourcePrefix = if ($script:Config.paths.sourceRoot) { $script:Config.paths.sourceRoot.TrimEnd('/') + '/' } else { $null }
$script:TestPrefix = if ($script:Config.paths.testRoot) { $script:Config.paths.testRoot.TrimEnd('/') + '/' } else { $null }
$script:SourceExtensions = @($script:Config.paths.sourceExtensions | Where-Object { $_ })
$script:DocPrefixes = @($script:Config.paths.docsRoots | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('/') + '/' })
$script:AdrPrefix = $script:Config.paths.adrFolder.TrimEnd('/') + '/'
$script:DocMap = @($script:Config.paths.sourceDocMap | Where-Object { $_ } | ForEach-Object { @{ Source = $_.source; Docs = @($_.docs) } })

$script:TestExempt = @(
    'Program.cs'
    'GlobalUsings.cs'
    '.Designer.cs'
    '.g.cs'
    '.razor.css'
)

$script:TestExemptFolders = @(
    '/Models/'
    '/Contracts/'
    '/Dtos/'
    '/Migrations/'
)

function Get-ChangedFile {
    param([string]$Root, [string]$Base, [string[]]$Explicit)

    if ($Explicit) { return $Explicit }
    if ($env:CHANGED_FILES) { return @($env:CHANGED_FILES -split "`r?`n" | Where-Object { $_.Trim() }) }

    Push-Location $Root
    try {
        $mergeBase = & git merge-base $Base HEAD 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $mergeBase) { return @() }

        $tracked = & git diff --name-only $mergeBase HEAD 2>$null
        $staged = & git diff --name-only --cached 2>$null
        $working = & git diff --name-only 2>$null
        $untracked = & git ls-files --others --exclude-standard 2>$null

        return @($tracked) + @($staged) + @($working) + @($untracked) | Where-Object { $_ } | Sort-Object -Unique
    }
    finally { Pop-Location }
}

function Test-CarriesBehaviour {
    param([string]$Path)

    if (-not $script:SourcePrefix -or -not $Path.StartsWith($script:SourcePrefix)) { return $false }
    if (-not ($script:SourceExtensions | Where-Object { $Path.EndsWith($_) })) { return $false }

    foreach ($suffix in $script:TestExempt) {
        if ($Path.EndsWith($suffix)) { return $false }
    }
    foreach ($folder in $script:TestExemptFolders) {
        if ($Path.Contains($folder)) { return $false }
    }

    return $true
}

function Get-MissingDoc {
    param([string[]]$Changed)

    $docsMoved = @($Changed | Where-Object { $path = $_; $script:DocPrefixes | Where-Object { $path.StartsWith($_) } })
    if ($docsMoved.Count -gt 0) {
        $adr = @($docsMoved | Where-Object { $_.StartsWith($script:AdrPrefix) })
        if ($adr.Count -gt 0) { return @() }
    }

    $missing = @()
    foreach ($entry in $script:DocMap) {
        $touched = @($Changed | Where-Object { $_.StartsWith($entry.Source) -and (Test-CarriesBehaviour $_) })
        if ($touched.Count -eq 0) { continue }

        $covered = $false
        foreach ($docPrefix in $entry.Docs) {
            if ($docsMoved | Where-Object { $_.StartsWith($docPrefix) }) { $covered = $true; break }
        }

        if (-not $covered) {
            $missing += [pscustomobject]@{
                Source = $entry.Source
                Docs = ($entry.Docs -join ', ')
                Files = $touched.Count
            }
        }
    }

    return $missing
}

function Invoke-ChangeCompletenessCheck {
    param([string[]]$Changed)

    $behaviour = @($Changed | Where-Object { Test-CarriesBehaviour $_ })
    $findings = @()

    if ($behaviour.Count -eq 0) {
        return [pscustomobject]@{ NoOp = $true; Findings = @() }
    }

    $testsMoved = @($Changed | Where-Object { $script:TestPrefix -and $_.StartsWith($script:TestPrefix) })
    if ($testsMoved.Count -eq 0) {
        $findings += "TESTS: $($behaviour.Count) source file(s) carry behaviour and no file under $($script:Config.paths.testRoot) changed. Add the tests, or say in the pull request why this change cannot carry one."
    }

    foreach ($gap in (Get-MissingDoc -Changed $Changed)) {
        $findings += "DOCS: $($gap.Files) changed file(s) under $($gap.Source) with nothing moved under $($gap.Docs) and no ADR."
    }

    return [pscustomobject]@{ NoOp = $false; Findings = $findings }
}

if ($MyInvocation.InvocationName -eq '.') { return }

$changed = Get-ChangedFile -Root $RepoRoot -Base $BaseRef -Explicit $ChangedFiles
$result = Invoke-ChangeCompletenessCheck -Changed $changed

if ($result.NoOp) {
    Write-Host "Change completeness: no behaviour change to check."
    exit 0
}

if ($result.Findings.Count -eq 0) {
    Write-Host "Change completeness: tests and documentation moved with the code."
    exit 0
}

foreach ($finding in $result.Findings) {
    Write-Host "Change completeness: $finding"
}

Write-Host "FIX: Run the wrap-up skill, which brings the tests and both documentation layers up to what the code now does."

if ($Strict) { exit 1 }

exit 0
