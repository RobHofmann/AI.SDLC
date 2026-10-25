#Requires -Version 7
<#
.SYNOPSIS
    Builds or refreshes the local Graphify code knowledge graph for this repository, and reports what
    the graph covers and whether it has gone stale.

.DESCRIPTION
    Builds the local code graph with `graphify extract --code-only --no-viz`, and optionally reports
    coverage and staleness. It does NOT write the documentation edges: a clean build drops them, and
    Invoke-DocGraphLink.ps1 puts them back. The git hooks run the two in that order, and so does
    Install-AiSdlc.ps1 for the first build on a clone; run the linker yourself if you call this
    script directly and want a graph the documentation tools can use.

    Every build is a clean full build, and the incremental update path is never used; the reason, the
    measured figures and the egress guarantee are in .claude/skills/dotnet-code-graph/references/code-graph.md.

.PARAMETER RepoRoot
    Repository root to index. Defaults to the folder that holds aisdlc.json, found from this script.

.PARAMETER Quiet
    Suppress progress output. Used by the git hooks so a commit does not print a wall of text.

.PARAMETER Report
    Rebuild the graph, then print the coverage and staleness report.

.PARAMETER ReportOnly
    Print the report for the graph that already exists, without rebuilding. Fails when there is no
    graph yet.

.PARAMETER GraphPath
    Path to graph.json. Defaults to graphify-out/graph.json under RepoRoot. Used by the Pester tests
    to report against a fixture.

.PARAMETER HeadCommit
    The commit to compare the graph's recorded build commit against. Defaults to the current HEAD as
    reported by git. Used by the Pester tests to exercise the staleness comparison without a repo.

.PARAMETER GraphifyCommand
    The executable to invoke for the rebuild. Defaults to 'graphify'. Used by the Pester tests.

.PARAMETER ExtraArguments
    Additional arguments appended to `graphify extract`. Only the flags in $script:AllowedExtraArgument
    pass through; anything else is refused. To use a flag that is not listed, add it there after checking
    what it does. See .claude/skills/dotnet-code-graph/references/code-graph.md for why this is an allowlist.

.EXAMPLE
    ./Invoke-GraphifyIndex.ps1

.EXAMPLE
    ./Invoke-GraphifyIndex.ps1 -Report

.EXAMPLE
    ./Invoke-GraphifyIndex.ps1 -ReportOnly
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,

    [switch]$Quiet,

    [switch]$Report,

    [switch]$ReportOnly,

    [string]$GraphPath,

    [string]$HeadCommit,

    [string]$GraphifyCommand = 'graphify',

    [string[]]$ExtraArguments = @()
)

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $aiSdlcGates 'ToolOutput.psm1') -Force

$script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture

$script:AllowedExtraArgument = @('--no-viz', '--code-only', '--quiet', '--verbose', '--force', '--stats')

$script:TrackedExtensions = @('.cs', '.razor', '.ps1', '.csproj', '.bicep', '.yml', '.json', '.js')


function Get-PinnedVersion {
    $pinFile = Join-Path $PSScriptRoot 'graphify-version.json'
    if (-not (Test-Path -LiteralPath $pinFile)) { return 'the pinned version in graphify-version.json' }
    $pinned = (Get-Content -LiteralPath $pinFile -Raw -Encoding utf8 | ConvertFrom-Json).graphifyVersion
    if ($pinned) { return $pinned }
    return 'the pinned version in graphify-version.json'
}

function Assert-NoBackendArgument {
    param([string[]]$Arguments)

    foreach ($argument in $Arguments) {
        $name = ([string]$argument).Split('=')[0].Trim()
        if ($script:AllowedExtraArgument -ccontains $name) { continue }
        return $argument
    }

    return $null
}

function Get-RepoFileCount {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Extension
    )

    Push-Location -LiteralPath $Root
    try {
        $tracked = & git ls-files "*$Extension" 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        if ($null -eq $tracked) { return 0 }
        return @($tracked | Where-Object { $_ }).Count
    }
    finally {
        Pop-Location
    }
}

function Get-HeadCommit {
    param([Parameter(Mandatory)][string]$Root)

    Push-Location -LiteralPath $Root
    try {
        $head = & git rev-parse HEAD 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return ($head | Select-Object -First 1)
    }
    finally {
        Pop-Location
    }
}

