#Requires -Version 7
<#
.SYNOPSIS
    Links documentation pages to the code they describe, by resolving the source files the docs
    already name, and writes those edges into the local code graph.

.DESCRIPTION
    Docs often cite their sources: a page says `Source: OrderServiceCollectionExtensions.cs`
    beside the thing it describes. That is a link waiting to be made, and it is made here deterministically:
    read the file name out of the page, find the node the AST extractor already produced for that file,
    write an edge. No model, no cost, no guessing.

    WHY THIS EXISTS RATHER THAN THE TOOL'S OWN SEMANTIC PASS. Graphify can send documents to an LLM and
    ask it for a knowledge-graph fragment. Measured on this repository that produced 3 usable doc-to-code
    edges out of 33517, at a cost of 3.53 dollars and ten minutes. The reason is structural, not a matter
    of model quality: code is parsed locally by tree-sitter into AST nodes, documents are sent to the model
    in separate chunks, the model never sees the code, and nothing reconciles the two afterwards. For the
    model to link a page to a class it has to GUESS a node id string that happens to match. This script
    does not guess; it resolves. The same corpus yields several hundred edges for nothing.
    See .claude/skills/dotnet-code-graph/references/code-graph.md.

    An edge is only written when the named file resolves to exactly one tracked source file. A bare name
    that matches two files in different projects is ambiguous and is skipped rather than guessed, which is
    the same precision-over-recall rule the C# resolver applies.

.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script.

.PARAMETER GraphPath
    Path to graph.json. Defaults to graphify-out/graph.json under RepoRoot.

.PARAMETER DocRoots
    Directories to scan for documentation. Defaults to paths.docsRoots in aisdlc.json.

.PARAMETER OutputPath
    Where to write the enriched graph. Defaults to GraphPath, i.e. in place.

.PARAMETER ReportOnly
    Report what would be linked without writing anything.

.EXAMPLE
    ./Invoke-DocGraphLink.ps1 -ReportOnly

.EXAMPLE
    ./Invoke-DocGraphLink.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$GraphPath,
    [string[]]$DocRoots,
    [string]$OutputPath,
    [switch]$ReportOnly
)

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' '..' 'dotnet-gates' 'scripts' 'DocSurface.psm1') -Force
Import-Module (Join-Path $aiSdlcGates 'ToolOutput.psm1') -Force

if (Test-Path -LiteralPath $RepoRoot) { $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path }
if (-not $DocRoots) { $DocRoots = @(Get-AiSdlcPath -Name docsRoots -RepoRoot $RepoRoot -Relative) }

$script:SourceExtensions = @('.cs', '.razor', '.ps1', '.bicep')


function Get-TrackedSourceFile {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][ref]$Failed
    )

    $Failed.Value = $false
    Push-Location -LiteralPath $Root
    try {
        $tracked = & git ls-files 2>$null
        if ($LASTEXITCODE -ne 0) {
            $Failed.Value = $true
            return @{}
        }
    }
    finally { Pop-Location }

    $byName = @{}
    foreach ($path in $tracked) {
        if (-not $path) { continue }
        $extension = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
        if ($script:SourceExtensions -notcontains $extension) { continue }
        $name = [System.IO.Path]::GetFileName($path)
        if (-not $byName.ContainsKey($name)) { $byName[$name] = [System.Collections.Generic.List[string]]::new() }
        $byName[$name].Add(($path -replace '\\', '/'))
    }
    return $byName
}

