#Requires -Version 7
<#
.SYNOPSIS
    Answers the relational questions about this codebase that reading files one at a time cannot:
    who consumes this library, what implements this interface, who calls this type.

.DESCRIPTION
    The documentation checks in this folder are text-only: they ask whether a name exists, never whether
    a stated relationship does. This module is the query layer that answers the second question, over a
    graph built by Invoke-GraphifyIndex.ps1.

    The precision filters it applies, and the blind spots it cannot cover, are recorded in
    .claude/skills/dotnet-code-graph/references/code-graph.md.

.PARAMETER GraphPath
    Path to graph.json, for Get-GraphIndex. Every other function takes the index it returns.

.PARAMETER Quiet
    Suppress the stale-graph warning Get-GraphIndex prints. For a caller that reports the state itself.

.PARAMETER BuiltAtCommit
    The commit graphify stamped into the graph, for Get-GraphFreshness. Get-GraphIndex reads it from
    the graph; a caller holding an already parsed graph passes $graph.built_at_commit.

.PARAMETER RepoRoot
    The repository the graph describes, for Get-GraphFreshness. Get-GraphIndex asks git which
    repository the graph file sits in.

.PARAMETER CoveredExtension
    The file extensions the graph holds nodes for, for Get-GraphFreshness. A changed file outside this
    set cannot have changed the graph, so it does not make the graph stale. Get-GraphIndex derives the
    set from the graph itself, not a hardcoded list, so it cannot drift from what graphify indexes.

.PARAMETER Freshness
    The verdict from Get-GraphFreshness, for Write-GraphFreshnessWarning.

.PARAMETER Index
    The index from Get-GraphIndex.

.PARAMETER Project
    The project name to ask about: who consumes it, what it calls into, what implements its contracts.

.PARAMETER First
    With Second, the two project names Test-ProjectsConnected asks about, in either direction.

.PARAMETER Second
    The other project name for Test-ProjectsConnected.

.PARAMETER TypeName
    The type Get-TypeCaller reports the callers of.

.PARAMETER MaximumImplementations
    Get-ProjectImplementation reports a contract only while it has at most this many implementers, so a
    marker interface with fifteen does not drown the answer. It filters on the IMPLEMENTER's project,
    not the contract's: most contracts implemented in a project are declared in another one, so each
    result carries ContractProject to say where to look for the interface.

.EXAMPLE
    Import-Module ./CodeGraph.psm1
    $index = Get-GraphIndex -GraphPath ./graphify-out/graph.json
    Get-ProjectConsumer -Index $index -Project 'Shared.StockLevel'

.EXAMPLE
    Test-ProjectsConnected -Index $index -First 'Shared.StockLevel' -Second 'Shared.Data'
#>

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1')

$script:TestDoublePrefix = '^(Mock|Fake|Stub|Test)'
$script:SourcePrefix = $null

$script:ConsumerRelation = @('calls', 'dispatches_to', 'references', 'implements', 'inherits')
$script:ConnectionRelation = @('calls', 'dispatches_to', 'references', 'implements', 'inherits', 'imports')

function New-GraphFreshness {
    param(
        [string]$State,
        [string]$BuiltAtCommit,
        [string]$HeadCommit,
        [string[]]$ChangedFiles = @(),
        [string]$Reason
    )

    return [pscustomobject]@{
        State         = $State
        BuiltAtCommit = $BuiltAtCommit
        HeadCommit    = $HeadCommit
        ChangedFiles  = @($ChangedFiles)
        Reason        = $Reason
    }
}

function Get-GitOutput {
    param([string]$Root, [string[]]$Arguments)

    $output = & git -C $Root @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return $output
}

function Test-GitSucceeds {
    param([string]$Root, [string[]]$Arguments)

    & git -C $Root @Arguments *> $null
    return ($LASTEXITCODE -eq 0)
}

function Get-StatusPath {
    param([string]$Line)

    if ($Line.Length -lt 4) { return $null }
    $path = $Line.Substring(3)
    $arrow = $path.IndexOf(' -> ')
    if ($arrow -ge 0) { $path = $path.Substring($arrow + 4) }
    return $path.Trim('"')
}

function Get-ShortCommit {
    param([string]$Commit)

    if ($Commit -and $Commit.Length -gt 8) { return $Commit.Substring(0, 8) }
    return $Commit
}

