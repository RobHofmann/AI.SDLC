#requires -Version 7.4

<#
.SYNOPSIS
Plans which stories get the in-review label after a draft pull request is published. Reads only.

.DESCRIPTION
The script reads the pull request, names its stories, reads each issue and says what to do with it.
It never writes to GitHub. Invoke-StoryMove.ps1 applies the plan.

A story is named only by the branch name, the pull request title, or a closing line in the body:
Fixes, Closes or Resolves with an issue key, in any letter case. A key of another repository is
skipped with a reason. Each issue shows up once, in the order branch, title, body.

An issue gets add-label only when the person says the draft is published, the pull request is open,
and it is not a draft. A closed issue is never moved. The rules run in this order: issue closed,
label there, no signal from the person, pull request not open, pull request still a draft.

When an issue cannot be read, its row is a skip with the reason. When the pull request cannot be read,
the script throws, because no plan is possible. When no story is named, it writes a warning and
returns no rows.

.PARAMETER PullRequest
The pull request number.

.PARAMETER PersonSaysPublished
Set it only when the person said the draft pull request is published. Without it, every row is a skip.

.PARAMETER Repository
Repository as owner/name. Defaults to tracker.repository, then github.repository of aisdlc.json. When
both are empty, gh reads the git remote and the script passes no --repo.

.PARAMETER Label
The label name. Defaults to tracker.inReviewLabel of aisdlc.json, then in-review.

.PARAMETER RepoRoot
The repository root that holds aisdlc.json. Defaults to the root found from this script.

.PARAMETER AsText
Also prints one line per row, as information.

.PARAMETER GhInvoker
Test seam. A scriptblock that receives the gh argument array (string[]) and returns gh stdout. When
omitted, the real `gh` CLI is used.

.EXAMPLE
./.claude/skills/move-story/scripts/Get-StoryMovePlan.ps1 -PullRequest 7 -PersonSaysPublished

.EXAMPLE
./.claude/skills/move-story/scripts/Get-StoryMovePlan.ps1 -PullRequest 7 -Repository contoso/portal -AsText

.OUTPUTS
One object per issue with Issue ('#42'), Action ('add-label' or 'skip'), Label and Reason.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$PullRequest,

    [Parameter()]
    [switch]$PersonSaysPublished,

    [Parameter()]
    [string]$Repository,

    [Parameter()]
    [string]$Label,

    [Parameter()]
    [string]$RepoRoot,

    [Parameter()]
    [switch]$AsText,

    [Parameter()]
    [scriptblock]$GhInvoker
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'StoryMoveGh.psm1')

$settings = Get-StoryMoveSettings -RepoRoot $RepoRoot -Repository $Repository -Label $Label
$Repository = $settings.Repository
$Label = $settings.Label
$repoArgs = @($settings.RepoArgs)

function Get-StoryKeyList {
    param([object]$Pr, [string]$Repository)

    # GitHub closes an issue on a closing keyword only; a plain mention in the body names no story.
    $found = [System.Collections.Generic.List[string]]::new()
    $found.Add([string](Get-AiSdlcBranchStoryKey -Branch ([string]$Pr.headRefName)))
    $found.Add([string](Get-AiSdlcStoryKey -Text ([string]$Pr.title)))
    $closing = '(?<!\w)(?:fix(?:e[sd])?|close[sd]?|resolve[sd]?)\s*:?\s+(?<key>(?:[\w.-]+/[\w.-]+)?#\d+)\b'
    foreach ($match in [regex]::Matches([string]$Pr.body, $closing, 'IgnoreCase')) {
        $found.Add([string](Get-AiSdlcStoryKey -Text $match.Groups['key'].Value))
    }

    $keys = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $found) {
        if (-not $key) { continue }
        $parts = [regex]::Match($key, '^(?<repo>[\w.-]+/[\w.-]+)?#(?<n>\d+)$')
        $normal = if ($parts.Groups['repo'].Success -and $parts.Groups['repo'].Value -ine $Repository) { $key } else { '#' + $parts.Groups['n'].Value }
        if (-not ($keys | Where-Object { $_ -ieq $normal })) { $keys.Add($normal) }
    }

    return $keys.ToArray()
}

function New-Row {
    param([string]$Issue, [string]$Action, [string]$Reason)
    return [pscustomobject]@{ Issue = $Issue; Action = $Action; Label = $Label; Reason = $Reason }
}

function Get-IssueRow {
    param([int]$Number, [object]$Pr)

    $issueKey = "#$Number"
    try {
        $json = Invoke-GitHubCli -Arguments (@('issue', 'view', [string]$Number) + $repoArgs + @('--json', 'number,state,labels,title')) -Invoker $GhInvoker
        $issue = $json | ConvertFrom-Json
    }
    catch {
        return (New-Row -Issue $issueKey -Action 'skip' -Reason "could not read the issue: $($_.Exception.Message)")
    }

    if ([string]$issue.state -ieq 'CLOSED') { return (New-Row -Issue $issueKey -Action 'skip' -Reason 'issue is closed, never moved') }
    if (@($issue.labels | Where-Object { [string]$_.name -ieq $Label }).Count -gt 0) { return (New-Row -Issue $issueKey -Action 'skip' -Reason 'already labelled') }
    if (-not $PersonSaysPublished) { return (New-Row -Issue $issueKey -Action 'skip' -Reason 'the person has not said the draft is published') }
    if ([string]$Pr.state -ine 'OPEN') { return (New-Row -Issue $issueKey -Action 'skip' -Reason "pull request is $($Pr.state)") }
    if ($Pr.isDraft -eq $true) { return (New-Row -Issue $issueKey -Action 'skip' -Reason 'pull request is still a draft') }
    return (New-Row -Issue $issueKey -Action 'add-label' -Reason 'published draft, open issue')
}

$prJson = Invoke-GitHubCli -Arguments (@('pr', 'view', [string]$PullRequest) + $repoArgs + @('--json', 'number,state,isDraft,headRefName,title,body,url')) -Invoker $GhInvoker
$pr = $prJson | ConvertFrom-Json

$rows = [System.Collections.Generic.List[object]]::new()
foreach ($key in (Get-StoryKeyList -Pr $pr -Repository $Repository)) {
    if ($key -match '^(?<repo>[\w.-]+/[\w.-]+)#\d+$') {
        $rows.Add((New-Row -Issue $key -Action 'skip' -Reason "the issue is in another repository ($($Matches['repo']))"))
        continue
    }
    $rows.Add((Get-IssueRow -Number ([int]$key.TrimStart('#')) -Pr $pr))
}

if ($rows.Count -eq 0) {
    Write-Warning "No story is named by pull request ${PullRequest}: no issue number in the branch, the title or a Fixes, Closes or Resolves line."
    return
}

if ($AsText) {
    foreach ($row in $rows) { Write-Information ('{0}  {1}  {2}' -f $row.Issue, $row.Action, $row.Reason) -InformationAction Continue }
}

return $rows.ToArray()
