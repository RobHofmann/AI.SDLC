#Requires -Version 7
<#
.SYNOPSIS
    Reports test classes and test methods that the change adds without the AI-SDLC Story trait, and fails
    on a malformed Story key that the change adds or changes.

.DESCRIPTION
    The AI-SDLC convention tags new or changed tests with a Story trait so the story's tests can be found
    from the story key. There is no per-criterion AC trait. The trait is [Trait("Story", "#42")] in xUnit,
    [Property("Story", "#42")] in NUnit and [TestProperty("Story", "#42")] in MSTest.

    The script judges only the lines the change adds or changes (Get-AiSdlcLineChange in
    ChangedFiles.psm1), measured against the base ref. It reads only the .cs files under the test root
    (paths.testRoot in aisdlc.json) that the change touched. Older code in a touched file is left alone.

    Test classes are found at the top level of a file, inside a block namespace (`namespace X { ... }`,
    also nested) and in a file-scoped namespace (`namespace X;`). A class nested in another class is not
    a top-level class and is left out.

    A class counts as a test class when its body contains a test attribute: [Fact] or [Theory] in xUnit,
    [Test], [TestCase] or [TestCaseSource] in NUnit, [TestMethod] or [DataTestMethod] in MSTest. Mocks,
    fixtures, and other helper types are ignored.

    - A test class that the change adds (its declaration line is added) is covered when a Story trait with
      a real key appears anywhere in that class body: on the class or on any of its test methods.
    - A test method that the change adds to an older class (its test attribute line is added) is covered
      when it carries a Story trait with a real key, or the class carries one.
    - LEGACY-0 is the placeholder for a test that predates the rule. It is allowed on older code: a class
      or method that existed at the base. It never covers a class or method that the change adds.

    Where a Story trait exists on a line the change adds or changes, its value must be a whole story key:
    the pattern of Get-AiSdlcStoryPattern (#42, or owner/repo#42 across repositories, unless
    tracker.keyPattern in aisdlc.json sets another one), or LEGACY-0. A malformed key on such a line
    always fails the build (exit 1), because a typo'd key is a defect regardless of adoption progress. A
    malformed key on an older line is not judged.

    Adoption is incremental, so a class or method without a trait is REPORT-ONLY by default (the script
    lists it and exits 0). Pass -Strict to fail the build when the change adds one.

    This is a line scanner in the style of Check-DocLineCitations.ps1, not a Roslyn parser. It assumes the
    repository's prevailing test layout (attributes on their own lines, braces that balance per file). It
    is intended as a CI signal, not a compiler.

    Exit 0 clean (or report-only), 1 a finding, 2 could not check (aisdlc.json names no paths.testRoot,
    or the change cannot be told because there is no merge base, so the lines it adds are unknown; the
    output has a FIX: line). It never judges a whole file instead. Exit 3 is not used: with no tests
    directory the script exits 0.

.PARAMETER RepoRoot
    Repository root that contains the test root. Defaults to the folder that holds aisdlc.json, found from this script.

.PARAMETER BaseRef
    The ref the change is measured against. Defaults to origin/<github.trunk> from aisdlc.json
    (Get-AiSdlcMainBranch), origin/main unless the repository names another trunk. In a pull request
    build the shared action sets CHANGED_FILES and PR_TARGET_BRANCH, which Get-AiSdlcChange reads.

.PARAMETER Strict
    Exit non-zero when the change adds a test class or method without a real Story key. Off by default
    (report-only). Malformed Story keys fail the build regardless of this switch.

.EXAMPLE
    pwsh .claude/skills/dotnet-gates/scripts/Check-StoryTraits.ps1
    Reports counts and the list of untagged test classes; exits 0 unless a malformed key is found.

