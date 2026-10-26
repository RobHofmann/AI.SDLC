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

    ADVISORY by design: it never writes the "::error::" annotation and is wrapped by Invoke-Gate.ps1 in
    Advisory mode, so a missing backlink is a warning, not a failed build. It reads issues only in GitHub
    Actions with a GH_TOKEN, so a local run is a safe NO-OP for the issue reads and never false-alarms off
    the workflow.

.PARAMETER RepoRoot
    Repository root containing the ADR folder. Defaults to the folder that holds aisdlc.json, found from this script.

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
    [string]$GhCommand = 'gh',
    [string]$GhToken = $env:GH_TOKEN,
    [bool]$InCi = ($env:GITHUB_ACTIONS -eq 'true'),
    [hashtable]$BodiesForTest
)

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

$ErrorActionPreference = 'Stop'

$aiSdlc = Get-AiSdlcConfig -RepoRoot $RepoRoot
$excludedAdrNames = @('0000-template.md')

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
        'NoAnchors' {
            Write-Host 'Story back-edges: no graph-anchored ADRs found; nothing to check.'
            return 0
        }
        'NoCredentials' {
            Write-Host 'Story back-edges: not in GitHub Actions with a GH_TOKEN, or gh is missing; skipping (advisory, runs in CI with the token).'
            return 0
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
            return 2
        }
        'PartlyReadable' {
            Write-Host ("Story back-edges partly checked: {0} issue body(ies) reference their anchoring ADR(s), and {1} could not be read from GitHub ({2})." -f $Result.Checked, $Result.Unreadable.Count, (($Result.Unreadable | Select-Object -First 5) -join ', '))
            return 2
        }
        default {
            Write-Host ("Story back-edges OK: {0} issue body(ies) each reference their anchoring ADR(s)." -f $Result.Checked)
            return 0
        }
    }
}

if (-not $env:PESTER_STORY_BACK_EDGES) { exit (Show-StoryBackEdgeResult -Result (Get-StoryBackEdgeResult)) }
