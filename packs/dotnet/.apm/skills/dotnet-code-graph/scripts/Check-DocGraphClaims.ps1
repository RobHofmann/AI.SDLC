#Requires -Version 7
<#
.SYNOPSIS
    Checks what a reference page claims about RELATIONSHIPS against the code graph: who consumes this
    library, and what implements its interfaces. The one check here that needs the graph, and the only
    one that can catch a stated relationship being false.

.DESCRIPTION
    Check-DocDrift.ps1 is deliberately graph-free so it runs for everyone on every push, which costs it
    the one thing a graph can see: whether a relationship a page states is true. This is that half, and
    it is optional for the same reason.

    It reports [unused], a page linking a project the graph records no edge to in either direction;
    [impl], a type in this project implementing a contract, usually declared elsewhere, that the page
    never names; and
    [unlisted], a consumer the page does not mention, which is informational. What each signal is worth,
    and what it took to make them precise, are in .claude/skills/dotnet-code-graph/references/code-graph.md.

    It warns, and checks anyway, when the graph is older than the working tree: a file of a kind the
    graph covers changed since the commit the graph was built at, committed or not. The verdict comes
    from Get-GraphFreshness in CodeGraph.psm1, the one staleness check every graph tool shares. The
    warning never changes the exit code.

.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script.

.PARAMETER GraphPath
    Path to graph.json. Defaults to graphify-out/graph.json under the repository root.

.PARAMETER Doc
    Only check pages whose path contains this fragment.

.PARAMETER FailOnFinding
    Exit 1 when a page carries an [unused] or an [impl] finding, the two that assert something is wrong.
    An [unlisted] finding never decides the exit code, because a page may link selectively. Off by default.

.EXAMPLE
    ./Check-DocGraphClaims.ps1

.EXAMPLE
    ./Check-DocGraphClaims.ps1 -Doc communication
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$GraphPath,
    [string]$Doc,
    [switch]$FailOnFinding
)

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' '..' 'dotnet-gates' 'scripts' 'DocSurface.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CodeGraph.psm1') -Force
Import-Module (Join-Path $aiSdlcGates 'ToolOutput.psm1') -Force

if (Test-Path -LiteralPath $RepoRoot) { $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path }


if (-not $GraphPath) { $GraphPath = Join-Path $RepoRoot 'graphify-out' 'graph.json' }

if (-not (Test-Path -LiteralPath $GraphPath)) {
    Write-Host "No code graph at '$GraphPath'." -ForegroundColor Yellow
    Write-Host 'This is the optional check: build the graph with Invoke-GraphifyIndex.ps1, or skip it.' -ForegroundColor Yellow
    Write-Host 'Check-DocDrift.ps1 needs no graph and covers everything except stated relationships.' -ForegroundColor Yellow
    $outDir = Split-Path -Parent $GraphPath
    if ((Test-Path -LiteralPath $outDir) -and (Test-Path -LiteralPath (Join-Path $outDir 'cache'))) {
        Write-Host 'The output folder exists without a graph, which is what a refresh in progress looks like: the' -ForegroundColor Yellow
        Write-Host 'git hooks empty it and rebuild after every commit, merge and checkout, and a build takes about' -ForegroundColor Yellow
        Write-Host '30 seconds. Wait for it, or run Invoke-GraphifyIndex.ps1 yourself.' -ForegroundColor Yellow
    }
    exit 0
}

$srcRoot = Join-Path $RepoRoot (Get-SourceRoot -RepoRoot $RepoRoot)
if (-not (Get-SourceRoot -RepoRoot $RepoRoot) -or -not (Test-Path -LiteralPath $srcRoot)) {
    Write-Host "No source tree at '$srcRoot'." -ForegroundColor Red
    exit 1
}
$allProjects = @(Get-ChildItem -LiteralPath $srcRoot -Directory | ForEach-Object { $_.Name })

