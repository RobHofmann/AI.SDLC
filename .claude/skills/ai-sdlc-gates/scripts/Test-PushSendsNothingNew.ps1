#Requires -Version 7
<#
.SYNOPSIS
    Says whether a push sends nothing new to the remote, so it needs no gate and no pre-flight receipt.

.DESCRIPTION
    The pre-push git hook calls this script with the remote name git gives it and the local commit of
    each pushed ref. A push sends nothing new when every pushed ref is a delete (a commit of all zeros),
    or when every pushed commit is reachable from the remote-tracking refs of that remote. Only the
    remote being pushed to counts: a commit that only another remote has is new. The rule lives in
    Test-PushSendsNothingNew in PreflightReceipt.psm1, which the agent hook Deny-IncompletePush.ps1
    calls too, so both hooks judge a push the same way.

    Exit 0 with one line that says why when the push sends nothing new. Exit 1 with no output when it
    sends a commit the remote does not have, or when the remote is not a configured remote name.

.PARAMETER RepoRoot
    The repository root. Defaults to the current folder.

.PARAMETER Remote
    The remote being pushed to, as git names it to the pre-push hook.

.PARAMETER Commit
    The local commit of each pushed ref. A value may hold several, split by commas or spaces, because a
    git hook passes them as one argument.

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Test-PushSendsNothingNew.ps1 -Remote origin -Commit (git rev-parse v2.4.0)
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Get-Location).Path,
    [AllowEmptyString()][string]$Remote = '',
    [string[]]$Commit = @()
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PreflightReceipt.psm1') -Force

if (-not (Test-PushSendsNothingNew -RepoRoot $RepoRoot -Remote $Remote -Commit $Commit)) { exit 1 }

$sent = @($Commit | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ -and $_ -notmatch '^0+$' })
if ($sent.Count -eq 0) { Write-Output 'every pushed ref is a delete, so no gate runs.' }
else { Write-Output "every pushed commit is already on $Remote, so no gate runs." }
exit 0
