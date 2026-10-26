#requires -Version 7.4

<#
.SYNOPSIS
Changes the title or the description of an existing GitHub pull request, and nothing else.

.DESCRIPTION
The agent keeps the title and the description of its pull request true at any time, with no prompt
(orchestration page of the ai-sdlc-handbook skill). This script is the one way it does that. It can
only change the title and the description: it passes no reviewer, label, milestone, base or draft
option to gh. So a repository can allow this script without a prompt, and keep `gh pr edit` itself
behind one.

It uses the helpers of PullRequestDescription.psm1, as New-PullRequest.ps1 does. It passes the
description as a temporary file (`--body-file <file>`), so blank lines and quotes survive. It refuses
an empty description and one over 65536 characters, then reads the pull request back with
`gh pr view --json`. On a lost line or lost text it makes one corrective call; if the title or the
description is still wrong, it throws.

.PARAMETER Id
The pull request number.

.PARAMETER Title
The new title, on one line. Leave it out to keep the title.

.PARAMETER Description
The new description. May be multi-line; pass it as one string. Leave it out to keep the description.

.PARAMETER Repository
Repository as owner/name. Defaults to github.repository in aisdlc.json; when that is empty, gh reads
the repository from the git remote.

.PARAMETER GhInvoker
Test seam. A scriptblock that receives the gh argument array (string[]) and returns gh stdout. When
omitted, the real `gh` CLI is used.

.EXAMPLE
./.claude/skills/github-pull-requests/scripts/Update-PullRequest.ps1 -Id 42 -Description (Get-Content temp/evidence.md -Raw)

.EXAMPLE
./.claude/skills/github-pull-requests/scripts/Update-PullRequest.ps1 -Id 42 -Title "Show the owner on the order page"

.OUTPUTS
The read-back pull request object. Throws when the change did not land or gh fails.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$Id,

    [Parameter()]
    [string]$Title,

    [Parameter()]
    [string]$Description,

    [Parameter()]
    [string]$Repository,

    [Parameter()]
    [scriptblock]$GhInvoker
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'PullRequestDescription.psm1') -Force

$hasTitle = $PSBoundParameters.ContainsKey('Title')
$hasDescription = $PSBoundParameters.ContainsKey('Description')
if (-not $hasTitle -and -not $hasDescription) {
    throw 'Nothing to change: pass -Title, -Description or both.'
}

if (-not $PSBoundParameters.ContainsKey('Repository')) {
    $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
    if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
    Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
    $github = (Get-AiSdlcConfig -RepoRoot (Find-AiSdlcRepoRoot -StartPath $PSScriptRoot)).github
    if ($github) { $Repository = [string]$github.repository }
}

$repoArgs = Get-RepositoryArgument -Repository $Repository
$editArgs = @('pr', 'edit', [string]$Id) + $repoArgs

if ($hasTitle) {
    $Title = $Title.Trim()
    if (-not $Title) { throw 'Refusing an empty title.' }
    if ($Title -match "[`r`n]") { throw 'The title must be one line.' }
    if ($Title -match '^-') { throw "The title starts with '-', which gh can read as an option flag. Offending title: '$Title'." }
    $editArgs += @('--title', $Title)
}

$lines = @()
$expectedContentLength = 0
$expectedLineCount = 0
$descriptionFile = $null
if ($hasDescription) {
    $lines = ConvertTo-PrDescriptionLine -Description $Description
    Assert-PrDescriptionLength -Lines $lines
    $expectedContentLength = Get-PrDescriptionContentLength -Text ($lines -join "`n")
    if ($expectedContentLength -eq 0) {
        throw 'Refusing an empty or whitespace-only description.'
    }
    $expectedLineCount = Get-PrDescriptionLineCount -Text ($lines -join "`n")
    $descriptionFile = New-PrDescriptionFile -Lines $lines
    $editArgs += @('--body-file', $descriptionFile)
}

try {
    Invoke-GitHubCli -Arguments $editArgs -Invoker $GhInvoker | Out-Null
    $pr = Get-PullRequestReadBack -Id $Id -Repository $Repository -GhInvoker $GhInvoker

    if ($hasDescription) {
        $actualLength = Get-PrDescriptionContentLength -Text $pr.body
        $actualLineCount = Get-PrDescriptionLineCount -Text $pr.body
        if (Test-PrDescriptionTruncated -ExpectedContentLength $expectedContentLength -ActualContentLength $actualLength -ExpectedLineCount $expectedLineCount -ActualLineCount $actualLineCount) {
            Write-Warning "PR $Id description read back as $actualLength of $expectedContentLength content chars and $actualLineCount of $expectedLineCount lines; issuing one corrective update."
            $retryArgs = @('pr', 'edit', [string]$Id) + $repoArgs + @('--body-file', $descriptionFile)
            Invoke-GitHubCli -Arguments $retryArgs -Invoker $GhInvoker | Out-Null
            $pr = Get-PullRequestReadBack -Id $Id -Repository $Repository -GhInvoker $GhInvoker
            $actualLength = Get-PrDescriptionContentLength -Text $pr.body
            $actualLineCount = Get-PrDescriptionLineCount -Text $pr.body
        }
        if (Test-PrDescriptionTruncated -ExpectedContentLength $expectedContentLength -ActualContentLength $actualLength -ExpectedLineCount $expectedLineCount -ActualLineCount $actualLineCount) {
            throw "PR $Id description is truncated after a corrective update: read back $actualLength of $expectedContentLength content chars and $actualLineCount of $expectedLineCount lines."
        }
    }
}
finally {
    if ($descriptionFile) { Remove-Item -LiteralPath $descriptionFile -Force -ErrorAction SilentlyContinue }
}

if ($hasTitle -and [string]$pr.title -ne $Title) {
    throw "PR $Id title read back as '$($pr.title)', not '$Title'."
}

Write-Information "PR $Id updated and read back." -InformationAction Continue
return $pr
