#Requires -Version 7
<#
.SYNOPSIS
    Gate: AGENTS.md stays small enough to be read whole on every session.

.DESCRIPTION
    AGENTS.md is loaded into every Claude Code and GitHub Copilot session. The official Claude Code
    guidance and the published AGENTS.md studies agree on the failure mode: past roughly 150 lines the
    model starts to drop rules, and a rule it keeps breaking is a sign the file is too long, not that
    the rule needs repeating. This gate makes that limit a number the build checks instead of a habit.

    Two limits, both checked, because a line limit alone is met by writing longer lines: a maximum
    number of lines and a maximum number of words. Everything with detail belongs in docs/ and loads
    on demand; AGENTS.md keeps the constitution, the commands, and the pointers.

    Exit 0 when the file is within both limits, 1 when it is over either, 2 when the file is missing
    so nothing could be checked. A gate always says whether it could check at all.

.PARAMETER RepoRoot
    Repository root that contains AGENTS.md. Defaults to the folder that holds aisdlc.json, found from this script.

.PARAMETER MaxLines
    The most lines AGENTS.md may have, blank lines included. Defaults to 150.

.PARAMETER MaxWords
    The most words AGENTS.md may have. Defaults to 1800, which is 150 lines at the twelve words per
    line the source guidance assumes.

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Check-AgentsFileSize.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [int]$MaxLines = 150,
    [int]$MaxWords = 1800
)

Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

$ErrorActionPreference = 'Stop'

$file = Join-Path $RepoRoot (Get-AiSdlcConfig -RepoRoot $RepoRoot).paths.agentsFile
if (-not (Test-Path -LiteralPath $file)) {
    Write-Output "::warning::AGENTS.md size could not be checked: $file does not exist."
    exit 2
}

$lines = @(Get-Content -LiteralPath $file -Encoding utf8)
$lineCount = $lines.Count
$wordCount = 0
foreach ($line in $lines) {
    $wordCount += @($line -split '\s+' | Where-Object { $_ -ne '' }).Count
}

$over = [System.Collections.Generic.List[string]]::new()
if ($lineCount -gt $MaxLines) { $over.Add("$lineCount lines, the limit is $MaxLines") }
if ($wordCount -gt $MaxWords) { $over.Add("$wordCount words, the limit is $MaxWords") }

if ($over.Count -gt 0) {
    Write-Host "AGENTS.md is too long to be read whole: $($over -join '; ')." -ForegroundColor Red
    Write-Host "FIX: Move the detail to a docs/ page and leave a one-line pointer. AGENTS.md keeps the constitution, the commands, and the pointers." -ForegroundColor Red
    exit 1
}

Write-Host "AGENTS.md size OK: $lineCount lines, $wordCount words (limits $MaxLines lines, $MaxWords words)."
exit 0
