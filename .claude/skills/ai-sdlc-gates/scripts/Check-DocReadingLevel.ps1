#Requires -Version 7
<#
.SYNOPSIS
    House-style doc lint: markdown prose must read at CEFR B2 for sentences and CEFR B1 for words.

.DESCRIPTION
    Reads every markdown file the repository keeps (AGENTS.md and the other root pages, and the
    folders in paths.readingLevelRoots of aisdlc.json) and reports two kinds of finding:

      long-sentence  a sentence with more than -MaxSentenceWords words (default 25). Headings and
                     table rows are not sentences and are skipped for this check. -SentenceScope
                     Paragraph also counts a sentence that wraps over several lines.
      hard-word      a word that the CEFR word lists place at B2, C1 or C2 and that is not also
                     listed at A1, A2 or B1, plus any word or phrase from the "Words to replace" table
                     in the handbook page language.md. A word the lists do not know at all (a product
                     name, an identifier, an acronym) is never flagged: the check only reports what
                     the lists positively place above B1.

    Front matter, fenced code, inline code, URLs and link targets are removed before checking, so a
    file path or a command never counts as prose. Simple inflections (plural, -ed, -ing, -er, -est,
    -ly) are folded back onto the headword before the lookup.

    The word lists live in the data/ folder beside this script (see the README there for source and licence): the
    CEFR-J Vocabulary Profile (A1 to B2) and the Octanove Vocabulary Profile (C1, C2). The allow list
    (paths.readingLevelAllowlist in aisdlc.json) names words the team accepts above B1, one per line.
    The shared allow list data/reading-level-allowlist.txt beside this script holds the exact terms the
    AI-SDLC itself uses, such as its skill and gate names; the gate accepts a word from either list.

    A folder that starts with a dot, such as .claude/skills or .github, is a hidden item on Linux and
    macOS, so every read of it passes -Force. Without that the gate cannot even open its own roots
    there, and it fails with a path error instead of a finding.

    Exits non-zero when any finding remains. A missing -Path, or a run that finds no markdown file at
    all, throws instead, because an empty run must not read as a pass. Registered as a Blocking gate
    in gates.json; the rule itself is the handbook page language.md and constitution clause C11.

.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script.
.PARAMETER Path
    One or more files or folders to check instead of the whole repository. Relative to RepoRoot.
.PARAMETER WordListPath
    Folder holding the CEFR word-list CSV files (columns headword, pos, CEFR). Defaults to the
    data folder beside this script.
.PARAMETER DenyListPath
    Markdown file whose "| Instead of | Write |" table supplies extra words to flag. Defaults to
    paths.languagePage in aisdlc.json when set, else language.md in the handbook skill beside this one
    (.claude/skills/ai-sdlc-handbook/references/language.md).
.PARAMETER AllowListPath
    Text file of accepted words, one per line, # starts a comment. Defaults to
    paths.readingLevelAllowlist in aisdlc.json, under RepoRoot.
.PARAMETER SharedAllowListPath
    The allow list the AI-SDLC ships, merged with AllowListPath. Defaults to
    data/reading-level-allowlist.txt beside this script.
.PARAMETER MaxSentenceWords
    Sentence length above which a sentence is reported. Default 25.
.PARAMETER SentenceScope
    Where a sentence is looked for. Line (the default) splits each line on its own, so a sentence that
    wraps onto the next line is counted in parts. Paragraph first joins the lines of a paragraph, and
    the lines of one list item, into one unit, so a wrapped sentence is counted whole. A blank line, a
    heading, a table row, a fence or a new list item starts a new unit. A finding names the line where
    the sentence starts. Line stays the default, so a repository whose pages pass today keeps passing.
.PARAMETER Detail
    Print every finding as file:line, however many there are, and drop the per-file summary.
.PARAMETER Top
    How many of the most frequent hard words to list in the summary. Default 40.
.PARAMETER MaxListed
    How many findings to print as file:line when -Detail is not passed. Default 50. Every failing run
    names its findings by file and line; this only caps how many. A run that printed counts per file
    and nothing else left the reader without a place to go, which is what the pipeline showed.
