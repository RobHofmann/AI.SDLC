#Requires -Version 7
<#
.SYNOPSIS
    The github-issues part of the local pre-flight: the gh form of the PR-story contract.

.DESCRIPTION
    Invoke-Preflight.ps1 in the ai-sdlc-gates skill runs this script, because check-pr-contract/gates.json
    names it as the github-issues preflight. It returns one row with Check, Status and Detail.

    First it reads the story key from the branch name, which needs no GitHub read. A branch with no
    story key (42-short-name, or the bare number 42 of a bug branch) is a FAIL row, so the pre-flight
    writes no receipt, with or without gh. Set PR_STORY_KEY to name the key of a branch that cannot
    carry it. Outside a git repository there is no branch, and this step is left out.

    When gh is installed and signed in (`gh auth status` succeeds), it runs Check-PrStoryContract.ps1
    for the current branch and the changed files. Without it, it says what is needed; the same check
    also runs from the run-preflight skill, through check-pr-contract.

    Exit 0 of that script is a PASS row. Exit 1 is a FAIL row, because the Blocking CI gate fails the
    pull request for the same reason, so the pre-flight writes no receipt. Exit 2 means the issue could
    not be checked, which is a REVIEW row.

.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script.

.PARAMETER ChangedFiles
    The changed source files the core script found.

.PARAMETER GhCommand
    The GitHub CLI command. Defaults to gh. A test passes a stand-in so no network call is made.

.EXAMPLE
    pwsh .claude/skills/check-pr-contract/scripts/Invoke-IssuePreflight.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string[]]$ChangedFiles = @(),
    [string]$GhCommand = 'gh'
)

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

function Test-GhReady {
    if (-not (Get-Command -Name $GhCommand -ErrorAction SilentlyContinue)) { return $false }
    & $GhCommand auth status *> $null
    return ($LASTEXITCODE -eq 0)
}

Write-Host "Issue contract (gh; the same check runs from the run-preflight skill)..." -ForegroundColor Cyan
$branch = [string](git -C $RepoRoot rev-parse --abbrev-ref HEAD 2>$null)
# The story key needs no GitHub read, so a branch without one fails before the gh check. The branch rule
# is the one Check-PrStoryContract.ps1 uses, so both forms agree on what a key is.
if ($branch -and -not ($env:PR_STORY_KEY -or (Get-AiSdlcBranchStoryKey -Branch $branch))) {
    [pscustomobject]@{ Check = 'IssueContract (story + ADR)'; Status = 'FAIL'; Detail = "branch '$branch' names no story key, and the pre-flight has no pull request title or body to read; start the branch name with the issue number (42-short-name), or set PR_STORY_KEY to the key" }
}
elseif (Test-GhReady) {
    & (Join-Path $PSScriptRoot 'Check-PrStoryContract.ps1') -SourceBranch $branch -ChangedFiles ($ChangedFiles -join "`n") -RepoRoot $RepoRoot -GhCommand $GhCommand | Out-Host
    $status = switch ($LASTEXITCODE) { 0 { 'PASS' } 1 { 'FAIL' } default { 'REVIEW' } }
    [pscustomobject]@{ Check = 'IssueContract (story + ADR)'; Status = $status; Detail = 'gh form (gh issue view)' }
}
else {
    [pscustomobject]@{ Check = 'IssueContract (story + ADR)'; Status = 'NEEDS-GH'; Detail = 'gh cannot read issues: install the GitHub CLI and run gh auth login, or run check-pr-contract from the run-preflight skill' }
}
