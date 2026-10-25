#Requires -Version 7
<#
.SYNOPSIS
    Reports whether a pull request's checks are done, and lists its open review threads by source:
    sonarcloud, gitleaks, bot or human.
.DESCRIPTION
    The read half of the pull request feedback loop (the orchestration page of the ai-sdlc-handbook skill).
    After the loop pushes and opens or updates a pull request, it runs this script with -Wait until
    the state is 'ready', fixes what the open threads say, pushes, and runs it again. It only reads.

    It makes two reads per poll: `gh pr view --json headRefOid,statusCheckRollup` for the checks of
    the head commit, and `gh api graphql` for the review threads and the comments of the pull request.
    The threads come 100 per call, so a pull request with more threads takes one call per page.

    State is 'pending' while a check is queued or running, 'ready' when every check is done, and
    'timeout' when -Wait gave up.

    Right after a push, GitHub may show no check on the head commit for a short time. So when no check
    has registered yet, the state is 'pending' until -NoCheckGraceMinutes have passed since the head
    commit was made. When there is still no check after that time, the state is 'ready', and Note says
    that no check ran on the head commit. A check that failed is listed with its workflow run id, so the loop
    can read its log with `gh run view <id> --log-failed`.

    With -Wait -ReturnOnReview the state is 'review' when a check still runs and a bot opened at least
    one unresolved review thread on the head commit. A bot review takes a few minutes and a build
    takes longer, so the loop fixes those threads while the build runs. 'review' is never 'ready': the
    loop runs this script again before the push and ends only on 'ready'.

    The open threads are the unresolved review threads; each one is tagged sonarcloud, gitleaks, bot
    or human (PullRequestFeedback.psm1). BotComments lists the conversation comments that a bot wrote
    since the head commit, such as a quality gate summary; they cannot be resolved, only read.

    A throttled read (HTTP 429 or a rate limit) waits and tries again within -TimeoutMinutes
    (Invoke-GitHubPoll in PullRequestFeedback.psm1). Without -Wait it is not tried again.

    Exit codes: 0 with a JSON report on stdout, 2 when GitHub could not be read (nothing was
    checked). The report never contains anything beyond the thread text, the ids and the statuses.
.PARAMETER PullRequestId
    The pull request number.
.PARAMETER Wait
    Poll until the state is not 'pending', or until -TimeoutMinutes runs out.
.PARAMETER ReturnOnReview
    With -Wait, also stop waiting, with state 'review', when a bot opened a thread on the head commit
    while a check still runs. Without -Wait it changes nothing, so a single check still says 'pending'.
    A thread counts only when it was made on the head commit, so a thread left open from an earlier
    round does not end the wait.
.PARAMETER TimeoutMinutes
    How long -Wait polls. Defaults to 9, so one call fits inside a ten-minute shell limit; call it again
    to keep waiting. The last sleep is cut to the time left, so a long -PollSeconds never runs past it.
.PARAMETER PollSeconds
    Seconds between two polls. Defaults to 20; one poll costs two gh calls.
.PARAMETER NoCheckGraceMinutes
    How long to wait for the first check on the head commit, counted from the commit date. Defaults to 3.
    The commit date comes from the clock of the machine that made the commit.
.PARAMETER Repository
    Repository as owner/name. Defaults to github.repository in aisdlc.json; when that is empty, gh reads
    the repository from the git remote.
.PARAMETER Reader
    Test seam: a scriptblock that takes a name ('pr' or 'threads') and, for 'threads', the page cursor
    (empty for the first page), and returns the parsed response. Never set in normal use.
.EXAMPLE
    pwsh .claude/skills/github-pull-requests/scripts/Get-PullRequestFeedback.ps1 -PullRequestId 42 -Wait
.EXAMPLE
    pwsh .claude/skills/github-pull-requests/scripts/Get-PullRequestFeedback.ps1 -PullRequestId 42 -Wait -ReturnOnReview
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$PullRequestId,
    [switch]$Wait,
    [switch]$ReturnOnReview,
    [double]$TimeoutMinutes = 9,
    [int]$PollSeconds = 20,
    [double]$NoCheckGraceMinutes = 3,
    [string]$Repository,
    [scriptblock]$Reader
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PullRequestFeedback.psm1') -Force

if (-not $Repository) { $Repository = $DefaultRepository }
$repo = Get-RepositoryPart -Repository $Repository

if (-not $Reader) {
    $Reader = {
        param([string]$Name, [string]$Cursor)
        $repoArgs = if ($Repository) { @('--repo', $Repository) } else { @() }
        switch ($Name) {
            'pr' { Invoke-GitHubJson -Arguments (@('pr', 'view', $PullRequestId) + $repoArgs + @('--json', 'number,headRefOid,commits,statusCheckRollup')) }
            'threads' {
                $cursorArgs = if ($Cursor) { @('-f', "cursor=$Cursor") } else { @() }
                Invoke-GitHubJson -Arguments (@('api', 'graphql', '-f', "query=$(Get-ReviewThreadQuery)", '-F', "owner=$($repo.Owner)", '-F', "name=$($repo.Name)", '-F', "number=$PullRequestId") + $cursorArgs)
            }
        }
    }
}

