#requires -Version 7.4

<#
.SYNOPSIS
Puts the in-review label on the stories of a published pull request. A failed move never stops the pull request work.

.DESCRIPTION
The script runs Get-StoryMovePlan.ps1, then applies each add-label row. For one issue it makes sure the
label exists, adds it with `gh issue edit`, and reads the issue back to check the label is there. The
label is created with `gh label create` when `gh label list` has no exact match, in any letter case.

Any failure for one issue is caught. The script writes a warning, marks that row failed and goes on
with the next issue. After the plan is made, it never throws and it exits 0. When the pull request
cannot be read, it returns one failed row and a summary that says no move was made.

Every row carries the same Summary text, and the script also writes that text as information, for
example: Story moves: #42 moved; #43 skipped (issue is closed, never moved); #44 failed (edit refused).
Put that line in the summary you give the person. -WhatIf makes no write call.

.PARAMETER PullRequest
The pull request number.

.PARAMETER PersonSaysPublished
Set it only when the person said the draft pull request is published.

.PARAMETER Repository
Repository as owner/name. Defaults to tracker.repository, then github.repository of aisdlc.json. When
both are empty, gh reads the git remote and the script passes no --repo.

.PARAMETER Label
The label name. Defaults to tracker.inReviewLabel of aisdlc.json, then in-review.

.PARAMETER RepoRoot
The repository root that holds aisdlc.json. Defaults to the root found from this script.

.PARAMETER GhInvoker
Test seam. A scriptblock that receives the gh argument array (string[]) and returns gh stdout. When
omitted, the real `gh` CLI is used.

.EXAMPLE
./.claude/skills/move-story/scripts/Invoke-StoryMove.ps1 -PullRequest 7 -PersonSaysPublished

.EXAMPLE
./.claude/skills/move-story/scripts/Invoke-StoryMove.ps1 -PullRequest 7 -PersonSaysPublished -WhatIf

.OUTPUTS
One object per issue with Issue, Action, Status (moved, skipped, failed or whatif), Reason and Summary.
Summary is the same one-line text on every row. With no story named, nothing is returned.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
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
    [scriptblock]$GhInvoker
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'StoryMoveGh.psm1')

$settings = Get-StoryMoveSettings -RepoRoot $RepoRoot -Repository $Repository -Label $Label
$Repository = $settings.Repository
$Label = $settings.Label
$repoArgs = @($settings.RepoArgs)

function Confirm-LabelExists {
    param([string]$Label)

    $json = Invoke-GitHubCli -Arguments (@('label', 'list') + $repoArgs + @('--search', $Label, '--json', 'name')) -Invoker $GhInvoker
    $found = @(([string]$json | ConvertFrom-Json) | Where-Object { [string]$_.name -ieq $Label })
    if ($found.Count -gt 0) { return }

    $description = 'A person published the draft pull request; it waits for review and merge.'
    Invoke-GitHubCli -Arguments (@('label', 'create', $Label) + $repoArgs + @('--color', 'FBCA04', '--description', $description)) -Invoker $GhInvoker | Out-Null
}

function Add-LabelToIssue {
    param([int]$Number, [string]$Label)

    Invoke-GitHubCli -Arguments (@('issue', 'edit', [string]$Number) + $repoArgs + @('--add-label', $Label)) -Invoker $GhInvoker | Out-Null
    $json = Invoke-GitHubCli -Arguments (@('issue', 'view', [string]$Number) + $repoArgs + @('--json', 'labels')) -Invoker $GhInvoker
    $labels = @(([string]$json | ConvertFrom-Json).labels | Where-Object { [string]$_.name -ieq $Label })
    if ($labels.Count -eq 0) { throw "the read back shows that label $Label is not on the issue" }
}

function New-ResultRow {
    param([string]$Issue, [string]$Action, [string]$Status, [string]$Reason)
    return [pscustomobject]@{ Issue = $Issue; Action = $Action; Status = $Status; Reason = $Reason; Summary = '' }
}

function Get-SummaryPart {
    param([object]$Row)

    switch ($Row.Status) {
        'moved' { return "$($Row.Issue) moved" }
        default { return "$($Row.Issue) $($Row.Status) ($($Row.Reason))" }
    }
}

$planScript = Join-Path $PSScriptRoot 'Get-StoryMovePlan.ps1'
$planArgs = @{ PullRequest = $PullRequest; Repository = $Repository; Label = $Label; RepoRoot = $RepoRoot }
if ($PersonSaysPublished) { $planArgs['PersonSaysPublished'] = $true }
if ($GhInvoker) { $planArgs['GhInvoker'] = $GhInvoker }
if (-not $RepoRoot) { $planArgs.Remove('RepoRoot') }

try {
    $plan = @(& $planScript @planArgs)
}
catch {
    $message = $_.Exception.Message
    Write-Warning "No story move was made for pull request ${PullRequest}: $message"
    $summary = "Story moves: none made (could not read pull request #${PullRequest}: $message)"
    Write-Information $summary -InformationAction Continue
    $row = New-ResultRow -Issue '' -Action 'none' -Status 'failed' -Reason $message
    $row.Summary = $summary
    return $row
}

if ($plan.Count -eq 0) {
    Write-Information 'Story moves: none (no story is named)' -InformationAction Continue
    return
}

$labelReady = $false
$rows = [System.Collections.Generic.List[object]]::new()
foreach ($item in $plan) {
    if ($item.Action -ne 'add-label') {
        $rows.Add((New-ResultRow -Issue $item.Issue -Action $item.Action -Status 'skipped' -Reason $item.Reason))
        continue
    }

    if (-not $PSCmdlet.ShouldProcess("issue $($item.Issue)", "add label $Label")) {
        $rows.Add((New-ResultRow -Issue $item.Issue -Action $item.Action -Status 'whatif' -Reason "would add label $Label"))
        continue
    }

    try {
        if (-not $labelReady) {
            Confirm-LabelExists -Label $Label
            $labelReady = $true
        }
        Add-LabelToIssue -Number ([int]$item.Issue.TrimStart('#')) -Label $Label
        $rows.Add((New-ResultRow -Issue $item.Issue -Action $item.Action -Status 'moved' -Reason $item.Reason))
    }
    catch {
        Write-Warning "Story move failed for $($item.Issue): $($_.Exception.Message)"
        $rows.Add((New-ResultRow -Issue $item.Issue -Action $item.Action -Status 'failed' -Reason $_.Exception.Message))
    }
}

$summary = 'Story moves: ' + (($rows | ForEach-Object { Get-SummaryPart -Row $_ }) -join '; ')
foreach ($row in $rows) { $row.Summary = $summary }
Write-Information $summary -InformationAction Continue

return $rows.ToArray()
