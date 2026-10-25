#Requires -Version 7
<#
.SYNOPSIS
    Gate: a pull request names its story and carries a description that survived the call.

.DESCRIPTION
    Two checks on the pull request itself, both repo-side and needing no tracker:

      1. STORY. A story key (#42) appears somewhere: the source branch, the title, or the description. Any
         one of the three is enough. Which story it is, and whether that story is dev-active, is the
         separate job of Check-PrStoryContract.ps1; this gate only asks that the pull request says
         which work it belongs to.

      2. DESCRIPTION. The description is there and reads like a description. The form is free text:
         no heading is required and no section is required. What is rejected is the shape a cut-off
         description has. An empty description, a description that repeats the title, or one under
         MinDescription characters is reported. A real incident cut a 2209-character body down to the
         10 characters of "## Summary", and nothing noticed until a reader opened the pull request.

    NO-OP with no pull request context at all (no title, no description, no source branch), so a local
    Invoke-LocalGates run does not trip it.

    Exit 0 clean, 1 a violation a person fixes by editing the pull request, 2 when the pull request
    could not be read at all. The
    gate is Blocking, because every finding it reports takes seconds to fix and needs nobody else.

.PARAMETER PrTitle
    The pull request title. The workflow fills it from the GitHub event.

.PARAMETER PrDescription
    The pull request description (body), as the GitHub event holds it.

.PARAMETER SourceBranch
    The pull request source branch (42-short-name or feature/42-short-name). Its last segment
    names the story when it starts with the issue number.

.PARAMETER PrId
    The pull request id. Present means there is a pull request, so a missing title is a read failure
    rather than a local run.

.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script. The story
    key pattern comes from tracker.keyPattern in aisdlc.json; with none, a GitHub issue key (#42) counts.
.PARAMETER MinDescription
    The shortest description that is accepted, in characters. Defaults to 40.

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Check-PrHygiene.ps1

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Check-PrHygiene.ps1 -PrTitle "Add a field" -PrDescription "Fixes #42 ..." -PrId 17
#>
[CmdletBinding()]
param(
    [string]$PrTitle = $env:PR_TITLE,
    [string]$PrDescription = $env:PR_DESCRIPTION,
    [string]$SourceBranch = $env:PR_SOURCE_BRANCH,
    [string]$PrId = $env:PR_ID,
    [int]$MinDescription = 40,
    [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

$storyPattern = Get-AiSdlcStoryPattern -RepoRoot $RepoRoot
$config = Get-AiSdlcConfig -RepoRoot $RepoRoot
$keyHint = if ($config.tracker.keyPattern) { 'story key (tracker.keyPattern)' } else { 'story key (#42)' }
$keyExample = if ($config.tracker.keyPattern) { '' } else { ' (Fixes #42)' }

function Fail([string]$msg) { Write-Output "::error::$msg"; exit 1 }
function Unknown([string]$msg) { Write-Output "::warning::$msg"; exit 2 }
function Ok([string]$msg) { Write-Output $msg; exit 0 }

$hasContext = @($PrTitle, $PrDescription, $SourceBranch, $PrId | Where-Object { $_ -and "$_".Trim() }).Count -gt 0
if (-not $hasContext) {
    Ok "PR hygiene: no pull request context (no id, title, description or source branch), so there is nothing to check here. This gate runs on a pull request build."
}

if ($PrId -and -not $PrTitle) {
    Unknown "PR hygiene could not be checked: pull request $PrId exists but its title and description were not read from the GitHub event. The step before this one says why. Nobody on this pull request can fix it by editing code."
}

$findings = [System.Collections.Generic.List[string]]::new()

$storyIn = @()
if ((Get-AiSdlcBranchStoryKey -Branch $SourceBranch) -or (Get-AiSdlcStoryKey -Text $SourceBranch -Pattern $storyPattern)) { $storyIn += 'the source branch' }
if (Get-AiSdlcStoryKey -Text $PrTitle -Pattern $storyPattern) { $storyIn += 'the title' }
if (Get-AiSdlcStoryKey -Text $PrDescription -Pattern $storyPattern) { $storyIn += 'the description' }

if ($storyIn.Count -eq 0) {
    $findings.Add("STORY: no $keyHint in the source branch, the title, or the description. Put the key in one of the three, so the pull request says which work it belongs to.")
}

$description = if ($PrDescription) { $PrDescription.Trim() } else { '' }
$title = if ($PrTitle) { $PrTitle.Trim() } else { '' }

if (-not $description) {
    $findings.Add("DESCRIPTION: empty. A description lost on the way looks exactly like this. Read the pull request back after you create or update it, and fix it with a corrective update (Update-PullRequest.ps1 in the github pack).")
}
elseif ($title -and $description -eq $title) {
    $findings.Add("DESCRIPTION: the same text as the title ($($description.Length) characters). That is the shape a cut-off description has, not a description.")
}
elseif ($description.Length -lt $MinDescription) {
    $findings.Add("DESCRIPTION: $($description.Length) characters, under the $MinDescription this gate accepts. A body cut down to its first line reads like this; a real incident cut 2209 characters to 10. Free text is fine, but say what the change does.")
}

if ($findings.Count -gt 0) {
    Write-Host "PR hygiene: the pull request does not carry what a reader needs." -ForegroundColor Red
    foreach ($finding in $findings) { Write-Host "  $finding" }
    Write-Host "FIX: Edit the pull request itself: put the $keyHint in the title or the description$keyExample, and give it a body that says what the change does. No code change is needed."
    Write-Output "::error::PR hygiene failed on $($findings.Count) point(s): $(($findings | ForEach-Object { ($_ -split ':')[0] }) -join ', '). Fix the pull request itself; no code change is needed."
    exit 1
}

Ok "PR hygiene OK: the story key is in $($storyIn -join ' and '), and the description is $($description.Length) characters."
