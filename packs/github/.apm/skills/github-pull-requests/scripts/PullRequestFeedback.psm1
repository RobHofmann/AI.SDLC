#Requires -Version 7
<#
.SYNOPSIS
    Shared helpers for the pull request feedback loop: call GitHub through the gh CLI and tell which
    source a review thread or a comment came from.
.DESCRIPTION
    Used by Get-PullRequestFeedback.ps1, Reply-PullRequestThread.ps1 and Wait-WorkflowRun.ps1. Every
    call goes through `gh` (`gh pr view`, `gh run view`, `gh api` for REST and GraphQL), signed in with
    `gh auth login` (the github-pull-requests skill). The loop they serve is described in the
    orchestration page of the ai-sdlc-handbook skill.

    Get-ThreadKind reads the author before the text. An author is a bot only when its login ends in
    "[bot]" (the REST form, such as github-actions[bot]) or GitHub reports the author type Bot (the
    GraphQL form, which leaves the suffix out). A bot thread is tagged sonarcloud when the login or the
    text names SonarCloud or SonarQube Cloud, gitleaks when the text names gitleaks, and bot otherwise.
    Every other author is a person, whatever the text says.

    Test-ThreadResolvable says which tags Reply-PullRequestThread.ps1 may resolve: only sonarcloud and
    gitleaks, the known tools that the skill names. A thread tagged bot comes from another bot or an
    unknown app, so it is treated like a person's thread and never resolved (C09).

    Read-ReviewThread reads every review thread of the pull request. GitHub returns at most 100 threads
    per call, so it follows pageInfo to the next page until there is none. When a page cannot be read,
    or it reaches the page limit, it writes a warning that some threads were not read.

    Invoke-GitHubPoll runs one read of a wait loop. When GitHub throttles the call (HTTP 429, a rate
    limit message or a Retry-After header in the error), it waits and tries again: the Retry-After
    seconds when the error names them, else the poll interval doubled per try, at most five minutes. It
    never waits past the deadline of the caller; then it throws, and the caller reports that nothing was
    checked. Any other error is thrown at once.
#>

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1')
$script:GitHub = (Get-AiSdlcConfig -RepoRoot (Find-AiSdlcRepoRoot -StartPath $PSScriptRoot)).github
$script:DefaultRepository = if ($script:GitHub) { [string]$script:GitHub.repository } else { '' }

$script:ThreadsQuery = @'
query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          comments(first: 1) {
            nodes { author { __typename login } body createdAt originalCommit { oid } }
          }
        }
      }
      comments(last: 50) {
        nodes { id author { __typename login } body createdAt }
      }
    }
  }
}
'@

function Get-ReviewThreadQuery {
    return $script:ThreadsQuery
}

function Get-RepositoryPart {
    param([string]$Repository)

    if ($Repository -match '^(?<owner>[\w.-]+)/(?<name>[\w.-]+)$') {
        return [pscustomobject]@{ Owner = $Matches.owner; Name = $Matches.name; Path = "repos/$Repository" }
    }
    return [pscustomobject]@{ Owner = '{owner}'; Name = '{repo}'; Path = 'repos/{owner}/{repo}' }
}

function Get-AuthorKind {
    param([object]$Author)

    if ($null -eq $Author) { return 'human' }
    $login = [string]$Author.login
    $type = if ($Author.PSObject.Properties['__typename']) { [string]$Author.__typename } else { '' }
    if ($login -match '\[bot\]$' -or $type -eq 'Bot') { return 'bot' }
    return 'human'
}

function Get-AuthorLogin {
    param([object]$Author)

    if ($null -eq $Author) { return '' }
    $login = [string]$Author.login
    if ((Get-AuthorKind -Author $Author) -eq 'bot' -and $login -notmatch '\[bot\]$') { return "$login[bot]" }
    return $login
}

