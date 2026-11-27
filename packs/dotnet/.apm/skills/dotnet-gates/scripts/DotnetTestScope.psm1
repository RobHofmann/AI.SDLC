#Requires -Version 7
<#
.SYNOPSIS
    Which .NET test projects a change can reach, so a local pre-flight runs only those.

.DESCRIPTION
    Get-DotnetProjectGraph reads every .csproj file of the repository, outside .claude/, .git/, bin/,
    obj/, apm_modules/ and node_modules/. For each project it gives the repo-relative path, the folder,
    the projects it references and whether it is a test project. A test project sets IsTestProject,
    references a test package (Microsoft.NET.Test.Sdk, xunit, NUnit or MSTest), or has a name that ends
    in .Tests or .Test.

    The graph also gives the data the project reference gate reads. ReferenceItems lists each
    ProjectReference with its Include text, its Path (null when it cannot be followed) and its
    ReferenceOutputAssembly and OutputItemType, read as an attribute or as a child element. Usings lists the
    Include of each Using item in the project file and in the nearest Directory.Build.props above it, up to
    the repository root. It goes on to the next one above only when that file imports it, with an Import
    whose Project holds GetPathOfFileAbove and Directory.Build.props, as MSBuild does. The Condition of that
    Import is not evaluated, so a parent that a false condition leaves out still counts. RootNamespace is the
    RootNamespace element, else the project file name. UsingsError names a Directory.Build.props that cannot be read, and does not set Error. A project
    file that cannot be read gets empty new properties.

    Get-DotnetProjectSourceFile gives each project the .cs and .razor files that it owns, as repo-relative
    paths. A file belongs to the deepest project folder that holds it, outside the skipped folders. When two projects share that folder, the file belongs to each of them. -Extension
    sets which file extensions are listed, .cs and .razor by default. The Include of a Using item may list
    several names split by semicolons, and each one is given.

    Get-DotnetAddedProjectReference gives the project references that a change adds, for the gates that
    judge them. It reads each listed .csproj file that the graph holds and that still exists. A
    ProjectReference counts as added when its Include sits on a line that the change adds, read with
    Get-AiSdlcLineChange, so an Include on a line after the element name counts. -AssumeNew with no -Base
    counts every line of a listed file as added. The answer holds References (each one the Project and the
    ReferenceItems entry, with no filter on ReferenceOutputAssembly or OutputItemType), Unreadable (a
    project file that cannot be read) and LinesUnknown (a file whose added lines cannot be read).

    Get-DotnetTestScope takes the files of a change and that graph. A file belongs to the project whose
    folder holds it, the deepest one when folders nest. The answer holds the projects the change touches,
    and the test projects that are one of them or reference one of them, also through other projects.

    The answer is All, with the reason, when the change touches a file that every project reads: a
    Directory.Build or Directory.Packages file, global.json, nuget.config, .editorconfig, a .globalconfig
    file, a solution or a run settings file. It is All too for a .NET file (.cs, .razor, .cshtml, .csproj, .props, .targets,
    .resx) outside every project folder, for a project file that cannot be read, and for a project
    reference that cannot be followed: one with an MSBuild property, item or wildcard, or a path that
    does not exist. A Markdown file,
    a file under docs/ or docs-functional/, and any other file outside every project folder count for
    no project, so a change to a Bicep template or a pipeline runs no .NET test. A test that reads such
    a file is still run by -Full and by the pull request pipeline.

.PARAMETER RepoRoot
    The repository root.

.PARAMETER Files
    The repo-relative paths of the change, with forward or back slashes.

.PARAMETER Base
    For Get-DotnetAddedProjectReference: the git ref or commit that the change is measured against.

.PARAMETER AssumeNew
    For Get-DotnetAddedProjectReference: with no Base, count every line of a listed file as added.

.PARAMETER Projects
    The graph from Get-DotnetProjectGraph. Get-DotnetTestScope reads it from RepoRoot when it is not given.

.EXAMPLE
    $scope = Get-DotnetTestScope -RepoRoot $RepoRoot -Files $ScopeFiles
    if ($scope.All) { "Every test runs, because $($scope.Reason)" } else { $scope.TestProjects }
#>

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'ChangedFiles.psm1')

$script:IncludeValue = '(?s)<ProjectReference\b[^>]*?\bInclude\s*=\s*["'']([^"'']*)["'']'
$script:SkippedFolders = @('.claude', '.git', 'bin', 'obj', 'apm_modules', 'node_modules')
$script:SharedNames = @('directory.build.props', 'directory.build.targets', 'directory.packages.props', 'global.json', 'nuget.config', '.editorconfig')
$script:SharedExtensions = @('.sln', '.slnx', '.slnf', '.runsettings', '.globalconfig')
$script:DotnetExtensions = @('.cs', '.razor', '.cshtml', '.csproj', '.props', '.targets', '.resx')
$script:TestPackages = '^(Microsoft\.NET\.Test\.Sdk|xunit|xunit\.v3|NUnit|MSTest|MSTest\.TestFramework)$'

