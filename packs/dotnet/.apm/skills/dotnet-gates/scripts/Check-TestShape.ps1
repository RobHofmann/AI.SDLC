#Requires -Version 7
<#
.SYNOPSIS
    Gate: every test method a change adds has the Arrange, Act and Assert markers once each, in that order, and the lines a change adds to an older test do not break that shape.
.DESCRIPTION
    A test splits into the `// Arrange`, `// Act` and `// Assert` parts that clause C10 allows as
    markers. A test that acts and asserts, then acts and asserts again, tests two things and hides the
    second one. This gate reads each xUnit test method ([Fact] or [Theory]) that the change touches and
    checks its markers:
      - each part is there, exactly once;
      - the parts come in the order Arrange, Act, Assert;
      - an Act is followed by an Assert.
    The gate judges only the lines that the change adds or changes. The change adds a test method when the
    line of its test attribute, or the line of its signature, is an added line. A new method must meet all
    three rules. A method that the change only edits is judged by its own lines: the gate reads the method
    with and without the added lines, and fails only on a problem that the added lines bring, such as a
    second Act, or a marker that puts the markers out of order. It fails a missing marker in an edited
    method only when a deleted line of that method was that marker. A marker that was missing or out of
    order before the change, with a harmless edit next to it, does not fail.
    A merged marker such as `// Arrange & Act` or `// Act & Assert` counts as both parts. A test the
    change does not touch is not checked. A test written with `=>` carries its markers inside the
    expression. A marker followed by more text, such as `// Assert - no exception`, still counts as its
    part; Check-CommentHygiene.ps1 judges that text, not this gate.

    The gate reads the change, not the tree: a test method counts as touched when an added line falls
    inside it, or when lines were deleted from inside it. It finds test methods by `[Fact]` and `[Theory]`
    in the whole file, as Check-StoryTraits.ps1 does. It reads the committed change since the merge base
    of the base ref and HEAD, plus the working tree, and it reads an untracked .cs file whole. The lines
    come from Get-AiSdlcLineChange in ChangedFiles.psm1. Generated files (*.Designer.cs, *.g.cs,
    *.g.i.cs and anything under bin/ or obj/) are skipped. The text of a string, also a raw or verbatim
    string over several lines, and the text of a `/* */` comment are neither a marker nor a brace
    (CSharpCodeView.psm1). An attribute over several lines and a test written with `=>` are read too.
    NUnit and MSTest tests are not read.

    The base ref is -BaseRef when given. Otherwise it is origin/ plus PR_TARGET_BRANCH, the variable the
    shared pull request action sets (without its refs/heads/ prefix), and without that variable the
    trunk that Get-AiSdlcMainBranch names (github.trunk in aisdlc.json, origin/main by default).

    Exit codes follow ADR 0019: 0 checked one or more test methods and all are clean, 1 a test method
    has a broken shape, 2 the change could not be read (no git, no repository, or no base ref), so
    nothing was checked, and the output holds a FIX line, 3 no test method changed, so there was
    nothing to check.
.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script.
.PARAMETER BaseRef
    The ref the change is measured against. Defaults to the pull request target branch, or the trunk
    when there is none. See the description.
.EXAMPLE
    pwsh .claude/skills/dotnet-gates/scripts/Check-TestShape.ps1
.EXAMPLE
    pwsh .claude/skills/dotnet-gates/scripts/Check-TestShape.ps1 -BaseRef HEAD^1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$BaseRef
)