function Get-GraphFreshness {
    [CmdletBinding()]
    param(
        [string]$BuiltAtCommit,
        [string]$RepoRoot,
        [string[]]$CoveredExtension = @()
    )

    if (-not $BuiltAtCommit) {
        return New-GraphFreshness -State 'Unknown' -Reason 'the graph records no build commit'
    }
    if (-not $RepoRoot -or -not (Test-Path -LiteralPath $RepoRoot)) {
        return New-GraphFreshness -State 'Unknown' -BuiltAtCommit $BuiltAtCommit -Reason 'the graph does not sit inside a git repository'
    }

    $head = [string](Get-GitOutput -Root $RepoRoot -Arguments @('rev-parse', 'HEAD'))
    if (-not $head) {
        return New-GraphFreshness -State 'Unknown' -BuiltAtCommit $BuiltAtCommit -Reason 'git reports no HEAD commit here'
    }
    if (-not (Test-GitSucceeds -Root $RepoRoot -Arguments @('cat-file', '-e', "$BuiltAtCommit^{commit}"))) {
        return New-GraphFreshness -State 'Unknown' -BuiltAtCommit $BuiltAtCommit -HeadCommit $head -Reason 'the commit the graph was built at is no longer in this repository'
    }

    $changed = [System.Collections.Generic.List[string]]::new()
    if ($BuiltAtCommit -ne $head) {
        foreach ($line in @(Get-GitOutput -Root $RepoRoot -Arguments @('diff', '--name-only', $BuiltAtCommit, $head))) {
            if ($line) { $changed.Add([string]$line) }
        }
    }
    foreach ($line in @(Get-GitOutput -Root $RepoRoot -Arguments @('status', '--porcelain', '--untracked-files=all'))) {
        if (-not $line) { continue }
        $path = Get-StatusPath -Line ([string]$line)
        if ($path) { $changed.Add($path) }
    }

    $covered = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($extension in $CoveredExtension) {
        if ($extension) { [void]$covered.Add($extension) }
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $relevant = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $changed) {
        $extension = [System.IO.Path]::GetExtension($file)
        if (-not $extension) { continue }
        if ($covered.Count -gt 0 -and -not $covered.Contains($extension)) { continue }
        if ($seen.Add($file)) { $relevant.Add($file) }
    }

    if ($relevant.Count -eq 0) {
        return New-GraphFreshness -State 'Current' -BuiltAtCommit $BuiltAtCommit -HeadCommit $head -Reason 'no file the graph covers has changed since it was built'
    }

    return New-GraphFreshness -State 'Stale' -BuiltAtCommit $BuiltAtCommit -HeadCommit $head -ChangedFiles (@($relevant) | Sort-Object) -Reason "$($relevant.Count) file(s) the graph covers changed since it was built"
}

function Write-GraphFreshnessWarning {
    param([Parameter(Mandatory)]$Freshness)

    if ($Freshness.State -ne 'Stale') { return }

    $sample = @($Freshness.ChangedFiles | Select-Object -First 3) -join ', '
    if ($Freshness.ChangedFiles.Count -gt 3) { $sample += ', and more' }
    Write-Host "STALE GRAPH: $($Freshness.ChangedFiles.Count) file(s) it covers changed since it was built at $(Get-ShortCommit -Commit $Freshness.BuiltAtCommit). Every answer below describes the older code: $sample" -ForegroundColor Yellow
    Write-Host 'Rebuild it with: pwsh .claude/skills/dotnet-code-graph/scripts/Invoke-GraphifyIndex.ps1' -ForegroundColor Yellow
}

