#Requires -Version 7
<#
.SYNOPSIS
    Gate: the shared parts of AGENTS.md, all packages together, stay within a budget, so every consumer
    keeps room for its own part.

.DESCRIPTION
    Sync-AgentsFile.ps1 writes the part of the core and of each pack into the AGENTS.md of every
    consumer, and Check-AgentsFileSize.ps1 fails a consumer past 150 lines or 1800 words. A line added to
    a shared part is a line taken from every consumer, so a consumer can break on a change it never made.
    This gate counts the parts of all packages together, as a consumer that installs every pack gets
    them, including the two marker lines around each part, and fails past the budget.

    Exit codes follow the gate contract: 0 within budget, 1 over budget, 2 could not check.

.PARAMETER RepoRoot
    The AI.SDLC repository root. Defaults to the folder above this script.

.PARAMETER MaxLines
    The line budget for all shared parts together. Defaults to 50, a third of the consumer limit.

.PARAMETER MaxWords
    The word budget for all shared parts together. Defaults to 600, a third of the consumer limit.

.EXAMPLE
    pwsh tools/Check-SharedAgentsPartSize.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [int]$MaxLines = 50,
    [int]$MaxWords = 600
)

if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$parts = @('core', 'packs') | ForEach-Object { Join-Path $RepoRoot $_ } | Where-Object { Test-Path -LiteralPath $_ } |
    ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -File -Force -Filter 'agents-*.md' } |
    Where-Object { $_.DirectoryName -match '[\\/]assets$' }
if (-not $parts) {
    Write-Host 'Could not check: no agents-*.md part under core/ or packs/.' -ForegroundColor Yellow
    exit 2
}

$lines = 0; $words = 0
$rows = foreach ($part in $parts) {
    $text = (Get-Content -LiteralPath $part.FullName -Raw) -replace "`r`n", "`n"
    $l = @($text.TrimEnd("`n") -split "`n").Count + 2
    $w = @($text -split '\s+' | Where-Object { $_ }).Count
    $lines += $l; $words += $w
    [pscustomobject]@{ Part = [IO.Path]::GetRelativePath($RepoRoot, $part.FullName).Replace('\', '/'); Lines = $l; Words = $w }
}

if ($lines -gt $MaxLines -or $words -gt $MaxWords) {
    Write-Host "Shared AGENTS.md parts over budget: $lines lines (budget $MaxLines), $words words (budget $MaxWords)." -ForegroundColor Red
    Write-Host 'FIX: Move the detail to a handbook page and leave a one-line pointer in the part; every consumer pays for each line here.' -ForegroundColor Red
    $rows | ForEach-Object { Write-Host ("  {0,4} lines {1,5} words  {2}" -f $_.Lines, $_.Words, $_.Part) }
    exit 1
}
Write-Host "Shared AGENTS.md parts OK: $lines lines (budget $MaxLines), $words words (budget $MaxWords), across $(@($rows).Count) part(s)."
exit 0