$ErrorActionPreference = 'Stop'

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
Import-Module (Join-Path $aiSdlcGates 'ChangedFiles.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CSharpCodeView.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

$testMarker = '^//\s*(?<parts>(Arrange|Act|Assert)(\s*(&|and|/|,)\s*(Arrange|Act|Assert))*)\b'
$testMethodPattern = '^\s*(\[[^\]]*\]\s*)*\[(?:[^\]]*,\s*)?(?:(?:global::)?Xunit\.)?(Fact|Theory)(?:Attribute)?\b'
$partOrder = @{ Arrange = 0; Act = 1; Assert = 2 }

function Stop-CouldNotCheck {
    param([string]$Reason, [string]$Fix)
    Write-Host "Test shape: $Reason, so the change could not be read and NOTHING WAS CHECKED." -ForegroundColor Yellow
    Write-Host "FIX: $Fix" -ForegroundColor Yellow
    exit 2
}

function Get-MarkerPart {
    param([string]$Text)
    $trimmed = $Text.Trim()
    if ($trimmed -notmatch $testMarker) { return @() }
    return @([regex]::Matches($matches['parts'], 'Arrange|Act|Assert') | ForEach-Object { $_.Value })
}

function Test-TestMethodStart {
    param([string[]]$Lines, [int]$Index)
    if ($Lines[$Index] -match $testMethodPattern) { return $true }
    if ($Lines[$Index] -notmatch '^\s*\[') { return $false }
    $joined = ''
    $depth = 0
    for ($k = $Index; $k -lt [Math]::Min($Lines.Count, $Index + 10); $k++) {
        $joined += ' ' + $Lines[$k].Trim()
        $depth += ([regex]::Matches($Lines[$k], '\[')).Count - ([regex]::Matches($Lines[$k], '\]')).Count
        if ($depth -le 0) { break }
    }
    return $joined.Trim() -match $testMethodPattern
}

function Remove-Attributes {
    param([string]$Code, [ref]$Depth)
    $kept = [System.Text.StringBuilder]::new()
    foreach ($ch in $Code.ToCharArray()) {
        if ($ch -eq '[') { $Depth.Value++; continue }
        if ($ch -eq ']' -and $Depth.Value -gt 0) { $Depth.Value--; continue }
        if ($Depth.Value -eq 0) { [void]$kept.Append($ch) }
    }
    $kept.ToString()
}

function Get-TestMethods {
    param([string[]]$Lines)
    $i = 0
    while ($i -lt $Lines.Count) {
        if (-not (Test-TestMethodStart -Lines $Lines -Index $i)) { $i++; continue }
        $start = $i
        $name = $null
        $nameLine = $null
        $depth = 0
        $opened = $false
        $expression = $false
        $attribute = 0
        $j = $i
        while ($j -lt $Lines.Count) {
            $code = $Lines[$j] -replace '//.*$', ''
            if (-not $opened -and -not $expression) { $code = Remove-Attributes $code ([ref]$attribute) }
            if (-not $name -and $code -match '\b(\w+)\s*(<[^>]*>)?\s*\(') { $name = $matches[1]; $nameLine = $j + 1 }
            $arrow = $code.IndexOf('=>')
            $brace = $code.IndexOf('{')
            if (-not $opened -and -not $expression -and $name -and $arrow -ge 0 -and ($brace -lt 0 -or $arrow -lt $brace)) { $expression = $true }
            if (-not $opened -and -not $expression -and $name -and $code.TrimEnd().EndsWith(';')) { break }
            foreach ($ch in $code.ToCharArray()) {
                if ($ch -eq '{') { $depth++; $opened = $true }
                elseif ($ch -eq '}') { $depth-- }
            }
            if ($expression -and $depth -le 0 -and $code.TrimEnd().EndsWith(';')) { break }
            if (-not $expression -and $opened -and $depth -le 0) { break }
            $j++
        }
        if ($opened -or $expression) { [pscustomobject]@{ Name = $name; NameLine = $nameLine; Start = $start + 1; End = [Math]::Min($j + 1, $Lines.Count) } }
        $i = [Math]::Max($j, $i) + 1
    }
}

function Get-ShapeProblems {
    param([string[]]$Lines, [object]$Method)
    $parts = [System.Collections.Generic.List[string]]::new()
    for ($n = $Method.Start; $n -le $Method.End; $n++) {
        foreach ($part in (Get-MarkerPart $Lines[$n - 1])) { $parts.Add($part) }
    }
    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($part in $partOrder.Keys | Sort-Object { $partOrder[$_] }) {
        if ($part -notin $parts -and -not ($part -eq 'Assert' -and 'Act' -in $parts)) { $problems.Add("the // $part marker is missing") }
    }
    foreach ($g in ($parts | Group-Object | Where-Object Count -gt 1)) { $problems.Add("$($g.Name) appears $($g.Count) times") }
    for ($k = 1; $k -lt $parts.Count; $k++) {
        if ($partOrder[$parts[$k]] -lt $partOrder[$parts[$k - 1]]) { $problems.Add("the markers are out of order: $($parts -join ', ')"); break }
    }
    $lastAct = $parts.LastIndexOf('Act')
    if ($lastAct -ge 0 -and $parts.IndexOf('Assert', $lastAct) -lt 0) { $problems.Add('no // Assert follows the // Act') }
    $problems
}

function Test-RemovedInside {
    # A removed line has no place in the new file. Git numbers a pure deletion after the line before it,
    # and a replacement at its first added line. So a position that is not an added line is a pure
    # deletion, and it sits inside a method when the method has a line after that position.
    param([int]$At, [object]$Method, [System.Collections.Generic.HashSet[int]]$Added)
    if ($Added.Contains($At)) { return $At -ge $Method.Start -and $At -le $Method.End }
    return $At -ge $Method.Start -and $At + 1 -le $Method.End
}

function Get-RemovedPart {
    param([object]$Change, [object]$Method, [System.Collections.Generic.HashSet[int]]$Added)
    for ($r = 0; $r -lt @($Change.Removed).Count; $r++) {
        if (Test-RemovedInside -At ([int]$Change.RemovedAt[$r]) -Method $Method -Added $Added) { Get-MarkerPart $Change.Removed[$r] }
    }
}

function Get-OwnProblems {
    param([string[]]$Lines, [object]$Method, [System.Collections.Generic.HashSet[int]]$Added, [string[]]$RemovedPart)
    $all = @(Get-ShapeProblems -Lines $Lines -Method $Method)
    $isAdded = $Added.Contains([int]$Method.Start) -or ($null -ne $Method.NameLine -and $Added.Contains([int]$Method.NameLine))
    if ($isAdded) { return $all }
    $before = [string[]]$Lines.Clone()
    foreach ($n in $Added) { if ($n -ge $Method.Start -and $n -le $Method.End) { $before[$n - 1] = '' } }
    $earlier = @(Get-ShapeProblems -Lines $before -Method $Method)
    $own = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $all) { if ($p -notin $earlier) { $own.Add($p) } }
    foreach ($part in ($RemovedPart | Select-Object -Unique)) {
        foreach ($p in $all) {
            $names = $p -match "the // $part marker is missing" -or ($part -eq 'Assert' -and $p -match '^no // Assert follows')
            if ($names -and $p -notin $own) { $own.Add($p) }
        }
    }
    return $own
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Stop-CouldNotCheck -Reason 'git is not available' -Fix 'Install git and put it on the PATH, then run the gate again.'
}

