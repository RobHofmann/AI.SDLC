#Requires -Version 7
<#
.SYNOPSIS
    PreToolUse hook: refuse a shell command that merges a pull request, because the merge belongs to
    the owner.

.DESCRIPTION
    The agent opens the pull request with the gh login of the owner, so GitHub sees the owner as the
    author and the owner cannot approve it. The ruleset on the default branch asks for a pull request
    and green required checks, with zero required approvals. The merge by the owner is then the
    approval (checkpoint Bravo). So the agent never merges: this hook refuses the commands that would.

    It refuses:

      - gh pr merge, with any flags, also --auto;
      - gh api with a path that ends in /merge, such as repos/<owner>/<repo>/pulls/42/merge;
      - gh api graphql with the mergePullRequest or enablePullRequestAutoMerge mutation.

    Every other command is allowed, also gh pr view, gh pr create and git merge.

    Wired from the PreToolUse hooks of the Bash and the PowerShell tool, which Claude Code and GitHub
    Copilot CLI both read. The payload arrives as JSON on stdin: tool_input in the Claude shape, or
    toolArgs in the Copilot shape, as HookPayload.psm1 reads them. Copilot ignores the if condition of
    the entry and starts the hook before every shell command, so the script tests the payload for the
    word merge before it loads any module.

    Allowing is exit 0 with no output. Denying is exit 0 with a deny decision on stdout, in both shapes
    in one object: the top-level permissionDecision Copilot CLI reads, and the nested
    hookSpecificOutput Claude Code reads. Every failure path exits 0 and allows (fail-open), because a
    non-zero exit would block every shell command on a bug in this script.

.PARAMETER Payload
    The hook payload as JSON. Read from stdin when not supplied.

.EXAMPLE
    '{"tool_input":{"command":"gh pr merge 42 --squash"}}' | pwsh -NoProfile -File .claude/skills/ai-sdlc-hooks/scripts/Deny-AgentMerge.ps1
#>
[CmdletBinding()]
param(
    [string]$Payload
)

$ErrorActionPreference = 'Stop'

trap { exit 0 }

if (-not $PSBoundParameters.ContainsKey('Payload')) {
    $Payload = if ([Console]::IsInputRedirected) { [Console]::In.ReadToEnd() } else { '' }
}

if ([string]::IsNullOrEmpty($Payload) -or $Payload.IndexOf('merge', [StringComparison]::OrdinalIgnoreCase) -lt 0) { exit 0 }

Import-Module (Join-Path $PSScriptRoot 'HookPayload.psm1') -Force

$hook = try { $Payload | ConvertFrom-Json -ErrorAction Stop } catch { $null }
$arguments = Get-HookToolArgument -Hook $hook
if ($null -eq $arguments -or $arguments -is [string] -or -not $arguments.PSObject.Properties['command']) { exit 0 }
$command = [string]$arguments.command

$gh = '(?:^|[\s;&|(])[''"]?gh(?:\.exe)?[''"]?'
$flag = '(?:-{1,2}[A-Za-z][\w-]*(?:=\S+|\s+[^\s;&|-]\S*)?\s+)*'
$patterns = @(
    "$gh\s+$flag" + 'pr\s+' + $flag + 'merge(?:\s|$|[;&|)])'
    "$gh\s+$flag" + 'api\s[^;&|]*?/merge(?:[\s''"?;&|)]|$)'
    "$gh\s+$flag" + 'api\s[^;&|]*?\b(?:mergePullRequest|enablePullRequestAutoMerge)\b'
)
$merges = @($patterns | Where-Object { [regex]::IsMatch($command, $_, 'IgnoreCase') }).Count -gt 0
if (-not $merges) { exit 0 }

$reason = ('Merging a pull request is the job of the owner, not of the agent. The owner merges it after ' +
    'the required checks pass, and that merge is the approval (checkpoint Bravo). Tell the person the ' +
    'pull request is ready, give its link and the state of its checks, and stop.')

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
