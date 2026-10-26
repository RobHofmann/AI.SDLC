#Requires -Version 7
<#
.SYNOPSIS
    Creates or updates the ruleset on the default branch: a pull request is needed, with zero required
    approvals, and the required status checks must pass.

.DESCRIPTION
    Checkpoint Bravo on GitHub: the agent opens the pull request with the owner's gh login, so the
    owner cannot approve it. So the ruleset asks for a pull request and the required status checks,
    with zero required approvals; the owner's merge is the approval.

    The ruleset targets the default branch (~DEFAULT_BRANCH), so it follows a rename of that branch.
    The script finds it by name. When it does not exist, it creates it; when it differs from what this
    script asks for, it updates it; when it already matches, it changes nothing. After a write it reads
    the ruleset back and throws when the result does not match. It uses `gh api` and the REST
    rulesets endpoints of the repository.

    Running it is the confirmation for this change on GitHub, and it needs the admin right on the
    repository; -WhatIf shows the change and writes nothing.

.PARAMETER RequiredCheck
    The names of the status checks that must pass, as GitHub shows them on a pull request (the job
    name, such as build-and-test or ai-sdlc).

.PARAMETER Name
    The name of the ruleset. Defaults to "ai-sdlc default branch".

.PARAMETER Repository
    Repository as owner/name. Defaults to github.repository in aisdlc.json; when that is empty, gh reads
    the repository from the git remote.

.PARAMETER RepoRoot
    The repository root. Defaults to the folder that holds aisdlc.json.

.PARAMETER Invoker
    Test seam. A scriptblock that receives the gh argument array (string[]) and returns gh stdout. When
    omitted, the real `gh` CLI is used.

.EXAMPLE
    pwsh .claude/skills/github-pull-requests/scripts/Set-BranchRuleset.ps1 -RequiredCheck "build-and-test,AI-SDLC gates" -WhatIf

.EXAMPLE
    pwsh .claude/skills/github-pull-requests/scripts/Set-BranchRuleset.ps1 -RequiredCheck "build-and-test,AI-SDLC gates"
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string[]]$RequiredCheck,
    [string]$Name = 'ai-sdlc default branch',
    [string]$Repository,
    [string]$RepoRoot,
    [scriptblock]$Invoker
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PullRequestDescription.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PullRequestFeedback.psm1') -Force

$RequiredCheck = @($RequiredCheck -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
if ($RequiredCheck.Count -eq 0) { throw 'RequiredCheck takes one or more check names, such as build-and-test and AI-SDLC gates.' }

if (-not $Repository) {
    $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
    if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
    Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
    if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath (Get-Location).Path }
    if ($RepoRoot) {
        $github = (Get-AiSdlcConfig -RepoRoot $RepoRoot).github
        if ($github) { $Repository = [string]$github.repository }
    }
}
$base = (Get-RepositoryPart -Repository $Repository).Path + '/rulesets'

function Invoke-Gh {
    param([string[]]$Arguments)
    $text = Invoke-GitHubCli -Arguments $Arguments -Invoker $Invoker
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json -Depth 20
}

function New-RulesetBody {
    [ordered]@{
        name        = $Name
        target      = 'branch'
        enforcement = 'active'
        conditions  = [ordered]@{ ref_name = [ordered]@{ include = @('~DEFAULT_BRANCH'); exclude = @() } }
        rules       = @(
            [ordered]@{
                type       = 'pull_request'
                parameters = [ordered]@{
                    required_approving_review_count   = 0
                    dismiss_stale_reviews_on_push     = $false
                    require_code_owner_review         = $false
                    require_last_push_approval        = $false
                    required_review_thread_resolution = $false
                }
            }
            [ordered]@{
                type       = 'required_status_checks'
                parameters = [ordered]@{
                    strict_required_status_checks_policy = $false
                    required_status_checks               = @($RequiredCheck | ForEach-Object { [ordered]@{ context = $_ } })
                }
            }
        )
    }
}

function Test-RulesetMatch {
    param([object]$Ruleset)

    if (-not $Ruleset) { return $false }
    if ([string]$Ruleset.enforcement -ne 'active' -or [string]$Ruleset.target -ne 'branch') { return $false }
    if (@($Ruleset.conditions.ref_name.include) -notcontains '~DEFAULT_BRANCH') { return $false }
    $pr = @($Ruleset.rules | Where-Object { $_.type -eq 'pull_request' }) | Select-Object -First 1
    if (-not $pr -or [int]$pr.parameters.required_approving_review_count -ne 0) { return $false }
    $checks = @($Ruleset.rules | Where-Object { $_.type -eq 'required_status_checks' }) | Select-Object -First 1
    if (-not $checks) { return $false }
    $have = @($checks.parameters.required_status_checks | ForEach-Object { [string]$_.context } | Sort-Object -Unique)
    $want = @($RequiredCheck | Sort-Object -Unique)
    return ($have -join "`n") -ceq ($want -join "`n")
}

function Write-Ruleset {
    param([string]$Method, [string]$Path)

    $file = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($file, ((New-RulesetBody) | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
        return Invoke-Gh -Arguments @('api', '--method', $Method, $Path, '--input', $file)
    }
    finally {
        Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
    }
}

$existing = @(Invoke-Gh -Arguments @('api', $base) | Where-Object { $_ -and [string]$_.name -eq $Name }) | Select-Object -First 1
$checkText = $RequiredCheck -join ', '

if ($existing) {
    $current = Invoke-Gh -Arguments @('api', "$base/$($existing.id)")
    if (Test-RulesetMatch -Ruleset $current) {
        Write-Host "Ruleset '$Name' (id $($existing.id)) already asks for a pull request with zero approvals and the checks $checkText. Nothing changed."
        exit 0
    }
    if (-not $PSCmdlet.ShouldProcess("ruleset '$Name' (id $($existing.id))", "update: pull request with zero approvals, required checks $checkText, on the default branch")) { exit 0 }
    $written = Write-Ruleset -Method 'PUT' -Path "$base/$($existing.id)"
    $id = if ($written -and $written.id) { $written.id } else { $existing.id }
    $verb = 'Updated'
}
else {
    if (-not $PSCmdlet.ShouldProcess("ruleset '$Name'", "create: pull request with zero approvals, required checks $checkText, on the default branch")) { exit 0 }
    $written = Write-Ruleset -Method 'POST' -Path $base
    if (-not $written -or -not $written.id) { throw "gh api returned no ruleset id after the create of '$Name'." }
    $id = $written.id
    $verb = 'Created'
}

$readBack = Invoke-Gh -Arguments @('api', "$base/$id")
if (-not (Test-RulesetMatch -Ruleset $readBack)) {
    throw "Ruleset '$Name' (id $id) does not read back as written. Check it under Settings, Rules, Rulesets."
}
Write-Host "$verb ruleset '$Name' (id $id): the default branch needs a pull request with zero approvals and the checks $checkText. Read back and verified."
exit 0