if (-not $BaseRef) {
    $target = ([string]$env:PR_TARGET_BRANCH) -replace '^refs/heads/', ''
    $BaseRef = if ($target) { "origin/$target" } else { Get-AiSdlcMainBranch -RepoRoot $RepoRoot }
}

$change = Get-AiSdlcChange -RepoRoot $RepoRoot -BaseRef $BaseRef -IncludeWorkingTree
if (-not $change.Readable) {
    Stop-CouldNotCheck -Reason "$($change.Reason) (base '$BaseRef')" -Fix 'Fetch the base branch (git fetch origin), or pass -BaseRef with a ref that exists.'
}
$untracked = @(git -C $RepoRoot -c core.quotepath=off ls-files --others --exclude-standard -- '*.cs' 2>$null | ForEach-Object { $_.Replace('\', '/') })

$findings = [System.Collections.Generic.List[object]]::new()
$checked = 0
foreach ($file in @($change.Files | Where-Object { Test-CheckedPath $_ })) {
    $full = Join-Path $RepoRoot $file
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
    $lineChange = if ($file -in $untracked) { Get-AiSdlcLineChange -RepoRoot $RepoRoot -Path $file -AssumeNew }
    else { Get-AiSdlcLineChange -RepoRoot $RepoRoot -Base $change.Base -Path $file }
    if ($null -eq $lineChange) {
        Stop-CouldNotCheck -Reason "git diff of $file failed" -Fix 'Check that the repository is readable and that the base ref points at a commit, or pass -BaseRef with a ref that exists.'
    }
    $added = [System.Collections.Generic.HashSet[int]]::new([int[]]@($lineChange.Added))
    $lines = @(Get-CodeView -Lines @(Get-Content -LiteralPath $full))
    foreach ($method in @(Get-TestMethods -Lines $lines)) {
        $touched = $false
        foreach ($n in $added) { if ($n -ge $method.Start -and $n -le $method.End) { $touched = $true; break } }
        if (-not $touched) {
            foreach ($at in @($lineChange.RemovedAt)) {
                if (Test-RemovedInside -At ([int]$at) -Method $method -Added $added) { $touched = $true; break }
            }
        }
        if (-not $touched) { continue }
        $checked++
        $removedPart = @(Get-RemovedPart -Change $lineChange -Method $method -Added $added)
        foreach ($p in @(Get-OwnProblems -Lines $lines -Method $method -Added $added -RemovedPart $removedPart)) {
            $findings.Add([pscustomobject]@{ File = $file; Line = $method.Start; Method = $method.Name; Problem = $p })
        }
    }
}

if ($findings.Count -gt 0) {
    Write-Host 'Test shape violation: a changed test method does not have // Arrange, // Act and // Assert once each, in that order.' -ForegroundColor Red
    Write-Host 'FIX: Add a missing marker (a test with nothing to arrange may merge "// Arrange & Act"), split a test that acts and asserts twice into two test methods, and put the markers in the order Arrange, Act, Assert.' -ForegroundColor Red
    foreach ($f in $findings) { Write-Host ("  {0}:{1}  {2}: {3}" -f $f.File, $f.Line, $f.Method, $f.Problem) }
    $methods = @($findings | ForEach-Object { "$($_.File)|$($_.Method)" } | Select-Object -Unique).Count
    Write-Host ("Found {0} problem(s) in {1} test method(s)." -f $findings.Count, $methods) -ForegroundColor Red
    exit 1
}

if ($checked -eq 0) {
    Write-Host 'Not applicable: no test method changed, so there was nothing to check.'
    exit 3
}

Write-Host ("Test shape OK: {0} changed test method(s) checked." -f $checked)
exit 0
