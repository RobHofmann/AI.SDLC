#Requires -Version 7
<#
.SYNOPSIS
    Reports xUnit test classes that lack the AI-SDLC Story trait, and fails on malformed Story keys.

.DESCRIPTION
    The AI-SDLC convention tags new or changed tests with [Trait("Story","#42")] so the
    story's tests can be found from the story key. There is no per-criterion AC trait. This script
    scans xUnit test classes under the test root (paths.testRoot in aisdlc.json) and reports which
    test CLASSES carry no [Trait("Story", ...)]
    on the class or on any of their [Fact]/[Theory] methods.

    A class counts as a test class when its body contains at least one [Fact] or [Theory]; mocks,
    fixtures, and other helper types are ignored. A class counts as covered when a [Trait("Story", ...)]
    appears anywhere in that class body (class-level attribute or on any method).

    Adoption is incremental: the existing suite predates this convention, so a blanket "every test must
    be tagged" gate would fail everything. Therefore this script is REPORT-ONLY by default (it lists the
    untagged classes and exits 0). Pass -Strict once the convention is adopted to fail the build when any
    test class is still untagged.

    Independently of -Strict, where a Story trait DOES exist its value must be a whole story key: the
    pattern of Get-AiSdlcStoryPattern (#42, or owner/repo#42 across repositories, unless
    tracker.keyPattern in aisdlc.json sets another one), or the placeholder LEGACY-0 for a test that
    predates the rule. A malformed key always fails the build (exit 1), because a typo'd key is a defect
    regardless of adoption progress.

    This is a line scanner in the style of Check-DocLineCitations.ps1, not a Roslyn parser. It assumes the
    repository's prevailing test layout (attributes on their own lines, braces that balance per file). It
    is intended as a CI signal, not a compiler.

.PARAMETER RepoRoot
    Repository root that contains the test root. Defaults to the folder that holds aisdlc.json, found from this script.

.PARAMETER Strict
    Exit non-zero when any test class lacks a [Trait("Story", ...)]. Off by default (report-only).
    Malformed Story keys fail the build regardless of this switch.

.EXAMPLE
    pwsh .claude/skills/dotnet-gates/scripts/Check-StoryTraits.ps1
    Reports counts and the list of untagged test classes; exits 0 unless a malformed key is found.

.EXAMPLE
    pwsh .claude/skills/dotnet-gates/scripts/Check-StoryTraits.ps1 -Strict
    Same report, but exits 1 if any test class is untagged.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [switch]$Strict
)

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

$ErrorActionPreference = 'Stop'

$testsRel = ([string](Get-AiSdlcConfig -RepoRoot $RepoRoot).paths.testRoot).TrimEnd('/')
if (-not $testsRel) {
    Write-Host 'Could not check: aisdlc.json names no paths.testRoot.' -ForegroundColor Yellow
    exit 2
}
$testsDir = Join-Path $RepoRoot $testsRel
if (-not (Test-Path $testsDir)) {
    Write-Host "No tests directory found at $testsDir; nothing to check." -ForegroundColor Yellow
    exit 0
}

$storyKeyPattern = '^(?:' + (Get-AiSdlcStoryPattern -RepoRoot $RepoRoot) + ')$'
$legacyKey = 'LEGACY-0'
$testMethodPattern = '\[\s*(Fact|Theory)\b'
$classDeclPattern = '^\s*(?:public|internal|private|protected|sealed|static|abstract|partial|\s)*\bclass\s+([A-Za-z_]\w*)'
$storyTraitPattern = 'Trait\s*\(\s*"Story"\s*,\s*"([^"]*)"\s*\)'

$untagged = [System.Collections.Generic.List[object]]::new()
$malformed = [System.Collections.Generic.List[object]]::new()
$taggedCount = 0
$testClassCount = 0