function Get-CommentKind {
    param([object]$Author, [string]$Content)

    if ((Get-AuthorKind -Author $Author) -ne 'bot') { return 'human' }
    $login = [string]$Author.login
    if ($login -match '(?i)sonar' -or $Content -match 'sonarcloud\.io|SonarQube Cloud') { return 'sonarcloud' }
    if ($login -match '(?i)gitleaks' -or $Content -match '(?i)gitleaks') { return 'gitleaks' }
    return 'bot'
}

$script:ResolvableKinds = @('sonarcloud', 'gitleaks')

function Test-ThreadResolvable {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Kind)

    return $Kind -in $script:ResolvableKinds
}

function Get-FirstComment {
    param([object]$Thread)

    $comments = $Thread.comments
    if ($null -eq $comments) { return $null }
    if ($comments.PSObject.Properties['nodes']) { $comments = $comments.nodes }
    return @($comments)[0]
}

function Get-ThreadKind {
    param([Parameter(Mandatory)][object]$Thread)

    $first = Get-FirstComment -Thread $Thread
    if (-not $first) { return 'human' }
    return Get-CommentKind -Author $first.author -Content ([string]$first.body)
}

function Get-PullRequestNode {
    param([object]$Response)

    if ($null -eq $Response) { return $null }
    if ($Response.PSObject.Properties['data']) { $Response = $Response.data }
    if ($Response.PSObject.Properties['repository']) { $Response = $Response.repository }
    if ($Response.PSObject.Properties['pullRequest']) { $Response = $Response.pullRequest }
    return $Response
}

function Read-ReviewThread {
    param(
        [Parameter(Mandatory)][scriptblock]$ReadPage,
        [int]$MaxPages = 20
    )

    $response = & $ReadPage ''
    $pr = Get-PullRequestNode -Response $response
    if (-not $pr -or -not $pr.PSObject.Properties['reviewThreads'] -or -not $pr.reviewThreads) { return $response }
    $nodes = [System.Collections.Generic.List[object]]::new()
    foreach ($node in @($pr.reviewThreads.nodes)) { if ($node) { $nodes.Add($node) } }
    $info = if ($pr.reviewThreads.PSObject.Properties['pageInfo']) { $pr.reviewThreads.pageInfo } else { $null }
    $pages = 1
    while ($info -and $info.hasNextPage) {
        if (-not $info.endCursor -or $pages -ge $MaxPages) {
            Write-Warning "Review threads: read $($nodes.Count) threads in $pages page(s), but GitHub has more. The threads after these were not read."
            break
        }
        $next = Get-PullRequestNode -Response (& $ReadPage ([string]$info.endCursor))
        if (-not $next -or -not $next.PSObject.Properties['reviewThreads'] -or -not $next.reviewThreads) {
            Write-Warning "Review threads: page $($pages + 1) could not be read, so the threads after the first $($nodes.Count) were not read."
            break
        }
        foreach ($node in @($next.reviewThreads.nodes)) { if ($node) { $nodes.Add($node) } }
        $info = if ($next.reviewThreads.PSObject.Properties['pageInfo']) { $next.reviewThreads.pageInfo } else { $null }
        $pages++
    }
    $pr.reviewThreads | Add-Member -NotePropertyName nodes -NotePropertyValue $nodes.ToArray() -Force
    return $response
}

function Get-OpenThread {
    param([Parameter(Mandatory)][object]$ThreadsResponse)

    $pr = Get-PullRequestNode -Response $ThreadsResponse
    if (-not $pr -or -not $pr.PSObject.Properties['reviewThreads']) { return }
    foreach ($thread in @($pr.reviewThreads.nodes)) {
        if (-not $thread -or $thread.isResolved) { continue }
        $first = Get-FirstComment -Thread $thread
        if (-not $first) { continue }
        [pscustomobject]@{
            Id         = [string]$thread.id
            Kind       = Get-ThreadKind -Thread $thread
            AuthorKind = Get-AuthorKind -Author $first.author
            Author     = Get-AuthorLogin -Author $first.author
            File       = [string]$thread.path
            Line       = $thread.line
            Outdated   = [bool]$thread.isOutdated
            CommitId   = if ($first.PSObject.Properties['originalCommit'] -and $first.originalCommit) { [string]$first.originalCommit.oid } else { '' }
            Published  = [string]$first.createdAt
            Content    = [string]$first.body
        }
    }
}