function Get-GraphCoverage {
    param([Parameter(Mandatory)]$Graph)

    $nodes = @($Graph.nodes)
    $links = @($Graph.links)

    $filesByExtension = @{}
    $nodesByExtension = @{}

    foreach ($node in $nodes) {
        $sourceFile = [string]$node.source_file
        if ([string]::IsNullOrWhiteSpace($sourceFile)) { continue }

        $extension = [System.IO.Path]::GetExtension($sourceFile).ToLowerInvariant()
        if (-not $extension) { continue }

        if (-not $filesByExtension.ContainsKey($extension)) {
            $filesByExtension[$extension] = [System.Collections.Generic.HashSet[string]]::new()
            $nodesByExtension[$extension] = 0
        }

        [void]$filesByExtension[$extension].Add($sourceFile)
        $nodesByExtension[$extension] = $nodesByExtension[$extension] + 1
    }

    $dispatches = @($links | Where-Object { $_.relation -eq 'dispatches_to' }).Count
    $implements = @($links | Where-Object { $_.relation -eq 'implements' }).Count
    $extracted = @($links | Where-Object { $_.confidence -eq 'EXTRACTED' }).Count

    $inferredByRelation = @{}
    foreach ($link in $links) {
        if ($link.confidence -eq 'EXTRACTED') { continue }
        $relation = [string]$link.relation
        if (-not $inferredByRelation.ContainsKey($relation)) { $inferredByRelation[$relation] = 0 }
        $inferredByRelation[$relation] = $inferredByRelation[$relation] + 1
    }

    return [pscustomobject]@{
        NodeCount          = $nodes.Count
        LinkCount          = $links.Count
        FilesByExtension   = $filesByExtension
        NodesByExtension   = $nodesByExtension
        DispatchesTo       = $dispatches
        Implements         = $implements
        Extracted          = $extracted
        InferredByRelation = $inferredByRelation
        BuiltAtCommit      = [string]$Graph.built_at_commit
    }
}

function Read-Graph {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
}

if (-not $GraphPath) {
    $GraphPath = Join-Path $RepoRoot 'graphify-out' 'graph.json'
}

$refused = Assert-NoBackendArgument -Arguments $ExtraArguments
if ($refused) {
    Write-Host "Refused '$refused': this wrapper passes through only $($script:AllowedExtraArgument -join ', '), so an argument it does not recognise cannot reach a model backend." -ForegroundColor Red
    Write-Host "Source code may be client-confidential, so nothing it does not recognise is passed on." -ForegroundColor Red
    exit 1
}

if (-not $ReportOnly) {
    if (-not (Get-Command $GraphifyCommand -ErrorAction SilentlyContinue)) {
        Write-Host "'$GraphifyCommand' is not on PATH; the existing graph was left alone." -ForegroundColor Red
        Write-Host "Install it with: uv tool install graphifyy==$(Get-PinnedVersion)  (see graphify-version.json in the dotnet-code-graph skill)" -ForegroundColor Red
        exit 1
    }

    $outputDirectory = Split-Path -Parent $GraphPath
    if ($outputDirectory -and (Test-Path -LiteralPath $outputDirectory) -and (Split-Path -Leaf $outputDirectory) -eq 'graphify-out') {
        Remove-Item -LiteralPath $outputDirectory -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $outputDirectory) {
            Write-Host "Could not empty '$outputDirectory'; a file in it is probably locked." -ForegroundColor Red
            Write-Host 'Refusing to build on top of it: the result would be a stale graph that looks fresh.' -ForegroundColor Red
            exit 1
        }
    }

    $extractArguments = @('extract', $RepoRoot, '--code-only', '--no-viz') + $ExtraArguments

    if (-not $Quiet) {
        Write-Invariant -Template 'Building the code graph (code-only, no backend): {0} {1}' -Values @($GraphifyCommand, ($extractArguments -join ' '))
    }

    if ($Quiet) {
        & $GraphifyCommand @extractArguments *> $null
    }
    else {
        & $GraphifyCommand @extractArguments
    }
    $extractExit = $LASTEXITCODE

    if ($extractExit -ne 0) {
        if (-not $Quiet) {
            Write-Host "graphify failed with exit code $extractExit." -ForegroundColor Red
            Write-Host "Install it with: uv tool install graphifyy==$(Get-PinnedVersion)  (see graphify-version.json in the dotnet-code-graph skill)" -ForegroundColor Red
        }
        exit 1
    }
}

