#Requires -Version 7
<#
.SYNOPSIS
    Reports how fast changes really reach main, per week, from the pull requests GitHub already
    holds.

.DESCRIPTION
    The skill usage report says which parts of the workflow are used. This says whether the workflow
    delivers. They answer different questions and neither replaces the other.

    Why it exists: the DORA research of 2025 and 2026 finds the same pattern in team after team. The
    output of one person rises with agent help while the team's delivery stays flat, because the wait
    moves to review. A team that measures only what it produces cannot see that. So this counts the
    things that move when delivery really improves.

    It reads the closed pull requests with `gh pr list --state closed --json ...`; a closed pull
    request with a merge date is merged, one without is abandoned.

    What it reports, per calendar week:

      Merged         pull requests merged into the target branch that week.
      LeadHours      median hours from opening the pull request to merging it (p75 beside it).
      ReviewedHours  median hours from opening to the first review or comment by a person other than
                     the author. Bots do not count. Needs -Detail, because it costs one API call per
                     pull request.
      Rework         median number of iterations after the first. A new iteration is a commit dated
                     after the pull request was opened, so this is the closest thing the API gives to
                     "how often did review send it back". Needs -Detail.
      Abandoned      pull requests closed without a merge that week, as a count.

    What it deliberately does NOT do:

      - It does not measure a person. There is no per-author column, and there will not be one. The
        unit is the team's week.
      - It does not read the first commit. The clock starts when the pull request opens, which is
          later than the first commit, so LeadHours is a floor, not the full lead time.
      - It does not know which pull requests an agent wrote. Comparing "with AI" against "without AI"
        needs a label this repository does not carry.
      - It says nothing about quality. The gates and the coverage ratchet do that.

    Read it monthly, next to the skill-usage page of the ai-sdlc-handbook skill. One reading proves
    nothing; the shape over three months is the signal.

.PARAMETER Repository
    The repository as owner/name. Defaults to github.repository in aisdlc.json; when that is empty, gh
    reads the repository from the git remote.

.PARAMETER TargetBranch
    Only pull requests into this branch are counted. Defaults to main.

.PARAMETER Days
    How far back to look, in days. Defaults to 90.

.PARAMETER Detail
    Also fetch the per-pull-request commits, reviews and comments, which gives the ReviewedHours and
    Rework columns. Costs one API call per pull request, so it is off by default.

.PARAMETER AsObject
    Return the weekly rows as objects instead of printing a table. Used by the tests.

.PARAMETER PullRequestsForTest
    Test seam only: the pull request list, standing in for the gh call. Never set in normal use.

.PARAMETER IterationsForTest
    Test seam only: a hashtable of pull request number to iteration count.

.PARAMETER FirstCommentForTest
    Test seam only: a hashtable of pull request number to the first review or comment date by a person
    other than the author.

.EXAMPLE
    pwsh .claude/skills/github-pull-requests/scripts/Get-PrMetrics.ps1

.EXAMPLE
    pwsh .claude/skills/github-pull-requests/scripts/Get-PrMetrics.ps1 -Days 30 -Detail
#>
[CmdletBinding()]
param(
    [string]$Repository,
    [string]$TargetBranch = 'main',
    [int]$Days = 90,
    [switch]$Detail,
    [switch]$AsObject,
    [object[]]$PullRequestsForTest,
    [hashtable]$IterationsForTest,
    [hashtable]$FirstCommentForTest
)

$ErrorActionPreference = 'Stop'

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
$github = (Get-AiSdlcConfig -RepoRoot (Find-AiSdlcRepoRoot -StartPath $PSScriptRoot)).github
if (-not $Repository -and $github) { $Repository = [string]$github.repository }

$script:UseTestPullRequests = $PSBoundParameters.ContainsKey('PullRequestsForTest')
$script:UseTestIterations = $PSBoundParameters.ContainsKey('IterationsForTest')
$script:UseTestFirstComment = $PSBoundParameters.ContainsKey('FirstCommentForTest')
$script:DetailCache = @{}

$script:DetailQuery = @'
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      commits(last: 100) { nodes { commit { committedDate } } }
      reviews(first: 100) { nodes { author { __typename login } submittedAt } }
      comments(first: 100) { nodes { author { __typename login } createdAt } }
    }
  }
}
'@

function Get-Median {
    param([double[]]$Values)

    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    $middle = [int][Math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 1) { return $sorted[$middle] }
    return ($sorted[$middle - 1] + $sorted[$middle]) / 2
}

