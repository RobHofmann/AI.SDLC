#Requires -Version 7
<#
.SYNOPSIS
    Names the nearest examples for each type a change touches: its test class and the test doubles of
    its dependencies.
.DESCRIPTION
    The builder writes a new helper or a new test class next to one that exists when nobody points it
    at the existing one. walk-substrate runs this script for each C# or Razor type a change touches, and
    puts the result in the context block, so the plan and the build start from what exists. The reuse
    order the builder follows is on the clean code page of code-conventions.

    For each type it finds:
      - the source file, a class, record or struct with that name under the source root, or a Razor
      component <Type>.razor, whose `@inject` lines are its dependencies;
      - the test class: a class named <Type>Tests under the test root, searched first in the test
        project `<test root>/<source project>.Tests`. Without one it says "none found",
        and names on its own line a test class that constructs the type with `new <Type>(` or renders it
        with `Render<Type>`, `RenderComponent<Type>` or
        as `<Type>`. That class tests something else, so a new test does not go there;
      - the test doubles: classes in the same test project that derive from or implement a dependency
        of the type, read from its primary constructor, or else from its classic constructor with the most
        parameters. Shared doubles come first. A double
        declared inside another class, or declared `private` or `file`, is private and comes after them.
        A generic dependency such as `IRepository<Order>` matches a double with the same type arguments,
        or an open generic double such as `FakeRepository<T>`.
    The test project is the folder with a .csproj that holds the test class. Without a test class it is
    `<test root>/<source project>.Tests`, else the whole test root.

    When it finds nothing, it says "none found" and what it searched, so the builder searches again and
    knows when it writes new code on purpose. It reads C# and Razor text only, so it can miss a double
    that a generator or a mocking library makes. It reads files only, and always exits 0.
.PARAMETER Type
    One or more type names the change touches, such as OrderService.
.PARAMETER Dependency
    More dependency types to search test doubles for, such as TimeProvider. Use it when the plan adds a
    dependency the constructor does not have yet.
.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script.
.EXAMPLE
    pwsh .claude/skills/walk-substrate/scripts/Find-NearestExample.ps1 -Type OrderService, StockService
