#requires -Version 7.4

<#
.SYNOPSIS
Asks Copilot to review a pull request, but only when a review is worth it.

.DESCRIPTION
The first review on a pull request is always asked for. After that, the script asks again only when
enough lines changed since the last Copilot review. It finds that review in the review list of the
pull request. Then it counts the changed lines with `git diff --numstat <commit> HEAD`: added plus
deleted lines, with binary files left out. When the count is below -MinChangedLines, it asks for
nothing and says why. When the count cannot be made, it asks.

The request is `gh pr edit <id> --add-reviewer @copilot`. A failed list or a failed request is a
warning, never an error, so the build loop can go on without the review. Say so in the evidence
record when that happens. The request is not supported on GitHub Enterprise Server.

The Copilot review is found by the field `is_copilot_code_review`. When a review has no such field,
the login `copilot-pull-request-reviewer[bot]` or `Copilot` counts as Copilot.

.PARAMETER Id
The pull request number.

.PARAMETER Repository
Repository as owner/name. Defaults to github.repository in aisdlc.json; when that is empty, the script
asks gh with `gh repo view`.

.PARAMETER MinChangedLines
The least number of changed lines since the last Copilot review that makes a new request. Default 20.

.PARAMETER Force
Ask without counting and without reading the review list.

.PARAMETER GhInvoker
Test seam. A scriptblock that receives the gh argument array (string[]) and returns gh stdout. When
omitted, the real `gh` CLI is used.

.PARAMETER GitInvoker
Test seam. A scriptblock that receives the git argument array (string[]) and returns git stdout. When
omitted, the real `git` is used, and a non-zero exit code is a failure.

.EXAMPLE
./.claude/skills/github-pull-requests/scripts/Request-CopilotReview.ps1 -Id 42

.EXAMPLE
./.claude/skills/github-pull-requests/scripts/Request-CopilotReview.ps1 -Id 42 -Repository contoso/portal -MinChangedLines 50

.EXAMPLE
./.claude/skills/github-pull-requests/scripts/Request-CopilotReview.ps1 -Id 42 -Force

.OUTPUTS
An object with Requested (bool), Reason (string), ChangedLines (int or $null) and ReviewedCommit
(string or $null). The reason is one of: 'forced', 'first review', 'changed <n> lines since <sha>',
'only <n> changed lines since <sha>, below <min>', 'could not count, asked' or 'request failed: ...'.
The script exits 0 when gh fails.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$Id,

    [Parameter()]
    [string]$Repository,

    [Parameter()]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$MinChangedLines = 20,

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [scriptblock]$GhInvoker,

    [Parameter()]
    [scriptblock]$GitInvoker
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'PullRequestDescription.psm1') -Force

if (-not $Repository) {
    $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
    if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
    Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
    $github = (Get-AiSdlcConfig -RepoRoot (Find-AiSdlcRepoRoot -StartPath $PSScriptRoot)).github
    if ($github) { $Repository = [string]$github.repository }
}

function ConvertFrom-JsonArrayStream {
    param([string]$Text)

    # gh api --paginate prints one JSON array per page, one after the other. Split the text at the
    # end of each top-level array, ignoring brackets inside strings.
    $items = [System.Collections.Generic.List[object]]::new()
    $depth = 0
    $inString = $false
    $escaped = $false
    $start = -1
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($inString) {
            if ($escaped) { $escaped = $false }
            elseif ($c -eq '\') { $escaped = $true }
            elseif ($c -eq '"') { $inString = $false }
            continue
        }
        if ($c -eq '"') { $inString = $true }
        elseif ($c -eq '[' -or $c -eq '{') {
            if ($depth -eq 0) { $start = $i }
            $depth++
        }
        elseif ($c -eq ']' -or $c -eq '}') {
            $depth--
            if ($depth -eq 0 -and $start -ge 0) {
                foreach ($item in @($Text.Substring($start, $i - $start + 1) | ConvertFrom-Json -NoEnumerate)) {
                    foreach ($element in @($item)) { $items.Add($element) }
                }
                $start = -1
            }
        }
    }

    return $items.ToArray()
}

