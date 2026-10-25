#requires -Version 7.4

<#
.SYNOPSIS
Canonical, verified path for creating a GitHub pull request with a full, intact description.

.DESCRIPTION
A multi-line description passed to `gh pr create --body` as one command-line value can lose lines or
quotes on its way through the shell, and a here-string from bash leaks its `@` markers into the text.

This script removes those traps and proves the result:
  1. It writes the description to a temporary file and passes `--body-file <file>`, which gh reads
     whole, blank lines and quotes included. The file is removed after the call.
  2. It refuses an empty/whitespace-only description outright, and one over the 65536-character
     limit of GitHub before the call.
  3. After create it reads the PR back with `gh pr view --json`. It compares the line count, and the
     non-whitespace content length against a small tolerance (GitHub can normalize a few characters
     on store, so an exact match is too strict); on truncation it issues one corrective
     `gh pr edit --body-file` and re-reads. If the description is still truncated it throws. The
     read-back is the proof - the call is never assumed to have worked.

The gh invocation is injectable via -GhInvoker so the file form and the truncation logic are
unit-testable without creating a real pull request (see New-PullRequest.Tests.ps1). The helpers
live in PullRequestDescription.psm1, which Update-PullRequest.ps1 shares.

Every rule this script applies, and the one it cannot apply for you (linking the PR to its issue
with `Fixes #42`), is written out in the github-pull-requests skill.
Check-PrHygiene.ps1 is the build-side backstop for the same traps.

.PARAMETER Title
PR title (single line).

.PARAMETER Description
PR description. May be multi-line; pass it as one string and let this script split it safely.

.PARAMETER Repository
Target repository as owner/name. Defaults to github.repository in aisdlc.json; when that is empty,
gh reads the repository from the git remote.

.PARAMETER SourceBranch
Source branch (the work branch). A bare name or a refs/heads/... ref both work.

.PARAMETER TargetBranch
Target branch. Defaults to github.trunk in aisdlc.json, else main.

.PARAMETER GhInvoker
Test seam. A scriptblock that receives the gh argument array (string[]) and returns gh stdout. When
omitted, the real `gh` CLI is used. Tests pass a fake to exercise the flow offline.

.EXAMPLE
./.claude/skills/github-pull-requests/scripts/New-PullRequest.ps1 -Title "Fix truncated PR descriptions" -SourceBranch 42-pr-descriptions -Description @'
## Summary

Make PR creation pass the description as a file and verify the read-back.

Fixes #42

## Change

- Add a tested helper.
- Update the guidance.
'@

.OUTPUTS
On success, the read-back PR object (number, url, title, body). Throws on truncation or gh failure.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Title,

    [Parameter(Mandatory = $true)]
    [string]$Description,

    [Parameter()]
    [string]$Repository,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SourceBranch,

    [Parameter()]
    [string]$TargetBranch,

    [Parameter()]
    [scriptblock]$GhInvoker
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
$github = (Get-AiSdlcConfig -RepoRoot (Find-AiSdlcRepoRoot -StartPath $PSScriptRoot)).github
if (-not $Repository -and $github) { $Repository = [string]$github.repository }
if (-not $TargetBranch -and $github) { $TargetBranch = [string]$github.trunk }
if (-not $TargetBranch) { $TargetBranch = 'main' }

Import-Module (Join-Path $PSScriptRoot 'PullRequestDescription.psm1') -Force

function New-PullRequest {
    param(
        [string]$Title,
        [string]$Description,
        [string]$Repository,
        [string]$SourceBranch,
        [string]$TargetBranch,
        [scriptblock]$GhInvoker
    )

    $lines = ConvertTo-PrDescriptionLine -Description $Description
    Assert-PrDescriptionLength -Lines $lines

    $expectedContentLength = Get-PrDescriptionContentLength -Text ($lines -join "`n")
    if ($expectedContentLength -eq 0) {
        throw "Refusing to create a PR with an empty or whitespace-only description."
    }
    $expectedLineCount = Get-PrDescriptionLineCount -Text ($lines -join "`n")
    $repoArgs = Get-RepositoryArgument -Repository $Repository
    $head = $SourceBranch -replace '^refs/heads/', ''

    $descriptionFile = New-PrDescriptionFile -Lines $lines
    try {
        $createArgs = @('pr', 'create') + $repoArgs + @(
            '--head', $head,
            '--base', $TargetBranch,
            '--title', $Title,
            '--body-file', $descriptionFile
        )

        $id = Get-PrNumberFromUrl -Text (Invoke-GitHubCli -Arguments $createArgs -Invoker $GhInvoker)

        $pr = Get-PullRequestReadBack -Id $id -Repository $Repository -GhInvoker $GhInvoker
        $actualLength = Get-PrDescriptionContentLength -Text $pr.body
        $actualLineCount = Get-PrDescriptionLineCount -Text $pr.body

        if (Test-PrDescriptionTruncated -ExpectedContentLength $expectedContentLength -ActualContentLength $actualLength -ExpectedLineCount $expectedLineCount -ActualLineCount $actualLineCount) {
            Write-Warning "PR $id description read back as $actualLength of $expectedContentLength content chars and $actualLineCount of $expectedLineCount lines; issuing one corrective update."

            $editArgs = @('pr', 'edit', [string]$id) + $repoArgs + @('--body-file', $descriptionFile)

            Invoke-GitHubCli -Arguments $editArgs -Invoker $GhInvoker | Out-Null

            $pr = Get-PullRequestReadBack -Id $id -Repository $Repository -GhInvoker $GhInvoker
            $actualLength = Get-PrDescriptionContentLength -Text $pr.body
            $actualLineCount = Get-PrDescriptionLineCount -Text $pr.body
        }
    }
    finally {
        Remove-Item -LiteralPath $descriptionFile -Force -ErrorAction SilentlyContinue
    }

    if (Test-PrDescriptionTruncated -ExpectedContentLength $expectedContentLength -ActualContentLength $actualLength -ExpectedLineCount $expectedLineCount -ActualLineCount $actualLineCount) {
        throw "PR $id description is truncated after a corrective update: read back $actualLength of $expectedContentLength content chars and $actualLineCount of $expectedLineCount lines. Fix this before treating the PR as done."
    }

    Write-Information "PR $id created with verified description ($actualLength content chars). URL: $($pr.PSObject.Properties['url'].Value)" -InformationAction Continue

    # Back-edge reminder: a PR is an artifact of its story, so the story should show it.
    # GitHub links the PR to its issue when the description says "Fixes #42", so the
    # reminder checks for that line and nudges the caller when it is missing.
    $storyKey = Get-AiSdlcBranchStoryKey -Branch $head
    $storyHint = if ($storyKey) { $storyKey } else { 'its story' }
    if ($storyKey -and ($lines -join "`n") -notmatch "(?i)\b(fixes|closes|resolves)\s+$([regex]::Escape($storyKey))\b") {
        Write-Information "Next: the description does not say 'Fixes $storyKey', so GitHub does not link this PR to $storyHint. Add the line with Update-PullRequest.ps1, or record the PR on $storyHint via write-story in update mode." -InformationAction Continue
    }
    else {
        Write-Information "Next: check that $storyHint shows this PR. The cycle is not done until the story shows the PR." -InformationAction Continue
    }

    return $pr
}

return New-PullRequest `
    -Title $Title `
    -Description $Description `
    -Repository $Repository `
    -SourceBranch $SourceBranch `
    -TargetBranch $TargetBranch `
    -GhInvoker $GhInvoker
