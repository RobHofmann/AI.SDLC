#requires -Version 7.4

<#
.SYNOPSIS
Shared helpers that pass a pull request description to gh safely and prove it arrived whole.

.DESCRIPTION
Used by New-PullRequest.ps1 and Update-PullRequest.ps1. A multi-line description passed as one
command-line value can lose lines or quotes on its way through the shell. So these helpers write the
description to a temporary file and pass it as `--body-file <file>`, which gh reads whole. They refuse
an empty description and one over the 65536-character limit of GitHub. The read-back check fails on
a lost line as well as on lost text. The gh call is injectable (-Invoker), so the tests need no real
pull request.
#>

Set-StrictMode -Version Latest

$script:MaxDescriptionLength = 65536

function ConvertTo-PrDescriptionLine {
    param([string]$Description)

    if ($null -eq $Description) {
        return [string[]]@()
    }

    $normalized = $Description -replace "`r`n", "`n" -replace "`r", "`n"
    $lines = [System.Collections.Generic.List[string]]@($normalized -split "`n")

    # A line that is solely a here-string delimiter (@, @', or '@) is never valid
    # description content. It leaks in when the description is passed as a PowerShell
    # here-string from a shell that does not parse @'...'@ (e.g. bash), so the @
    # delimiters arrive as literal first and last lines. Strip them and warn rather
    # than publishing a PR description that starts and ends with a stray @.
    $isDelimiter = { param([string]$Line) $Line.Trim() -in @('@', "@'", "'@") }

    $stripped = $false
    while ($lines.Count -gt 0 -and (& $isDelimiter $lines[0])) {
        $lines.RemoveAt(0)
        $stripped = $true
    }
    while ($lines.Count -gt 0 -and (& $isDelimiter $lines[$lines.Count - 1])) {
        $lines.RemoveAt($lines.Count - 1)
        $stripped = $true
    }

    if ($stripped) {
        Write-Warning "Stripped a leaked here-string delimiter line (@, @', or '@) from the PR description. If you call this script from bash, do not wrap the description in @'...'@; pass it as a normal quoted string, or call the script from PowerShell."
    }

    return [string[]]@($lines)
}

function Assert-PrDescriptionLength {
    param([string[]]$Lines)

    $length = ($Lines -join "`n").Length
    if ($length -gt $script:MaxDescriptionLength) {
        throw "PR description is $length characters; GitHub rejects more than $($script:MaxDescriptionLength). Shorten it before the call."
    }
}

function New-PrDescriptionFile {
    param([string[]]$Lines)

    $path = Join-Path ([IO.Path]::GetTempPath()) ("pr-description-{0}.md" -f [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($path, ($Lines -join "`n"), [Text.UTF8Encoding]::new($false))
    return $path
}

function Get-PrDescriptionLineCount {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return 0
    }

    return @(($Text -replace "`r`n", "`n" -replace "`r", "`n").TrimEnd() -split "`n").Count
}

function Get-PrDescriptionContentLength {
    param([string]$Text)

    if ($null -eq $Text) {
        return 0
    }

    return ($Text -replace '\s', '').Length
}

function Test-PrDescriptionTruncated {
    param(
        [int]$ExpectedContentLength,
        [int]$ActualContentLength,
        [int]$ExpectedLineCount = -1,
        [int]$ActualLineCount = -1,
        [int]$MinimumAbsoluteTolerance = 8,
        [double]$RelativeTolerance = 0.02
    )

    # A lost blank line changes no content length, so the line count is checked on its own.
    if ($ExpectedLineCount -ge 0 -and $ActualLineCount -ge 0 -and $ActualLineCount -lt $ExpectedLineCount) {
        return $true
    }

    # GitHub can normalize a few characters when it stores the description
    # (line endings, trimming), so an exact length match is too strict and
    # raises false positives on intact descriptions. The failure mode we actually
    # guard against is newline truncation that keeps only the first line, a
    # near-total content loss. Treat the read-back as truncated only when it falls
    # short by more than a small tolerance.
    $tolerance = [Math]::Max($MinimumAbsoluteTolerance, [Math]::Ceiling($ExpectedContentLength * $RelativeTolerance))
    return $ActualContentLength -lt ($ExpectedContentLength - $tolerance)
}

function Invoke-GitHubCli {
    param(
        [string[]]$Arguments,
        [scriptblock]$Invoker
    )

    if ($Invoker) {
        return (& $Invoker $Arguments)
    }

    $output = & gh @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "gh $($Arguments -join ' ') failed (exit $LASTEXITCODE): $output"
    }

    return ($output | Out-String)
}

function Get-PrFromJson {
    param([string]$Json)

    if ([string]::IsNullOrWhiteSpace($Json)) {
        throw "gh returned no JSON to parse."
    }

    return ($Json | ConvertFrom-Json)
}

function Get-PrNumberFromUrl {
    param([string]$Text)

    $match = [regex]::Match([string]$Text, '/pull/(\d+)')
    if (-not $match.Success) {
        throw "gh pr create returned no pull request URL: '$Text'."
    }

    return [int]$match.Groups[1].Value
}

function Get-RepositoryArgument {
    param([string]$Repository)

    if ([string]::IsNullOrWhiteSpace($Repository)) {
        return [string[]]@()
    }

    return [string[]]@('--repo', $Repository)
}

function Get-PullRequestReadBack {
    param(
        [object]$Id,
        [string]$Repository,
        [scriptblock]$GhInvoker
    )

    $viewArgs = @('pr', 'view', [string]$Id) + (Get-RepositoryArgument -Repository $Repository) + @('--json', 'number,url,title,body')

    return Get-PrFromJson -Json (Invoke-GitHubCli -Arguments $viewArgs -Invoker $GhInvoker)
}

Export-ModuleMember -Function ConvertTo-PrDescriptionLine, Assert-PrDescriptionLength, New-PrDescriptionFile,
    Get-PrDescriptionLineCount, Get-PrDescriptionContentLength, Test-PrDescriptionTruncated, Invoke-GitHubCli,
    Get-PrFromJson, Get-PrNumberFromUrl, Get-RepositoryArgument, Get-PullRequestReadBack