.EXAMPLE
    pwsh .claude/skills/dotnet-gates/scripts/Check-StoryTraits.ps1 -Strict
    Same report, but exits 1 if the change adds an untagged test class or method.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$BaseRef,
    [switch]$Strict
)

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
Import-Module (Join-Path $aiSdlcGates 'ChangedFiles.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }
if (-not $BaseRef) { $BaseRef = Get-AiSdlcMainBranch -RepoRoot $RepoRoot }

$ErrorActionPreference = 'Stop'

$testsRel = ([string](Get-AiSdlcConfig -RepoRoot $RepoRoot).paths.testRoot).TrimEnd('/')
if (-not $testsRel) {
    Write-Host 'Could not check: aisdlc.json names no paths.testRoot.' -ForegroundColor Yellow
    Write-Host 'FIX: Set paths.testRoot in aisdlc.json to the folder that holds the tests.' -ForegroundColor Yellow
    exit 2
}
$testsDir = Join-Path $RepoRoot $testsRel
if (-not (Test-Path $testsDir)) {
    Write-Host "No tests directory found at $testsDir; nothing to check." -ForegroundColor Yellow
    exit 0
}

$change = Get-AiSdlcChange -RepoRoot $RepoRoot -BaseRef $BaseRef
if (-not $change.Readable -or -not $change.Base) {
    $why = if ($change.Reason) { $change.Reason } else { "no merge base between $BaseRef and HEAD" }
    Write-Host "Could not check: the lines that the change adds are unknown ($why)." -ForegroundColor Yellow
    Write-Host 'FIX: Fetch the target branch with full history (for example fetch-depth: 0 in the checkout step), then run the gate again.' -ForegroundColor Yellow
    exit 2
}

$storyKeyPattern = '^(?:' + (Get-AiSdlcStoryPattern -RepoRoot $RepoRoot) + ')$'
$legacyKey = 'LEGACY-0'
$testMethodPattern = '\[[^\]]*?\b(?:Fact|Theory|Test|TestCase|TestCaseSource|TestMethod|DataTestMethod)\b'
$classDeclPattern = '^\s*(?:public|internal|private|protected|sealed|static|abstract|partial|\s)*\bclass\s+([A-Za-z_]\w*)'
$storyTraitPattern = '(?:Trait|Property|TestProperty)\s*\(\s*"Story"\s*,\s*"([^"]*)"\s*\)'
$blockNamespacePattern = '^namespace\s+[\w.]+\s*(?:\{.*|//.*)?$'
$attributeOnlyPattern = '^\[.*\]\s*(?://.*)?$'

$untagged = [System.Collections.Generic.List[object]]::new()
$malformed = [System.Collections.Generic.List[object]]::new()
$taggedCount = 0
$testClassCount = 0

$deleted = [System.Collections.Generic.HashSet[string]]::new([string[]]@($change.Deleted))
foreach ($rel in @($change.Files)) {
    if ($deleted.Contains($rel)) { continue }
    if (-not $rel.StartsWith("$testsRel/") -or -not $rel.EndsWith('.cs')) { continue }
    $full = Join-Path $RepoRoot $rel
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }

    $lineChange = Get-AiSdlcLineChange -RepoRoot $RepoRoot -Base $change.Base -Path $rel
    if (-not $lineChange) { continue }
    $added = [System.Collections.Generic.HashSet[int]]::new([int[]]@($lineChange.Added))
    $lines = Get-Content -LiteralPath $full

    $depth = 0
    # Brace depth after the open brace of each block namespace. A top-level class sits at that many levels.
    $nsLevels = [System.Collections.Generic.Stack[int]]::new()
    $nsPending = $false
    $current = $null
    $block = [System.Collections.Generic.List[object]]::new()
    $classes = [System.Collections.Generic.List[object]]::new()

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $lineNo = $i + 1
        $trimmed = $line.Trim()

        if ($trimmed -match $attributeOnlyPattern) {
            $block.Add([pscustomobject]@{ Line = $lineNo; Text = $line })
        }
        elseif ($trimmed -and -not $trimmed.StartsWith('//')) {
            # A code line owns the attributes above it. A line that starts with an attribute carries its own.
            if ($trimmed.StartsWith('[')) { $block.Add([pscustomobject]@{ Line = $lineNo; Text = $line }) }
            $classMatch = [regex]::Match($line, $classDeclPattern)
            $traits = @(foreach ($entry in $block) {
                    foreach ($keyMatch in [regex]::Matches($entry.Text, $storyTraitPattern)) {
                        [pscustomobject]@{ Line = $entry.Line; Value = $keyMatch.Groups[1].Value; Text = $entry.Text.Trim() }
                    }
                })

            if ($classMatch.Success -and $depth -eq $nsLevels.Count) {
                $current = [pscustomobject]@{
                    Name     = $classMatch.Groups[1].Value
                    Line     = $lineNo
                    Added    = $added.Contains($lineNo)
                    HasTest  = $false
                    Traits   = [System.Collections.Generic.List[object]]::new()
                    ClassTraits = $traits
                    Methods  = [System.Collections.Generic.List[object]]::new()
                }
                foreach ($trait in $traits) { $current.Traits.Add($trait) }
                $classes.Add($current)
            }
            elseif ($current -and $block.Count -gt 0 -and (($block | Where-Object { $_.Text -match $testMethodPattern }).Count -gt 0)) {
                $testLine = ($block | Where-Object { $_.Text -match $testMethodPattern } | Select-Object -First 1).Line
                $signature = [regex]::Replace($line, '^\s*(?:\[[^\]]*\]\s*)+', '')
                $nameMatch = [regex]::Match($signature, '([A-Za-z_]\w*)\s*(?:<[^>]*>)?\s*\(')
                $current.HasTest = $true
                $current.Methods.Add([pscustomobject]@{
                        Name   = if ($nameMatch.Success) { $nameMatch.Groups[1].Value } else { 'test method' }
                        Line   = $testLine
                        Added  = $added.Contains($testLine)
                        Traits = $traits
                    })
                foreach ($trait in $traits) { $current.Traits.Add($trait) }
            }
            elseif ($current -and $traits.Count -gt 0) {
                foreach ($trait in $traits) { $current.Traits.Add($trait) }
            }

            foreach ($trait in $traits) {
                if ($trait.Value -cne $legacyKey -and $trait.Value -cnotmatch $storyKeyPattern -and $added.Contains($trait.Line)) {
                    $malformed.Add([pscustomobject]@{ File = $rel; Line = $trait.Line; Text = $trait.Text })
                }
            }
            # A file-scoped namespace ends in ';' and opens no brace, so it never matches here.
            if ($trimmed -match $blockNamespacePattern) { $nsPending = $true }
            $block.Clear()
        }

        foreach ($brace in [regex]::Matches($line, '[{}]')) {
            if ($brace.Value -eq '{') {
                $depth++
                if ($nsPending) { $nsLevels.Push($depth); $nsPending = $false }
            }
            else {
                $depth--
                if ($nsLevels.Count -gt 0 -and $depth -lt $nsLevels.Peek()) { [void]$nsLevels.Pop() }
            }
        }
        if ($depth -lt 0) { $depth = 0 }
    }

    foreach ($cls in $classes) {
        if (-not $cls.HasTest) { continue }
        $testClassCount++
        $realKey = { param($t) $t.Value -cne $legacyKey -and $t.Value -cmatch $storyKeyPattern }
        $classHasReal = @($cls.Traits | Where-Object { & $realKey $_ }).Count -gt 0
        $classLevelReal = @($cls.ClassTraits | Where-Object { & $realKey $_ }).Count -gt 0
        $classHasAny = $cls.Traits.Count -gt 0
        $flagged = $false

        if ($cls.Added) {
            if (-not $classHasReal) {
                $flagged = $true
                $note = if ($classHasAny) { "class $($cls.Name) (LEGACY-0 is not allowed on a class the change adds)" } else { "class $($cls.Name)" }
                $untagged.Add([pscustomobject]@{ File = $rel; Line = $cls.Line; Text = $note })
            }
        }
        else {
            foreach ($method in @($cls.Methods | Where-Object { $_.Added })) {
                $methodReal = @($method.Traits | Where-Object { & $realKey $_ }).Count -gt 0
                if ($methodReal -or $classLevelReal) { continue }
                $flagged = $true
                $note = if ($method.Traits.Count -gt 0 -or $classHasAny) { "method $($method.Name) in class $($cls.Name) (LEGACY-0 is not allowed on a method the change adds)" } else { "method $($method.Name) in class $($cls.Name)" }
                $untagged.Add([pscustomobject]@{ File = $rel; Line = $method.Line; Text = $note })
            }
        }
        if (-not $flagged -and $classHasAny) { $taggedCount++ }
    }
}

