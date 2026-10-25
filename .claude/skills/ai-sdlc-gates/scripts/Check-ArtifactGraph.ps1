#Requires -Version 7
<#
.SYNOPSIS
    Validates the AI-SDLC artifact graph (.claude/skills/ai-sdlc-handbook/references/artifact-graph.md).

.DESCRIPTION
    Every artifact under docs/, docs-functional/, or specs/ that declares `story:` in YAML front-matter has "opted
    in" to the graph. For those, this checker verifies:
      1. `story` is a valid story key, quoted: story: "#42". An unquoted number (story: 42) counts as #42.
         An empty value is an error: an unquoted # starts a YAML comment, so story: #42 reads as empty.
      2. `phase` is present and one of the known phases.
      3. Each `relates.*` repo path resolves to a file. A URL is not checked.
      4. `intent.hypothesis`, when present as a repo path, resolves to a file. A URL is not checked.
    Artifacts without front-matter (or without `story:`) are ignored, so adoption is incremental.

    The `intent:` block (hypothesis / assumption / decision-drivers) and the `because:` block (a one-line
    reason per relates edge) carry the why. `intent.assumption` and `intent.decision-drivers` are free text;
    only -Strict asks for intent.assumption, and nothing checks decision-drivers. Under -Strict, every intent-bearing relates edge (adr, spec) must carry a non-empty
    `because.<edge>` reason; without -Strict the gate does not check it and prints nothing, so the build stays green while
    teams backfill reasons (the same advisory-then-blocking pattern the other gates use).

    Exits non-zero (fails the build) on any violation.

.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script. The roots come from paths.docsRoots and paths.specsRoot in aisdlc.json.

.PARAMETER Strict
    Additionally require a non-empty `because.<edge>` reason on every intent-bearing relates edge
    (adr, spec), and a non-empty intent.assumption on a discovery or elaboration artifact.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [switch]$Strict
)

Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

$ErrorActionPreference = 'Stop'

$phases = @('discovery', 'elaboration', 'create', 'mature', 'governance')
$storyPattern = Get-AiSdlcStoryPattern -RepoRoot $RepoRoot
$intentEdges = @('adr', 'spec')   # relates edges that should carry a `because` reason under -Strict

$rootNames = @(Get-AiSdlcPath -Name docsRoots -RepoRoot $RepoRoot -Relative) + @(Get-AiSdlcPath -Name specsRoot -RepoRoot $RepoRoot -Relative)
$roots = $rootNames | ForEach-Object { Join-Path $RepoRoot $_ } | Where-Object { Test-Path $_ }
if (-not $roots) {
    Write-Host ("Could not check: none of the artifact roots in aisdlc.json exists ({0})." -f ($rootNames -join ', ')) -ForegroundColor Yellow
    exit 2
}
$files = @()
if ($roots) { $files = Get-ChildItem -Path $roots -Recurse -Include *.md, *.markdown -File }

$violations = [System.Collections.Generic.List[string]]::new()
$checked = 0
$emptyStory = $false

function Get-FrontMatterValue([string]$fm, [string]$key) {
    $m = [regex]::Match($fm, "(?m)^\s*$key`:\s*(.+?)\s*$")
    if ($m.Success) { return $m.Groups[1].Value.Trim().Trim('"').Trim("'") }
    return $null
}

# Return the indented child lines of a top-level block key (e.g. `intent:` or `because:`), stopping at the
# first line dedented back to (or past) the key's own indentation. Blank lines inside the block are skipped.
function Get-BlockChildLines([string]$fm, [string]$key) {
    $m = [regex]::Match($fm, "(?ms)^(?<i>[ \t]*)$key`:[ \t]*\r?\n(?<b>.*)$")
    $result = [System.Collections.Generic.List[string]]::new()
    if (-not $m.Success) { return $result }
    $keyIndent = $m.Groups['i'].Value.Length
    foreach ($line in ($m.Groups['b'].Value -split '\r?\n')) {
        if ($line.Trim() -eq '') { continue }
        $w = [regex]::Match($line, '^[ \t]*').Value.Length
        if ($w -le $keyIndent) { break }
        $result.Add($line)
    }
    return $result
}