$files = Get-ChildItem -Path $testsDir -Recurse -Filter *.cs -File
foreach ($file in $files) {
    $rel = [IO.Path]::GetRelativePath($RepoRoot, $file.FullName).Replace('\', '/')
    $lines = Get-Content -LiteralPath $file.FullName

    $depth = 0
    $current = $null
    $pendingStory = $false
    $classes = [System.Collections.Generic.List[object]]::new()

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $lineNo = $i + 1

        $classMatch = [regex]::Match($line, $classDeclPattern)
        if ($classMatch.Success -and $depth -eq 0) {
            $current = [pscustomobject]@{
                Name       = $classMatch.Groups[1].Value
                Line       = $lineNo
                HasTest    = $false
                HasStory   = $pendingStory
            }
            $pendingStory = $false
            $classes.Add($current)
        }

        foreach ($keyMatch in [regex]::Matches($line, $storyTraitPattern)) {
            $value = $keyMatch.Groups[1].Value
            if ($depth -eq 0 -and -not $classMatch.Success) {
                # A class-level [Trait] sits on a line above the class declaration, where $current is
                # still the previous class. Defer it to the next class declaration instead.
                $pendingStory = $true
            }
            elseif ($current) {
                $current.HasStory = $true
            }
            if ($value -cne $legacyKey -and $value -cnotmatch $storyKeyPattern) {
                $malformed.Add([pscustomobject]@{ File = $rel; Line = $lineNo; Text = $line.Trim() })
            }
        }

        if ($current -and ($line -match $testMethodPattern)) {
            $current.HasTest = $true
        }

        $depth += ([regex]::Matches($line, '\{')).Count
        $depth -= ([regex]::Matches($line, '\}')).Count
        if ($depth -lt 0) { $depth = 0 }
    }

    foreach ($cls in $classes) {
        if (-not $cls.HasTest) { continue }
        $testClassCount++
        if ($cls.HasStory) {
            $taggedCount++
        }
        else {
            $untagged.Add([pscustomobject]@{ File = $rel; Line = $cls.Line; Text = "class $($cls.Name)" })
        }
    }
}

Write-Host "Story-trait coverage ($testsRel):"
Write-Host ("  Test classes found : {0}" -f $testClassCount)
Write-Host ("  With Story trait   : {0}" -f $taggedCount)
Write-Host ("  Missing Story trait: {0}" -f $untagged.Count)
Write-Host ("  Malformed keys     : {0}" -f $malformed.Count)

if ($malformed.Count -gt 0) {
    Write-Host ""
    Write-Host "Malformed [Trait(""Story"", ...)] key(s) - must be a whole story key such as #42, or ${legacyKey}:" -ForegroundColor Red
    foreach ($m in $malformed) { Write-Host ("  {0}:{1}  {2}" -f $m.File, $m.Line, $m.Text) }
}

if ($untagged.Count -gt 0) {
    Write-Host ""
    $sev = if ($Strict) { 'Red' } else { 'Yellow' }
    Write-Host "Test classes without a [Trait(""Story"", ...)]:" -ForegroundColor $sev
    foreach ($u in $untagged) { Write-Host ("  {0}:{1}  {2}" -f $u.File, $u.Line, $u.Text) }
}

if ($malformed.Count -gt 0) {
    Write-Host ""
    Write-Host "FIX: Write the trait as [Trait(\"Story\", \"#42\")] with the number of a real issue, or LEGACY-0 for a test that predates the rule." -ForegroundColor Red
    Write-Host ("Found {0} malformed Story key(s); failing." -f $malformed.Count) -ForegroundColor Red
    exit 1
}

if ($Strict -and $untagged.Count -gt 0) {
    Write-Host ""
    Write-Host ("Strict mode: {0} test class(es) missing a Story trait; failing." -f $untagged.Count) -ForegroundColor Red
    exit 1
}

if ($untagged.Count -gt 0) {
    Write-Host ""
    Write-Host "Report-only: missing Story traits do not fail the build. Run with -Strict to enforce." -ForegroundColor Yellow
}
else {
    Write-Host ""
    Write-Host "All test classes carry a Story trait."
}

exit 0