function Get-GraphIndex {
    param(
        [Parameter(Mandatory)][string]$GraphPath,
        [switch]$Quiet
    )

    $resolved = $GraphPath
    if (-not [System.IO.Path]::IsPathRooted($resolved)) {
        $candidates = @(
            (Join-Path (Get-Location).Path $resolved),
            (Join-Path (Find-AiSdlcRepoRoot -StartPath $PSScriptRoot) $resolved)
        )
        foreach ($candidate in $candidates) {
            if (Test-Path -LiteralPath $candidate) { $resolved = $candidate; break }
        }
    }
    if (-not (Test-Path -LiteralPath $resolved)) {
        throw "No graph at '$GraphPath'. Build it with Invoke-GraphifyIndex.ps1. A relative path is tried against the current directory and then the repository root."
    }
    $GraphPath = $resolved

    $configRoot = Find-AiSdlcRepoRoot -StartPath (Split-Path -Parent ([System.IO.Path]::GetFullPath($GraphPath)))
    if (-not $configRoot) { $configRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }
    $sourceRoot = ([string](Get-AiSdlcConfig -RepoRoot $configRoot).paths.sourceRoot).Replace([char]92, '/').TrimEnd('/')
    $script:SourcePrefix = if ($sourceRoot) { "$sourceRoot/" } else { $null }

    $graph = Get-Content -LiteralPath $GraphPath -Raw -Encoding utf8 | ConvertFrom-Json
    $nodeById = @{}
    $projectById = @{}
    $extensions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($node in $graph.nodes) {
        $id = [string]$node.id
        $nodeById[$id] = $node
        $sourceFile = ([string]$node.source_file).Replace([char]92, '/')
        $extension = [System.IO.Path]::GetExtension($sourceFile)
        if ($extension) { [void]$extensions.Add($extension) }
        if ($script:SourcePrefix -and $sourceFile.StartsWith($script:SourcePrefix) -and $sourceFile -notlike '*.csproj') {
            $projectById[$id] = ($sourceFile.Substring($script:SourcePrefix.Length) -split '/')[0]
        }
    }

    $repoRoot = [string](Get-GitOutput -Root (Split-Path -Parent $GraphPath) -Arguments @('rev-parse', '--show-toplevel'))
    $freshness = Get-GraphFreshness -BuiltAtCommit ([string]$graph.built_at_commit) -RepoRoot $repoRoot -CoveredExtension @($extensions)
    if (-not $Quiet) { Write-GraphFreshnessWarning -Freshness $freshness }

    return [pscustomobject]@{
        Nodes     = $nodeById
        Projects  = $projectById
        Links     = $graph.links
        NodeCount = $graph.nodes.Count
        LinkCount = $graph.links.Count
        Freshness = $freshness
    }
}

function Test-PrimarySymbol {
    param($Node)

    if (-not $Node) { return $false }
    if ($Node._callable -or $Node._callable_class) { return $true }
    $stem = [System.IO.Path]::GetFileNameWithoutExtension(([string]$Node.source_file))
    return ([string]$Node.label -eq $stem)
}

function Get-ProjectConsumer {
    param(
        [Parameter(Mandatory)]$Index,
        [Parameter(Mandatory)][string]$Project
    )

    $byProject = @{}
    foreach ($edge in $Index.Links) {
        if ($edge.relation -notin $script:ConsumerRelation) { continue }
        $sourceProject = $Index.Projects[[string]$edge.source]
        $targetProject = $Index.Projects[[string]$edge.target]
        if (-not $sourceProject -or -not $targetProject) { continue }
        if ($targetProject -ne $Project -or $sourceProject -eq $Project) { continue }
        if (-not (Test-PrimarySymbol -Node $Index.Nodes[[string]$edge.target])) { continue }

        if (-not $byProject.ContainsKey($sourceProject)) {
            $byProject[$sourceProject] = [pscustomobject]@{
                Project = $sourceProject
                Edges   = 0
                Reaches = [System.Collections.Generic.HashSet[string]]::new()
            }
        }
        $byProject[$sourceProject].Edges++
        $target = $Index.Nodes[[string]$edge.target]
        if ($target -and $target.label) { [void]$byProject[$sourceProject].Reaches.Add([string]$target.label) }
    }

    return @($byProject.Values | Sort-Object -Property Edges -Descending)
}

function Get-ProjectDependency {
    param(
        [Parameter(Mandatory)]$Index,
        [Parameter(Mandatory)][string]$Project
    )

    $byProject = @{}
    foreach ($edge in $Index.Links) {
        if ($edge.relation -notin $script:ConsumerRelation) { continue }
        $sourceProject = $Index.Projects[[string]$edge.source]
        $targetProject = $Index.Projects[[string]$edge.target]
        if (-not $sourceProject -or -not $targetProject) { continue }
        if ($sourceProject -ne $Project -or $targetProject -eq $Project) { continue }
        if (-not (Test-PrimarySymbol -Node $Index.Nodes[[string]$edge.target])) { continue }

        if (-not $byProject.ContainsKey($targetProject)) {
            $byProject[$targetProject] = [pscustomobject]@{
                Project = $targetProject
                Edges   = 0
                Uses    = [System.Collections.Generic.HashSet[string]]::new()
            }
        }
        $byProject[$targetProject].Edges++
        $target = $Index.Nodes[[string]$edge.target]
        if ($target -and $target.label) { [void]$byProject[$targetProject].Uses.Add([string]$target.label) }
    }

    return @($byProject.Values | Sort-Object -Property Edges -Descending)
}

