#Requires -Version 7
<#
.SYNOPSIS
    House-style doc lint (blocking): a documentation line either carries a fact or it is not written.

.DESCRIPTION
    Generated documentation fails in a particular way. It produces rows that name a thing and then say
    nothing about it, sentences admitting the source did not describe something, and fragments left
    behind by a template. A page like that reads as complete and tells a reader nothing, and it also
    satisfies any check that counts how many names appear, which is the worst combination: the page
    looks better by every measure while being worth less.

    The rules here were Pester assertions inside the tool-wiring suite, which made them a blocking CI
    failure with no advisory mode, reported as "the gate scripts themselves regressed". They are
    repository-wide documentation rules, so they belong beside their siblings Check-DocEmDashes.ps1
    (C06), Check-DocLineCitations.ps1 (C02) and Check-DocPersonNames.ps1, run through Invoke-LocalGates.ps1
    (through GateAnnotation.psm1) with an explicit mode and an escalation ramp.

    WHAT IT REPORTS.
      [voidclaim]  a page telling the reader that something is "not described in the cited sources".
                   A row that carries no fact is worse than no row.
      [emptyrow]   a table row naming a thing in backticks whose remaining cells are empty, a dash, or
                   n/a. 329 of these were deleted from this repository in one pass.
      [fragment]   a template leftover such as "Public type Source", which is not a sentence.
      [emptytable] a table header and separator with no rows under them.
      [machinepath] an absolute path from somebody's machine, which resolves for nobody else.

    Advisory by default; -FailOnFinding exits non-zero.

.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script.

.PARAMETER DocRoots
    Directories to scan. Defaults to paths.docsRoots in aisdlc.json.

.PARAMETER ExplainPage
    Page names exempt from the [voidclaim] rule because they quote the phrase in order to forbid it.

.PARAMETER MaximumFindingsPerRule
    How many findings of one kind to print before summarising the rest.

.PARAMETER FailOnFinding
    Exit 1 when anything is reported. Off by default.

.EXAMPLE
    ./Check-DocRowContent.ps1

.EXAMPLE
    ./Check-DocRowContent.ps1 -FailOnFinding
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string[]]$DocRoots,
    [string[]]$ExplainPage = @('graphify-code-graph.md', 'docs-wiki.md'),
    [int]$MaximumFindingsPerRule = 20,
    [switch]$FailOnFinding
)

Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }
if (-not $DocRoots) { $DocRoots = @(Get-AiSdlcPath -Name docsRoots -RepoRoot $RepoRoot -Relative) }
if (-not @($DocRoots | Where-Object { Test-Path (Join-Path $RepoRoot $_) })) {
    Write-Host ("Could not check: none of the doc roots exists ({0})." -f ($DocRoots -join ', ')) -ForegroundColor Yellow
    exit 2
}

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ToolOutput.psm1') -Force

if (Test-Path -LiteralPath $RepoRoot) { $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path }

$script:VoidClaim = 'not described in the cited sources'
$script:Fragment = @('Public type Source', 'Public named member Source', 'Public model Source', '` - source:', 'no longer exists in the cited source set')
$script:EmptyCell = @('', '-', 'n/a', 'N/A')

function Test-EmptyNamedRow {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)

    $trimmed = $Line.Trim()
    if (-not $trimmed.StartsWith('| `')) { return $false }
    $cells = @($trimmed.Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
    if ($cells.Count -lt 2) { return $false }
    $prose = @($cells[1..($cells.Count - 1)] | Where-Object { -not ($_.StartsWith('`') -and $_.EndsWith('`')) })
    if ($prose.Count -eq 0) { return $false }
    return (@($prose | Where-Object { $_ -notin $script:EmptyCell }).Count -eq 0)
}

$pages = [System.Collections.Generic.List[object]]::new()
foreach ($relative in $DocRoots) {
    $full = Join-Path $RepoRoot $relative
    if (-not (Test-Path -LiteralPath $full)) { continue }
    foreach ($file in (Get-ChildItem -LiteralPath $full -Recurse -Filter *.md -File)) { $pages.Add($file) }
}

$findings = [System.Collections.Generic.List[object]]::new()

foreach ($page in $pages) {
    $relative = ($page.FullName.Substring($RepoRoot.Length).TrimStart([char]92, '/')).Replace([char]92, '/')
    $text = Get-Content -LiteralPath $page.FullName -Raw -Encoding utf8
    if (-not $text) { continue }
    $lines = @(Get-Content -LiteralPath $page.FullName -Encoding utf8)

    if ($page.Name -notin $ExplainPage -and $text -match [regex]::Escape($script:VoidClaim)) {
        $findings.Add([pscustomobject]@{ Rule = 'voidclaim'; Page = $relative; Detail = $script:VoidClaim })
    }

    foreach ($fragment in $script:Fragment) {
        if ($page.Name -in $ExplainPage) { continue }
        if ($text.Contains($fragment)) {
            $findings.Add([pscustomobject]@{ Rule = 'fragment'; Page = $relative; Detail = $fragment })
        }
    }

    if ($text -match '[A-Za-z]:\\[A-Za-z0-9_.-]') {
        $findings.Add([pscustomobject]@{ Rule = 'machinepath'; Page = $relative; Detail = 'an absolute path from one machine' })
    }

    foreach ($line in $lines) {
        if (Test-EmptyNamedRow -Line $line) {
            $name = @($line.Trim().Trim('|') -split '\|')[0].Trim()
            $findings.Add([pscustomobject]@{ Rule = 'emptyrow'; Page = $relative; Detail = $name })
        }
    }

    for ($i = 0; $i -lt $lines.Count - 1; $i++) {
        if (-not $lines[$i].StartsWith('|')) { continue }
        if ($lines[$i + 1] -notmatch '^\|[\s:|-]+\|\s*$') { continue }
        if (($i + 2) -lt $lines.Count -and $lines[$i + 2].StartsWith('|')) { continue }
        $findings.Add([pscustomobject]@{ Rule = 'emptytable'; Page = $relative; Detail = 'a header with no rows under it' })
    }
}

Write-Invariant -Template 'Pages read: {0:N0}' -Values @($pages.Count)
Write-Host ''

if ($findings.Count -eq 0) {
    Write-Host 'Every documented row carries a fact, and no page cites a path only its author can open.' -ForegroundColor Green
    exit 0
}

foreach ($rule in @('voidclaim', 'emptyrow', 'fragment', 'emptytable', 'machinepath')) {
    $forRule = @($findings | Where-Object { $_.Rule -eq $rule })
    if ($forRule.Count -eq 0) { continue }
    foreach ($finding in ($forRule | Select-Object -First $MaximumFindingsPerRule)) {
        Write-Invariant -Template '   [{0}] {1}: {2}' -Values @($finding.Rule, $finding.Page, $finding.Detail)
    }
    if ($forRule.Count -gt $MaximumFindingsPerRule) {
        Write-Invariant -Template '   [{0}] and {1:N0} more' -Values @($rule, ($forRule.Count - $MaximumFindingsPerRule))
    }
}

Write-Host ''
Write-Invariant -Template '{0:N0} finding(s) across {1:N0} page(s).' -Values @($findings.Count, @($findings | Select-Object -ExpandProperty Page -Unique).Count) -ForegroundColor Yellow
Write-Host 'A row that carries no fact is worse than no row: it makes a page look complete and tells the reader nothing.'

if ($FailOnFinding) {
    Write-Host "FIX: Put the fact in the row, or remove the row. A row that says a thing is not described tells the reader nothing they could not already see."
    exit 1
}
exit 0