$index = Get-GraphIndex -GraphPath $GraphPath
if ($index.Freshness.State -eq 'Stale') {
    Write-Host 'The findings below may be wrong, because the graph is older than the working tree. Rebuild it with Invoke-GraphifyIndex.ps1, run Invoke-DocGraphLink.ps1, then run this check again.' -ForegroundColor Yellow
    Write-Host 'Right after a rebuild this warning is expected while edits are not committed: the graph records the commit it was built at, not the edits.' -ForegroundColor Yellow
}

$pageRoots = @((Get-ProjectPageFolder -RepoRoot $RepoRoot) | ForEach-Object { $_.TrimEnd('/') })
$pages = [System.Collections.Generic.List[string]]::new()
foreach ($relative in $pageRoots) {
    $full = Join-Path $RepoRoot $relative
    if (-not (Test-Path -LiteralPath $full)) { continue }
    foreach ($file in (Get-ChildItem -LiteralPath $full -Filter *.md -File)) {
        $pages.Add("$relative/$($file.Name)")
    }
}

function Resolve-PageProject {
    param([Parameter(Mandatory)][string]$PagePath)

    $votes = @{}
    foreach ($edge in $index.Links) {
        if ($edge.relation -ne 'documents') { continue }
        if ((([string]$edge.source_file).Replace([char]92, '/')) -ne $PagePath) { continue }
        $project = $index.Projects[[string]$edge.target]
        if (-not $project) { continue }
        if (-not $votes.ContainsKey($project)) { $votes[$project] = 0 }
        $votes[$project]++
    }
    return Resolve-DocumentedProject -DocPath $PagePath -ProjectName @($allProjects) -Vote $votes -RepoRoot $RepoRoot
}

function Get-LineAt {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][int]$Index
    )

    if ($Index -le 0) { $start = 0 }
    else {
        $start = $Text.LastIndexOf([char]10, $Index - 1)
        if ($start -lt 0) { $start = 0 } else { $start++ }
    }
    $end = $Text.IndexOf([char]10, $Index)
    if ($end -lt 0) { $end = $Text.Length }
    return $Text.Substring($start, $end - $start)
}

$projectByPage = @{}
foreach ($page in $pages) { $projectByPage[$page] = Resolve-PageProject -PagePath $page }

$findings = [System.Collections.Generic.List[object]]::new()
$checkedPages = 0