if (-not ($Report -or $ReportOnly)) {
    if (-not $Quiet) {
        Write-Invariant -Template 'Graph written to {0}. Re-run with -Report for coverage and staleness.' -Values @($GraphPath) -ForegroundColor Green
    }
    exit 0
}

$graph = Read-Graph -Path $GraphPath
if ($null -eq $graph) {
    Write-Host "No graph at '$GraphPath'. Run this script without -ReportOnly to build it." -ForegroundColor Red
    exit 1
}

$coverage = Get-GraphCoverage -Graph $graph

Write-Invariant -Template 'Graph: {0:N0} nodes, {1:N0} edges, {2:N0} of them EXTRACTED.' -Values @($coverage.NodeCount, $coverage.LinkCount, $coverage.Extracted)
Write-Host ''
Write-Invariant -Template '{0,-10}{1,12}{2,12}{3,10}' -Values @('type', 'in graph', 'in repo', 'nodes')

$missing = @()
foreach ($extension in $script:TrackedExtensions) {
    $inGraph = if ($coverage.FilesByExtension.ContainsKey($extension)) { $coverage.FilesByExtension[$extension].Count } else { 0 }
    $nodeCount = if ($coverage.NodesByExtension.ContainsKey($extension)) { $coverage.NodesByExtension[$extension] } else { 0 }
    $inRepo = Get-RepoFileCount -Root $RepoRoot -Extension $extension

    $inRepoText = if ($null -eq $inRepo) { 'n/a' } else { [string]::Format($script:Invariant, '{0:N0}', $inRepo) }
    Write-Invariant -Template '{0,-10}{1,12:N0}{2,12}{3,10:N0}' -Values @($extension, $inGraph, $inRepoText, $nodeCount)

    if ($null -ne $inRepo -and $inRepo -gt 0 -and $inGraph -eq 0) {
        $missing += $extension
    }
}

Write-Host ''
Write-Invariant -Template 'Interface dispatch: {0:N0} resolved call edges (dispatches_to) across {1:N0} implements edges.' -Values @($coverage.DispatchesTo, $coverage.Implements)

$inferredTotal = 0
foreach ($count in $coverage.InferredByRelation.Values) { $inferredTotal += $count }

if ($inferredTotal -gt 0) {
    Write-Host ''
    Write-Invariant -Template 'Structurally inferred edges: {0:N0}. These are NOT model output. No API key is used' -Values @($inferredTotal)
    Write-Host 'in code-only mode; the C# resolver marks an edge inferred when it resolved it by rule rather'
    Write-Host 'than by reading it literally from the syntax tree. They are where the DI graph lives, so'
    Write-Host 'discarding them would remove most of what makes this graph worth querying:'
    foreach ($relation in ($coverage.InferredByRelation.Keys | Sort-Object { -$coverage.InferredByRelation[$_] })) {
        Write-Invariant -Template '  {0,-16}{1,8:N0}' -Values @($relation, $coverage.InferredByRelation[$relation])
    }
}

if ($missing.Count -gt 0) {
    Write-Host ''
    Write-Invariant -Template 'Not in the graph, so still a grep problem: {0}' -Values @(($missing -join ', ')) -ForegroundColor Yellow
    Write-Host 'An empty result for those file types is not evidence of absence. See .claude/skills/dotnet-code-graph/references/code-graph.md.' -ForegroundColor Yellow
}

if (-not $HeadCommit) {
    $HeadCommit = Get-HeadCommit -Root $RepoRoot
}

Write-Host ''
if (-not $coverage.BuiltAtCommit) {
    Write-Host 'The graph records no build commit, so its freshness cannot be checked. Rebuild it.' -ForegroundColor Yellow
    exit 0
}

if (-not $HeadCommit) {
    Write-Invariant -Template 'Graph built at {0}. HEAD is unknown here, so staleness was not checked.' -Values @($coverage.BuiltAtCommit) -ForegroundColor Yellow
    exit 0
}

if ($coverage.BuiltAtCommit -ne $HeadCommit) {
    Write-Invariant -Template 'STALE: the graph was built at {0} but HEAD is {1}.' -Values @($coverage.BuiltAtCommit, $HeadCommit) -ForegroundColor Yellow
    Write-Host 'It describes code that may no longer exist, and it will answer with full confidence anyway. Rebuild before trusting it.' -ForegroundColor Yellow
    exit 0
}

Write-Invariant -Template 'Fresh: the graph was built at HEAD ({0}).' -Values @($coverage.BuiltAtCommit) -ForegroundColor Green
exit 0
