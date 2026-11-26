#Requires -Version 7
<#
.SYNOPSIS
    Advisory gate: a repo artifact that anchors a GitHub issue should be referenced back from that issue.
    The headless, repo-to-issue half of the deferred issue-side check in the artifact-graph page of the ai-sdlc-handbook skill.

.DESCRIPTION
    The artifact graph is bidirectional, but only the repo-to-repo edges are enforced (Check-ArtifactGraph.ps1).
    The repo-to-issue backlink (the issue body referencing the ADR / spec that points at it) is upheld
    by skill discipline only, so it silently drifts. This gate surfaces that drift.

    It scans the ADR folder (paths.adrFolder in aisdlc.json) for front-matter `story: "#1234"`, groups
    the ADRs by issue, reads each issue body with `gh issue view <n> --json body`, and reports any issue
    whose body does not reference the ADR(s) that declare it. A reference counts if the body
    contains the ADR slug (e.g. 0011-billing-cost-center...), the path <adrFolder>/0011, or "ADR 0011".
    An ADR whose `story:` has no value (an unquoted # starts a YAML comment) is reported too; that part
    needs no issue read.

    It judges only the change. It reads an ADR only when the change adds or changes that ADR's `story:`
    line (Get-AiSdlcLineChange in ChangedFiles.psm1), so an ADR whose story line is older is skipped,
    also when other lines of the file changed. A change that holds no such ADR is not applicable.

    ADVISORY by design: it never writes the "::error::" annotation and is wrapped by Invoke-Gate.ps1 in
    Advisory mode, so a missing backlink is a warning, not a failed build. It reads issues only in GitHub
    Actions with a GH_TOKEN, so a local run is not applicable (exit 3) for the issue reads and never false-alarms
    off the workflow. It is also not applicable when no ADR is anchored to a story by the change, and in a
    local run with no merge base, where the lines of the change cannot be told.

    Exit 0 clean, 1 a finding, 2 could not check (no issue body could be read, or CHANGED_FILES is set but
    there is no merge base; the output has a FIX: line), 3 not applicable. With an explicit -ChangedFiles
    list and no merge base, every line of the listed files counts as added.

.PARAMETER RepoRoot
    Repository root containing the ADR folder. Defaults to the folder that holds aisdlc.json, found from this script.

.PARAMETER BaseRef
    The ref the change is measured against. Defaults to origin/<github.trunk> from aisdlc.json
    (Get-AiSdlcMainBranch), origin/main unless the repository names another trunk.

.PARAMETER ChangedFiles
    Explicit repository-relative paths, bypassing git for the file list. Falls back to the
    newline-separated CHANGED_FILES environment variable, which the pipeline sets from the pull request
    diff, and then to git.

.PARAMETER GhCommand
    The GitHub CLI command. Defaults to gh.

.PARAMETER GhToken
    The token gh uses in CI. Defaults to the GH_TOKEN environment variable.

.PARAMETER InCi
    True when the gate runs in GitHub Actions. Defaults to GITHUB_ACTIONS being "true".

.PARAMETER BodiesForTest
    Test seam only: a hashtable of issue key -> body string. When set, gh is not called.
    Used by the Pester test so it runs without network; never set in CI.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$BaseRef,
    [string[]]$ChangedFiles,
    [string]$GhCommand = 'gh',
    [string]$GhToken = $env:GH_TOKEN,
    [bool]$InCi = ($env:GITHUB_ACTIONS -eq 'true'),
    [hashtable]$BodiesForTest
)

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
Import-Module (Join-Path $aiSdlcGates 'ChangedFiles.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }
if (-not $BaseRef) { $BaseRef = Get-AiSdlcMainBranch -RepoRoot $RepoRoot }

$ErrorActionPreference = 'Stop'

$aiSdlc = Get-AiSdlcConfig -RepoRoot $RepoRoot
$excludedAdrNames = @('0000-template.md')

# A list the caller passes has no base to measure lines against, so its files count as new. A list from
# the pipeline must have a base, because reading every listed ADR would blame the change for old files.
$change = Get-AiSdlcChange -RepoRoot $RepoRoot -BaseRef $BaseRef -Explicit $ChangedFiles
$listedByCaller = [bool]$ChangedFiles
$changedPath = [System.Collections.Generic.HashSet[string]]::new([string[]]@($change.Files))
foreach ($gone in @($change.Deleted)) { [void]$changedPath.Remove($gone) }

function Get-TrackerRepository {
    foreach ($value in @($aiSdlc.tracker.repository, $aiSdlc.github.repository)) {
        if ($value) { return [string]$value }
    }
    $url = [string](git -C $RepoRoot remote get-url origin 2>$null)
    $m = [regex]::Match($url, '[:/](?<repo>[\w.-]+/[\w.-]+?)(?:\.git)?/?$')
    if ($m.Success) { return $m.Groups['repo'].Value }
    return ''
}
$trackerRepository = Get-TrackerRepository

function ConvertTo-LocalKey([string]$key) {
    $m = [regex]::Match($key, '^(?<repo>[\w.-]+/[\w.-]+)#(?<n>\d+)$')
    if ($m.Success -and $trackerRepository -and $m.Groups['repo'].Value -ieq $trackerRepository) { return "#$($m.Groups['n'].Value)" }
    return $key
}

function Get-AdrStory([string]$frontMatter) {
    $m = [regex]::Match($frontMatter, '(?m)^\s*story:[ \t]*(?<value>.*?)\s*$')
    if (-not $m.Success) { return $null }
    $story = ConvertTo-AiSdlcStoryKey -Value $m.Groups['value'].Value -RepoRoot $RepoRoot
    if ($story.Status -eq 'ok') { $story.Key = ConvertTo-LocalKey $story.Key }
    return $story
}

# True when the change adds or changes the story: line in the front matter of this ADR. The line number
# is read from the file on disk, which is the numbering that Get-AiSdlcLineChange uses.
function Test-StoryLineChanged {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][System.IO.FileInfo]$File, [Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][System.Text.RegularExpressions.Match]$FrontMatter)

    $relative = [IO.Path]::GetRelativePath($Root, $File.FullName).Replace('\', '/')
    if (-not $changedPath.Contains($relative)) { return $false }
    $storyLine = [regex]::Match($FrontMatter.Groups[1].Value, '(?m)^[ \t]*story:')
    if (-not $storyLine.Success) { return $false }
    $lineNumber = ($Text.Substring(0, $FrontMatter.Groups[1].Index + $storyLine.Index) -split "`n").Count
    $lines = Get-AiSdlcLineChange -RepoRoot $Root -Base $change.Base -Path $relative -AssumeNew:$listedByCaller
    return [bool]($lines -and ($lines.Added -contains $lineNumber))
}