.EXAMPLE
    pwsh .claude/skills/walk-substrate/scripts/Find-NearestExample.ps1 -Type OrderService -Dependency TimeProvider
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$Type,
    [string[]]$Dependency = @(),
    [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'
$Type = @($Type -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Dependency = @($Dependency -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$sourceRel = @(Get-AiSdlcPath -Name sourceRoot -RepoRoot $RepoRoot -Relative)[0]
$testRel = @(Get-AiSdlcPath -Name testRoot -RepoRoot $RepoRoot -Relative)[0]
$sourceRoot = if ($sourceRel) { Join-Path $RepoRoot $sourceRel } else { $RepoRoot }
$testRoot = if ($testRel) { Join-Path $RepoRoot $testRel } else { $RepoRoot }
$skipPattern = '[\\/](bin|obj)[\\/]'

function Test-Under {
    param([string]$Path, [string]$Folder)
    $Path.StartsWith($Folder.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-Relative {
    param([string]$Path)
    [System.IO.Path]::GetRelativePath($RepoRoot, $Path).Replace('\', '/')
}

function Get-CsFiles {
    param([string]$Root)
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.cs' | Where-Object { $_.FullName -notmatch $skipPattern })
}

function Get-ProjectFolder {
    param([string]$File, [string]$Stop)
    $dir = Split-Path -Parent $File
    while ($dir -and $dir.Length -ge $Stop.Length) {
        if (Get-ChildItem -LiteralPath $dir -Filter '*.csproj' -File) { return $dir }
        $dir = Split-Path -Parent $dir
    }
    $null
}

function Split-Parameters {
    param([string]$Text)
    $parts = [System.Collections.Generic.List[string]]::new()
    $depth = 0
    $current = ''
    foreach ($ch in $Text.ToCharArray()) {
        if ($ch -in '<', '(', '[') { $depth++ }
        elseif ($ch -in '>', ')', ']') { $depth-- }
        if ($ch -eq ',' -and $depth -eq 0) { $parts.Add($current); $current = ''; continue }
        $current += $ch
    }
    if ($current.Trim()) { $parts.Add($current) }
    $parts
}

function ConvertTo-DependencyName {
    param([string]$Type)
    $type = ($Type -replace '\?$', '').Trim()
    if ($type -match '^([^<]+)(<.*>)$') { return ($matches[1].Trim() -replace '^.*\.', '') + ($matches[2] -replace '\s', '') }
    $type -replace '^.*\.', ''
}

function Get-TextInsideParentheses {
    param([string]$Text, [int]$Open)
    $depth = 0
    for ($k = $Open; $k -lt $Text.Length; $k++) {
        if ($Text[$k] -eq '(') { $depth++ }
        elseif ($Text[$k] -eq ')') { $depth--; if ($depth -eq 0) { return $Text.Substring($Open + 1, $k - $Open - 1) } }
    }
    ''
}

function Get-Dependencies {
    param([string]$Source, [string]$Name)
    $Source = Get-MaskedCode $Source
    $n = [regex]::Escape($Name)
    foreach ($inject in [regex]::Matches($Source, '(?m)^\s*@inject\s+(\S+)\s+\w+')) { ConvertTo-DependencyName $inject.Groups[1].Value }
    $match = [regex]::Match($Source, "\b(class|struct|record(?:\s+(?:class|struct))?)\s+$n\s*(<[^>]*>)?\s*\(")
    $params = if ($match.Success) { Get-TextInsideParentheses -Text $Source -Open ($match.Index + $match.Length - 1) } else {
        $ctors = @([regex]::Matches($Source, "\b(public|internal|protected|private)\s+$n\s*\(") | ForEach-Object { Get-TextInsideParentheses -Text $Source -Open ($_.Index + $_.Length - 1) })
        @($ctors | Sort-Object { @(Split-Parameters $_).Count } -Descending)[0] ?? ''
    }
    foreach ($p in (Split-Parameters $params)) {
        $clean = ($p -replace '\[[^\]]*\]', '' -replace '=.*$', '').Trim()
        $words = @($clean -split '\s+' | Where-Object { $_ -and $_ -notin 'this', 'params', 'in', 'out', 'ref', 'scoped' })
        if ($words.Count -lt 2) { continue }
        ConvertTo-DependencyName ($words[0..($words.Count - 2)] -join ' ')
    }
}

function Get-MaskedCode {
    param([string]$Text)
    $pattern = '(?<q>"{3,})[\s\S]*?\k<q>|(?:\$@|@\$|@)"(?:[^"]|"")*"|\$"(?:[^"\\{}]|\\.|\{\{|\}\}|\{(?:[^{}"]|"(?:[^"\\]|\\.)*")*\})*"|\$?"(?:[^"\\\r\n]|\\.)*"|''(?:[^''\\\r\n]|\\.)''|//[^\r\n]*|/\*[\s\S]*?\*/'
    [regex]::Replace($Text, $pattern, { param($m) $m.Value -replace '[^\r\n]', ' ' })
}

function Get-EnclosingTypes {
    param([string]$Text, [int]$Index)
    $code = $Text.Substring(0, $Index)
    $open = [System.Collections.Generic.List[object]]::new()
    $last = 0
    foreach ($d in [regex]::Matches($code, '[{};]')) {
        if ($d.Value -eq '{') {
            $head = [regex]::Match($code.Substring($last, $d.Index - $last), '\b(?:class|record|struct|interface)\s+(\w+)')
            $open.Add($(if ($head.Success) { $head.Groups[1].Value } else { $null }))
        }
        elseif ($d.Value -eq '}' -and $open.Count) { $open.RemoveAt($open.Count - 1) }
        $last = $d.Index + 1
    }
    @($open | Where-Object { $_ })
}

function Find-TestClass {
    param([string]$Name, [object[]]$TestFiles)
    $n = [regex]::Escape($Name)
    $texts = @{}
    foreach ($f in $TestFiles) {
        if (-not (Select-String -LiteralPath $f.FullName -Pattern "\bclass\s+${n}Tests\b" -Quiet)) { continue }
        $texts[$f.FullName] = Get-MaskedCode (Get-Content -LiteralPath $f.FullName -Raw)
        if ($texts[$f.FullName] -match "\bclass\s+${n}Tests\b") {
            return [pscustomobject]@{ File = $f.FullName; Class = "${Name}Tests"; Own = $true }
        }
    }
    foreach ($f in $TestFiles) {
        $text = if ($texts.ContainsKey($f.FullName)) { $texts[$f.FullName] } else { Get-MaskedCode (Get-Content -LiteralPath $f.FullName -Raw) }
        $testTypes = @([regex]::Matches($text, '\[\s*(Fact|Theory)\b') | ForEach-Object { @(Get-EnclosingTypes -Text $text -Index $_.Index)[-1] } | Where-Object { $_ })
        if (-not $testTypes) { continue }
        foreach ($use in [regex]::Matches($text, "\bnew\s+$n\s*\(|(?<![\w.])<$n\b|\bRender(?:Component)?<$n>")) {
            $types = @(Get-EnclosingTypes -Text $text -Index $use.Index)
            if ($types.Count -and $types[-1] -in $testTypes) { return [pscustomobject]@{ File = $f.FullName; Class = $types[-1]; Own = $false } }
        }
    }
    $null
}

function Find-TestDoubles {
    param([string[]]$Dependencies, [object[]]$Files)
    foreach ($f in $Files) {
        $text = Get-MaskedCode (Get-Content -LiteralPath $f.FullName -Raw)
        foreach ($m in [regex]::Matches($text, '(?m)^(?<indent>[ \t]*)(?<mods>(?:\w+\s+)*?)(?:record\s+(?:class|struct)|record|class|struct)\s+(?<name>\w+)\s*(?<tparams><[^>]*>)?[^:{;]*?:\s*(?<bases>[^{;]+)')) {
            $bases = $m.Groups['bases'].Value -replace '\bwhere\b.*$', ''
            $own = @($m.Groups['tparams'].Value.Trim('<', '>') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            foreach ($dep in $Dependencies) {
                $depName = $dep -replace '<.*$', ''
                if ($bases -notmatch "(^|[\s,.])$([regex]::Escape($depName))\b") { continue }
                if ($dep -match '<(?<args>.*)>$') {
                    $wanted = $matches['args']
                    $fits = @([regex]::Matches($bases, "(?:^|[\s,.])$([regex]::Escape($depName))\s*<(?<a>[^>]*)>") | Where-Object {
                            $given = $_.Groups['a'].Value -replace '\s', ''
                            $given -eq $wanted -or -not @($given -split ',' | Where-Object { $_ -notin $own }).Count
                        })
                    if (-not $fits) { continue }
                }
                [pscustomobject]@{
                    File       = $f.FullName
                    Name       = $m.Groups['name'].Value
                    Dependency = $dep
                    Shared     = $m.Groups['mods'].Value -notmatch '\b(private|file)\b' -and -not @(Get-EnclosingTypes -Text $text -Index $m.Index).Count
                }
            }
        }
    }
}

$sourceFiles = @(Get-CsFiles $sourceRoot | Where-Object { $sourceRoot -eq $testRoot -or -not ((Test-Under $testRoot $sourceRoot) -and (Test-Under $_.FullName $testRoot)) })
$testFiles = @(Get-CsFiles $testRoot)
$razorFiles = @(if (Test-Path -LiteralPath $sourceRoot) { Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Filter '*.razor' | Where-Object { $_.FullName -notmatch $skipPattern } })
$sourceLabel = if ($sourceRel) { $sourceRel } else { 'the repository' }
$testLabel = if ($testRel) { $testRel } else { 'the repository' }

Write-Output 'Nearest examples (Find-NearestExample.ps1):'
foreach ($name in $Type) {
    $n = [regex]::Escape($name)
    $sources = @($sourceFiles | Where-Object { (Get-MaskedCode (Get-Content -LiteralPath $_.FullName -Raw)) -match "\b(?:class|struct|record(?:\s+(?:class|struct))?)\s+$n\b" })
    if (-not $sources) { $sources = @($razorFiles | Where-Object { $_.BaseName -eq $name }) }
    $source = $sources | Select-Object -First 1
    if (-not $source) {
        Write-Output "- ${name}: none found (searched $sourceLabel for a class, record or struct named $name, and for $name.razor)"
        continue
    }
    $more = if ($sources.Count -gt 1) { ", $($sources.Count) matches, first shown" } else { '' }
    Write-Output "- $name ($(Get-Relative $source.FullName)$more)"

    $sourceProject = Get-ProjectFolder -File $source.FullName -Stop $sourceRoot
    $mirror = if ($sourceProject) { Join-Path $testRoot ((Split-Path -Leaf $sourceProject) + '.Tests') }
    if (-not ($mirror -and (Test-Path -LiteralPath $mirror))) { $mirror = $null }
    $ordered = if ($mirror) { @($testFiles | Where-Object { Test-Under $_.FullName $mirror }) + @($testFiles | Where-Object { -not (Test-Under $_.FullName $mirror) }) } else { $testFiles }
    $testClass = Find-TestClass -Name $name -TestFiles $ordered
    if ($testClass -and $testClass.Own) {
        Write-Output "  - Test class: $(Get-Relative $testClass.File) :: $($testClass.Class)"
        $project = Get-ProjectFolder -File $testClass.File -Stop $testRoot
    }
    else {
        Write-Output "  - Test class: none found (searched $testLabel for class ${name}Tests)"
        if ($testClass) { Write-Output "  - Constructed in: $(Get-Relative $testClass.File) :: $($testClass.Class), a test of something else" }
        $project = $mirror
    }
    if (-not $project) { $project = $testRoot }

    $markup = @($razorFiles | Where-Object { $_.BaseName -eq $name -and $_.FullName -ne $source.FullName } | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw })
    $sourceText = (@(Get-Content -LiteralPath $source.FullName -Raw) + $markup) -join "`n"
    $dependencies = @(@(Get-Dependencies -Source $sourceText -Name $name) + $Dependency | Where-Object { $_ } | Select-Object -Unique)
    $projectFiles = @($testFiles | Where-Object { Test-Under $_.FullName $project })
    $doubles = @(Find-TestDoubles -Dependencies $dependencies -Files $projectFiles | Sort-Object @{ Expression = 'Shared'; Descending = $true }, File, Name)
    if ($doubles.Count -eq 0) {
        $searched = if ($dependencies.Count) { "a class that implements $($dependencies -join ', ')" } else { 'constructor dependencies, and the type has none' }
        Write-Output "  - Test doubles: none found (searched $(Get-Relative $project) for $searched)"
        continue
    }
    Write-Output '  - Test doubles:'
    foreach ($d in $doubles) {
        $kind = if ($d.Shared) { 'shared' } else { 'private' }
        Write-Output "    - $(Get-Relative $d.File) :: $($d.Name) ($($d.Dependency), $kind)"
    }
}
exit 0