function Test-CopilotReview {
    param([object]$Review)

    $flag = $Review.PSObject.Properties['is_copilot_code_review']
    if ($flag) { return ($flag.Value -eq $true) }

    $user = $Review.PSObject.Properties['user']
    if (-not $user -or $null -eq $user.Value) { return $false }
    $login = [string]$user.Value.login
    return ($login -match '^copilot-pull-request-reviewer') -or ($login -ceq 'Copilot')
}

function Get-LastCopilotReviewCommit {
    param([string]$Repository, [int]$Id, [scriptblock]$GhInvoker)

    $json = Invoke-GitHubCli -Arguments @('api', "repos/$Repository/pulls/$Id/reviews", '--paginate') -Invoker $GhInvoker
    $reviews = ConvertFrom-JsonArrayStream -Text ([string]$json)
    $commit = $null
    foreach ($review in $reviews) {
        if (-not (Test-CopilotReview -Review $review)) { continue }
        $property = $review.PSObject.Properties['commit_id']
        if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) { $commit = [string]$property.Value }
    }

    return $commit
}

function Get-ChangedLineCount {
    param([string]$Commit, [scriptblock]$GitInvoker)

    $gitArgs = @('diff', '--numstat', $Commit, 'HEAD')
    if ($GitInvoker) {
        $output = & $GitInvoker $gitArgs
    }
    else {
        $output = & git @gitArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git $($gitArgs -join ' ') failed (exit $LASTEXITCODE): $output" }
    }

    $total = 0
    foreach ($row in @(([string]($output -join "`n")) -split "`r?`n")) {
        $match = [regex]::Match($row, '^(\d+)\t(\d+)\t')
        if ($match.Success) { $total += [int]$match.Groups[1].Value + [int]$match.Groups[2].Value }
    }

    return $total
}

function Request-CopilotReview {
    param([int]$Id, [string]$Repository, [int]$MinChangedLines, [bool]$Force, [scriptblock]$GhInvoker, [scriptblock]$GitInvoker)

    $result = [pscustomobject]@{ Requested = $false; Reason = ''; ChangedLines = $null; ReviewedCommit = $null }
    $fail = {
        param([string]$Message)
        Write-Warning "Copilot review not requested on PR ${Id}: $Message. Go on without it and say so in the evidence record."
        $result.Requested = $false
        $result.Reason = "request failed: $Message"
        return $result
    }

    try {
        if (-not $Repository) {
            $Repository = ((Invoke-GitHubCli -Arguments @('repo', 'view', '--json', 'nameWithOwner') -Invoker $GhInvoker) | ConvertFrom-Json).nameWithOwner
        }

        $ask = $true
        if ($Force) {
            $result.Reason = 'forced'
        }
        else {
            $commit = Get-LastCopilotReviewCommit -Repository $Repository -Id $Id -GhInvoker $GhInvoker
            if (-not $commit) {
                $result.Reason = 'first review'
            }
            else {
                $short = $commit.Substring(0, [Math]::Min(7, $commit.Length))
                $result.ReviewedCommit = $commit
                try {
                    $result.ChangedLines = Get-ChangedLineCount -Commit $commit -GitInvoker $GitInvoker
                    if ($result.ChangedLines -ge $MinChangedLines) {
                        $result.Reason = "changed $($result.ChangedLines) lines since $short"
                    }
                    else {
                        $ask = $false
                        $result.Reason = "only $($result.ChangedLines) changed lines since $short, below $MinChangedLines"
                        Write-Information "Copilot review not requested on PR ${Id}: $($result.Reason)." -InformationAction Continue
                    }
                }
                catch {
                    $result.ChangedLines = $null
                    $result.Reason = 'could not count, asked'
                }
            }
        }
    }
    catch {
        return (& $fail $_.Exception.Message)
    }

    if (-not $ask) { return $result }

    try {
        $requestArgs = @('pr', 'edit', [string]$Id, '--repo', $Repository, '--add-reviewer', '@copilot')
        Invoke-GitHubCli -Arguments $requestArgs -Invoker $GhInvoker | Out-Null
        $result.Requested = $true
    }
    catch {
        return (& $fail $_.Exception.Message)
    }

    Write-Information "Copilot review requested on PR ${Id} ($($result.Reason))." -InformationAction Continue
    return $result
}

return Request-CopilotReview -Id $Id -Repository $Repository -MinChangedLines $MinChangedLines -Force $Force.IsPresent -GhInvoker $GhInvoker -GitInvoker $GitInvoker