function Get-BotComment {
    param([Parameter(Mandatory)][object]$ThreadsResponse, [string]$Since)

    $pr = Get-PullRequestNode -Response $ThreadsResponse
    if (-not $pr -or -not $pr.PSObject.Properties['comments']) { return }
    foreach ($comment in @($pr.comments.nodes)) {
        if (-not $comment -or (Get-AuthorKind -Author $comment.author) -ne 'bot') { continue }
        if ($Since -and $comment.createdAt -and [datetimeoffset]$comment.createdAt -lt [datetimeoffset]$Since) { continue }
        [pscustomobject]@{
            Id        = [string]$comment.id
            Kind      = Get-CommentKind -Author $comment.author -Content ([string]$comment.body)
            Author    = Get-AuthorLogin -Author $comment.author
            Published = [string]$comment.createdAt
            Content   = [string]$comment.body
        }
    }
}

function Test-GitHubThrottle {
    param([string]$Message)

    return $Message -match '(?i)\b429\b|too many requests|rate limit|retry-after'
}

function Get-GitHubRetryDelay {
    param([string]$Message, [int]$Attempt, [int]$PollSeconds)

    if ($Message -match '(?i)retry-after\D{0,3}(\d+)') { return [int]$Matches[1] }
    return [int][math]::Min(300, [math]::Max(1, $PollSeconds) * [math]::Pow(2, $Attempt))
}

function Invoke-GitHubPoll {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][datetime]$Deadline,
        [int]$PollSeconds = 20,
        [scriptblock]$Sleep = { param([int]$Seconds) Start-Sleep -Seconds $Seconds }
    )

    $attempt = 0
    while ($true) {
        try { return & $Action }
        catch {
            $message = $_.Exception.Message
            if (-not (Test-GitHubThrottle -Message $message)) { throw }
            $delay = Get-GitHubRetryDelay -Message $message -Attempt $attempt -PollSeconds $PollSeconds
            if ((Get-Date).AddSeconds($delay) -ge $Deadline) { throw }
            & $Sleep $delay
            $attempt++
        }
    }
}

function Invoke-GitHubJson {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $previousEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    try {
        $errorFile = [System.IO.Path]::GetTempFileName()
        $raw = & gh @Arguments 2>$errorFile | Out-String
        $reason = (Get-Content -LiteralPath $errorFile -Raw) -replace '\s+', ' '
        Remove-Item -LiteralPath $errorFile -ErrorAction SilentlyContinue
        if ($LASTEXITCODE -ne 0) { throw "gh $($Arguments[0..[math]::Min(2, $Arguments.Count - 1)] -join ' ') failed with exit code ${LASTEXITCODE}: $reason Run gh auth status and check the repository and the number." }
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json -Depth 20
    }
    finally {
        [Console]::OutputEncoding = $previousEncoding
    }
}

function Invoke-GitHubGraphQL {
    param([Parameter(Mandatory)][string]$Query, [hashtable]$Variables = @{})

    $file = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($file, (@{ query = $Query; variables = $Variables } | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
        return Invoke-GitHubJson -Arguments @('api', 'graphql', '--input', $file)
    }
    finally {
        Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Get-ReviewThreadQuery, Get-RepositoryPart, Get-AuthorKind, Get-AuthorLogin, Get-CommentKind, Get-ThreadKind,
    Test-ThreadResolvable, Read-ReviewThread, Get-OpenThread, Get-BotComment, Invoke-GitHubJson, Invoke-GitHubGraphQL, Invoke-GitHubPoll, Test-GitHubThrottle, Get-GitHubRetryDelay -Variable DefaultRepository
