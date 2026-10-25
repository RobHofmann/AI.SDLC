#Requires -Version 7
<#
.SYNOPSIS
    Checks a drafted documentation page against the facts file New-DocCandidate.ps1 wrote for it.

.DESCRIPTION
    New-DocCandidate.ps1 writes a facts file to doc-candidates/, and a drafting subagent writes the page
    from it into the draft path the facts file names. This script checks that draft before a person or
    the docs-reviewer agent reads it:

      1. Every name in backticks must be in the facts, the linkable pages, the units or the title. The
         names that are not are listed under UNVERIFIED:, and above -MaximumUnverifiedSymbols the
         draft is refused.
      2. The H1 is exactly the title in the facts file.
      3. A technical draft carries the front matter that names each of its units.
      4. The draft holds no em-dash character.
      5. A functional draft that names more code items than -MaximumFunctionalCodeNames gets a warning.
      6. The reading-level gate runs on the draft; its findings are listed under READING LEVEL:.

    It never edits the draft or the page. Exit codes: 0 the draft passes, 1 it is refused, 2 the
    draft or the facts file could not be read.

.PARAMETER Draft
    The drafted page, relative to RepoRoot or a full path.

.PARAMETER FactsFile
    The facts file New-DocCandidate.ps1 wrote for the page, relative to RepoRoot or a full path.

.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, or the git top level.

.PARAMETER MaximumUnverifiedSymbols
    Refuse the draft when it names more backticked symbols than this that are not in the facts.
    Defaults to 8.

.PARAMETER MaximumFunctionalCodeNames
    Warn when a functional draft names more code items (backticked names) than this. Defaults to 10.

.EXAMPLE
    pwsh .claude/skills/adopt-docs/scripts/Test-DocCandidate.ps1 -Draft doc-candidates/docs_hub-network.md -FactsFile doc-candidates/building-blocks_hub-network.facts.md
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Draft,
    [Parameter(Mandatory)][string]$FactsFile,
    [string]$RepoRoot,
    [int]$MaximumUnverifiedSymbols = 8,
    [int]$MaximumFunctionalCodeNames = 10
)

$ErrorActionPreference = 'Stop'
$gates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
Import-Module (Join-Path $gates 'AiSdlcConfig.psm1') -Force
Import-Module (Join-Path $gates 'DocCoverage.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath (Get-Location).Path }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

function Resolve-RepoFile([string]$Value) {
    if ([IO.Path]::IsPathRooted($Value)) { return $Value }
    return [IO.Path]::GetFullPath((Join-Path $RepoRoot $Value))
}

$draftFull = Resolve-RepoFile $Draft
$factsFull = Resolve-RepoFile $FactsFile
foreach ($file in $draftFull, $factsFull) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        Write-Host "Could not check: $file does not exist." -ForegroundColor Yellow
        Write-Host 'FIX: Write the draft into the draft path the facts file names, or run New-DocCandidate.ps1 again to write the facts file.'
        exit 2
    }
}

$text = [string](Get-Content -LiteralPath $draftFull -Raw)
$factsText = [string](Get-Content -LiteralPath $factsFull -Raw)

function Get-FactsField([string]$Name) {
    $match = [regex]::Match($factsText, "(?m)^- ${Name}:[ \t]*(?<value>.*?)[ \t]*\r?$")
    if ($match.Success) { return $match.Groups['value'].Value }
    return ''
}

function Get-FactsSection([string]$Heading) {
    $match = [regex]::Match($factsText, "(?ms)^## $Heading[ \t]*\r?\n(?<body>.*?)(?=^## |\z)")
    if ($match.Success) { return $match.Groups['body'].Value }
    return ''
}