Write-Host "Story-trait coverage of the change ($testsRel):"
Write-Host ("  Test classes found : {0}" -f $testClassCount)
Write-Host ("  With Story trait   : {0}" -f $taggedCount)
Write-Host ("  Missing Story trait: {0}" -f $untagged.Count)
Write-Host ("  Malformed keys     : {0}" -f $malformed.Count)

if ($malformed.Count -gt 0) {
    Write-Host ""
    Write-Host "Malformed Story key(s) on lines the change adds - must be a whole story key such as #42, or ${legacyKey} on older code:" -ForegroundColor Red
    foreach ($m in $malformed) { Write-Host ("  {0}:{1}  {2}" -f $m.File, $m.Line, $m.Text) }
}

if ($untagged.Count -gt 0) {
    Write-Host ""
    $sev = if ($Strict) { 'Red' } else { 'Yellow' }
    Write-Host "Test classes and methods that the change adds without a Story trait:" -ForegroundColor $sev
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
    Write-Host "FIX: Add a Story trait with a real story key, such as #42, to each test class or method that the change adds. LEGACY-0 is for older code only." -ForegroundColor Red
    Write-Host ("Strict mode: {0} test class(es) or method(s) missing a Story trait; failing." -f $untagged.Count) -ForegroundColor Red
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
