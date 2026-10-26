#Requires -Version 7
<#
.SYNOPSIS
    CI gate: a pull request must be anchored to a dev-active GitHub issue, and a domain-model change must be
    governed by an ADR. The headless form of the check-pr-contract skill.

.DESCRIPTION
    Two checks, applied to a pull request:
      1. The PR's story key (#42, or owner/repo#42 for another repository) resolves to a GitHub issue that is
         dev-active: the issue carries the refined label (tracker.refinedLabel in aisdlc.json, default
         "refined"). A closed issue counts too: work can follow a story after it closed, such as an
         update to an AI.SDLC release whose issue closed at the release. The key is taken from the first of five places that carries one: the key passed
         explicitly, the source branch name (our branch convention, 42-short-name), the PR title, the PR body,
         then the issues the PR closes (its closing issue references). The later places let a branch that
         was cut before its story still name the story, without renaming the branch or reopening the PR.
         A key of another repository counts only when that repository is in tracker.acceptedRepositories.
         Its issue is read from that repository and must be dev-active in the same way. A key of any other
         repository fails, because the gate would otherwise accept an issue nobody here tracks. The update
         pull request that takes an AI.SDLC release is the case this is for: it names the release issue of AI.SDLC.
      2. If the PR changes domain-model files (tracker.dataModelPatterns in aisdlc.json), a governing ADR
         exists: an ADR in paths.adrFolder whose front-matter `story:` matches the PR's story key. A new ADR
         added in the same PR counts only when its story matches; merely touching some unrelated ADR file does
         not. This half is repo-side and needs no GitHub read.

    NEVER PASSES BLIND. If a story key is present but the issue cannot be read (gh is missing, the token is
    missing, or the repository cannot be reached), the gate exits 2: it could not check. The workflow shows
    that as a warning, never as a pass. An issue that does not exist is exit 1. It is a NO-OP only when there
    is no PR context at all (no story key, source branch, title, body or PR number), so a normal local
    `Invoke-LocalGates` run does not trip it; the live local check is the check-pr-contract skill.

    The issue is read with the GitHub CLI: `gh issue view <n> -R <repository> --json number,state,labels,url`.
    In GitHub Actions, gh reads the token from GH_TOKEN (the composite action sets it to github.token). The
    issue repository is the accepted repository in the key, else tracker.repository, else github.repository,
    else the origin remote of the repository.

.PARAMETER RepoRoot
    Repository root containing the ADR folder. Defaults to the folder that holds aisdlc.json, found from this script.

.PARAMETER StoryKey
    The story key (#42 or owner/repo#42; a bare number is read as #<n>). If omitted, derived from the other sources.

.PARAMETER SourceBranch
    The PR source branch (e.g. refs/heads/42-short-name or 42). The story key is the number it starts with.

.PARAMETER PrTitle
    The pull request title. Read for a story key when the branch name carries none. The workflow fills it
    from the pull request event; it is empty locally, where there is no pull request.

.PARAMETER PrDescription
    The pull request body. Read for a story key after the title, for example "Fixes #42".

.PARAMETER PrNumber
    The pull request number. When no other place carries a key, the issues the PR closes are read from it.

.PARAMETER ChangedFiles
    Newline-separated list of changed file paths (the PR diff). Used for the domain-model -> ADR check.

.PARAMETER GhCommand
    The GitHub CLI command. Defaults to gh.

.PARAMETER GhToken
    The token gh uses in CI. Defaults to the GH_TOKEN environment variable.

.PARAMETER InCi
    True when the gate runs in GitHub Actions. Defaults to GITHUB_ACTIONS being "true". In CI a missing
    GH_TOKEN means the issue cannot be read, so the gate exits 2.

.PARAMETER IssueForTest
    Test seam only: a hashtable standing in for the issue (keys: number, state, labels, url). When set, gh is
    not called. Used by the Pester test so it runs without network; never set in CI.

.PARAMETER IssueErrorForTest
    Test seam only: the error text gh would print when the issue read fails. When set, gh is not called.

.PARAMETER ClosingIssuesForTest
    Test seam only: the issue URLs or keys the pull request closes. When set, gh is not called for them.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$StoryKey = $env:PR_STORY_KEY,
    [string]$SourceBranch = $env:PR_SOURCE_BRANCH,
    [string]$PrTitle = $env:PR_TITLE,
    [string]$PrDescription = $env:PR_DESCRIPTION,
    [string]$PrNumber = $env:PR_ID,
    [string]$ChangedFiles = $env:CHANGED_FILES,
    [string]$GhCommand = 'gh',
    [string]$GhToken = $env:GH_TOKEN,
    [bool]$InCi = ($env:GITHUB_ACTIONS -eq 'true'),
    [hashtable]$IssueForTest,
    [string]$IssueErrorForTest,
    [string[]]$ClosingIssuesForTest
)

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