$title = Get-FactsField 'Title'
$layer = Get-FactsField 'Layer'
$units = @((Get-FactsField 'Units') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (-not $title -or -not $layer) {
    Write-Host "Could not check: $FactsFile names no Title or Layer, so it is not a facts file of New-DocCandidate.ps1." -ForegroundColor Yellow
    Write-Host 'FIX: Run New-DocCandidate.ps1 again to write the facts file.'
    exit 2
}

$known = (Get-FactsSection 'Facts') + "`n" + (Get-FactsSection 'Linkable pages') + "`n" + ($units -join "`n") + "`n" + $title
$refusals = [System.Collections.Generic.List[string]]::new()

$invented = Get-DocUnverifiedSymbol -Candidate $text -Facts $known
if ($invented.Count -gt 0) {
    Write-Host ("UNVERIFIED: {0} symbol(s) the draft names are not in the facts:" -f $invented.Count) -ForegroundColor Yellow
    Write-Host ("  {0}" -f (($invented | Select-Object -First 12) -join ', ')) -ForegroundColor Yellow
    Write-Host '  Check each against the source before you copy that line, and the sentences around it too.' -ForegroundColor Yellow
}
if ($invented.Count -gt $MaximumUnverifiedSymbols) { $refusals.Add("it names $($invented.Count) symbols that are not in the facts, above the $MaximumUnverifiedSymbols allowed") }
if (-not [regex]::IsMatch($text, '(?m)^#\s+' + [regex]::Escape($title) + '\s*$')) { $refusals.Add("its H1 is not '# $title'") }
if ($layer -eq 'Technical') {
    $claims = Get-DocPageUnitClaim -Text $text
    $lost = @($units | Where-Object { $claims -notcontains $_ })
    if ($lost.Count -gt 0) { $refusals.Add("its front matter does not name the unit(s) $($lost -join ', ')") }
}
if ($text.Contains([char]0x2014)) { $refusals.Add('it holds the em-dash character (constitution C06)') }

if ($layer -eq 'Functional') {
    $codeNames = @([regex]::Matches($text, '`[^`\r\n]+`')).Count
    if ($codeNames -gt $MaximumFunctionalCodeNames) {
        Write-Host ("FUNCTIONAL: the draft names {0} code items, above the {1} a functional page should need. It reads like a technical page. Write what the reader gets, and name code only when the reader must act on it." -f $codeNames, $MaximumFunctionalCodeNames) -ForegroundColor Yellow
    }
}

$readingLevel = Join-Path $gates 'Check-DocReadingLevel.ps1'
if ((Test-Path -LiteralPath $readingLevel) -and $draftFull.StartsWith($RepoRoot, [StringComparison]::OrdinalIgnoreCase)) {
    $relativeDraft = [IO.Path]::GetRelativePath($RepoRoot, $draftFull).Replace('\', '/')
    $levelOutput = @(& pwsh -NoProfile -File $readingLevel -RepoRoot $RepoRoot -Path $relativeDraft -SentenceScope Paragraph -MaxSentenceWords 25 -Detail 2>&1 | ForEach-Object { "$_" })
    $levelFindings = @($levelOutput | Where-Object { $_ -match '\[(long-sentence|hard-word)\]' })
    if ($levelFindings.Count -gt 0) {
        Write-Host ("READING LEVEL: {0} finding(s) in the draft. Fix them before you copy the text into the page:" -f $levelFindings.Count) -ForegroundColor Yellow
        foreach ($finding in ($levelFindings | Select-Object -First 20)) { Write-Host "  $($finding.Trim())" -ForegroundColor Yellow }
    }
}

if ($refusals.Count -gt 0) {
    Write-Host 'Draft refused:' -ForegroundColor Red
    foreach ($reason in $refusals) { Write-Host "  - $reason" -ForegroundColor Red }
    Write-Host 'FIX: Redraft from the facts file: keep only names the facts hold, use the exact H1 and front matter, and replace each em-dash with " - ".' -ForegroundColor Red
    exit 1
}

Write-Host "Draft OK against its facts: $Draft. Verify each claim against the source, then copy only what you confirmed into $(Get-FactsField 'Page')." -ForegroundColor Green
exit 0