# Map each anchoring artifact to the issues it declares. v1 covers ADRs; widen to specs/docs when their
# repo-to-issue backlink is also worth surfacing.
function Get-StoryToArtifacts([string]$root) {
    $map = @{}
    $traps = [System.Collections.Generic.List[string]]::new()
    $invalid = [System.Collections.Generic.List[string]]::new()
    $adrDir = Join-Path $root $aiSdlc.paths.adrFolder
    if (-not (Test-Path $adrDir)) { return [pscustomobject]@{ Map = $map; Traps = @(); Invalid = @() } }
    foreach ($adr in (Get-ChildItem -Path $adrDir -Filter *.md -File)) {
        if ($excludedAdrNames -contains $adr.Name) { continue }
        $text = Get-Content -LiteralPath $adr.FullName -Raw
        $fm = [regex]::Match($text, '\A\s*---\r?\n(.*?)\r?\n---\r?\n', 'Singleline')
        if (-not $fm.Success) { continue }
        if (-not (Test-StoryLineChanged -Root $root -File $adr -Text $text -FrontMatter $fm)) { continue }
        $story = Get-AdrStory $fm.Groups[1].Value
        if (-not $story) { continue }
        if ($story.Status -eq 'empty') { $traps.Add($adr.BaseName); continue }
        if ($story.Status -eq 'invalid') { $invalid.Add("$($adr.BaseName) ('$($story.Value)')"); continue }
        $key = $story.Key
        if (-not $map.ContainsKey($key)) { $map[$key] = [System.Collections.Generic.List[string]]::new() }
        $map[$key].Add($adr.BaseName)
    }
    return [pscustomobject]@{ Map = $map; Traps = $traps.ToArray(); Invalid = $invalid.ToArray() }
}