function ConvertTo-Check {
    param([object]$Item)

    $isContext = $Item.PSObject.Properties['context'] -or ($Item.PSObject.Properties['__typename'] -and $Item.__typename -eq 'StatusContext')
    if (-not $isContext) {
        $name = [string]$Item.name
        $url = [string]$Item.detailsUrl
        $conclusion = [string]$Item.conclusion
        $status = if ([string]$Item.status -ne 'COMPLETED') { 'pending' }
        elseif ($conclusion -in @('SUCCESS', 'NEUTRAL', 'SKIPPED')) { 'pass' }
        else { 'fail' }
    }
    else {
        $name = [string]$Item.context
        $url = [string]$Item.targetUrl
        $conclusion = [string]$Item.state
        $status = if ($conclusion -in @('PENDING', 'EXPECTED')) { 'pending' } elseif ($conclusion -eq 'SUCCESS') { 'pass' } else { 'fail' }
    }
    $runMatch = [regex]::Match($url, '/actions/runs/(\d+)')
    [pscustomobject]@{
        Name       = $name
        Status     = $status
        Conclusion = $conclusion
        RunId      = if ($runMatch.Success) { [long]$runMatch.Groups[1].Value } else { $null }
        Url        = $url
    }
}

function Get-Snapshot {
    $pr = & $Reader 'pr'
    $checks = @(@($pr.statusCheckRollup) | Where-Object { $_ } | ForEach-Object { ConvertTo-Check -Item $_ })
    $commits = @($pr.commits)
    $rawDate = if ($commits.Count -gt 0) { $commits[-1].committedDate } else { $null }
    $headAt = $null
    if ($rawDate -is [datetime]) { $headAt = $rawDate.ToUniversalTime() }
    elseif ($rawDate) { try { $headAt = ([datetimeoffset][string]$rawDate).UtcDateTime } catch { $headAt = $null } }
    $headDate = if ($headAt) { $headAt.ToString('o') } else { '' }
    $pending = @($checks | Where-Object { $_.Status -eq 'pending' }).Count -gt 0
    $note = ''
    if ($checks.Count -eq 0) {
        $since = if ($headAt) { $headAt } else { $script:StartedAt }
        $pending = (Get-Date).ToUniversalTime() -lt $since.AddMinutes($NoCheckGraceMinutes)
        if (-not $pending) { $note = "No check ran on the head commit within $NoCheckGraceMinutes minute(s) of the commit. Check that the repository has a pull request workflow." }
    }
    [pscustomobject]@{ Pending = $pending; Checks = $checks; HeadCommit = [string]$pr.headRefOid; HeadCommittedAt = $headDate; Note = $note }
}

function Test-BotRound {
    param([object]$Snapshot, [object[]]$Threads)

    if (-not $Snapshot.Pending -or -not $Snapshot.HeadCommit) { return $false }
    @($Threads | Where-Object { $_.AuthorKind -eq 'bot' -and $_.CommitId -eq $Snapshot.HeadCommit }).Count -gt 0
}

$script:StartedAt = (Get-Date).ToUniversalTime()

try {
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $retryUntil = if ($Wait) { $deadline } else { Get-Date }
    $readPage = { param([string]$Cursor) & $Reader 'threads' $Cursor }
    $readThreads = { Invoke-GitHubPoll -Action { Read-ReviewThread -ReadPage $readPage } -Deadline $retryUntil -PollSeconds $PollSeconds }
    $snapshot = Invoke-GitHubPoll -Action { Get-Snapshot } -Deadline $retryUntil -PollSeconds $PollSeconds
    while ($true) {
        $response = $null
        $review = $false
        if ($Wait -and $ReturnOnReview -and $snapshot.Pending) {
            $response = & $readThreads
            $review = Test-BotRound -Snapshot $snapshot -Threads @(Get-OpenThread -ThreadsResponse $response)
        }
        if (-not $Wait -or -not $snapshot.Pending -or $review -or (Get-Date) -ge $deadline) { break }
        Start-Sleep -Milliseconds ([math]::Min($PollSeconds * 1000, [math]::Max(0, ($deadline - (Get-Date)).TotalMilliseconds)))
        $snapshot = Invoke-GitHubPoll -Action { Get-Snapshot } -Deadline $retryUntil -PollSeconds $PollSeconds
    }
    if ($null -eq $response) { $response = & $readThreads }
    $threads = @(Get-OpenThread -ThreadsResponse $response)
    $comments = @(Get-BotComment -ThreadsResponse $response -Since $snapshot.HeadCommittedAt)
}
catch {
    Write-Host "Pull request feedback: GitHub could not be read, so NOTHING WAS CHECKED. $($_.Exception.Message)" -ForegroundColor Yellow
    exit 2
}

$state = if (-not $snapshot.Pending) { 'ready' } elseif ($review) { 'review' } elseif ($Wait) { 'timeout' } else { 'pending' }

[pscustomobject]@{
    PullRequestId = $PullRequestId
    State         = $state
    HeadCommit    = $snapshot.HeadCommit
    Note          = $snapshot.Note
    Checks        = $snapshot.Checks
    OpenThreads   = $threads
    BotComments   = $comments
    Summary       = ('{0}; {1} failed check(s); {2} open thread(s): {3} sonarcloud, {4} gitleaks, {5} bot, {6} human; {7} new bot comment(s)' -f $state,
        @($snapshot.Checks | Where-Object Status -EQ 'fail').Count, $threads.Count,
        @($threads | Where-Object Kind -EQ 'sonarcloud').Count, @($threads | Where-Object Kind -EQ 'gitleaks').Count,
        @($threads | Where-Object Kind -EQ 'bot').Count, @($threads | Where-Object Kind -EQ 'human').Count, $comments.Count)
} | ConvertTo-Json -Depth 6
exit 0
