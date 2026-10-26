#Requires -Version 7
<#
.SYNOPSIS
    Asks the local code graph one read-only question, with the graph's freshness reported first.

.DESCRIPTION
    `graphify affected`, `graphify explain` and `graphify path` read graphify-out/graph.json themselves
    and know nothing about whether it still matches the working tree, so a question typed at the shell
    can be answered from a graph built before the last pull with nothing on screen to say so. This
    wrapper is the checked path: it loads the graph through Get-GraphIndex, which reports the freshness,
    and only then runs the query.

    Only those three read-only subcommands are accepted. `extract` is the path that can reach a model
    backend, and it belongs to Invoke-GraphifyIndex.ps1, which guards its arguments. Source code may be
    client-confidential. See .claude/skills/dotnet-code-graph/references/code-graph.md.

.PARAMETER Subcommand
    The query to run: affected, explain or path.

.PARAMETER Argument
    The rest of the command line, passed through to graphify. Flags are checked against an allowlist, so
    an argument this wrapper does not recognise is refused rather than forwarded.

.PARAMETER RepoRoot
    The repository root. Defaults to the repository this script sits in.

.PARAMETER GraphPath
    Path to graph.json. Defaults to `--graph` when the caller passes one, then graphify-out/graph.json
    under RepoRoot.

.PARAMETER GraphifyCommand
    The executable to invoke. Defaults to 'graphify'. Used by the Pester tests to feed canned output.

.PARAMETER FailOnStaleGraph
    Exit 1 instead of querying when the graph is behind the working tree. Off by default: a slightly old
    answer is usually still useful once you have been told it is old.

.EXAMPLE
    ./Invoke-GraphifyQuery.ps1 affected 'OrderBuilder' --depth 2

.EXAMPLE
    ./Invoke-GraphifyQuery.ps1 explain 'IPricingStrategy'

.EXAMPLE
    ./Invoke-GraphifyQuery.ps1 path 'OrderService' 'IOrderRepository'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Subcommand,

    [Parameter(Position = 1, ValueFromRemainingArguments)][string[]]$Argument = @(),

    [string]$RepoRoot,

    [string]$GraphPath,

    [string]$GraphifyCommand = 'graphify',

    [switch]$FailOnStaleGraph
)

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'CodeGraph.psm1') -Force

$script:AllowedSubcommand = @('affected', 'explain', 'path')
$script:AllowedFlag = @('--relation', '--depth', '--graph', '--undirected', '--json')

if ($script:AllowedSubcommand -cnotcontains $Subcommand) {
    Write-Host "Refused '$Subcommand': this wrapper asks only the read-only queries $($script:AllowedSubcommand -join ', ')." -ForegroundColor Red
    Write-Host "'extract' is the path that can reach a model backend and belongs to Invoke-GraphifyIndex.ps1," -ForegroundColor Red
    Write-Host 'which guards its arguments.' -ForegroundColor Red
    exit 1
}

foreach ($item in @($Argument)) {
    if (-not ([string]$item).StartsWith('-')) { continue }
    $name = (([string]$item) -split '=', 2)[0]
    if ($script:AllowedFlag -ccontains $name) { continue }
    Write-Host "Refused '$item': this wrapper passes through only $($script:AllowedFlag -join ', ')." -ForegroundColor Red
    Write-Host 'An argument it does not recognise is refused rather than forwarded, so a flag that reaches a' -ForegroundColor Red
    Write-Host 'model backend cannot arrive through the query path.' -ForegroundColor Red
    exit 1
}

$graphFlag = [array]::IndexOf(@($Argument), '--graph')
if ($graphFlag -ge 0 -and $graphFlag -lt (@($Argument).Count - 1)) {
    $GraphPath = @($Argument)[$graphFlag + 1]
}
if (-not $GraphPath) { $GraphPath = Join-Path $RepoRoot 'graphify-out' 'graph.json' }

if (-not (Test-Path -LiteralPath $GraphPath)) {
    Write-Host "No graph at '$GraphPath'. Build it with Invoke-GraphifyIndex.ps1 first." -ForegroundColor Red
    exit 1
}

$index = Get-GraphIndex -GraphPath $GraphPath
if ($index.Freshness.State -eq 'Stale' -and $FailOnStaleGraph) {
    Write-Host 'Refusing to query a stale graph. Rebuild it, or drop -FailOnStaleGraph to ask anyway.' -ForegroundColor Red
    exit 1
}

if (-not (Get-Command $GraphifyCommand -ErrorAction SilentlyContinue)) {
    Write-Host "'$GraphifyCommand' is not on PATH." -ForegroundColor Red
    Write-Host 'Install it first; Invoke-GraphifyIndex.ps1 prints the pinned install command.' -ForegroundColor Red
    exit 1
}

& $GraphifyCommand $Subcommand @Argument
exit $LASTEXITCODE
