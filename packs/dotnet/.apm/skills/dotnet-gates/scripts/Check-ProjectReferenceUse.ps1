#Requires -Version 7
<#
.SYNOPSIS
    Gate: each project reference that the change adds has namespace use in code.

.DESCRIPTION
    A project reference that no code uses still ties two projects together: the build order, the test
    scope and the dependency graph all follow it. This gate asks one question of each ProjectReference
    that the change adds: does the code of the referencing project use a namespace that the target
    project declares?

    In the default mode the gate judges only a ProjectReference whose Include line the change adds or
    changes in a changed .csproj file, read with Get-DotnetAddedProjectReference. A new project file counts as all
    lines added. With -All it judges every reference of every project file, and it uses no git.

    The project graph comes from Get-DotnetProjectGraph in DotnetTestScope.psm1, so this gate adds no
    second project file parser. A reference is left alone when ReferenceOutputAssembly is false or
    OutputItemType is Analyzer, read as an attribute or a child element, with the case ignored. A
    reference to a file that is not a .csproj file (.vbproj, .fsproj, .sqlproj) is named as not checked, and
    gives exit 2 when nothing else is found. Package references are not read. A .cshtml file of the
    referencing project is read for use (@using, @inject, @model and dotted names, also in
    _ViewImports.cshtml) and never for declarations. VB and F# files are not read. A comment in a .cs
    file gives no use, found with a pass that knows strings, verbatim, interpolated and raw strings and
    char literals, so a // inside a string starts no comment. A Razor comment (@* *@) or an HTML comment
    gives no use in a .razor or .cshtml file, and neither does a C# comment inside an @code, @functions
    or @{ } block; a // in markup is not a comment. Only a ProjectReference element whose Include sits on an
    added line counts as added.

    How use is found, with a text search and not a compiler:

      Declared  The namespaces that each project declares: namespace X in its .cs files, @namespace X in
                its .razor files, and for each folder that holds a .razor file with no @namespace the
                RootNamespace plus the folder path joined with dots. A type in a .cs file with no
                namespace is a global type. Program counts as declared when such a file starts with
                top-level statements.
      Use       Project P uses project T when one of these resolves to a namespace that T declares:
                each dotted name in the .cs and .razor text of P, outside its own namespace lines; the
                target of each using, global using, using static, alias and @using, with or without
                global::; each Using item of P in the project file or a Directory.Build.props; and each
                prefix of a namespace that P itself declares. A name is also tried behind each prefix
                of the namespaces that P declares, so Domain.Service inside namespace
                Company.Product.Web reaches Company.Product.Domain. A name resolves to the longest declared namespace that it equals or
                starts with, and every project that declares that namespace counts. A whole-word hit
                on a global type of T counts as use of T too.

    ADVISORY: exit 1 is a warning, not a block. A text search cannot see code that finds its types at run
    time, so a project that is used that way shows up as a finding.

    Exit codes follow the gate contract: 0 checked and clean, 1 a finding, 2 could not check (the change
    cannot be listed, a project file, a target project or a Directory.Build.props cannot be read, a
    reference cannot be followed, or a reference is not to a C# project; a changed project file that
    cannot be read always counts), 3 not applicable (the repository holds no .csproj file, or no changed
    project file adds a project reference that the gate judges).

.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script.

.PARAMETER BaseRef
    The ref the change is measured against when no explicit file list is given. Defaults to origin/<github.trunk> from aisdlc.json (Get-AiSdlcMainBranch),
    origin/main unless the repository names another trunk.

.PARAMETER ChangedFiles
    Explicit repository-relative paths, bypassing the git file list. With no base to diff against, the
    whole of each listed file counts as added. When a base resolves, only the lines that differ from it count.
    Falls back to the newline-separated CHANGED_FILES environment variable, which the pipeline sets from
    the pull request diff.

.PARAMETER All
    Judge every project reference of every project file, with no git.

.EXAMPLE
    pwsh .claude/skills/dotnet-gates/scripts/Check-ProjectReferenceUse.ps1