function ConvertTo-RepoPath {
    param([string]$RepoRoot, [string]$FullPath)

    $root = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
    $full = [IO.Path]::GetFullPath($FullPath)
    return $full.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
}

function Find-DotnetProjectFile {
    param([string]$Folder, [string[]]$Extension = @('.csproj'))

    foreach ($file in [IO.Directory]::EnumerateFiles($Folder)) {
        if ([IO.Path]::GetExtension($file).ToLowerInvariant() -in $Extension) { $file }
    }
    foreach ($sub in [IO.Directory]::EnumerateDirectories($Folder)) {
        if ($script:SkippedFolders -contains [IO.Path]::GetFileName($sub).ToLowerInvariant()) { continue }
        Find-DotnetProjectFile -Folder $sub -Extension $Extension
    }
}

function Get-DotnetItemMetadataValue {
    param([System.Xml.XmlNode]$Node, [string]$Name)

    if ($Node.HasAttribute($Name)) { return $Node.GetAttribute($Name) }
    $child = $Node.SelectSingleNode("*[local-name()='$Name']")
    if ($child) { return $child.InnerText.Trim() }
    return $null
}

function Get-DotnetUsingInclude {
    param([xml]$Xml)

    foreach ($node in @($Xml.SelectNodes('//*[local-name()="Using"]'))) {
        foreach ($part in $node.GetAttribute('Include').Split(';')) {
            if ($part.Trim()) { $part.Trim() }
        }
    }
}

function Get-DotnetPropsUsing {
    param([string]$RepoRoot, [string]$Folder, [hashtable]$Cache)

    if ($Cache.ContainsKey($Folder)) { return $Cache[$Folder] }
    $answer = [pscustomobject]@{ Exists = $false; ImportsParent = $false; Usings = @(); Error = $null }
    $file = Join-Path $Folder 'Directory.Build.props'
    if (Test-Path -LiteralPath $file -PathType Leaf) {
        $answer.Exists = $true
        try {
            [xml]$xml = [IO.File]::ReadAllText($file)
            $answer.Usings = @(Get-DotnetUsingInclude -Xml $xml)
            $imports = @($xml.SelectNodes('//*[local-name()="Import"]') | Where-Object {
                    $_.GetAttribute('Project') -match '(?i)GetPathOfFileAbove' -and $_.GetAttribute('Project') -match '(?i)Directory\.Build\.props'
                })
            $answer.ImportsParent = $imports.Count -gt 0
        }
        catch { $answer.Error = "$(ConvertTo-RepoPath -RepoRoot $RepoRoot -FullPath $file) cannot be read" }
    }
    $Cache[$Folder] = $answer
    return $answer
}

function Get-DotnetProjectUsing {
    param([string]$RepoRoot, [string]$ProjectFolder, [string[]]$Own, [hashtable]$Cache)

    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $root = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
    $usings = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $Own) { $usings.Add($item) }
    $problem = $null
    $folder = [IO.Path]::GetFullPath($ProjectFolder).TrimEnd('\', '/')
    while ($folder) {
        $props = Get-DotnetPropsUsing -RepoRoot $RepoRoot -Folder $folder -Cache $Cache
        foreach ($item in $props.Usings) { $usings.Add($item) }
        if ($props.Error -and -not $problem) { $problem = $props.Error }
        if ($props.Exists -and -not $props.ImportsParent) { break }
        if ([string]::Equals($folder, $root, $comparison)) { break }
        $folder = [IO.Path]::GetDirectoryName($folder)
    }
    return [pscustomobject]@{ Usings = $usings.ToArray(); Error = $problem }
}

