#Requires -Version 7
<#
.SYNOPSIS
    SessionStart hook: tell the agent, in one line, when the SonarCloud MCP token is not ready.

.DESCRIPTION
    The sonarqube MCP server needs AISDLC_SONAR_MCP_TOKEN in the environment of the tool. When it is
    not there, the server fails to sign in, and the agent does not know why. This hook runs when a
    session starts and hands the agent one line of context:

    - Process: the token is set. The hook prints nothing.
    - Stored: the user store holds the token, but this session did not read it. The line says to
      restart the terminal and the tool, and off Windows to add the shell profile line.
    - Missing: the line names pwsh .claude/skills/sonarcloud-mcp/scripts/Set-SonarMcpToken.ps1 and the
      restart.

    The hook never returns or prints a token value. Wired from .claude/settings.json, which Claude Code
    and GitHub Copilot CLI both read. Every failure path exits 0 with no output, because a non-zero exit
    from a hook can block a session, and this hook is a convenience and not a gate.

.EXAMPLE
    pwsh .claude/skills/sonarcloud-mcp/scripts/Invoke-SonarTokenHook.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Import-HookModule {
    Import-Module (Join-Path $PSScriptRoot 'SonarMcpToken.psm1') -Force
    $hooksScripts = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-hooks' 'scripts'
    if (-not (Test-Path -LiteralPath $hooksScripts)) { $hooksScripts = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-hooks' 'scripts' }
    Import-Module (Join-Path $hooksScripts 'HookPayload.psm1') -Force
}

function Get-SonarTokenHookOutput {
    try {
        $advice = Get-SonarMcpTokenAdvice -State (Get-SonarMcpTokenState)
        if ([string]::IsNullOrWhiteSpace($advice)) { return $null }
        return New-HookContextOutput -EventName 'SessionStart' -Text $advice
    }
    catch { return $null }
}

if ($MyInvocation.InvocationName -eq '.') { Import-HookModule; return }

trap { exit 0 }

Import-HookModule
$output = Get-SonarTokenHookOutput
if ($output) { Write-Output $output }
exit 0