function Test-ProjectsConnected {
    param(
        [Parameter(Mandatory)]$Index,
        [Parameter(Mandatory)][string]$First,
        [Parameter(Mandatory)][string]$Second
    )

    foreach ($edge in $Index.Links) {
        if ($edge.relation -notin $script:ConnectionRelation) { continue }
        $source = $Index.Projects[[string]$edge.source]
        $target = $Index.Projects[[string]$edge.target]
        if (-not $source -or -not $target) { continue }
        if ($edge.relation -ne 'imports' -and -not (Test-PrimarySymbol -Node $Index.Nodes[[string]$edge.target])) { continue }
        if (($source -eq $First -and $target -eq $Second) -or ($source -eq $Second -and $target -eq $First)) {
            return $true
        }
    }
    return $false
}

function Get-ProjectImplementation {
    param(
        [Parameter(Mandatory)]$Index,
        [Parameter(Mandatory)][string]$Project,
        [int]$MaximumImplementations = 4
    )

    $byInterface = @{}
    $contractProject = @{}
    foreach ($edge in $Index.Links) {
        if ($edge.relation -ne 'implements') { continue }
        $implementer = $Index.Nodes[[string]$edge.source]
        if (-not $implementer) { continue }
        if ($Index.Projects[[string]$edge.source] -ne $Project) { continue }

        $contract = $Index.Nodes[[string]$edge.target]
        if (-not $contract) { continue }
        $contractFile = ([string]$contract.source_file).Replace([char]92, '/')
        if (-not $script:SourcePrefix -or -not $contractFile.StartsWith($script:SourcePrefix)) { continue }
        $implementerName = [string]$implementer.label
        if ($implementerName -match $script:TestDoublePrefix) { continue }

        $contractName = [string]$contract.label
        if (-not $byInterface.ContainsKey($contractName)) {
            $byInterface[$contractName] = [System.Collections.Generic.HashSet[string]]::new()
            $contractProject[$contractName] = $Index.Projects[[string]$edge.target]
        }
        [void]$byInterface[$contractName].Add($implementerName)
    }

    return @($byInterface.GetEnumerator() |
        Where-Object { $_.Value.Count -le $MaximumImplementations } |
        Sort-Object -Property Key |
        ForEach-Object {
            [pscustomobject]@{
                Contract        = $_.Key
                ContractProject = $contractProject[$_.Key]
                Implementations = @($_.Value | Sort-Object)
            }
        })
}

function Get-TypeCaller {
    param(
        [Parameter(Mandatory)]$Index,
        [Parameter(Mandatory)][string]$TypeName
    )

    $wanted = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($entry in $Index.Nodes.GetEnumerator()) {
        if ([string]$entry.Value.label -eq $TypeName) { [void]$wanted.Add([string]$entry.Key) }
    }
    if ($wanted.Count -eq 0) { return @() }

    $callers = @{}
    foreach ($edge in $Index.Links) {
        if ($edge.relation -notin @('calls', 'dispatches_to', 'references')) { continue }
        if (-not $wanted.Contains([string]$edge.target)) { continue }
        $source = $Index.Nodes[[string]$edge.source]
        if (-not $source) { continue }
        $file = ([string]$source.source_file).Replace([char]92, '/')
        if (-not $file) { continue }
        $key = "$($source.label)|$file"
        if (-not $callers.ContainsKey($key)) {
            $callers[$key] = [pscustomobject]@{
                Caller     = [string]$source.label
                SourceFile = $file
                Relation   = [string]$edge.relation
            }
        }
    }

    return @($callers.Values | Sort-Object -Property SourceFile, Caller)
}

Export-ModuleMember -Function @(
    'Get-GraphIndex',
    'Get-GraphFreshness',
    'Write-GraphFreshnessWarning',
    'Get-ProjectConsumer',
    'Get-ProjectDependency',
    'Test-ProjectsConnected',
    'Get-ProjectImplementation',
    'Get-TypeCaller'
)