.EXAMPLE
    pwsh .claude/skills/dotnet-gates/scripts/Check-ProjectReferenceUse.ps1 -All
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$BaseRef,
    [string[]]$ChangedFiles,
    [switch]$All
)

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
Import-Module (Join-Path $aiSdlcGates 'ChangedFiles.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DotnetTestScope.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }
$aiSdlc = Get-AiSdlcConfig -RepoRoot $RepoRoot
if (-not $BaseRef) { $BaseRef = Get-AiSdlcMainBranch -RepoRoot $RepoRoot }
$script:MainBranch = $BaseRef -replace '^origin/', ''

$ErrorActionPreference = 'Stop'

$script:CsNamespace = '(?m)^[ \t]*namespace[ \t]+([A-Za-z_][\w.]*)'
$script:RazorNamespace = '(?m)^[ \t]*@namespace[ \t]+([A-Za-z_][\w.]*)'
$script:OwnNamespaceLine = '(?m)^[ \t]*@?namespace[ \t]+[\w.]+[ \t]*[;{]?'
$script:CSharpToken = [regex]::new('(?s)("{3,}).*?\1|(?:@\$|\$@|@)"(?:[^"]|"")*"|\$?"(?:[^"\\\r\n]|\\.)*"|''(?:\\.|[^''\\\r\n])+''|//[^\r\n]*|/\*.*?\*/')
$script:UsingDirectives = '^(?:(?:global\s+)?using\s+(?:static\s+)?(?:[A-Za-z_]\w*\s*=\s*)?[\w.:]+\s*;\s*)+'
$script:StandaloneAttribute = '^\[\s*(?:assembly|module)\s*:[^\]]*\]\s*'
$script:RazorCodeStart = [regex]::new('@(?:code|functions)\s*\{|@\{')
$script:BraceOrToken = [regex]::new($script:CSharpToken.ToString() + '|[{}]')
$script:CsUsing = '(?m)^[ \t]*(?:global[ \t]+)?using[ \t]+(?:static[ \t]+)?(?:[A-Za-z_]\w*[ \t]*=[ \t]*)?(?:global::)?([A-Za-z_][\w.]*)'
$script:RazorUsing = '(?m)^[ \t]*@using[ \t]+(?:static[ \t]+)?(?:[A-Za-z_]\w*[ \t]*=[ \t]*)?(?:global::)?([A-Za-z_][\w.]*)'
$script:DottedName = '[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)+'
$script:TypeDeclaration = '\b(?:class|record|struct|interface|enum)\s+(?:(?:class|struct)\s+)?([A-Za-z_]\w*)'
$script:NotATypeName = @('where', 'new', 'struct', 'class', 'unmanaged', 'notnull', 'default')
$script:TypeStart = '^(?:(?:public|internal|private|protected|static|abstract|sealed|partial|readonly|unsafe|file|ref|new)\s+)*(?:class|struct|interface|enum|record|delegate)\b'

$script:Problems = [System.Collections.Generic.List[string]]::new()
$script:SourceText = @{}

function Add-Problem {
    param([string]$Text)

    if (-not $script:Problems.Contains($Text)) { $script:Problems.Add($Text) }
}

function Test-SkippedReference {
    param([object]$Item)

    if ([string]$Item.ReferenceOutputAssembly -ieq 'false') { return $true }
    return [string]$Item.OutputItemType -ieq 'Analyzer'
}

function Get-SourceText {
    param([string]$Relative)

    if ($script:SourceText.ContainsKey($Relative)) { return $script:SourceText[$Relative] }
    $text = $null
    try { $text = [IO.File]::ReadAllText((Join-Path $RepoRoot $Relative)) }
    catch { Add-Problem "$Relative cannot be read" }
    $script:SourceText[$Relative] = $text
    return $text
}

function Get-CSharpTextWithoutComment {
    param([string]$Text)

    return $script:CSharpToken.Replace($Text, {
            param($match)
            if ($match.Value.StartsWith('//')) { return '' }
            if ($match.Value.StartsWith('/*')) { return ' ' }
            return $match.Value
        })
}

function Get-MarkupTextWithoutComment {
    param([string]$Text)

    $clean = [regex]::Replace($Text, '(?s)@\*.*?\*@|<!--.*?-->', ' ')
    $builder = [System.Text.StringBuilder]::new()
    $position = 0
    while ($position -lt $clean.Length) {
        $start = $script:RazorCodeStart.Match($clean, $position)
        if (-not $start.Success) { break }
        $bodyStart = $start.Index + $start.Length
        $depth = 1
        $cursor = $bodyStart
        $bodyEnd = $clean.Length
        while ($cursor -lt $clean.Length) {
            $token = $script:BraceOrToken.Match($clean, $cursor)
            if (-not $token.Success) { break }
            $cursor = $token.Index + $token.Length
            if ($token.Value -eq '{') { $depth++ }
            elseif ($token.Value -eq '}') {
                $depth--
                if ($depth -eq 0) { $bodyEnd = $token.Index; break }
            }
        }
        [void]$builder.Append($clean.Substring($position, $bodyStart - $position))
        [void]$builder.Append((Get-CSharpTextWithoutComment -Text $clean.Substring($bodyStart, $bodyEnd - $bodyStart)))
        $position = $bodyEnd
    }
    if ($position -lt $clean.Length) { [void]$builder.Append($clean.Substring($position)) }
    return $builder.ToString()
}

function Get-OutsideNamespaceText {
    param([string]$Code)

    $blank = $script:CSharpToken.Replace($Code, { param($match) if ($match.Value.StartsWith('//') -or $match.Value.StartsWith('/*')) { ' ' } else { '""' } })
    $builder = [System.Text.StringBuilder]::new()
    $stack = [System.Collections.Generic.Stack[bool]]::new()
    $open = 0
    $position = 0
    foreach ($match in [regex]::Matches($blank, '\bnamespace\s+[\w.]+\s*([;{])|\{|\}')) {
        if ($open -eq 0) { [void]$builder.Append($blank.Substring($position, $match.Index - $position)) }
        $position = $match.Index + $match.Length
        if ($match.Value.StartsWith('namespace')) {
            if ($match.Groups[1].Value -eq ';') { return $builder.ToString() }
            $stack.Push($true)
            $open++
        }
        elseif ($match.Value -eq '{') { $stack.Push($false) }
        elseif ($stack.Count -gt 0 -and $stack.Pop()) { $open-- }
    }
    if ($open -eq 0) { [void]$builder.Append($blank.Substring($position)) }
    return $builder.ToString()
}

function Test-TopLevelStatement {
    param([string]$Text)

    foreach ($raw in ((Get-CSharpTextWithoutComment -Text $Text) -split '\r?\n')) {
        $line = $raw.Trim()
        do {
            $before = $line
            $line = [regex]::Replace($line, $script:UsingDirectives, '')
            $line = [regex]::Replace($line, $script:StandaloneAttribute, '')
        } while ($line -ne $before)
        if (-not $line -or $line.StartsWith('#')) { continue }
        return ($line -notmatch $script:TypeStart) -and -not $line.StartsWith('[') -and ($line -notmatch '^namespace\b')
    }
    return $false
}

function Get-ProjectDeclaration {
    param([object]$Project, [string[]]$File)

    $namespaces = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $globalTypes = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $razorFolders = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($relative in $File) {
        $text = Get-SourceText -Relative $relative
        if ($null -eq $text) { continue }
        if ($relative -match '(?i)\.cshtml$') { continue }
        if ($relative -match '\.razor$') {
            $found = [regex]::Matches((Get-MarkupTextWithoutComment -Text $text), $script:RazorNamespace)
            if ($found.Count -gt 0) { foreach ($match in $found) { [void]$namespaces.Add($match.Groups[1].Value) } }
            else { [void]$razorFolders.Add([IO.Path]::GetDirectoryName($relative).Replace('\', '/')) }
            continue
        }
        $code = Get-CSharpTextWithoutComment -Text $text
        $found = [regex]::Matches($code, $script:CsNamespace)
        foreach ($match in $found) { [void]$namespaces.Add($match.Groups[1].Value) }
        $outside = if ($found.Count -gt 0) { Get-OutsideNamespaceText -Code $code } else { $code }
        foreach ($match in [regex]::Matches($outside, $script:TypeDeclaration)) {
            $name = $match.Groups[1].Value
            if ($name -notin $script:NotATypeName) { [void]$globalTypes.Add($name) }
        }
        if (Test-TopLevelStatement -Text $outside) { [void]$globalTypes.Add('Program') }
    }
    foreach ($folder in $razorFolders) {
        $inside = if ($Project.Folder -and $folder.Length -gt $Project.Folder.Length) { $folder.Substring($Project.Folder.Length) } elseif ($Project.Folder) { '' } else { $folder }
        $parts = @($inside -split '/' | Where-Object { $_ } | ForEach-Object { $_ -replace '[^\w]', '_' })
        [void]$namespaces.Add((@($Project.RootNamespace) + $parts) -join '.')
    }
    return [pscustomobject]@{ Namespaces = $namespaces; GlobalTypes = $globalTypes }
}

function Resolve-NamespaceOwner {
    param([string]$Token)

    $parts = $Token.Split('.')
    for ($length = $parts.Length; $length -ge 1; $length--) {
        $candidate = [string]::Join('.', $parts, 0, $length)
        if ($script:NamespaceOwners.ContainsKey($candidate)) { return $script:NamespaceOwners[$candidate] }
    }
    return @()
}

function Get-ProjectUse {
    param([object]$Project, [string[]]$File)

    $used = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $tokens = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $hits = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($relative in $File) {
        $text = Get-SourceText -Relative $relative
        if ($null -eq $text) { continue }
        $isCSharp = $relative -match '(?i)\.cs$'
        $text = if ($isCSharp) { Get-CSharpTextWithoutComment -Text $text } else { Get-MarkupTextWithoutComment -Text $text }
        $body = [regex]::Replace($text, $script:OwnNamespaceLine, '')
        foreach ($match in [regex]::Matches($body, $script:DottedName)) { [void]$tokens.Add($match.Value) }
        $usingPattern = if ($isCSharp) { $script:CsUsing } else { $script:RazorUsing }
        foreach ($match in [regex]::Matches($body, $usingPattern)) { [void]$tokens.Add($match.Groups[1].Value) }
        if ($script:GlobalTypePattern) { foreach ($match in [regex]::Matches($body, $script:GlobalTypePattern)) { [void]$hits.Add($match.Value) } }
    }
    foreach ($item in $Project.Usings) { [void]$tokens.Add($item) }
    $prefixes = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($namespace in $script:Declared[$Project.Path].Namespaces) {
        $parts = $namespace.Split('.')
        for ($length = 1; $length -le $parts.Length; $length++) { [void]$prefixes.Add([string]::Join('.', $parts, 0, $length)) }
    }
    $qualified = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($token in $tokens) {
        foreach ($prefix in $prefixes) { [void]$qualified.Add("$prefix.$token") }
    }
    foreach ($prefix in $prefixes) { [void]$tokens.Add($prefix) }
    foreach ($token in @($tokens) + @($qualified)) { foreach ($owner in @(Resolve-NamespaceOwner -Token $token)) { [void]$used.Add($owner) } }
    foreach ($name in $hits) { foreach ($owner in $script:GlobalOwners[$name]) { [void]$used.Add($owner) } }
    [void]$used.Remove($Project.Path)
    return , $used
}

$graph = @(Get-DotnetProjectGraph -RepoRoot $RepoRoot)
if ($graph.Count -eq 0) {
    Write-Host 'Not applicable: the repository holds no .csproj file, so there is no project reference to check.'
    exit 3
}
$byPath = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($project in $graph) { $byPath[$project.Path] = $project }

$candidates = [System.Collections.Generic.List[object]]::new()

if ($All) {
    foreach ($project in $graph) {
        if ($project.Error -eq 'cannot be read') { Add-Problem "$($project.Path) cannot be read"; continue }
        foreach ($item in $project.ReferenceItems) {
            if (-not (Test-SkippedReference -Item $item)) { $candidates.Add([pscustomobject]@{ Project = $project; Item = $item }) }
        }
    }
}
else {
    $change = Get-AiSdlcChange -RepoRoot $RepoRoot -BaseRef $BaseRef -Explicit $ChangedFiles
    if (-not $change.Readable) {
        Write-Host "Could not check: $($change.Reason), so the change cannot be listed." -ForegroundColor Yellow
        Write-Host "FIX: Fetch the base branch (git fetch origin $($script:MainBranch)), or pass -BaseRef with a ref that exists." -ForegroundColor Yellow
        exit 2
    }
    $added = Get-DotnetAddedProjectReference -RepoRoot $RepoRoot -Projects $graph -Files @($change.Files) -Base $change.Base -AssumeNew:([bool]$ChangedFiles)
    if (@($added.LinesUnknown).Count -gt 0) {
        Write-Host ("Could not check: there is no base to diff against, so the lines this change adds to {0} cannot be read." -f (@($added.LinesUnknown) -join ', ')) -ForegroundColor Yellow
        Write-Host "FIX: Fetch the base branch (git fetch origin $($script:MainBranch)), or pass -BaseRef with a ref that exists." -ForegroundColor Yellow
        exit 2
    }
    foreach ($file in @($added.Unreadable)) { Add-Problem "$file cannot be read" }
    foreach ($row in @($added.References)) {
        if (-not (Test-SkippedReference -Item $row.Item)) { $candidates.Add([pscustomobject]@{ Project = $row.Project; Item = $row.Item }) }
    }
}

if ($candidates.Count -eq 0 -and $script:Problems.Count -eq 0) {
    $scope = if ($All) { 'the repository holds no project reference that the gate judges' } else { 'no changed project file adds a project reference that the gate judges' }
    Write-Host "Not applicable: $scope."
    exit 3
}

$judged = [System.Collections.Generic.List[object]]::new()
foreach ($candidate in $candidates) {
    $project = $candidate.Project
    $item = $candidate.Item
    if ($project.UsingsError) { Add-Problem $project.UsingsError }
    if (-not $item.Path) { Add-Problem "$($project.Path) : references $($item.Include), which cannot be followed"; continue }
    if (-not $byPath.ContainsKey($item.Path)) {
        if ($item.Path -match '(?i)\.csproj$') { Add-Problem "$($project.Path) : references $($item.Include), which cannot be followed" }
        else { Add-Problem "$($project.Path) -> $($item.Path) : not checked: not a C# project" }
        continue
    }
    $target = $byPath[$item.Path]
    if ($target.Error -eq 'cannot be read') { Add-Problem "$($target.Path) cannot be read"; continue }
    if ($project.Error -eq 'cannot be read') { continue }
    $judged.Add([pscustomobject]@{ Project = $project; Target = $target })
}

$findings = [System.Collections.Generic.List[object]]::new()
if ($judged.Count -gt 0) {
    $sources = @{}
    foreach ($row in @(Get-DotnetProjectSourceFile -RepoRoot $RepoRoot -Projects $graph -Extension @('.cs', '.razor', '.cshtml'))) { $sources[$row.Project] = @($row.Files) }

    $script:Declared = @{}
    $script:NamespaceOwners = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.HashSet[string]]]::new([StringComparer]::Ordinal)
    $script:GlobalOwners = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.HashSet[string]]]::new([StringComparer]::Ordinal)
    foreach ($project in $graph) {
        $declaration = Get-ProjectDeclaration -Project $project -File $sources[$project.Path]
        $script:Declared[$project.Path] = $declaration
        foreach ($namespace in $declaration.Namespaces) {
            if (-not $script:NamespaceOwners.ContainsKey($namespace)) { $script:NamespaceOwners[$namespace] = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }
            [void]$script:NamespaceOwners[$namespace].Add($project.Path)
        }
        foreach ($name in $declaration.GlobalTypes) {
            if (-not $script:GlobalOwners.ContainsKey($name)) { $script:GlobalOwners[$name] = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }
            [void]$script:GlobalOwners[$name].Add($project.Path)
        }
    }
    $script:GlobalTypePattern = if ($script:GlobalOwners.Count -gt 0) { '\b(?:' + (($script:GlobalOwners.Keys | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\b' } else { $null }

    $useByProject = @{}
    foreach ($row in $judged) {
        $key = $row.Project.Path
        if (-not $useByProject.ContainsKey($key)) { $useByProject[$key] = Get-ProjectUse -Project $row.Project -File $sources[$key] }
        if (-not $useByProject[$key].Contains($row.Target.Path)) { $findings.Add($row) }
    }
}

$unique = @($findings | Sort-Object { $_.Project.Path }, { $_.Target.Path } -Unique)
$problemText = @($script:Problems)

if ($unique.Count -gt 0) {
    Write-Host 'Project reference use: a project reference has no namespace use in code.' -ForegroundColor Yellow
    foreach ($finding in $unique) {
        Write-Host ("  {0} -> {1} : no namespace use in code" -f $finding.Project.Path, $finding.Target.Path)
    }
    if ($problemText.Count -gt 0) {
        Write-Host 'Could not check:' -ForegroundColor Yellow
        foreach ($problem in $problemText) { Write-Host "  $problem" }
    }
    Write-Host 'FIX: Remove the project reference, or keep it when code finds its types at run time and say so in the pull request.'
    Write-Host ("Project reference use: {0} project reference(s) have no namespace use in code." -f $unique.Count)
    exit 1
}

if ($problemText.Count -gt 0) {
    Write-Host 'Could not check:' -ForegroundColor Yellow
    foreach ($problem in $problemText) { Write-Host "  $problem" -ForegroundColor Yellow }
    Write-Host 'FIX: Repair the file or the reference path named above, or check by hand a reference that is not a C# project, then run the gate again.' -ForegroundColor Yellow
    exit 2
}

Write-Host ("Project reference use OK: {0} project reference(s) checked, and each has namespace use in code." -f $judged.Count)
exit 0
