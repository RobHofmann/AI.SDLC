#Requires -Version 7
<#
.SYNOPSIS
    Replies to a pull request review thread, and resolves it when the thread came from a known tool.
.DESCRIPTION
    The write half of the pull request feedback loop (the orchestration page of the ai-sdlc-handbook skill).
    After a fix is pushed, the loop replies to the thread that asked for it, naming the commit, or says
    why it declines the finding. A thread from a known tool (tagged sonarcloud or gitleaks) may then be
    resolved, so a ruleset that asks for resolved conversations can clear.

    It uses GitHub GraphQL through `gh api graphql`: it reads the thread, posts the reply with
    addPullRequestReviewThreadReply, and resolves with resolveReviewThread.

    A thread a person started is never resolved from here: the reply is posted and the thread is left
    for that person, because resolving it would sign off for a human (clause C09). Asking to resolve
    such a thread posts the reply, prints why the thread was left open, and exits 0.

    A thread from any other bot (tagged bot) is treated like a person's thread: it is never resolved
    (C09). Asking to resolve it exits 1 and writes nothing, so the loop runs the script again without
    -Resolve and a person resolves the thread.

    Exit codes: 0 when the reply was posted, 1 when the input is wrong, 2 when GitHub could not be
    reached.
.PARAMETER PullRequestId
    The pull request number that holds the thread. A thread of another pull request exits 1.
.PARAMETER ThreadId
    The node id of the review thread, as Get-PullRequestFeedback.ps1 lists it (for example PRRT_kwDOA1b2c3).
.PARAMETER Message
    The reply text. An empty text, or one of only spaces, exits 1 and writes nothing.
.PARAMETER Resolve
    Resolve the thread after the reply, when a known tool (sonarcloud or gitleaks) started it.
.PARAMETER Invoker
    Test seam: a scriptblock that takes (Operation, Variables), where Operation is 'thread', 'reply' or
    'resolve', and returns the parsed response. Never set in normal use.
.EXAMPLE
    pwsh .claude/skills/github-pull-requests/scripts/Reply-PullRequestThread.ps1 -PullRequestId 42 -ThreadId PRRT_kwDOA1b2c3 -Message "Fixed in a1b2c3d: --all and --mirror are refused." -Resolve
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$PullRequestId,
    [Parameter(Mandatory)][string]$ThreadId,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
    [switch]$Resolve,
    [scriptblock]$Invoker
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PullRequestFeedback.psm1') -Force

if ([string]::IsNullOrWhiteSpace($Message)) { Write-Host 'Reply: the message is empty. Pass the reply text in -Message; nothing was written.' -ForegroundColor Red; exit 1 }
if ([string]::IsNullOrWhiteSpace($ThreadId)) { Write-Host 'Reply: the thread id is empty. Pass the node id that Get-PullRequestFeedback.ps1 lists; nothing was written.' -ForegroundColor Red; exit 1 }

if (-not $Invoker) {
    $Invoker = {
        param([string]$Operation, [hashtable]$Variables)
        $query = switch ($Operation) {
            'thread' { 'query($thread: ID!) { node(id: $thread) { ... on PullRequestReviewThread { id isResolved pullRequest { number } comments(first: 1) { nodes { author { __typename login } body } } } } }' }
            'reply' { 'mutation($thread: ID!, $body: String!) { addPullRequestReviewThreadReply(input: { pullRequestReviewThreadId: $thread, body: $body }) { comment { id } } }' }
            'resolve' { 'mutation($thread: ID!) { resolveReviewThread(input: { threadId: $thread }) { thread { isResolved } } }' }
        }
        Invoke-GitHubGraphQL -Query $query -Variables $Variables
    }
}

try {
    $response = & $Invoker 'thread' @{ thread = $ThreadId }
    $thread = if ($response -and $response.PSObject.Properties['data']) { $response.data.node } else { $response }
}
catch {
    Write-Host "Reply: GitHub could not be reached, so nothing was written. $($_.Exception.Message)" -ForegroundColor Yellow
    exit 2
}

if (-not $thread -or -not $thread.PSObject.Properties['pullRequest']) {
    Write-Host "Reply: $ThreadId is not a review thread. Pass the thread id that Get-PullRequestFeedback.ps1 lists; nothing was written." -ForegroundColor Red
    exit 1
}
if ([int]$thread.pullRequest.number -ne $PullRequestId) {
    Write-Host "Reply: thread $ThreadId belongs to pull request $($thread.pullRequest.number), not $PullRequestId; nothing was written." -ForegroundColor Red
    exit 1
}

$kind = Get-ThreadKind -Thread $thread
if ($Resolve -and $kind -ne 'human' -and -not (Test-ThreadResolvable -Kind $kind)) {
    Write-Host "Reply: thread $ThreadId comes from a bot that is not a known tool (sonarcloud or gitleaks). It is treated like a person's thread and never resolved here (clause C09). Run the script again without -Resolve; nothing was written." -ForegroundColor Red
    exit 1
}

try {
    & $Invoker 'reply' @{ thread = $ThreadId; body = $Message } | Out-Null
    Write-Host "Reply posted on thread $ThreadId ($kind)."
    if ($Resolve) {
        if ($kind -eq 'human') {
            Write-Host "Thread left open: a person started thread $ThreadId, so that person resolves it (clause C09)."
        }
        elseif ($thread.isResolved) {
            Write-Host "Thread $ThreadId was already resolved."
        }
        else {
            & $Invoker 'resolve' @{ thread = $ThreadId } | Out-Null
            Write-Host "Thread $ThreadId resolved."
        }
    }
}
catch {
    Write-Host "Reply: GitHub could not be reached, so the step in progress was not written. $($_.Exception.Message)" -ForegroundColor Yellow
    exit 2
}
exit 0