foreach ($file in $files) {
    $text = [string](Get-Content -LiteralPath $file.FullName -Raw)   # an empty file reads as $null
    $fmMatch = [regex]::Match($text, '\A\s*---\r?\n(.*?)\r?\n---\r?\n', 'Singleline')
    if (-not $fmMatch.Success) { continue }
    $fm = $fmMatch.Groups[1].Value

    $storyLine = [regex]::Match($fm, '(?m)^[ \t]*story:[ \t]*(?<v>.*?)[ \t]*$')
    if (-not $storyLine.Success) { continue }   # not opted into the graph

    $checked++
    $rel = [IO.Path]::GetRelativePath($RepoRoot, $file.FullName).Replace('\', '/')

    $story = ConvertTo-AiSdlcStoryKey -Value $storyLine.Groups['v'].Value -Pattern $storyPattern
    if ($story.Status -eq 'empty') {
        $emptyStory = $true
        $violations.Add("$rel : 'story:' has no value. An unquoted # starts a YAML comment, so the key reads as empty.")
    }
    elseif ($story.Status -eq 'invalid') {
        $violations.Add("$rel : story '$($story.Value)' is not a valid story key (e.g. ""#42"").")
    }

    $phase = Get-FrontMatterValue $fm 'phase'
    if (-not $phase) {
        $violations.Add("$rel : declares 'story' but is missing 'phase'.")
    }
    elseif ($phase.ToLower() -notin $phases) {
        $violations.Add("$rel : phase '$phase' is not one of: $($phases -join ', ').")
    }

    $relatesKeys = [System.Collections.Generic.List[string]]::new()
    $relBlock = [regex]::Match($fm, '(?ms)^\s*relates:\s*\r?\n(.*)$')
    if ($relBlock.Success) {
        foreach ($line in ($relBlock.Groups[1].Value -split '\r?\n')) {
            if ($line -match '^\s+([A-Za-z0-9_-]+):\s*(.+?)\s*$') {
                $k = $Matches[1]; $v = $Matches[2].Trim().Trim('"').Trim("'")
                $relatesKeys.Add($k)
                if ($v -match '^https?://') { continue }       # external URL: not checked
                if (-not (Test-Path (Join-Path $RepoRoot $v))) {
                    $violations.Add("$rel : relates.$k -> '$v' does not resolve to a file in the repo.")
                }
            }
            elseif ($line.Trim() -ne '') { break }              # end of the relates block
        }
    }

    # intent block: hypothesis is the upstream-why edge (resolve repo paths; URLs are not checked);
    # assumption is the riskiest belief (free text, presence enforced only under -Strict on why-bearing phases).
    $intentAssumption = $null
    foreach ($line in (Get-BlockChildLines $fm 'intent')) {
        if ($line -match '^\s+hypothesis:\s*(.+?)\s*$') {
            $hv = $Matches[1].Trim().Trim('"').Trim("'")
            if ($hv -and $hv -notmatch '^https?://' -and $hv -notmatch '^<') {
                if (-not (Test-Path (Join-Path $RepoRoot $hv))) {
                    $violations.Add("$rel : intent.hypothesis -> '$hv' does not resolve to a file in the repo.")
                }
            }
        }
        elseif ($line -match '^\s+assumption:\s*(.+?)\s*$') {
            $intentAssumption = $Matches[1].Trim().Trim('"').Trim("'")
        }
    }

    # Under -Strict only: enforce that the why was captured. A discovery or elaboration artifact must
    # carry a non-empty intent.assumption, and every intent-bearing relates edge
    # (adr, spec) must carry a non-empty because.<edge> reason. Not checked without -Strict.
    if ($Strict) {
        if (($phase) -and ($phase.ToLower() -in @('discovery', 'elaboration')) -and [string]::IsNullOrWhiteSpace($intentAssumption)) {
            $violations.Add("$rel : missing intent.assumption (required under -Strict for a $($phase.ToLower()) artifact).")
        }

        $becauseKeys = @{}
        foreach ($line in (Get-BlockChildLines $fm 'because')) {
            if ($line -match '^\s+([A-Za-z0-9_-]+):\s*(.+?)\s*$') {
                $becauseKeys[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
            }
        }
        foreach ($edge in $intentEdges) {
            if ($relatesKeys -contains $edge) {
                if (-not $becauseKeys.ContainsKey($edge) -or [string]::IsNullOrWhiteSpace($becauseKeys[$edge])) {
                    $violations.Add("$rel : relates.$edge has no 'because' reason (required under -Strict).")
                }
            }
        }
    }
}

if ($violations.Count -gt 0) {
    Write-Host "Artifact-graph violations (see .claude/skills/ai-sdlc-handbook/references/artifact-graph.md):" -ForegroundColor Red
    foreach ($v in $violations) { Write-Host "  $v" }
    if ($emptyStory) {
        Write-Host 'FIX: Quote the story key in the front matter, for example story: "#42".' -ForegroundColor Red
    }
    Write-Host "FIX: Correct the front-matter link each finding names, so every relates/story edge points at an artifact that exists (.claude/skills/ai-sdlc-handbook/references/artifact-graph.md)." -ForegroundColor Red
    Write-Host ("Checked {0} graph artifact(s); {1} violation(s)." -f $checked, $violations.Count) -ForegroundColor Red
    exit 1
}

$mode = if ($Strict) { ' (strict: edge reasons enforced)' } else { '' }
Write-Host ("Artifact graph OK: {0} graph artifact(s) validated, no violations.{1}" -f $checked, $mode)
exit 0