.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Check-DocReadingLevel.ps1
.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Check-DocReadingLevel.ps1 -Path docs -Detail
.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Check-DocReadingLevel.ps1 -Path docs,README.md -SentenceScope Paragraph
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string[]]$Path,
    [string]$WordListPath,
    [string]$DenyListPath,
    [string]$AllowListPath,
    [string]$SharedAllowListPath,
    [int]$MaxSentenceWords = 25,
    [ValidateSet('Line', 'Paragraph')]
    [string]$SentenceScope = 'Line',
    [switch]$Detail,
    [int]$Top = 40,
    [int]$MaxListed = 50
)

Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

$ErrorActionPreference = 'Stop'

$config = Get-AiSdlcConfig -RepoRoot $RepoRoot
if (-not $WordListPath) { $WordListPath = Join-Path $PSScriptRoot 'data' }
if (-not $DenyListPath) {
    $DenyListPath = if ($config.paths.languagePage) { Join-Path $RepoRoot $config.paths.languagePage } else { Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-handbook' 'references' 'language.md' }
}
if (-not $AllowListPath) { $AllowListPath = Join-Path $RepoRoot $config.paths.readingLevelAllowlist }
if (-not $SharedAllowListPath) { $SharedAllowListPath = Join-Path $PSScriptRoot 'data' 'reading-level-allowlist.txt' }

$levelRank = @{ A1 = 1; A2 = 2; B1 = 3; B2 = 4; C1 = 5; C2 = 6 }
$lowest = @{}
foreach ($csv in Get-ChildItem -Path $WordListPath -Filter *.csv -File -ErrorAction SilentlyContinue) {
    foreach ($row in Import-Csv -LiteralPath $csv.FullName) {
        $level = $row.CEFR
        if (-not $levelRank.ContainsKey($level)) { continue }
        foreach ($form in ($row.headword -split '/')) {
            $w = $form.Trim().ToLowerInvariant()
            if ($w -notmatch '^[a-z][a-z''-]*$') { continue }
            if (-not $lowest.ContainsKey($w) -or $levelRank[$level] -lt $levelRank[$lowest[$w]]) { $lowest[$w] = $level }
        }
    }
}
if ($lowest.Count -eq 0) { throw "No CEFR word list found under '$WordListPath'." }

$deny = [System.Collections.Generic.List[string]]::new()
$wordTablePages = @($DenyListPath, (Join-Path $PSScriptRoot ".." ".." "ai-sdlc-handbook" "references" "language.md")) |
    Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { (Get-Item -LiteralPath $_ -Force).FullName }

if (Test-Path -LiteralPath $DenyListPath) {
    $inTable = $false
    foreach ($line in Get-Content -LiteralPath $DenyListPath) {
        if ($line -match '^\|\s*Instead of\s*\|') { $inTable = $true; continue }
        if ($inTable -and $line -notmatch '^\|') { $inTable = $false; continue }
        if (-not $inTable -or $line -match '^\|\s*-') { continue }
        $left = ($line -split '\|')[1]
        foreach ($entry in ($left -split ',')) {
            $e = $entry.Trim().ToLowerInvariant()
            if ($e) { $deny.Add($e) }
        }
    }
}

$allow = [System.Collections.Generic.HashSet[string]]::new()
foreach ($listPath in @($SharedAllowListPath, $AllowListPath)) {
    if (-not (Test-Path -LiteralPath $listPath)) { continue }
    foreach ($line in Get-Content -LiteralPath $listPath) {
        $w = ($line -split '#')[0].Trim().ToLowerInvariant()
        if ($w) { [void]$allow.Add($w) }
    }
}

$irregular = @{
    began = 'begin'; begun = 'begin'; bound = 'bind'; bought = 'buy'; broke = 'break'; broken = 'break'; brought = 'bring'
    built = 'build'; caught = 'catch'; chose = 'choose'; chosen = 'choose'; came = 'come'; dealt = 'deal'; did = 'do'; done = 'do'
    drawn = 'draw'; drew = 'draw'; driven = 'drive'; drove = 'drive'; fallen = 'fall'; fell = 'fall'; felt = 'feel'; fought = 'fight'
    forgot = 'forget'; forgotten = 'forget'; found = 'find'; gave = 'give'; given = 'give'; gone = 'go'; got = 'get'; gotten = 'get'
    grew = 'grow'; grown = 'grow'; had = 'have'; heard = 'hear'; held = 'hold'; hidden = 'hide'; hid = 'hide'; kept = 'keep'
    knew = 'know'; known = 'know'; laid = 'lay'; led = 'lead'; left = 'leave'; lent = 'lend'; lost = 'lose'; made = 'make'
    meant = 'mean'; met = 'meet'; paid = 'pay'; ran = 'run'; rose = 'rise'; risen = 'rise'; said = 'say'; sat = 'sit'; saw = 'see'
    seen = 'see'; sent = 'send'; shook = 'shake'; shaken = 'shake'; shown = 'show'; sold = 'sell'; sought = 'seek'; spent = 'spend'
    spoke = 'speak'; spoken = 'speak'; stood = 'stand'; struck = 'strike'; stuck = 'stick'; swung = 'swing'; taken = 'take'
    taught = 'teach'; thought = 'think'; threw = 'throw'; thrown = 'throw'; told = 'tell'; took = 'take'; understood = 'understand'
    went = 'go'; woke = 'wake'; won = 'win'; wore = 'wear'; worn = 'wear'; written = 'write'; wrote = 'write'
    children = 'child'; feet = 'foot'; men = 'man'; people = 'person'; teeth = 'tooth'; women = 'woman'
    better = 'good'; best = 'good'; worse = 'bad'; worst = 'bad'; less = 'little'; least = 'little'; more = 'much'; most = 'much'
}

function Get-Candidates([string]$word) {
    $c = [System.Collections.Generic.List[string]]::new()
    $c.Add($word)
    if ($irregular.ContainsKey($word)) { $c.Add($irregular[$word]) }
    if ($word -match "'s$") { $c.Add($word.Substring(0, $word.Length - 2)) }
    if ($word -match 'ies$') { $c.Add($word.Substring(0, $word.Length - 3) + 'y') }
    if ($word -match 'es$') { $c.Add($word.Substring(0, $word.Length - 2)) }
    if ($word -match 's$') { $c.Add($word.Substring(0, $word.Length - 1)) }
    if ($word -match 'ied$') { $c.Add($word.Substring(0, $word.Length - 3) + 'y') }
    if ($word -match 'ed$') { $c.Add($word.Substring(0, $word.Length - 2)); $c.Add($word.Substring(0, $word.Length - 1)) }
    if ($word -match 'ing$') { $c.Add($word.Substring(0, $word.Length - 3)); $c.Add($word.Substring(0, $word.Length - 3) + 'e') }
    if ($word -match 'er$') { $c.Add($word.Substring(0, $word.Length - 2)); $c.Add($word.Substring(0, $word.Length - 1)) }
    if ($word -match 'est$') { $c.Add($word.Substring(0, $word.Length - 3)); $c.Add($word.Substring(0, $word.Length - 2)) }
    if ($word -match 'ly$') { $c.Add($word.Substring(0, $word.Length - 2)) }
    if ($word -match 'ily$') { $c.Add($word.Substring(0, $word.Length - 3) + 'y') }
    if ($word -match '(.)\1(ed|ing|er|est)$') { $c.Add(($word -replace '(.)\1(ed|ing|er|est)$', '$1')) }
    return $c
}

function Test-HardWord([string]$word) {
    $w = $word.ToLowerInvariant()
    if ($w.Length -lt 3) { return $false }
    if ($allow.Contains($w)) { return $false }
    $candidates = Get-Candidates $w
    foreach ($c in $candidates) { if ($allow.Contains($c)) { return $false } }
    $best = $null
    foreach ($c in $candidates) {
        if ($lowest.ContainsKey($c)) {
            $r = $levelRank[$lowest[$c]]
            if ($null -eq $best -or $r -lt $best) { $best = $r }
        }
    }
    return ($null -ne $best -and $best -gt $levelRank['B1'])
}

$targets = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
function Add-Targets([string]$p, [switch]$Required) {
    if (-not (Test-Path -LiteralPath $p)) {
        if ($Required) { throw "Path not found: '$p'. Pass a path that exists under '$RepoRoot'." }
        return
    }
    $item = Get-Item -LiteralPath $p -Force
    if ($item.PSIsContainer) {
        Get-ChildItem -LiteralPath $p -Recurse -Force -Include *.md, *.markdown -File |
            Where-Object { $_.FullName -notmatch '[\\/](bin|obj|node_modules|\.git)[\\/]' } |
            ForEach-Object { $targets.Add($_) }
    }
    else { $targets.Add($item) }
}
if ($Path) {
    foreach ($p in ($Path | ForEach-Object { $_ -split ',' } | Where-Object { $_.Trim() })) { Add-Targets (Join-Path $RepoRoot $p.Trim()) -Required }
}
else {
    foreach ($f in @($config.paths.agentsFile, 'README.md', 'ONBOARDING.md', 'CLAUDE.md', '.claude/CLAUDE.md') | Select-Object -Unique) { Add-Targets (Join-Path $RepoRoot $f) }
    foreach ($d in @(Get-AiSdlcPath -Name readingLevelRoots -RepoRoot $RepoRoot -Relative)) { Add-Targets (Join-Path $RepoRoot $d) }
}
if ($targets.Count -eq 0) { throw "No markdown file found under '$RepoRoot'. An empty set cannot be reported on, so this is a fault in the gate or its arguments, not a finding in the docs." }

$findings = [System.Collections.Generic.List[object]]::new()
$wordCounts = @{}
$perFile = [ordered]@{}
$sentences = 0
$wordsChecked = 0
$sentenceSplit = '(?:(?<=[.!?])|(?<=[.!?]\*\*)|(?<=[.!?]["'')\]]))\s+'
$unit = [System.Collections.Generic.List[object]]::new()

function Measure-Sentence([string]$Sentence, [int]$LineNumber) {
    $n = ([regex]::Matches($Sentence, "[A-Za-z][A-Za-z'-]*")).Count
    if ($n -eq 0) { return }
    $script:sentences++
    if ($n -gt $MaxSentenceWords) {
        $script:long++
        $findings.Add([pscustomobject]@{ File = $rel; Line = $LineNumber; Kind = 'long-sentence'; Detail = "$n words: " + $Sentence.Trim() })
    }
}

function Close-Unit {
    if ($unit.Count -eq 0) { return }
    $joined = [System.Text.StringBuilder]::new()
    $starts = [System.Collections.Generic.List[int]]::new()
    foreach ($part in $unit) {
        if ($joined.Length -gt 0) { [void]$joined.Append(' ') }
        $starts.Add($joined.Length)
        [void]$joined.Append($part.Text.Trim())
    }
    $whole = $joined.ToString()
    $cursor = 0
    foreach ($s in ($whole -split $sentenceSplit)) {
        $at = if ($s) { $whole.IndexOf($s, $cursor, [StringComparison]::Ordinal) } else { -1 }
        if ($at -lt 0) { $at = $cursor } else { $cursor = $at + $s.Length }
        $k = 0
        while ($k + 1 -lt $starts.Count -and $starts[$k + 1] -le $at) { $k++ }
        Measure-Sentence -Sentence $s -LineNumber $unit[$k].Line
    }
    $unit.Clear()
}

foreach ($file in $targets) {
    $rel = [IO.Path]::GetRelativePath($RepoRoot, $file.FullName).Replace('\', '/')
    $lines = Get-Content -LiteralPath $file.FullName
    $long = 0; $hard = 0
    $inFence = $false
    $i = 0
    $unit.Clear()
    $inFront = ($lines.Count -gt 0 -and $lines[0] -eq '---')
    foreach ($raw in $lines) {
        $i++
        if ($inFront) { if ($i -gt 1 -and $raw -eq '---') { $inFront = $false }; continue }
        if ($raw -match '^\s*(```|~~~)') { Close-Unit; $inFence = -not $inFence; continue }
        if ($inFence) { continue }
        $text = $raw -replace '<!--.*?-->', ' '
        $text = $text -replace '`[^`]*`', ' '
        $text = $text -replace '\]\([^)]*\)', '] '
        $text = $text -replace '\[Source:[^\]]*\]', ' '
        $text = $text -replace '"[^"]*[.!?]"', ' . '
        $text = $text -replace '"[^"]*"', ' '
        $text = $text -replace '“[^”]*[.!?]”', ' . '
        $text = $text -replace '“[^”]*”', ' '
        $isIndexRow = $raw -match '^\s*[-*]\s*\[[^\]]+\]\([^)]+\)\s+-\s'
        $text = $text -replace '<https?://[^>]+>', ' '
        $text = $text -replace 'https?://\S+', ' '
        $text = $text -replace '[*_>#]+', ' '
        $isHeading = $raw -match '^\s*#'
        $isTableRow = $raw -match '^\s*\|'
        $isSentenceLine = -not ($isHeading -or $isTableRow -or $isIndexRow)
        if ($SentenceScope -eq 'Paragraph') {
            $startsUnit = (-not $isSentenceLine) -or ($raw.Trim() -eq '') -or ($raw -match '^\s*(>\s*)?([-*+]|\d+[.)])\s+')
            if ($startsUnit) { Close-Unit }
        }
        if ($isTableRow -and $wordTablePages -contains $file.FullName) { continue }

        if ($isSentenceLine) {
            if ($SentenceScope -eq 'Paragraph') {
                if ($raw.Trim() -ne '') { $unit.Add([pscustomobject]@{ Line = $i; Text = $text }) }
            }
            else {
                foreach ($s in ($text -split $sentenceSplit)) { Measure-Sentence -Sentence $s -LineNumber $i }
            }
        }

        $lower = $text.ToLowerInvariant()
        foreach ($phrase in $deny) {
            $pattern = '(?<![a-z-])' + [regex]::Escape($phrase) + '(?![a-z-])'
            foreach ($m in [regex]::Matches($lower, $pattern)) {
                $hard++
                $wordCounts[$phrase] = 1 + [int]$wordCounts[$phrase]
                $findings.Add([pscustomobject]@{ File = $rel; Line = $i; Kind = 'hard-word'; Detail = $phrase })
            }
            $text = [regex]::Replace($text, $pattern, ' ', 'IgnoreCase')
        }
        foreach ($m in [regex]::Matches($text, "(?<![A-Za-z-])[A-Za-z][a-z'-]*(?![A-Za-z-])")) {
            $w = $m.Value
            if ($w -cmatch '^[A-Z]{2,}') { continue }
            $wordsChecked++
            if (Test-HardWord $w) {
                $hard++
                $key = $w.ToLowerInvariant()
                $wordCounts[$key] = 1 + [int]$wordCounts[$key]
                $findings.Add([pscustomobject]@{ File = $rel; Line = $i; Kind = 'hard-word'; Detail = $w })
            }
        }
    }
    Close-Unit
    if ($long -gt 0 -or $hard -gt 0) { $perFile[$rel] = [pscustomobject]@{ LongSentences = $long; HardWords = $hard } }
}

$longTotal = ($findings | Where-Object Kind -eq 'long-sentence').Count
$hardTotal = ($findings | Where-Object Kind -eq 'hard-word').Count

if ($findings.Count -eq 0) {
    Write-Host ("Reading level OK: {0} file(s), {1} sentence(s) at or under {2} words, no word above B1." -f $targets.Count, $sentences, $MaxSentenceWords)
    exit 0
}

Write-Host "Doc house-style: prose must read at CEFR B2 sentences and CEFR B1 words (.claude/skills/ai-sdlc-handbook/references/language.md)." -ForegroundColor Yellow

$listed = if ($Detail) { $findings } else { $findings | Select-Object -First $MaxListed }
foreach ($f in $listed) { Write-Host ("  {0}:{1}  [{2}]  {3}" -f $f.File, $f.Line, $f.Kind, $f.Detail) }
if (-not $Detail -and $findings.Count -gt $MaxListed) {
    Write-Host ("  ... and {0} more finding(s); run with -Detail to see them all." -f ($findings.Count - $MaxListed))
}

if (-not $Detail -and $findings.Count -gt 1) {
    Write-Host ""
    Write-Host "Per file (long sentences / hard words):"
    foreach ($k in $perFile.Keys) { Write-Host ("  {0,5} / {1,-5} {2}" -f $perFile[$k].LongSentences, $perFile[$k].HardWords, $k) }
    Write-Host ""
    Write-Host ("Most frequent hard words (top {0}):" -f $Top)
    $wordCounts.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First $Top |
        ForEach-Object { Write-Host ("  {0,5}  {1}" -f $_.Value, $_.Key) }
    Write-Host ""
}
Write-Host "FIX: Split a long sentence in two, and swap a hard word for the one you would say in a meeting (the handbook page language.md has the table). A word that is the exact name of a thing goes on the allow list, $($config.paths.readingLevelAllowlist)."
$pct = if ($sentences -gt 0) { [math]::Round(100.0 * $longTotal / $sentences, 1) } else { 0 }
Write-Host ("Found {0} long sentence(s) of {1} ({2}%) and {3} hard word(s) across {4} of {5} file(s)." -f $longTotal, $sentences, $pct, $hardTotal, $perFile.Count, $targets.Count) -ForegroundColor Yellow
exit 1
