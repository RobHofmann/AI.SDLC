#Requires -Version 7
<#
.SYNOPSIS
    PreToolUse hook: refuse a raw graphify query while the code graph is behind the working tree, and
    point at the checked path instead of only reporting the problem.

.DESCRIPTION
    `graphify affected`, `explain` and `path` read graphify-out/graph.json themselves. They cannot tell
    whether it still describes the working tree, so they answer from a graph built before the last pull
    with full confidence and nothing on screen to say so. Invoke-GraphifyQuery.ps1 is the same query
    with the freshness reported first, and this hook is what makes an agent take it.

    It denies only when the graph is actually stale. A current graph is not a style question, so a raw
    query against one proceeds untouched: a hook that fired every time would be turned off within a day.

    Wired from .claude/settings.json, which Claude Code and GitHub Copilot CLI both read, so one entry
    covers both tools. The payload arrives as JSON on stdin in the Claude shape (tool_name,
    tool_input.command); the camelCase toolArgs shape of the Copilot-native config is accepted too.

    The command filter lives in this script rather than in the configuration, for the reason
    Deny-IncompletePush.ps1 records: Claude's `if` condition is a Claude-only field, and Copilot CLI
    loads the same entry and ignores it, so a hook that trusted the configuration would run on every
    shell command.

    Allowing is exit 0 with no output. Denying is exit 0 with a deny decision on stdout, written in both
    shapes in one object. A non-zero exit denies the call under Copilot CLI, so every failure path here
    exits 0 and allows rather than blocking every shell command on a bug in this script. This hook is a
    convenience that protects an answer; it is not a gate, and nothing here is load-bearing for safety.

.PARAMETER Payload
    The hook payload as JSON. Read from stdin when not supplied.

.PARAMETER RepoRoot
    The repository root. Defaults to the repository this script sits in.

.PARAMETER GraphPath
    Path to graph.json. Defaults to graphify-out/graph.json under RepoRoot.
#>
[CmdletBinding()]
param(
    [string]$Payload,
    [string]$RepoRoot,
    [string]$GraphPath
)

$ErrorActionPreference = 'Stop'

trap { exit 0 }

function Get-ShellCommand {
    param([string]$Json)

    if ([string]::IsNullOrWhiteSpace($Json)) { return $null }
    try { $hook = $Json | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    if (-not $hook) { return $null }

    foreach ($name in 'tool_input', 'toolArgs', 'tool_args') {
        $property = $hook.PSObject.Properties[$name]
        if (-not $property -or -not $property.Value) { continue }
        $value = $property.Value
        if ($value -is [string]) {
            try { $value = $value | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        }
        if ($value -and $value.PSObject.Properties['command']) { return [string]$value.command }
    }
    return $null
}

function Get-RawQuerySubcommand {
    param([string]$CommandLine)

    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $null }
    $match = [regex]::Match($CommandLine, '(?:^|[\s;&|(])graphify\s+(affected|explain|path)(?:\s|$)')
    if (-not $match.Success) { return $null }
    return $match.Groups[1].Value
}

if (-not $PSBoundParameters.ContainsKey('Payload')) {
    $Payload = if ([Console]::IsInputRedirected) { [Console]::In.ReadToEnd() } else { '' }
}

if ([string]::IsNullOrEmpty($Payload) -or $Payload.IndexOf('graphify', [StringComparison]::OrdinalIgnoreCase) -lt 0) { exit 0 }

$subcommand = Get-RawQuerySubcommand -CommandLine (Get-ShellCommand -Json $Payload)
if (-not $subcommand) { exit 0 }

# Only a raw graph query gets this far. Copilot CLI starts this hook before every shell command, so the
# configuration module loads after the cheap filter above.
$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

if (-not $GraphPath) { $GraphPath = Join-Path $RepoRoot 'graphify-out' 'graph.json' }
if (-not (Test-Path -LiteralPath $GraphPath)) { exit 0 }

Import-Module (Join-Path $PSScriptRoot 'CodeGraph.psm1') -Force
$freshness = (Get-GraphIndex -GraphPath $GraphPath -Quiet).Freshness
if ($freshness.State -ne 'Stale') { exit 0 }

$sample = @($freshness.ChangedFiles | Select-Object -First 5)
$reason = @(
    "The code graph is $($freshness.ChangedFiles.Count) file(s) behind the working tree, so 'graphify $subcommand' would"
    'answer from the older code and say nothing about it. Changed since the graph was built:'
    ''
    ($sample | ForEach-Object { "  $_" })
    ''
    'Rebuild it:  pwsh .claude/skills/dotnet-code-graph/scripts/Invoke-GraphifyIndex.ps1'
    "Or ask through the checked path, which reports the freshness first:"
    "  pwsh .claude/skills/dotnet-code-graph/scripts/Invoke-GraphifyQuery.ps1 $subcommand ..."
) -join "`n"

@{
    permissionDecision       = 'deny'
    permissionDecisionReason = $reason
    hookSpecificOutput       = @{
        hookEventName            = 'PreToolUse'
        permissionDecision       = 'deny'
        permissionDecisionReason = $reason
    }
} | ConvertTo-Json -Depth 5 -Compress | Write-Output

exit 0
