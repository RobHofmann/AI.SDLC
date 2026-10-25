#Requires -Version 7
<#
.SYNOPSIS
    Reads what one .NET project holds and how it connects: its references, its public types and
    methods, and, when the code graph is there, who consumes it. The documentation tools send these
    facts to the model when they draft a new page.

.DESCRIPTION
    Update-DocFromGraph.ps1 adds to a page that exists, from the files that page already cites. A
    project with no page cites nothing, so it needs its facts from the project itself. This script
    reads them:

      - the project file: its SDK, its project references and its package references;
      - each C# file outside bin/ and obj/: its public types and public methods, read with the same
        rules as the drift check (DocSurface.psm1), capped per file so the request stays small. A
        constructor is left out, because a model reads it as a method with the name of its type;
      - from the code graph, when graph.json exists and is fresh: the projects that consume this one,
        the projects it calls into, and the contracts it implements (CodeGraph.psm1).

    Without a graph, or with a stale one, the relationship part is left out and the facts say so.
    New-DocCandidate.ps1 in the adopt-docs skill runs this script as the facts source of the
    dotnet pack (docFacts in gates.json). It sends nothing anywhere itself.

.PARAMETER Unit
    The project folder, relative to RepoRoot, for example src/Shared.Thing.

.PARAMETER RepoRoot
    The repository root. Defaults to the folder that holds aisdlc.json.

.PARAMETER GraphPath
    The code graph. Defaults to graphify-out/graph.json at the repository root.

.PARAMETER MaximumMethodsPerFile
    How many public method names to list per file. Defaults to 15.

.EXAMPLE
    pwsh .claude/skills/dotnet-code-graph/scripts/Get-ProjectFacts.ps1 -Unit src/Shared.Thing
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Unit,
    [string]$RepoRoot,
    [string]$GraphPath,
    [int]$MaximumMethodsPerFile = 15
)

$ErrorActionPreference = 'Stop'
$gates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $gates)) { $gates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $gates 'AiSdlcConfig.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..' '..' 'dotnet-gates' 'scripts' 'DocSurface.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CodeGraph.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$projectDir = Join-Path $RepoRoot $Unit
if (-not (Test-Path -LiteralPath $projectDir -PathType Container)) { throw "Get-ProjectFacts: '$Unit' is not a folder under $RepoRoot." }
$projectDir = (Resolve-Path -LiteralPath $projectDir).Path
if (-not $projectDir.StartsWith($RepoRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "Get-ProjectFacts: '$Unit' resolves outside the repository." }
$projectName = Split-Path $projectDir -Leaf

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("UNIT: $Unit (project $projectName)")

$projectFile = Get-ChildItem -LiteralPath $projectDir -Filter *.csproj -File | Select-Object -First 1
if ($projectFile) {
    [xml]$xml = Get-Content -LiteralPath $projectFile.FullName -Raw -Encoding utf8
    $sdk = [string]$xml.Project.Sdk
    if ($sdk) { $lines.Add("  sdk: $sdk") }
    $refs = @($xml.SelectNodes('//ProjectReference') | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension(($_.Include -replace '\\', '/')) } | Sort-Object -Unique)
    if ($refs.Count -gt 0) { $lines.Add("  project references: $($refs -join ', ')") }
    $packages = @($xml.SelectNodes('//PackageReference') | ForEach-Object { [string]$_.Include } | Where-Object { $_ } | Sort-Object -Unique)
    if ($packages.Count -gt 0) { $lines.Add("  package references: $($packages -join ', ')") }
}

$lines.Add('')
$lines.Add('PUBLIC TYPES AND METHODS, per file:')
$sourceFiles = Get-ChildItem -LiteralPath $projectDir -Recurse -File -Filter *.cs |
    Where-Object { $_.FullName -notmatch '[\\/](bin|obj)[\\/]' } | Sort-Object FullName
foreach ($file in $sourceFiles) {
    $source = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
    if (-not $source) { continue }
    $types = @(Get-PublicTypeName -Source $source | Where-Object { -not (Test-IsTestDouble -Name $_) } | Sort-Object)
    if ($types.Count -eq 0) { continue }
    $rel = [IO.Path]::GetRelativePath($RepoRoot, $file.FullName).Replace('\', '/')
    $lines.Add("  FILE: $rel")
    $lines.Add("    public types: $($types -join ', ')")
    $allTypes = @(Get-PublicTypeName -Source $source)
    $methods = @(Get-PublicMethodName -Source $source | Where-Object { $allTypes -notcontains $_ } | Sort-Object)
    if ($methods.Count -gt 0) {
        $shown = @($methods | Select-Object -First $MaximumMethodsPerFile)
        $more = if ($methods.Count -gt $shown.Count) { " (and $($methods.Count - $shown.Count) more)" } else { '' }
        $lines.Add("    public methods: $($shown -join ', ')$more")
    }
    $members = @(Get-PublicMemberName -Source $source | Sort-Object)
    if ($members.Count -gt 0) { $lines.Add("    public named members: $($members -join ', ')") }
}

if (-not $GraphPath) { $GraphPath = Join-Path $RepoRoot 'graphify-out' 'graph.json' }
$lines.Add('')
if (-not (Test-Path -LiteralPath $GraphPath)) {
    $lines.Add('RELATIONSHIPS: not included, because there is no code graph. Build it with Invoke-GraphifyIndex.ps1.')
}
else {
    $index = Get-GraphIndex -GraphPath $GraphPath
    if ($index.Freshness.State -eq 'Stale') {
        $lines.Add('RELATIONSHIPS: not included, because the code graph is stale. Rebuild it with Invoke-GraphifyIndex.ps1.')
    }
    else {
        $consumers = @(Get-ProjectConsumer -Index $index -Project $projectName)
        $lines.Add('WHO CONSUMES THIS PROJECT, from the code graph:')
        if ($consumers.Count -eq 0) { $lines.Add('  no project in the graph reaches this one') }
        foreach ($consumer in $consumers) { $lines.Add("  $($consumer.Project) reaches $((($consumer.Reaches | Sort-Object | Select-Object -First 6) -join ', '))") }
        $dependencies = @(Get-ProjectDependency -Index $index -Project $projectName)
        if ($dependencies.Count -gt 0) {
            $lines.Add('WHAT THIS PROJECT CALLS INTO, from the code graph:')
            foreach ($dependency in $dependencies) { $lines.Add("  $($dependency.Project): $((($dependency.Uses | Sort-Object | Select-Object -First 6) -join ', '))") }
        }
        $implementations = @(Get-ProjectImplementation -Index $index -Project $projectName)
        if ($implementations.Count -gt 0) {
            $lines.Add('WHAT THIS PROJECT IMPLEMENTS, from the syntax tree:')
            foreach ($pair in $implementations) {
                $where = if ($pair.ContractProject) { " (declared in $($pair.ContractProject))" } else { '' }
                $lines.Add("  $($pair.Contract)$where <- $($pair.Implementations -join ', ')")
            }
        }
    }
}

return $lines.ToArray()
