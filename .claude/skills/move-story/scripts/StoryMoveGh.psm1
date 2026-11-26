#requires -Version 7.4

<#
.SYNOPSIS
Small helpers that Get-StoryMovePlan.ps1 and Invoke-StoryMove.ps1 share.

.DESCRIPTION
Invoke-GitHubCli runs one gh command, or the test seam in its place. Get-StoryMoveSettings finds the
repository and the label name from the caller or from aisdlc.json. The module lives in this skill
because the github pack, which has a similar helper, may not be installed.

.PARAMETER Arguments
For Invoke-GitHubCli: the gh argument array.

.PARAMETER Invoker
For Invoke-GitHubCli: a scriptblock that gets the argument array and returns gh stdout. When omitted,
the real gh CLI runs and a non-zero exit code throws.

.PARAMETER RepoRoot
For Get-StoryMoveSettings: the repository root that holds aisdlc.json. Defaults to the root found from
this module.

.PARAMETER Repository
For Get-StoryMoveSettings: the repository as owner/name. When empty, tracker.repository and then
github.repository of aisdlc.json are used.

.PARAMETER Label
For Get-StoryMoveSettings: the label name. When empty, tracker.inReviewLabel of aisdlc.json is used,
then in-review.

.EXAMPLE
Invoke-GitHubCli -Arguments @('issue', 'view', '42', '--json', 'state')

.EXAMPLE
Get-StoryMoveSettings -Repository contoso/portal
#>

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

function Get-StoryMoveSettings {
    param(
        [string]$RepoRoot,
        [string]$Repository,
        [string]$Label
    )

    $tracker = $null
    $github = $null
    if (-not $Repository -or -not $Label) {
        $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
        if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
        Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1')
        if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }
        $config = Get-AiSdlcConfig -RepoRoot $RepoRoot
        $tracker = $config.tracker
        $github = $config.github
    }

    if (-not $Repository -and $tracker -and $tracker['repository']) { $Repository = [string]$tracker['repository'] }
    if (-not $Repository -and $github -and $github['repository']) { $Repository = [string]$github['repository'] }
    if (-not $Label -and $tracker -and $tracker['inReviewLabel']) { $Label = [string]$tracker['inReviewLabel'] }
    if (-not $Label) { $Label = 'in-review' }

    return [pscustomobject]@{
        Repository = $Repository
        Label      = $Label
        RepoArgs   = if ($Repository) { @('--repo', $Repository) } else { @() }
    }
}

Export-ModuleMember -Function Invoke-GitHubCli, Get-StoryMoveSettings