$ErrorActionPreference = 'Stop'

$aiSdlc = Get-AiSdlcConfig -RepoRoot $RepoRoot
$tracker = $aiSdlc.tracker
$refinedLabel = if ($tracker -and $tracker.refinedLabel) { [string]$tracker.refinedLabel } else { 'refined' }
# Domain-model files: a change here is a data-model change that must be governed by an ADR.
$modelPatterns = @($tracker.dataModelPatterns | Where-Object { $_ })

function Fail([string]$msg) {
    Write-Output "::error::$msg"
    Write-Output "FIX: Put the issue key (#NNN) in the branch name (42-short-name), the pull request title, or its body (Fixes #42), and make sure that issue is labelled '$refinedLabel'. A key of another repository (owner/repo#NNN) needs that repository in tracker.acceptedRepositories. A data-model change also needs an ADR whose story matches."
    exit 1
}
function Unknown([string]$msg) { Write-Output "::warning::$msg"; exit 2 }
function Ok([string]$msg) { Write-Output $msg; exit 0 }

function Get-TrackerRepository {
    foreach ($value in @($tracker.repository, $aiSdlc.github.repository)) {
        if ($value) { return [string]$value }
    }
    $url = [string](git -C $RepoRoot remote get-url origin 2>$null)
    $m = [regex]::Match($url, '[:/](?<repo>[\w.-]+/[\w.-]+?)(?:\.git)?/?$')
    if ($m.Success) { return $m.Groups['repo'].Value }
    return ''
}
$trackerRepository = Get-TrackerRepository
$acceptedRepositories = @($tracker.acceptedRepositories | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() })

function ConvertTo-LocalKey([string]$key) {
    $m = [regex]::Match($key, '^(?<repo>[\w.-]+/[\w.-]+)#(?<n>\d+)$')
    if ($m.Success -and $trackerRepository -and $m.Groups['repo'].Value -ieq $trackerRepository) { return "#$($m.Groups['n'].Value)" }
    return $key
}

function Get-TextKey([string]$text) {
    if (-not $text) { return $null }
    $keyArgs = @{ Text = $text }
    if ((Get-Command Get-AiSdlcStoryKey).Parameters.ContainsKey('RepoRoot')) { $keyArgs['RepoRoot'] = $RepoRoot }
    $key = Get-AiSdlcStoryKey @keyArgs
    if ($key) { return ConvertTo-LocalKey $key }
    return $null
}

function Get-BranchKey([string]$branch) {
    if (-not $branch) { return $null }
    $key = Get-AiSdlcBranchStoryKey -Branch $branch
    if ($key) { return ConvertTo-LocalKey $key }
    return $null
}

function Test-GhReadable {
    if (-not (Get-Command -Name $GhCommand -ErrorAction SilentlyContinue)) {
        return "the GitHub CLI ($GhCommand) is not installed"
    }
    if ($InCi -and -not $GhToken) {
        return 'GH_TOKEN is not set in the workflow, so gh has no credentials'
    }
    return $null
}