function Get-DotnetProjectGraph {
    <#
    .SYNOPSIS
        Reads every project file of the repository into a graph of references, usings and test flags.

    .PARAMETER RepoRoot
        The repository root.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $propsCache = @{}
    foreach ($file in @(Find-DotnetProjectFile -Folder $RepoRoot)) {
        $path = ConvertTo-RepoPath -RepoRoot $RepoRoot -FullPath $file
        $folder = [IO.Path]::GetDirectoryName($file)
        try { [xml]$xml = [IO.File]::ReadAllText($file) }
        catch {
            [pscustomobject]@{ Path = $path; Folder = ([string][IO.Path]::GetDirectoryName($path)).Replace('\', '/'); References = @(); IsTest = $false; Error = 'cannot be read'; ReferenceItems = @(); Usings = @(); RootNamespace = $null; UsingsError = $null }
            continue
        }
        $problem = $null
        $references = [System.Collections.Generic.List[string]]::new()
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($node in @($xml.SelectNodes('//*[local-name()="ProjectReference"]'))) {
            $include = $node.GetAttribute('Include')
            if (-not $include) { continue }
            $target = Join-Path $folder ($include.Replace('\', [IO.Path]::DirectorySeparatorChar))
            $followed = $null
            if ($include -match '[$%@*?]' -or -not (Test-Path -LiteralPath $target -PathType Leaf)) {
                if (-not $problem) { $problem = "references $include, which cannot be followed" }
            }
            else {
                $followed = ConvertTo-RepoPath -RepoRoot $RepoRoot -FullPath $target
                $references.Add($followed)
            }
            $items.Add([pscustomobject]@{
                    Include                 = $include
                    Path                    = $followed
                    ReferenceOutputAssembly = Get-DotnetItemMetadataValue -Node $node -Name 'ReferenceOutputAssembly'
                    OutputItemType          = Get-DotnetItemMetadataValue -Node $node -Name 'OutputItemType'
                })
        }
        $packages = @($xml.SelectNodes('//*[local-name()="PackageReference"]') | ForEach-Object { $_.GetAttribute('Include') })
        $flag = @($xml.SelectNodes('//*[local-name()="IsTestProject"]') | ForEach-Object { $_.InnerText.Trim() }) -contains 'true'
        $name = [IO.Path]::GetFileNameWithoutExtension($file)
        $rootNamespace = @($xml.SelectNodes('//*[local-name()="RootNamespace"]') | ForEach-Object { $_.InnerText.Trim() } | Where-Object { $_ })[0]
        $ownUsings = @(Get-DotnetUsingInclude -Xml $xml)
        $usingAnswer = Get-DotnetProjectUsing -RepoRoot $RepoRoot -ProjectFolder $folder -Own $ownUsings -Cache $propsCache
        [pscustomobject]@{
            Path           = $path
            Folder         = ([string][IO.Path]::GetDirectoryName($path)).Replace('\', '/')
            References     = $references.ToArray()
            IsTest         = $flag -or [bool]@($packages | Where-Object { $_ -match $script:TestPackages }).Count -or $name -match '\.Tests?$'
            Error          = $problem
            ReferenceItems = $items.ToArray()
            Usings         = @($usingAnswer.Usings)
            RootNamespace  = if ($rootNamespace) { $rootNamespace } else { $name }
            UsingsError    = $usingAnswer.Error
        }
    }
}

function Find-DotnetProjectOwner {
    param([object[]]$Projects, [string]$File, [switch]$AllTied)

    $holders = @($Projects | Where-Object { $_.Folder -eq '' -or $File.StartsWith($_.Folder + '/', [StringComparison]::OrdinalIgnoreCase) } |
            Sort-Object { $_.Folder.Length } -Descending)
    if ($holders.Count -eq 0) { return }
    if (-not $AllTied) { return $holders[0] }
    $deepest = $holders[0].Folder.Length
    return @($holders | Where-Object { $_.Folder.Length -eq $deepest })
}

function Get-DotnetProjectSourceFile {
    <#
    .SYNOPSIS
        Lists the code files of each project, so a gate can read the code that a project compiles.

    .DESCRIPTION
        Each file goes to the project whose folder holds it most deeply. A file in a folder that two
        projects share goes to both. Folders that the graph skips, such as bin and obj, are left out.

    .PARAMETER RepoRoot
        The repository root.

    .PARAMETER Projects
        The projects from Get-DotnetProjectGraph.

    .PARAMETER Extension
        The file extensions to list. Defaults to .cs and .razor.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Projects,
        [string[]]$Extension = @('.cs', '.razor')
    )

    $byProject = @{}
    foreach ($project in $Projects) { $byProject[$project.Path] = [System.Collections.Generic.List[string]]::new() }
    foreach ($file in @(Find-DotnetProjectFile -Folder $RepoRoot -Extension $Extension)) {
        $relative = ConvertTo-RepoPath -RepoRoot $RepoRoot -FullPath $file
        foreach ($owner in @(Find-DotnetProjectOwner -Projects $Projects -File $relative -AllTied)) { $byProject[$owner.Path].Add($relative) }
    }
    foreach ($project in $Projects) { [pscustomobject]@{ Project = $project.Path; Files = $byProject[$project.Path].ToArray() } }
}

function Get-DotnetAddedProjectReference {
    <#
    .SYNOPSIS
        Lists the project references that a change adds, for the gates that judge a new reference.

    .DESCRIPTION
        It reads each changed project file of the graph. A reference counts as added when the Include of
        its ProjectReference element sits on a line that the change adds. A changed file that cannot be
        read goes in Unreadable. A file whose added lines cannot be listed goes in LinesUnknown.

    .PARAMETER RepoRoot
        The repository root.

    .PARAMETER Projects
        The projects from Get-DotnetProjectGraph.

    .PARAMETER Files
        The changed files, as repository paths.

    .PARAMETER Base
        The commit to compare with. Without it, only -AssumeNew lists references.

    .PARAMETER AssumeNew
        Counts every reference of a listed file as added when no base resolves.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Projects,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Files,
        [string]$Base,
        [switch]$AssumeNew
    )

    $byPath = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($project in $Projects) { $byPath[$project.Path] = $project }
    $references = [System.Collections.Generic.List[object]]::new()
    $unreadable = [System.Collections.Generic.List[string]]::new()
    $linesUnknown = [System.Collections.Generic.List[string]]::new()
    foreach ($file in @($Files | Where-Object { $_ -match '(?i)\.csproj$' })) {
        $full = Join-Path $RepoRoot $file
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        if (-not $byPath.ContainsKey($file)) { continue }
        $project = $byPath[$file]
        if ($project.Error -eq 'cannot be read') { $unreadable.Add($file); continue }
        $lineChange = Get-AiSdlcLineChange -RepoRoot $RepoRoot -Base $Base -Path $file -AssumeNew:$AssumeNew
        if ($null -eq $lineChange) { $linesUnknown.Add($file); continue }
        $fileText = Get-Content -LiteralPath $full -Encoding utf8 -Raw
        $addedNumbers = [System.Collections.Generic.HashSet[int]]::new([int[]]@($lineChange.Added))
        $includes = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($match in [regex]::Matches($fileText, $script:IncludeValue)) {
            $group = $match.Groups[1]
            $lineNumber = 1 + ($fileText.Substring(0, $group.Index).Split("`n").Length - 1)
            if ($addedNumbers.Contains($lineNumber)) { [void]$includes.Add($group.Value) }
        }
        foreach ($item in $project.ReferenceItems) {
            if ($includes.Contains($item.Include)) { $references.Add([pscustomobject]@{ Project = $project; Item = $item }) }
        }
    }
    return [pscustomobject]@{ References = $references.ToArray(); Unreadable = $unreadable.ToArray(); LinesUnknown = $linesUnknown.ToArray() }
}

function Get-DotnetTestScope {
    <#
    .SYNOPSIS
        Works out which projects and test projects a change reaches, or says that it reaches all of them.

    .PARAMETER RepoRoot
        The repository root.

    .PARAMETER Files
        The repo-relative paths of the change.

    .PARAMETER Projects
        The graph from Get-DotnetProjectGraph. It is read from RepoRoot when it is not given.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string[]]$Files = @(),
        [object[]]$Projects
    )

    if ($null -eq $Projects) { $Projects = @(Get-DotnetProjectGraph -RepoRoot $RepoRoot) }
    $broken = @($Projects | Where-Object { $_.Error })
    if ($broken.Count) { return [pscustomobject]@{ All = $true; Reason = "the project file $($broken[0].Path) $($broken[0].Error)"; Projects = @(); TestProjects = @() } }

    $touched = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($raw in $Files) {
        $file = $raw.Replace('\', '/').TrimStart('/')
        $name = [IO.Path]::GetFileName($file).ToLowerInvariant()
        $extension = [IO.Path]::GetExtension($file).ToLowerInvariant()
        if ($extension -eq '.md' -or $file -match '^(docs|docs-functional)/') { continue }
        if ($script:SharedNames -contains $name -or $script:SharedExtensions -contains $extension) {
            return [pscustomobject]@{ All = $true; Reason = "the change touches $file, which every project reads"; Projects = @(); TestProjects = @() }
        }
        $owner = Find-DotnetProjectOwner -Projects $Projects -File $file
        if ($owner) { [void]$touched.Add($owner.Path); continue }
        if ($script:DotnetExtensions -contains $extension) {
            return [pscustomobject]@{ All = $true; Reason = "the change touches $file, a .NET file outside every project"; Projects = @(); TestProjects = @() }
        }
    }

    $reached = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $queue = [System.Collections.Generic.Queue[string]]::new()
    foreach ($path in $touched) { [void]$reached.Add($path); $queue.Enqueue($path) }
    while ($queue.Count) {
        $current = $queue.Dequeue()
        foreach ($project in $Projects) {
            if (@($project.References | Where-Object { $_ -ieq $current }).Count -and $reached.Add($project.Path)) { $queue.Enqueue($project.Path) }
        }
    }

    return [pscustomobject]@{
        All          = $false
        Reason       = $null
        Projects     = @($touched | Sort-Object)
        TestProjects = @($Projects | Where-Object { $_.IsTest -and $reached.Contains($_.Path) } | ForEach-Object Path | Sort-Object)
    }
}

Export-ModuleMember -Function Get-DotnetAddedProjectReference, Get-DotnetProjectGraph, Get-DotnetProjectSourceFile, Get-DotnetTestScope
