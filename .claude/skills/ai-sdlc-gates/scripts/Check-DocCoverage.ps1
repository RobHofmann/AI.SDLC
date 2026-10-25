#Requires -Version 7
<#
.SYNOPSIS
    Gate: the repository has a technical and a functional documentation layer, and every unit has a page.

.DESCRIPTION
    The wiki gates check the pages that exist. None of them sees a page that was never written. A
    repository with a page for half its projects passes every other doc gate, and a reader looking
    for the other half finds nothing and guesses. This gate reads the other side: what should have
    a page.

    It checks two things (clause C05):

    1. Both layers exist. paths.technicalDocs and paths.functionalDocs in aisdlc.json each name a
       folder that holds an index.md and at least one other page. The technical layer says how the
       repository is built; the functional layer says what it gives its users.
    2. Every unit has a technical page. The installed packs name the units (a .NET project, a Bicep
       building block), and docs.units in aisdlc.json can replace that list. DocCoverage.psm1 says
       how a page covers a unit. For each unit without a page it prints the page to write.

    A decision record is never counted as a page, because an ADR records a decision and not a part.
    To leave a unit out on purpose, list its path under docs.unitExclude in aisdlc.json.

    Exit 0 clean, 1 a finding. The adopt-docs skill turns the findings into pages.

.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script.

.PARAMETER AsObject
    Return the findings as objects and do not exit, for a script or a test that needs the list.

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Check-DocCoverage.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [switch]$AsObject
)

Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DocCoverage.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$ErrorActionPreference = 'Stop'

$layerFindings = @(Get-DocLayerFinding -RepoRoot $RepoRoot)
$coverage = @(Get-DocCoverage -RepoRoot $RepoRoot)
$missing = @($coverage | Where-Object { $_.Pages.Count -eq 0 })

if ($AsObject) {
    return [pscustomobject]@{
        Layers   = $layerFindings
        Units    = $coverage
        Missing  = $missing
    }
}

if ($layerFindings.Count -gt 0 -or $missing.Count -gt 0) {
    Write-Host 'Documentation coverage: a layer or a page is missing.' -ForegroundColor Red
    foreach ($finding in $layerFindings) { Write-Host "  [layer] $($finding.Problem)" }
    foreach ($unit in $missing) { Write-Host "  [no page] $($unit.Kind) $($unit.Unit) has no technical page; write $($unit.SuggestedPage)" }
    Write-Host 'FIX: Run the adopt-docs skill, which drafts each missing page for review. A page that covers a unit under another name lists it in its front matter as "unit: <path>".'
    Write-Output "::error::Documentation coverage: $($layerFindings.Count) layer problem(s) and $($missing.Count) unit(s) without a page."
    exit 1
}

Write-Host ("Documentation coverage OK: both layers exist, and {0} unit(s) each have a technical page." -f $coverage.Count)
exit 0
