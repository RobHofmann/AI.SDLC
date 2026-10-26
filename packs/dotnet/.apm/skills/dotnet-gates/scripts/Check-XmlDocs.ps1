#Requires -Version 7
<#
.SYNOPSIS
    Gate (advisory): every public or protected type and member a change adds carries a /// doc comment (clause C10).
.DESCRIPTION
    Code is documented: a public or shared type or member carries a doc comment in the form of its
    language. In C# that is the XML doc comment (/// <summary>). This gate reads the lines a change
    adds to .cs files and names each added public or protected declaration with no /// line directly
    above it. Attribute lines between the doc comment and the declaration are allowed.

    It does not report:
      - files under the test root (paths.testRoot in aisdlc.json, or -TestRoot);
      - generated files (*.Designer.cs, *.g.cs, *.g.i.cs and anything under bin/ or obj/);
      - members of a type marked [GeneratedCode], or of a type that is not public itself;
      - override members, which take their documentation from the base member.
    Known limits: interface members and enum values carry no modifier, so they are not read; a raw
    string that spans lines can confuse the brace count that finds the enclosing type.

    The gate diffs the working tree against the merge base of -BaseRef and HEAD with the whole file as
    context, so it knows the type around each added member. It reads untracked .cs files whole.

    ADVISORY: exit 1 is a warning in the gate runner, not a block. Exit codes follow Invoke-Gate.ps1:
    0 checked and clean, 1 a finding, 2 the change could not be computed, so nothing was checked.
.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script.
.PARAMETER BaseRef
    The ref the change is measured against. Defaults to origin/main. The pull request build passes
    HEAD^1, the target branch side of the merge commit.
.PARAMETER TestRoot
    The folder that holds the test projects, relative to RepoRoot. Defaults to paths.testRoot in
    aisdlc.json.
.PARAMETER DiffText
    A unified diff to read instead of asking git. Used by the tests.
.EXAMPLE
    pwsh .claude/skills/dotnet-gates/scripts/Check-XmlDocs.ps1