function Get-Percentile {
    param([double[]]$Values, [double]$Percentile)

    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    $index = [int][Math]::Ceiling(($Percentile / 100) * $sorted.Count) - 1
    if ($index -lt 0) { $index = 0 }
    if ($index -ge $sorted.Count) { $index = $sorted.Count - 1 }
    return $sorted[$index]
}

function Get-WeekStart {
    param([datetime]$Date)

    $offset = (([int]$Date.DayOfWeek) + 6) % 7
    return $Date.Date.AddDays(-$offset)
}

function Invoke-GhJson {
    param([string[]]$GhArgs, [string]$What)

    $captured = & gh @GhArgs 2>&1
    $noise = @($captured | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
    $json = @($captured | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read $What from GitHub. Run 'gh auth status' and check the -Repository value. gh said: $(($noise + $json) -join ' ')"
    }
    $text = ($json -join "`n").Trim()
    if (-not $text) { return @() }
    return ($text | ConvertFrom-Json)
}

function Get-RepositoryArgs {
    if ($Repository) { return @('--repo', $Repository) }
    return @()
}

function Get-PullRequest {
    if ($script:UseTestPullRequests) { return @($PullRequestsForTest) }

    $sinceDate = (Get-Date).ToUniversalTime().AddDays(-$Days).ToString('yyyy-MM-dd')
    $ghArgs = @('pr', 'list') + (Get-RepositoryArgs) + @(
        '--state', 'closed', '--base', $TargetBranch, '--limit', '1000',
        '--search', "closed:>=$sinceDate",
        '--json', 'number,state,createdAt,closedAt,mergedAt,author'
    )
    return @(Invoke-GhJson -GhArgs $ghArgs -What 'the closed pull requests')
}

function Test-IsBot {
    param([object]$Author)

    if (-not $Author) { return $true }
    return ([string]$Author.login -match '\[bot\]$') -or ([string]$Author.__typename -eq 'Bot')
}

function Get-PrDetail {
    param([int]$Id)

    if ($script:DetailCache.ContainsKey($Id)) { return $script:DetailCache[$Id] }
    $owner = '{owner}'
    $name = '{repo}'
    if ($Repository -match '^(?<o>[\w.-]+)/(?<n>[\w.-]+)$') { $owner = $Matches.o; $name = $Matches.n }
    $ghArgs = @('api', 'graphql', '-f', "query=$($script:DetailQuery)", '-F', "owner=$owner", '-F', "name=$name", '-F', "number=$Id")
    try { $detail = (Invoke-GhJson -GhArgs $ghArgs -What "the detail of pull request $Id").data.repository.pullRequest }
    catch { $detail = $null }
    $script:DetailCache[$Id] = $detail
    return $detail
}

function Get-IterationCount {
    param([int]$Id, [datetime]$Created)

    if ($script:UseTestIterations) { return [int]$IterationsForTest[$Id] }
    $detail = Get-PrDetail -Id $Id
    if (-not $detail) { return 0 }
    $later = @($detail.commits.nodes | Where-Object { $_.commit.committedDate -and ([datetime]$_.commit.committedDate).ToUniversalTime() -gt $Created })
    return 1 + $later.Count
}

function Get-FirstCommentDate {
    param([int]$Id, [string]$AuthorLogin)

    if ($script:UseTestFirstComment) {
        $value = $FirstCommentForTest[$Id]
        if ($value) { return [datetime]$value }
        return $null
    }

    $detail = Get-PrDetail -Id $Id
    if (-not $detail) { return $null }
    $dates = [System.Collections.Generic.List[datetime]]::new()
    foreach ($item in @($detail.reviews.nodes) + @($detail.comments.nodes)) {
        if (-not $item -or (Test-IsBot -Author $item.author)) { continue }
        if ($AuthorLogin -and [string]$item.author.login -eq $AuthorLogin) { continue }
        $when = if ($item.PSObject.Properties['submittedAt']) { $item.submittedAt } else { $item.createdAt }
        if ($when) { $dates.Add([datetime]$when) }
    }
    if ($dates.Count -eq 0) { return $null }
    return ($dates | Sort-Object | Select-Object -First 1)
}

$since = (Get-Date).ToUniversalTime().AddDays(-$Days)
$pullRequests = @(Get-PullRequest)

$rows = [System.Collections.Generic.List[object]]::new()
foreach ($pr in $pullRequests) {
    if (-not $pr.closedAt -or -not $pr.createdAt) { continue }
    $closed = ([datetime]$pr.closedAt).ToUniversalTime()
    if ($closed -lt $since) { continue }
    $created = ([datetime]$pr.createdAt).ToUniversalTime()
    $merged = ([string]$pr.state -eq 'MERGED') -or ($pr.PSObject.Properties['mergedAt'] -and $pr.mergedAt)

    $row = [pscustomobject]@{
        Id         = [int]$pr.number
        Status     = if ($merged) { 'merged' } else { 'abandoned' }
        Created    = $created
        Closed     = $closed
        LeadHours  = [Math]::Round(($closed - $created).TotalHours, 1)
        Reviewed   = $null
        Iterations = $null
    }

    if ($Detail -and $row.Status -eq 'merged') {
        $count = Get-IterationCount -Id $row.Id -Created $created
        if ($count -gt 0) { $row.Iterations = $count - 1 }
        $authorLogin = if ($pr.PSObject.Properties['author'] -and $pr.author) { [string]$pr.author.login } else { '' }
        $first = Get-FirstCommentDate -Id $row.Id -AuthorLogin $authorLogin
        if ($first) { $row.Reviewed = [Math]::Round(($first.ToUniversalTime() - $created).TotalHours, 1) }
    }

    $rows.Add($row)
}

$weekly = [System.Collections.Generic.List[object]]::new()
foreach ($group in ($rows | Group-Object { (Get-WeekStart -Date $_.Closed).ToString('yyyy-MM-dd') } | Sort-Object Name)) {
    $mergedRows = @($group.Group | Where-Object { $_.Status -eq 'merged' })
    $abandoned = @($group.Group | Where-Object { $_.Status -eq 'abandoned' })
    $lead = @($mergedRows | ForEach-Object { [double]$_.LeadHours })
    $reviewed = @($mergedRows | Where-Object { $null -ne $_.Reviewed } | ForEach-Object { [double]$_.Reviewed })
    $rework = @($mergedRows | Where-Object { $null -ne $_.Iterations } | ForEach-Object { [double]$_.Iterations })

    $weekly.Add([pscustomobject]@{
            Week          = $group.Name
            Merged        = $mergedRows.Count
            LeadHours     = if ($null -ne (Get-Median -Values $lead)) { [Math]::Round((Get-Median -Values $lead), 1) } else { $null }
            LeadHoursP75  = if ($null -ne (Get-Percentile -Values $lead -Percentile 75)) { [Math]::Round((Get-Percentile -Values $lead -Percentile 75), 1) } else { $null }
            ReviewedHours = if ($reviewed.Count -gt 0) { [Math]::Round((Get-Median -Values $reviewed), 1) } else { $null }
            Rework        = if ($rework.Count -gt 0) { [Math]::Round((Get-Median -Values $rework), 1) } else { $null }
            Abandoned     = $abandoned.Count
        })
}

if ($AsObject) { return $weekly.ToArray() }

if ($weekly.Count -eq 0) {
    Write-Host "No pull request into $TargetBranch closed in the last $Days days, so there is nothing to report."
    exit 0
}

$label = if ($Repository) { $Repository } else { 'this repository' }
Write-Host ""
Write-Host "Delivery per week: $label into $TargetBranch, the last $Days days" -ForegroundColor Cyan
$weekly | Format-Table -AutoSize | Out-String | Write-Host

$allMerged = @($rows | Where-Object { $_.Status -eq 'merged' })
$allLead = @($allMerged | ForEach-Object { [double]$_.LeadHours })
Write-Host ("Over the whole window: {0} merged, {1} abandoned, median lead {2} hours, p75 {3} hours." -f `
        $allMerged.Count,
    @($rows | Where-Object { $_.Status -eq 'abandoned' }).Count,
    $(if ($allLead.Count) { [Math]::Round((Get-Median -Values $allLead), 1) } else { 'n/a' }),
    $(if ($allLead.Count) { [Math]::Round((Get-Percentile -Values $allLead -Percentile 75), 1) } else { 'n/a' }))

if (-not $Detail) {
    Write-Host "ReviewedHours and Rework are empty: pass -Detail to fetch them (one API call per pull request)." -ForegroundColor Yellow
}

Write-Host "The clock starts when the pull request opens, not at the first commit, so LeadHours is a floor. Read this next to the skill-usage page of the ai-sdlc-handbook skill and treat one reading as noise."
exit 0