foreach ($page in ($pages | Sort-Object)) {
    if ($Doc -and ($page -notlike "*$Doc*")) { continue }
    $project = $projectByPage[$page]
    if (-not $project) { continue }

    $full = Join-Path $RepoRoot $page
    $text = Get-Content -LiteralPath $full -Raw -Encoding utf8
    if (-not $text) { continue }
    $checkedPages++

    $consumers = Get-ProjectConsumer -Index $index -Project $project
    $consumerNames = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($consumer in $consumers) { [void]$consumerNames.Add($consumer.Project) }

    $unused = [System.Collections.Generic.List[string]]::new()
    $linked = [System.Collections.Generic.HashSet[string]]::new()
    $pageFolder = Split-Path -Parent $page
    foreach ($link in [regex]::Matches($text, '\]\((?!https?:)([A-Za-z0-9_./-]+\.md)\)')) {
        $targetPage = $link.Groups[1].Value
        $resolved = $null
        if ($pageFolder) {
            $joined = [System.IO.Path]::GetFullPath((Join-Path (Join-Path '/' $pageFolder) $targetPage))
            $resolved = $joined.Replace([char]92, '/').TrimStart('/')
            if ($resolved -match '^[A-Za-z]:/') { $resolved = $resolved.Substring(3) }
        }
        $candidates = @()
        if ($resolved) { $candidates += $resolved }
        $candidates += @("docs/$targetPage") + @($pageRoots | ForEach-Object { "$_/$targetPage" })
        $targetProject = $null
        foreach ($candidate in $candidates) {
            if ($projectByPage.ContainsKey($candidate)) { $targetProject = $projectByPage[$candidate]; break }
        }
        if (-not $targetProject -or $targetProject -eq $project) { continue }
        [void]$linked.Add($targetProject)
        if (Get-LineAt -Text $text -Index $link.Index | Select-String -SimpleMatch -Pattern 'no direct code path' -Quiet) { continue }
        if (-not (Test-ProjectsConnected -Index $index -First $project -Second $targetProject)) {
            $unused.Add("$targetProject (linked as $targetPage)")
        }
    }

    $unlisted = [System.Collections.Generic.List[string]]::new()
    foreach ($consumer in $consumers) {
        if ($linked.Contains($consumer.Project)) { continue }
        if ($text -match ([regex]::Escape($consumer.Project))) { continue }
        $reaches = (($consumer.Reaches | Sort-Object | Select-Object -First 3) -join ', ')
        $unlisted.Add("$($consumer.Project) reaches $reaches")
    }

    $missingImplementations = [System.Collections.Generic.List[string]]::new()
    foreach ($pair in (Get-ProjectImplementation -Index $index -Project $project)) {
        foreach ($implementation in $pair.Implementations) {
            if ($text -match ('\b' + [regex]::Escape($implementation) + '\b')) { continue }
            $where = if ($pair.ContractProject) { " (declared in $($pair.ContractProject))" } else { '' }
            $missingImplementations.Add("$($pair.Contract)$where is implemented here by $implementation")
        }
    }

    if ($unused.Count -gt 0 -or $unlisted.Count -gt 0 -or $missingImplementations.Count -gt 0) {
        $findings.Add([pscustomobject]@{
                Page       = $page
                Project    = $project
                Unused     = @($unused | Sort-Object -Unique)
                Unlisted   = @($unlisted | Sort-Object -Unique)
                Implements = @($missingImplementations | Sort-Object -Unique)
            })
    }
}

Write-Invariant -Template 'Pages checked against the graph: {0:N0}' -Values @($checkedPages)
Write-Host ''

if ($findings.Count -eq 0) {
    Write-Host 'No contradicted relationship: every linked project consumes the library, and every implementation is named.' -ForegroundColor Green
    exit 0
}

$totalUnused = 0
$totalImplementations = 0
foreach ($finding in $findings) {
    Write-Invariant -Template '{0}  ({1})' -Values @($finding.Page, $finding.Project) -ForegroundColor Yellow
    foreach ($item in $finding.Unused) {
        $totalUnused++
        Write-Invariant -Template '   [unused]   linked from this page, but the graph records no edge either way: {0}' -Values @($item)
    }
    foreach ($item in $finding.Implements) {
        $totalImplementations++
        Write-Invariant -Template '   [impl]     implementation the page never names: {0}' -Values @($item)
    }
    foreach ($item in $finding.Unlisted) {
        Write-Invariant -Template '   [unlisted] consumes this and is not mentioned: {0}' -Values @($item)
    }
}

Write-Host ''
$assertedPages = @($findings | Where-Object { $_.Unused.Count -gt 0 -or $_.Implements.Count -gt 0 }).Count
Write-Invariant -Template '{0:N0} page(s) carry a relationship the graph does not support: {1:N0} contradicted outright, {2:N0} implementation(s) never named.' -Values @($assertedPages, $totalUnused, $totalImplementations) -ForegroundColor Yellow
Write-Host '[unused] is the one to act on: two projects that never touch should not be linked as though they did.'
Write-Host '[impl] gates too: a type in this project implementing a contract the page never names. The contract is usually declared in another project, so the line says which.'
Write-Host '[unlisted] is informational, because a page may link selectively, and it never decides the exit code.'
if ($FailOnFinding -and $findings.Count -gt 0) {
    Write-Host 'FIX: Correct the page to the relationship the code has, or change the code if the page describes the intent. The graph, not the page, is the record of what calls what.'
}

if ($FailOnFinding -and ($totalUnused + $totalImplementations) -gt 0) { exit 1 }
exit 0