function Get-DocFile {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$Roots
    )

    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($relative in $Roots) {
        $full = Join-Path $Root $relative
        if (-not (Test-Path -LiteralPath $full)) { continue }
        foreach ($file in (Get-ChildItem -LiteralPath $full -Recurse -Filter '*.md' -File)) {
            $found.Add(($file.FullName.Substring($Root.Length).TrimStart('\', '/') -replace '\\', '/'))
        }
    }
    return $found
}

function Build-FileNodeIndex {
    param([Parameter(Mandatory)]$Graph)

    $named = @{}
    $any = @{}
    foreach ($node in $Graph.nodes) {
        $file = ([string]$node.source_file) -replace '\\', '/'
        if (-not $file) { continue }
        if (-not $any.ContainsKey($file)) { $any[$file] = $node.id }
        if (-not $named.ContainsKey($file) -and ([string]$node.label) -eq [System.IO.Path]::GetFileName($file)) {
            $named[$file] = $node.id
        }
    }
    return @{ Named = $named; Any = $any }
}

function Resolve-FileNode {
    param(
        [Parameter(Mandatory)]$Index,
        [Parameter(Mandatory)][string]$SourceFile
    )

    if ($Index.Named.ContainsKey($SourceFile)) { return $Index.Named[$SourceFile] }
    if ($Index.Any.ContainsKey($SourceFile)) { return $Index.Any[$SourceFile] }
    return $null
}

if (-not $GraphPath) { $GraphPath = Join-Path $RepoRoot 'graphify-out' 'graph.json' }
if (-not $OutputPath) { $OutputPath = $GraphPath }

if (-not (Test-Path -LiteralPath $GraphPath)) {
    Write-Host "No graph at '$GraphPath'. Build it with Invoke-GraphifyIndex.ps1 first." -ForegroundColor Red
    exit 1
}

$graph = Get-Content -LiteralPath $GraphPath -Raw -Encoding utf8 | ConvertFrom-Json
$gitFailed = $false
$sourceByName = Get-TrackedSourceFile -Root $RepoRoot -Failed ([ref]$gitFailed)
if ($gitFailed) {
    Write-Host "'$RepoRoot' is not inside a git working tree, or git failed there." -ForegroundColor Red
    Write-Host 'Refusing to report success over an empty file list: every citation would look unresolved.' -ForegroundColor Red
    exit 1
}
$docs = Get-DocFile -Root $RepoRoot -Roots $DocRoots

if ($docs.Count -eq 0) {
    Write-Host "No documentation found under: $($DocRoots -join ', ')" -ForegroundColor Yellow
    exit 1
}

$fileNodeIndex = Build-FileNodeIndex -Graph $graph
$nodeIdByFile = @{}
$existingEdges = [System.Collections.Generic.HashSet[string]]::new()
foreach ($link in $graph.links) {
    [void]$existingEdges.Add("$($link.source)|$($link.target)|documents")
}

$newEdges = [System.Collections.Generic.List[object]]::new()
$docNodes = [System.Collections.Generic.List[object]]::new()
$linkedDocs = 0
$ambiguous = 0
$unresolved = 0

foreach ($doc in $docs) {
    $fullPath = Join-Path $RepoRoot $doc
    $text = Get-Content -LiteralPath $fullPath -Raw -Encoding utf8
    if (-not $text) { continue }

    $names = Get-NamedSourceFile -Text $text
    if ($names.Count -eq 0) { continue }

    $targets = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $names) {
        if (-not $sourceByName.ContainsKey($name)) { $unresolved++; continue }
        if ($sourceByName[$name].Count -gt 1) { $ambiguous++; continue }

        $sourceFile = $sourceByName[$name][0]
        if (-not $nodeIdByFile.ContainsKey($sourceFile)) {
            $nodeIdByFile[$sourceFile] = Resolve-FileNode -Index $fileNodeIndex -SourceFile $sourceFile
        }
        $targetId = $nodeIdByFile[$sourceFile]
        if ($targetId) { $targets.Add($targetId) }
    }

    if ($targets.Count -eq 0) { continue }

    $docId = 'doc_' + (($doc -replace '[^A-Za-z0-9]', '_').ToLowerInvariant())
    $docNodes.Add([pscustomobject]@{
            id           = $docId
            label        = [System.IO.Path]::GetFileNameWithoutExtension($doc)
            file_type    = 'document'
            source_file  = $doc
            _origin      = 'docgraph-link'
        })

    foreach ($targetId in ($targets | Select-Object -Unique)) {
        $key = "$docId|$targetId|documents"
        if ($existingEdges.Contains($key)) { continue }
        [void]$existingEdges.Add($key)
        $newEdges.Add([pscustomobject]@{
                source           = $docId
                target           = $targetId
                relation         = 'documents'
                confidence       = 'EXTRACTED'
                confidence_score = 1.0
                context          = 'doc-citation'
                source_file      = $doc
                weight           = 1.0
                _origin          = 'docgraph-link'
            })
    }
    $linkedDocs++
}

Write-Invariant -Template 'Documentation pages scanned : {0:N0}' -Values @($docs.Count)
Write-Invariant -Template 'Pages that cite real source : {0:N0}' -Values @($linkedDocs)
Write-Invariant -Template 'Doc-to-code edges resolved  : {0:N0}' -Values @($newEdges.Count)
Write-Invariant -Template 'Skipped, name not tracked   : {0:N0}' -Values @($unresolved)
Write-Invariant -Template 'Skipped, name ambiguous     : {0:N0}' -Values @($ambiguous)

if ($ReportOnly) {
    Write-Host ''
    Write-Host 'Report only; nothing written.' -ForegroundColor Yellow
    exit 0
}

if ($newEdges.Count -eq 0) {
    Write-Host ''
    Write-Host 'Nothing to add; the graph already carries these edges.' -ForegroundColor Green
    exit 0
}

$existingNodeIds = [System.Collections.Generic.HashSet[string]]::new()
foreach ($node in $graph.nodes) { [void]$existingNodeIds.Add([string]$node.id) }

$nodesToAdd = @($docNodes | Where-Object { -not $existingNodeIds.Contains($_.id) } | Group-Object id | ForEach-Object { $_.Group[0] })

$graph.nodes = @($graph.nodes) + $nodesToAdd
$graph.links = @($graph.links) + $newEdges.ToArray()

$graph | ConvertTo-Json -Depth 12 -Compress | Set-Content -LiteralPath $OutputPath -Encoding utf8

Write-Host ''
Write-Invariant -Template 'Wrote {0}: {1:N0} document node(s) and {2:N0} edge(s) added.' -Values @($OutputPath, $nodesToAdd.Count, $newEdges.Count) -ForegroundColor Green
exit 0
