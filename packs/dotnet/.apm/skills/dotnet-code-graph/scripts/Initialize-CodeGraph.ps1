#Requires -Version 7
<#
.SYNOPSIS
    The code graph setup step of Initialize-AiSdlc.ps1: install the pinned Graphify CLI and build the
    first graph.

.DESCRIPTION
    Initialize-AiSdlc.ps1 in the ai-sdlc-hooks skill runs this script, because dotnet-code-graph/gates.json
    names it as the setup of this skill. It returns rows with Step, Status and Detail for the one summary
    table.

    The graph is a local, code-only map of the codebase. The version installed comes from graphifyVersion
    in graphify-version.json beside this script, so the CLI and the accuracy benchmark cannot drift apart.
    It installs into uv's own isolated tool environment, then builds the first graph with
    Invoke-GraphifyIndex.ps1 and links the documentation edges with Invoke-DocGraphLink.ps1. The step is
    skipped with a clear message when uv is not present. -Minimal and -SkipGraphify leave it out.

.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script.

.PARAMETER Minimal
    Report only; no install and no graph build.

.PARAMETER SkipGraphify
    Do not install the Graphify CLI and do not build the code graph.

.PARAMETER Plan
    Return the step this run would take, as text, and do nothing else.

.EXAMPLE
    pwsh .claude/skills/dotnet-code-graph/scripts/Initialize-CodeGraph.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$RepoRoot,
    [switch]$Minimal,
    [switch]$SkipGraphify,
    [switch]$Plan
)

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

$doGraphify = -not ($Minimal -or $SkipGraphify)
if ($Plan) {
    if ($doGraphify) { 'pinned Graphify CLI + first code graph' }
    return
}

function New-Row([string]$Step, [string]$Status, [string]$Detail) {
    [pscustomobject]@{ Step = $Step; Status = $Status; Detail = $Detail }
}

function Test-Tool([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

$pinFile = Join-Path $PSScriptRoot 'graphify-version.json'
$pinnedVersion = $null
if (Test-Path $pinFile) {
    $pinnedVersion = (Get-Content -LiteralPath $pinFile -Raw -Encoding utf8 | ConvertFrom-Json).graphifyVersion
}

if (Test-Tool 'graphify') {
    New-Row 'Graphify code graph' 'PASS' "on PATH; this repository pins graphifyy==$pinnedVersion (Invoke-GraphifyIndex.ps1 -Report builds and checks it)"
}
elseif ($doGraphify) {
    New-Row 'Graphify code graph' 'OPTIONAL' "not installed yet; this run installs the pinned graphifyy==$pinnedVersion below"
}
else {
    New-Row 'Graphify code graph' 'OPTIONAL' "uv tool install graphifyy==$pinnedVersion (pinned, code-only; see .claude/skills/dotnet-code-graph/references/code-graph.md)"
}

if (-not $doGraphify) { return }

Write-Host "Graphify code graph..." -ForegroundColor Cyan

if (-not $pinnedVersion) {
    New-Row 'Graphify install' 'FAIL' "no graphifyVersion in $pinFile; cannot pin the install"
}
elseif (-not (Test-Tool 'uv')) {
    New-Row 'Graphify install' 'SKIP' 'uv not on PATH; install uv, then re-run this script'
}
elseif ($PSCmdlet.ShouldProcess("graphifyy==$pinnedVersion", 'uv tool install')) {
    & uv tool install "graphifyy==$pinnedVersion" | Out-Host
    if ($LASTEXITCODE -ne 0) {
        New-Row 'Graphify install' 'FAIL' "uv tool install exited $LASTEXITCODE"
    }
    else {
        New-Row 'Graphify install' 'PASS' "graphifyy==$pinnedVersion (base package only; no model-backed extras)"

        $indexer = Join-Path $PSScriptRoot 'Invoke-GraphifyIndex.ps1'
        $linker = Join-Path $PSScriptRoot 'Invoke-DocGraphLink.ps1'
        if (Test-Path $indexer) {
            & $indexer -RepoRoot $RepoRoot -Quiet | Out-Host
            if ($LASTEXITCODE -ne 0) {
                New-Row 'Graphify first build' 'WARN' "first build exited $LASTEXITCODE; run Invoke-GraphifyIndex.ps1 -Report to see why"
            }
            elseif (-not (Test-Path $linker)) {
                New-Row 'Graphify first build' 'PASS' 'graphify-out/ built; hooks keep it fresh from here'
            }
            else {
                & $linker -RepoRoot $RepoRoot *> $null
                if ($LASTEXITCODE -eq 0) { New-Row 'Graphify first build' 'PASS' 'graphify-out/ built and the documentation edges linked; hooks keep it fresh from here' }
                else { New-Row 'Graphify first build' 'WARN' "graph built, but the documentation edges did not link (exit $LASTEXITCODE); the doc tools need them" }
            }
        }
    }
}
else {
    New-Row 'Graphify install' 'WHATIF' "would install graphifyy==$pinnedVersion and build the first graph"
}