function Test-GhReadable {
    if ($BodiesForTest) { return $true }
    if (-not $InCi -or -not $GhToken) { return $false }
    return [bool](Get-Command -Name $GhCommand -ErrorAction SilentlyContinue)
}

function Get-IssueBody([string]$key) {
    if ($BodiesForTest) {
        if ($BodiesForTest.ContainsKey($key)) { return [string]$BodiesForTest[$key] }
        return $null   # absent in the seam stands for "could not read" (unverified)
    }
    $m = [regex]::Match($key, '^(?:(?<repo>[\w.-]+/[\w.-]+))?#(?<n>\d+)$')
    $repo = if ($m.Groups['repo'].Success) { $m.Groups['repo'].Value } else { $trackerRepository }
    $repoArgs = if ($repo) { @('-R', $repo) } else { @() }
    $output = @(& $GhCommand issue view $m.Groups['n'].Value @repoArgs --json body 2>$null)
    if ($LASTEXITCODE -ne 0) { return $null }   # advisory: an unreadable issue is reported as unverified, never a hard fail
    try { return [string](($output -join "`n") | ConvertFrom-Json).body }
    catch { return $null }
}

# An ADR is referenced if the body names it by slug, by <adrFolder>/NNNN path, or as "ADR NNNN".
function Test-BodyReferencesAdr([string]$body, [string]$adrBaseName) {
    if ([string]::IsNullOrWhiteSpace($body)) { return $false }
    $number = ($adrBaseName -split '-', 2)[0]
    return ($body -match [regex]::Escape($adrBaseName)) -or
           ($body -match ([regex]::Escape(([string]$aiSdlc.paths.adrFolder).Replace('\', '/').TrimEnd('/')) + "/$number")) -or
           ($body -match "(?i)\bADR\s*$number\b")
}

function Get-MissingBackEdge {
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][AllowEmptyString()][string]$Body, [string[]]$Adrs)

    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($adr in $Adrs) {
        if (-not (Test-BodyReferencesAdr $Body $adr)) {
            $missing.Add("$Key : issue body does not reference ADR $adr that anchors to it (add a Decisions & ADRs backlink via write-story in update mode).")
        }
    }
    return $missing.ToArray()
}

function Get-BackEdgeState {
    param([int]$FindingCount, [int]$Checked, [int]$UnreadableCount)

    if ($FindingCount -gt 0) { return 'Findings' }
    if ($Checked -eq 0 -and $UnreadableCount -gt 0) { return 'NoneReadable' }
    if ($UnreadableCount -gt 0) { return 'PartlyReadable' }
    return 'Clean'
}

function Get-StoryBackEdgeResult {
    if ($env:CHANGED_FILES -and -not $listedByCaller -and (-not $change.Readable -or -not $change.Base)) {
        $why = if ($change.Reason) { $change.Reason } else { "no merge base between $BaseRef and HEAD" }
        return [pscustomobject]@{ State = 'NoBase'; Reason = $why }
    }
    if (-not $listedByCaller -and -not $change.Readable) { return [pscustomobject]@{ State = 'NoChange' } }
    $anchors = Get-StoryToArtifacts $RepoRoot
    $map = $anchors.Map
    $findings = [System.Collections.Generic.List[string]]::new()
    foreach ($trap in $anchors.Traps) {
        $findings.Add("$trap : front matter 'story:' has no value, because an unquoted # starts a YAML comment. Write the key in quotes, for example story: `"#1234`".")
    }
    foreach ($bad in $anchors.Invalid) {
        $findings.Add("$bad : front matter 'story:' is not a story key. Write it as #<number> or owner/repo#<number>, in quotes, for example story: `"#1234`".")
    }
    if ($map.Count -eq 0 -and $findings.Count -eq 0) { return [pscustomobject]@{ State = 'NoAnchors' } }

    $readable = Test-GhReadable
    if (-not $readable -and $findings.Count -eq 0) { return [pscustomobject]@{ State = 'NoCredentials' } }

    $unreadable = [System.Collections.Generic.List[string]]::new()
    $checked = 0
    if ($readable) {
        foreach ($key in ($map.Keys | Sort-Object)) {
            $body = Get-IssueBody $key
            if ($null -eq $body) {
                $unreadable.Add($key)
                continue
            }
            $checked++
            foreach ($missing in (Get-MissingBackEdge -Key $key -Body $body -Adrs $map[$key])) { $findings.Add($missing) }
        }
    }

    $state = Get-BackEdgeState -FindingCount $findings.Count -Checked $checked -UnreadableCount $unreadable.Count
    return [pscustomobject]@{ State = $state; Findings = $findings.ToArray(); Unreadable = $unreadable.ToArray(); Checked = $checked }
}

function Show-StoryBackEdgeResult {
    param([Parameter(Mandatory)][object]$Result)

    switch ($Result.State) {
        'NoBase' {
            Write-Host "Story back-edges could not be checked: CHANGED_FILES is set, but the lines of the change cannot be told ($($Result.Reason))."
            Write-Host 'FIX: Fetch the target branch with full history (for example fetch-depth: 0 in the checkout step), then run the gate again.'
            return 2
        }
        'NoChange' {
            Write-Host 'Story back-edges: not applicable, there is no merge base, so the lines of the change cannot be told and no ADR is read.'
            return 3
        }
        'NoAnchors' {
            Write-Host 'Story back-edges: not applicable, the change adds or changes no story: line of an ADR; nothing to check.'
            return 3
        }
        'NoCredentials' {
            Write-Host 'Story back-edges: not applicable, this is not GitHub Actions with a GH_TOKEN, or gh is missing (advisory, runs in CI with the token).'
            return 3
        }
        'Findings' {
            Write-Host "Story back-edge advisories (repo-to-issue backlinks; see the artifact-graph page of the ai-sdlc-handbook skill):"
            foreach ($f in $Result.Findings) { Write-Host "  $f" }
            if ($Result.Unreadable.Count -gt 0) {
                Write-Host ("  plus {0} issue body(ies) that could not be read at all: {1}" -f $Result.Unreadable.Count, (($Result.Unreadable | Select-Object -First 5) -join ', '))
            }
            Write-Host "FIX: Add the ADR backlink to each issue named above through write-story in update mode, in the Decisions and ADRs section of its body. Quote the story key in ADR front matter."
            Write-Host ("Checked {0} issue body(ies); {1} advisory finding(s); {2} could not be read." -f $Result.Checked, $Result.Findings.Count, $Result.Unreadable.Count)
            return 1
        }
        'NoneReadable' {
            Write-Host ("Story back-edges could not be checked: not one of the {0} anchored issue body(ies) could be read from GitHub." -f $Result.Unreadable.Count)
            Write-Host "  Every one failing the same way points at the GH_TOKEN of the workflow or its read access to issues rather than at the issues, and nothing was verified."
            Write-Host ("  issues: {0}" -f (($Result.Unreadable | Select-Object -First 10) -join ', '))
            Write-Host 'FIX: Give the workflow a GH_TOKEN with read access to the issues of the tracker repository, then run the gate again.'
            return 2
        }
        'PartlyReadable' {
            Write-Host ("Story back-edges partly checked: {0} issue body(ies) reference their anchoring ADR(s), and {1} could not be read from GitHub ({2})." -f $Result.Checked, $Result.Unreadable.Count, (($Result.Unreadable | Select-Object -First 5) -join ', '))
            Write-Host 'FIX: Give the workflow a GH_TOKEN with read access to the issues of the tracker repository, then run the gate again.'
            return 2
        }
        default {
            Write-Host ("Story back-edges OK: {0} issue body(ies) each reference their anchoring ADR(s)." -f $Result.Checked)
            return 0
        }
    }
}

if (-not $env:PESTER_STORY_BACK_EDGES) { exit (Show-StoryBackEdgeResult -Result (Get-StoryBackEdgeResult)) }