.EXAMPLE
    pwsh .claude/skills/dotnet-gates/scripts/Check-XmlDocs.ps1 -BaseRef HEAD^1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$BaseRef = 'origin/main',
    [string]$TestRoot,
    [string]$DiffText
)

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CodeDiff.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }
if (-not $PSBoundParameters.ContainsKey('TestRoot')) { $TestRoot = [string](Get-AiSdlcConfig -RepoRoot $RepoRoot).paths.testRoot }
$testPrefix = if ($TestRoot) { $TestRoot.Replace('\', '/').TrimEnd('/') + '/' } else { $null }

$ErrorActionPreference = 'Stop'

$literalPattern = '\$*(?<q>"{3,})(?:(?!\k<q>).)*\k<q>|(?:\$@|@\$|@)"(?:[^"]|"")*"|\$"(?:[^"\\{}]|\\.|\{\{|\}\}|\{(?:[^{}"]|"(?:[^"\\]|\\.)*")*\})*"|\$?"(?:[^"\\]|\\.)*"|''(?:[^''\\]|\\.)'''
$modifiers = 'public|protected|internal|private|static|sealed|abstract|partial|readonly|ref|unsafe|new|file'
$typePattern = "^(?<mods>(?:(?:$modifiers)\s+)*)(?:class|struct|interface|enum|record(?:\s+(?:class|struct))?)\s+\w+"
$memberPattern = '^(?:public|protected)\s'

function Get-CodePart {
    param([string]$Text)
    $code = [regex]::Replace($Text, $literalPattern, '""')
    $cut = [regex]::Match($code, '//|/\*')
    if ($cut.Success) { $code = $code.Substring(0, $cut.Index) }
    return $code.Trim()
}

function Get-AttributeLinesAbove {
    param([object[]]$Lines, [int]$Index)
    $i = $Index - 1
    while ($i -ge 0 -and $Lines[$i].Line -eq $Lines[$i + 1].Line - 1 -and $Lines[$i].Text.Trim().StartsWith('[')) { $i-- }
    $attributes = @(if ($i + 1 -le $Index - 1) { $Lines[($i + 1)..($Index - 1)] | ForEach-Object { $_.Text } })
    $above = if ($i -ge 0 -and $Lines[$i].Line -eq $Lines[$i + 1].Line - 1) { $Lines[$i].Text.Trim() } else { '' }
    return [pscustomobject]@{ Attributes = $attributes; Above = $above }
}

function Find-UndocumentedDeclarations {
    param([object[]]$Lines)
    $findings = [System.Collections.Generic.List[object]]::new()
    $depth = 0
    $stack = [System.Collections.Generic.List[object]]::new()
    $pending = $null
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $text = $Lines[$i].Text.Trim()
        if ($text -eq '' -or $text.StartsWith('//') -or $text.StartsWith('/*') -or $text.StartsWith('*')) { continue }
        $code = Get-CodePart $text
        $enclosingApi = -not ($stack | Where-Object { -not $_.Api })
        $type = [regex]::Match($code, $typePattern)
        $isDeclaration = $false
        if ($type.Success) {
            $mods = $type.Groups['mods'].Value
            $around = Get-AttributeLinesAbove -Lines $Lines -Index $i
            $generated = [bool]($around.Attributes | Where-Object { $_ -match '\bGeneratedCode(Attribute)?\b' })
            $isPublic = $mods -match '\b(public|protected)\b'
            $pending = [pscustomobject]@{ Api = ($enclosingApi -and $isPublic -and -not $generated) }
            $isDeclaration = $isPublic -and -not $generated
        }
        elseif ($code -match $memberPattern -and $code -notmatch '\boverride\b') {
            $isDeclaration = $true
        }
        if ($isDeclaration -and $enclosingApi -and $Lines[$i].IsAdded) {
            $around = Get-AttributeLinesAbove -Lines $Lines -Index $i
            if (-not $around.Above.StartsWith('///')) { $findings.Add($Lines[$i]) }
        }
        foreach ($ch in $code.ToCharArray()) {
            if ($ch -eq '{') {
                $depth++
                if ($pending) { $stack.Add([pscustomobject]@{ BodyDepth = $depth; Api = $pending.Api }); $pending = $null }
            }
            elseif ($ch -eq '}') {
                if ($stack.Count -gt 0 -and $stack[$stack.Count - 1].BodyDepth -eq $depth) { $stack.RemoveAt($stack.Count - 1) }
                $depth--
            }
            elseif ($ch -eq ';' -and $pending) { $pending = $null }
        }
    }
    $findings
}

function Test-ReadPath {
    param([string]$Path)
    $normal = $Path.Replace('\', '/')
    if (-not (Test-CodeDiffPath -Path $normal -Extension '.cs')) { return $false }
    return -not ($testPrefix -and $normal.StartsWith($testPrefix))
}

if (-not $PSBoundParameters.ContainsKey('DiffText')) {
    $read = Get-CodeDiffText -RepoRoot $RepoRoot -BaseRef $BaseRef -ContextLines 100000
    if ($read.Problem) {
        Write-Host "XML docs: $($read.Problem), so NOTHING WAS CHECKED." -ForegroundColor Yellow
        exit 2
    }
    $DiffText = $read.Text
}

$all = @(Get-CodeDiffLine -Diff $DiffText | Where-Object { Test-ReadPath $_.File })
$findings = [System.Collections.Generic.List[object]]::new()
foreach ($group in ($all | Group-Object File)) {
    foreach ($f in @(Find-UndocumentedDeclarations -Lines @($group.Group))) { $findings.Add($f) }
}

if ($findings.Count -gt 0) {
    Write-Host 'C10 advice: the change adds public or protected C# declarations without a /// doc comment.' -ForegroundColor Yellow
    Write-Host 'FIX: Put a /// <summary> above each declaration named below. Say what the type or member is for and what a caller must know, not how it works inside (clause C10, .claude/skills/ai-sdlc-handbook/references/comments.md).' -ForegroundColor Yellow
    foreach ($f in $findings) { Write-Host ("  {0}:{1}  {2}" -f $f.File, $f.Line, $f.Text.Trim()) }
    $files = ($findings | Select-Object -ExpandProperty File -Unique).Count
    Write-Host ("Found {0} undocumented declaration(s) in {1} file(s)." -f $findings.Count, $files) -ForegroundColor Yellow
    exit 1
}

$checked = @($all | Where-Object { $_.IsAdded }).Count
Write-Host ("XML docs OK: {0} added C# line(s) checked, every public or protected declaration has a doc comment." -f $checked)
exit 0
