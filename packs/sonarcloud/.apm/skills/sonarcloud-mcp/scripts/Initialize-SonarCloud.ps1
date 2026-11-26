#Requires -Version 7
<#
.SYNOPSIS
    The SonarCloud setup step of Initialize-AiSdlc.ps1: report whether the SonarCloud MCP token is ready.

.DESCRIPTION
    Initialize-AiSdlc.ps1 in the ai-sdlc-hooks skill runs this script, because
    sonarcloud-mcp/gates.json names it as the setup of this skill. It returns one row with Step, Status
    and Detail for the one summary table.

    The row is OK when this process holds AISDLC_SONAR_MCP_TOKEN. It is WARN when only the user store
    holds it (restart the terminal and the tool) or when it is not set (the row names
    Set-SonarMcpToken.ps1). The script never asks for a token, never stores one and never shows a value.

    A setup script must not stop the whole setup, so every error gives a WARN row. The script never
    returns FAIL and never throws.

.PARAMETER RepoRoot
    Accepted for the setup contract; the token does not depend on the repository.

.PARAMETER Plan
    Return nothing: this step changes no machine setting.

.EXAMPLE
    pwsh .claude/skills/sonarcloud-mcp/scripts/Initialize-SonarCloud.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$RepoRoot,
    [switch]$Plan
)

try { Import-Module (Join-Path $PSScriptRoot 'SonarMcpToken.psm1') -Force -ErrorAction Stop } catch { $null = $_ }

function New-Row([string]$Step, [string]$Status, [string]$Detail) {
    [pscustomobject]@{ Step = $Step; Status = $Status; Detail = $Detail }
}

function Get-SonarCloudSetupRow {
    $step = 'SonarCloud MCP token'
    try {
        $state = Get-SonarMcpTokenState
        if ($state -eq 'Process') { return New-Row $step 'OK' 'AISDLC_SONAR_MCP_TOKEN is set in this process' }
        return New-Row $step 'WARN' (Get-SonarMcpTokenAdvice -State $state)
    }
    catch {
        return New-Row $step 'WARN' 'the SonarCloud MCP token could not be checked; to set it, run pwsh .claude/skills/sonarcloud-mcp/scripts/Set-SonarMcpToken.ps1 in your own terminal'
    }
}

if ($MyInvocation.InvocationName -eq '.') { return }

if ($Plan) { return }

Get-SonarCloudSetupRow