function Invoke-Gh([string[]]$arguments) {
    $output = @(& $GhCommand @arguments 2>&1)
    $code = $LASTEXITCODE
    $stdout = ($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    $stderr = ($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join "`n"
    return [pscustomobject]@{ Code = $code; Out = $stdout; Err = $stderr }
}

function Split-IssueKey([string]$key) {
    $m = [regex]::Match($key, '^(?:(?<repo>[\w.-]+/[\w.-]+))?#(?<n>\d+)$')
    $repo = if ($m.Groups['repo'].Success) { $m.Groups['repo'].Value } else { $trackerRepository }
    return [pscustomobject]@{ Number = $m.Groups['n'].Value; Repository = $repo }
}

function Get-ClosingIssueKeys {
    if ($null -ne $ClosingIssuesForTest) { $refs = $ClosingIssuesForTest }
    else {
        if (-not $PrNumber -or (Test-GhReadable)) { return @() }
        $repoArgs = if ($aiSdlc.github.repository) { @('-R', [string]$aiSdlc.github.repository) } else { @() }
        $r = Invoke-Gh (@('pr', 'view', $PrNumber) + $repoArgs + @('--json', 'closingIssuesReferences'))
        if ($r.Code -ne 0) { return @() }
        $refs = @(($r.Out | ConvertFrom-Json).closingIssuesReferences | ForEach-Object { $_.url })
    }
    $keys = foreach ($ref in $refs) {
        $m = [regex]::Match([string]$ref, 'github\.com/(?<repo>[^/]+/[^/]+)/issues/(?<n>\d+)')
        if ($m.Success) { ConvertTo-LocalKey "$($m.Groups['repo'].Value)#$($m.Groups['n'].Value)" }
        else { Get-TextKey ([string]$ref) }
    }
    return @($keys | Where-Object { $_ })
}

function Resolve-StoryKey {
    $sources = @(
        @{ Name = 'the story key passed in'; Key = { if ($StoryKey -match '^\s*#?(\d+)\s*$') { "#$($Matches[1])" } else { Get-TextKey $StoryKey } } },
        @{ Name = 'the PR source branch'; Key = { Get-BranchKey $SourceBranch } },
        @{ Name = 'the PR title'; Key = { Get-TextKey $PrTitle } },
        @{ Name = 'the PR body'; Key = { Get-TextKey $PrDescription } },
        @{ Name = 'the issues the PR closes'; Key = { Get-ClosingIssueKeys | Select-Object -First 1 } }
    )
    foreach ($source in $sources) {
        $key = & $source.Key
        if ($key) { return [pscustomobject]@{ Key = $key; Source = $source.Name } }
    }
    return $null
}

function Get-Issue([string]$key, [string]$from) {
    if ($IssueForTest) { return $IssueForTest }
    $errorText = $IssueErrorForTest
    if (-not $errorText) {
        $blocker = Test-GhReadable
        if ($blocker) {
            Unknown "Issue $key, read from $from, could not be checked at all: $blocker. Install gh and give it a token (GH_TOKEN in the workflow); no change to this pull request can fix it."
        }
        $target = Split-IssueKey $key
        $repoArgs = if ($target.Repository) { @('-R', $target.Repository) } else { @() }
        $r = Invoke-Gh (@('issue', 'view', $target.Number) + $repoArgs + @('--json', 'number,state,labels,url'))
        if ($r.Code -eq 0) {
            $issue = $r.Out | ConvertFrom-Json
            return @{ number = $issue.number; state = $issue.state; url = $issue.url; labels = @($issue.labels | ForEach-Object { $_.name }) }
        }
        $errorText = "$($r.Err) $($r.Out)".Trim()
    }
    if ($errorText -match 'Could not resolve to an issue or pull request') { return $null }
    if ($errorText -match 'Could not resolve to a Repository') {
        Unknown "Issue $key, read from $from, could not be read: GitHub cannot resolve the repository with this token. The repository is missing or the token has no read access, so this is no permission rather than no issue. Give the token read access to issues; no change to this pull request can fix it."
    }
    Unknown "Issue $key, read from $from, could not be read: $errorText. The issue could not be checked, so this is neither a pass nor a violation."
}

function Get-AdrStory([string]$frontMatter) {
    $m = [regex]::Match($frontMatter, '(?m)^\s*story:[ \t]*(?<value>.*?)\s*$')
    if (-not $m.Success) { return $null }
    $story = ConvertTo-AiSdlcStoryKey -Value $m.Groups['value'].Value -RepoRoot $RepoRoot
    if ($story.Status -eq 'ok') { $story.Key = ConvertTo-LocalKey $story.Key }
    return $story
}

function Test-TouchesModel([string]$changed) {
    foreach ($line in ($changed -split '\r?\n')) {
        $f = $line.Trim().Replace('\', '/')
        if (-not $f) { continue }
        foreach ($p in $modelPatterns) { if ($f -match $p) { return $true } }
    }
    return $false
}

function Find-AdrGovernance([string]$key) {
    # An ADR governs this change only if its front-matter story matches the key. A new ADR in this PR is
    # present on disk in the checkout, so this scan finds it too; merely touching any ADR file is not
    # enough (that let an unrelated ADR edit satisfy the gate).
    $traps = [System.Collections.Generic.List[string]]::new()
    $invalid = [System.Collections.Generic.List[string]]::new()
    $adrDir = Join-Path $RepoRoot $aiSdlc.paths.adrFolder
    if (Test-Path $adrDir) {
        foreach ($adr in (Get-ChildItem -Path $adrDir -Filter *.md -File)) {
            $text = Get-Content -LiteralPath $adr.FullName -Raw
            $fm = [regex]::Match($text, '\A\s*---\r?\n(.*?)\r?\n---\r?\n', 'Singleline')
            if (-not $fm.Success) { continue }
            $story = Get-AdrStory $fm.Groups[1].Value
            if (-not $story) { continue }
            if ($story.Status -eq 'empty') { $traps.Add($adr.Name); continue }
            if ($story.Status -eq 'invalid') { $invalid.Add("$($adr.Name) ('$($story.Value)')"); continue }
            if ($story.Key -eq $key) { return [pscustomobject]@{ Governed = $true; Traps = @(); Invalid = @() } }
        }
    }
    return [pscustomobject]@{ Governed = $false; Traps = $traps.ToArray(); Invalid = $invalid.ToArray() }
}

function Invoke-PrStoryContractGate {
    $found = Resolve-StoryKey

    if (-not $found) {
        if (-not $StoryKey -and -not $SourceBranch -and -not $PrTitle -and -not $PrDescription -and -not $PrNumber) {
            Ok "PR-story contract gate: no PR context (no story key, source branch, title, body or PR number); no-op."
        }
        Fail "No story key (#NNN) found. Looked in the story key passed in, the PR source branch '$SourceBranch', the PR title, the PR body and the issues the PR closes, in that order. Name the branch for its issue (e.g. 1234-short-name), or write the key in the PR title or body (Fixes #1234)."
    }

    $key = $found.Key
    $from = $found.Source

    $target = Split-IssueKey $key
    $otherRepository = $key -match '^[\w.-]+/[\w.-]+#'
    if ($otherRepository -and -not ($acceptedRepositories | Where-Object { $_ -ieq $target.Repository })) {
        $accepted = if ($acceptedRepositories) { $acceptedRepositories -join ', ' } else { 'none' }
        Fail "Issue $key, read from $from, belongs to $($target.Repository). That is not the tracker of this repository ($(if ($trackerRepository) { $trackerRepository } else { 'unknown' })), and tracker.acceptedRepositories in aisdlc.json does not list it (accepted: $accepted). Name an issue of this repository, or add $($target.Repository) to tracker.acceptedRepositories when its issues may anchor a pull request here."
    }
    if ($otherRepository) { $from = "$from, in the accepted repository $($target.Repository)" }

    $issue = Get-Issue $key $from
    if ($null -eq $issue) {
        Fail "Issue $key, read from $from, does not exist. GitHub answered that no issue or pull request has that number, so the key names nothing. Correct the key in the branch name, the PR title or the PR body."
    }

    if ([string]$issue.url -match '/pull/\d+') {
        Fail "$key, read from $from, is a pull request, not an issue. Reference the issue the work belongs to."
    }
    $labels = @($issue.labels | ForEach-Object { [string]$_ })
    if (-not ($labels | Where-Object { $_ -ieq $refinedLabel })) {
        Fail "Issue $key (read from $from) does not carry the '$refinedLabel' label, so it is not dev-active. A person adds that label when the issue is refined; or reference the correct issue."
    }

    if ($ChangedFiles -and (Test-TouchesModel $ChangedFiles)) {
        $governance = Find-AdrGovernance $key
        if (-not $governance.Governed) {
            if ($governance.Traps.Count -gt 0) {
                Write-Output ("::error::ADR front matter with an empty 'story:' value: {0}. An unquoted # starts a YAML comment, so the key is lost." -f ($governance.Traps -join ', '))
                Write-Output "FIX: Quote the key in the ADR front matter: story: `"$key`"."
            }
            if ($governance.Invalid.Count -gt 0) {
                Write-Output ("::error::ADR front matter with a 'story:' value that is not a story key: {0}." -f ($governance.Invalid -join ', '))
                Write-Output "FIX: Write the key as #<number> or owner/repo#<number>, in quotes: story: `"$key`"."
            }
            Fail "This PR changes domain-model files (tracker.dataModelPatterns in aisdlc.json) but no governing ADR was found: no ADR under $($aiSdlc.paths.adrFolder)/ has front-matter 'story: `"$key`"' (a new ADR added in this PR counts only when its story matches). A data-model change requires an ADR (constitution C01)."
        }
        Ok "PR-story contract OK: $key (read from $from, '$refinedLabel', dev-active); domain-model change governed by an ADR."
    }

    Ok "PR-story contract OK: $key (read from $from) is dev-active ('$refinedLabel'); no domain-model change requiring an ADR."
}

if (-not $env:PESTER_PR_STORY_CONTRACT) { Invoke-PrStoryContractGate }
