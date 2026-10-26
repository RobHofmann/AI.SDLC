#Requires -Version 7
<#
.SYNOPSIS
    Waits for one or more GitHub Actions workflow runs and reports their result, or that a run waits
    for a person's approval.
.DESCRIPTION
    The one way an agent waits for a workflow run that is not a pull request check: a release run or
    a test consumer run. Without it, each session writes its own sleep loop. It only reads.

    It reads each run with `gh run view <id> --json status,conclusion,workflowName,url,jobs`. For a run
    that is not completed, it also reads the pending deployments of the run
    (`gh api repos/<owner>/<repo>/actions/runs/<id>/pending_deployments`).

    State is 'ready' when every run is completed, 'approval' when the runs that are not completed all
    wait for a reviewer of an environment (a pending deployment, or the run status waiting, and no job
    in progress next to it), 'pending' while a run still works, and 'timeout' when -Wait gave up. A run
    that waits for an approval needs a person, so the wait stops there and says which run.

    A throttled read (HTTP 429 or a rate limit) waits and tries again within -TimeoutMinutes
    (Invoke-GitHubPoll in PullRequestFeedback.psm1). Without -Wait it is not tried again.

    Exit codes: 0 with a JSON report on stdout, 2 when GitHub could not be read (nothing was
    checked).
.PARAMETER RunId
    The run ids to wait for. Several ids are waited for in one call: -RunId 1,2 or, through
    pwsh -File, -RunId "1,2".
.PARAMETER Wait
    Poll until no run is pending, or until -TimeoutMinutes runs out.
.PARAMETER TimeoutMinutes
    How long -Wait polls. Defaults to 9, so one call fits inside a ten-minute shell limit; call it again
    to keep waiting. The last sleep is cut to the time left, so a long -PollSeconds never runs past it.
.PARAMETER PollSeconds
    Seconds between two polls. Defaults to 20.
.PARAMETER Repository
    Repository as owner/name. Defaults to github.repository in aisdlc.json; when that is empty, gh reads
    the repository from the git remote.
.PARAMETER Reader
    Test seam: a scriptblock that takes a name ('run' or 'pending') and a run id, and returns the
    parsed response. Never set in normal use.
.EXAMPLE
    pwsh .claude/skills/github-pull-requests/scripts/Wait-WorkflowRun.ps1 -RunId 678075 -Wait
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$RunId,
    [switch]$Wait,
    [double]$TimeoutMinutes = 9,
    [int]$PollSeconds = 20,
    [string]$Repository,
    [scriptblock]$Reader
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PullRequestFeedback.psm1') -Force

$RunId = @($RunId -split '[,\s]+' | Where-Object { $_ })
if ($RunId.Count -eq 0 -or @($RunId | Where-Object { $_ -notmatch '^\d+$' }).Count -gt 0) { throw "RunId takes run ids, such as 678075 or 678075,678142; got '$($RunId -join ',')'." }

if (-not $Repository) { $Repository = $DefaultRepository }
$repo = Get-RepositoryPart -Repository $Repository

if (-not $Reader) {
    $Reader = {
        param([string]$Name, [long]$Id)
        $repoArgs = if ($Repository) { @('--repo', $Repository) } else { @() }
        switch ($Name) {
            'run' { Invoke-GitHubJson -Arguments (@('run', 'view', $Id) + $repoArgs + @('--json', 'databaseId,status,conclusion,workflowName,url,jobs')) }
            'pending' { Invoke-GitHubJson -Arguments @('api', "$($repo.Path)/actions/runs/$Id/pending_deployments") }
        }
    }
}

function Get-RunState {
    param([long]$Id)

    $run = & $Reader 'run' $Id
    $status = [string]$run.status
    $approval = $false
    if ($status -ne 'completed') {
        $waiting = $status -eq 'waiting' -or @(& $Reader 'pending' $Id | Where-Object { $_ }).Count -gt 0
        $working = @(@($run.jobs) | Where-Object { $_ -and [string]$_.status -eq 'in_progress' }).Count -gt 0
        $approval = $waiting -and -not $working
    }
    [pscustomobject]@{
        Id       = $Id
        Workflow = [string]$run.workflowName
        Status   = $status
        Result   = [string]$run.conclusion
        Approval = $approval
        Url      = [string]$run.url
    }
}

function Get-Snapshot {
    $runs = @($RunId | ForEach-Object { Get-RunState -Id ([long]$_) })
    $pending = @($runs | Where-Object { $_.Status -ne 'completed' -and -not $_.Approval }).Count -gt 0
    [pscustomobject]@{ Pending = $pending; Runs = $runs }
}

try {
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $retryUntil = if ($Wait) { $deadline } else { Get-Date }
    $snapshot = Invoke-GitHubPoll -Action { Get-Snapshot } -Deadline $retryUntil -PollSeconds $PollSeconds
    while ($Wait -and $snapshot.Pending -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds ([math]::Min($PollSeconds * 1000, [math]::Max(0, ($deadline - (Get-Date)).TotalMilliseconds)))
        $snapshot = Invoke-GitHubPoll -Action { Get-Snapshot } -Deadline $retryUntil -PollSeconds $PollSeconds
    }
}
catch {
    Write-Host "Workflow run: GitHub could not be read, so NOTHING WAS CHECKED. $($_.Exception.Message)" -ForegroundColor Yellow
    exit 2
}

$open = @($snapshot.Runs | Where-Object Status -NE 'completed')
$state = if ($snapshot.Pending) { if ($Wait) { 'timeout' } else { 'pending' } } elseif ($open.Count -gt 0) { 'approval' } else { 'ready' }

[pscustomobject]@{
    State   = $state
    Runs    = $snapshot.Runs
    Summary = ('{0}; {1} run(s): {2}' -f $state, $snapshot.Runs.Count, (($snapshot.Runs | ForEach-Object {
                    if ($_.Status -eq 'completed') { "$($_.Id) $($_.Result)" } elseif ($_.Approval) { "$($_.Id) waits for an approval" } else { "$($_.Id) $($_.Status)" }
                }) -join ', '))
} | ConvertTo-Json -Depth 5
exit 0
