#Requires -Version 7
<#
.SYNOPSIS
    Gate: a public repository holds no term from the private term list, and the gate never prints one.

.DESCRIPTION
    Some names must never reach a public repository: a former employer, a customer, a server or a
    person. The list of those names is private itself, so it is kept outside the repository. This gate
    reads the list and checks everything a public pull request publishes:

      - every tracked file (git ls-files) and every staged new file, binary files skipped;
      - the commit messages of <BaseRef>..HEAD;
      - the branch name (PR_SOURCE_BRANCH, else the current branch);
      - the pull request title and description (PR_TITLE, PR_DESCRIPTION).

    A file name that matches is a finding too. Its name is then hidden in the output.

    The list is a text file with one regular expression per line, matched case-sensitively unless the
    line starts with (?i). Blank lines and lines that start with # are skipped. The first list found
    is used:

      1. -TermsFile;
      2. the content of the environment variable AISDLC_PRIVATE_TERMS (in CI, from a secret);
      3. paths.privateTermsFile in aisdlc.json;
      4. <paths.knowledgeRoot>/ai-sdlc/private-terms.txt.

    The output never holds the matched text or the rule text. A finding reads "<file>:<line>  rule <n>",
    where n is the line number of the rule in the list. The owner of the list looks the rule up.

    The gate runs only when "visibility" in aisdlc.json is "public", or with -Force. A private
    repository passes with "skipped".

    In GitHub Actions the gate also reads the event file of the run (GITHUB_EVENT_PATH), but only when
    it checks the checked-out repository (GITHUB_WORKSPACE). When GitHub says that repository is public:

      - it is checked even when aisdlc.json says private, and that wrong setting is a failure;
      - no list is a failure, because a public repository must never pass unchecked;
      - a pull request from a fork gets no secrets, so there no list stays exit 2 with a FIX line.

    Exit codes follow the gate contract: 0 nothing found or skipped, 1 a finding, 2 could not check
    (no list, or a rule that is not a valid regular expression). With -Required, no list exits 1.

.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script.

.PARAMETER TermsFile
    The private term list to use instead of the other sources.

.PARAMETER BaseRef
    The commits after this ref are checked. Defaults to origin/main when it exists; without it, no
    commit message is checked.

.PARAMETER Force
    Check a repository whose visibility is private too.

.PARAMETER Required
    Fail (exit 1) instead of exit 2 when no list is found.

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Check-PrivateTerms.ps1

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Check-PrivateTerms.ps1 -Force -TermsFile ../Knowledge/ai-sdlc/private-terms.txt
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$TermsFile,
    [string]$BaseRef,
    [switch]$Force,
    [switch]$Required
)

Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$ErrorActionPreference = 'Stop'

$config = Get-AiSdlcConfig -RepoRoot $RepoRoot

function Get-GitHubRun {
    # The event file describes the repository of the workflow run, so it speaks only for the checkout
    # at GITHUB_WORKSPACE. A test consumer inside the AI.SDLC run must not take AI.SDLC's visibility.
    if ($env:GITHUB_ACTIONS -ne 'true' -or -not $env:GITHUB_EVENT_PATH -or -not $env:GITHUB_WORKSPACE) { return $null }
    if (-not (Test-Path -LiteralPath $env:GITHUB_EVENT_PATH -PathType Leaf)) { return $null }
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $workspace = [IO.Path]::GetFullPath($env:GITHUB_WORKSPACE).TrimEnd('\', '/')
    if (-not [string]::Equals($workspace, [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/'), $comparison)) { return $null }
    try { $payload = Get-Content -LiteralPath $env:GITHUB_EVENT_PATH -Raw | ConvertFrom-Json }
    catch { return $null }
    if ($null -eq $payload.repository -or $null -eq $payload.repository.private) { return $null }
    $fork = $false
    if ($payload.pull_request) {
        $head = $payload.pull_request.head.repo
        $fork = ($null -eq $head) -or ([string]$head.full_name -ne [string]$payload.repository.full_name)
    }
    return [pscustomobject]@{ Public = -not [bool]$payload.repository.private; Fork = $fork }
}

$run = Get-GitHubRun
$wrongVisibility = $run -and $run.Public -and $config.visibility -ne 'public'
if ($wrongVisibility) {
    Write-Host 'Private terms: GitHub says this repository is public, but visibility in aisdlc.json says it is not. The gate checks it as public.' -ForegroundColor Red
    Write-Host 'FIX: Set "visibility": "public" in aisdlc.json, so the gate runs on every machine too.' -ForegroundColor Red
}
elseif ($config.visibility -ne 'public' -and -not $Force) {
    Write-Host 'Private terms: skipped: the repository is private (visibility in aisdlc.json). -Force checks it anyway.'
    exit 0
}

function Exit-Gate([int]$Code) {
    if ($wrongVisibility) { $Code = 1 }
    exit $Code
}

function Resolve-RepoPath([string]$Value) {
    if ([IO.Path]::IsPathRooted($Value)) { return $Value }
    return [IO.Path]::GetFullPath((Join-Path $RepoRoot $Value))
}

$listText = $null
$listSource = $null
$listFile = $null
if ($TermsFile) {
    $listFile = Resolve-RepoPath $TermsFile
    if (Test-Path -LiteralPath $listFile -PathType Leaf) { $listText = Get-Content -LiteralPath $listFile -Raw; $listSource = $listFile }
}
if ($null -eq $listText -and $env:AISDLC_PRIVATE_TERMS -and $env:AISDLC_PRIVATE_TERMS.Trim()) {
    $listText = $env:AISDLC_PRIVATE_TERMS
    $listSource = 'the environment variable AISDLC_PRIVATE_TERMS'
    $listFile = $null
}
if ($null -eq $listText) {
    $candidates = @()
    if ($config.paths.privateTermsFile) { $candidates += Resolve-RepoPath $config.paths.privateTermsFile }
    if ($config.paths.knowledgeRoot) { $candidates += Resolve-RepoPath (Join-Path $config.paths.knowledgeRoot 'ai-sdlc' 'private-terms.txt') }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $listText = Get-Content -LiteralPath $candidate -Raw
            $listSource = $candidate
            $listFile = $candidate
            break
        }
    }
}

$rules = [System.Collections.Generic.List[object]]::new()
$invalid = [System.Collections.Generic.List[int]]::new()
if ($null -ne $listText) {
    $number = 0
    foreach ($line in ($listText -split '\r?\n')) {
        $number++
        $rule = $line.Trim()
        if (-not $rule -or $rule.StartsWith('#')) { continue }
        try { $rules.Add([pscustomobject]@{ Number = $number; Regex = [regex]::new($rule) }) }
        catch { $invalid.Add($number) }
    }
}

if ($rules.Count -eq 0 -and $invalid.Count -eq 0) {
    if ($run -and $run.Public -and $run.Fork -and -not $Required) {
        Write-Host 'Private terms could not be checked: this pull request comes from a fork, and GitHub passes no secrets to it.' -ForegroundColor Yellow
        Write-Host 'FIX: Before you merge, check out the branch and run Check-PrivateTerms.ps1 -Required with the private list.'
        Exit-Gate 2
    }
    Write-Host 'Private terms could not be checked: no private term list was found, or the list holds no rule.' -ForegroundColor Yellow
    Write-Host 'FIX: Put the list in <knowledgeRoot>/ai-sdlc/private-terms.txt, set paths.privateTermsFile, or pass it in AISDLC_PRIVATE_TERMS (in CI, from the secret AISDLC_PRIVATE_TERMS).'
    if ($Required -or ($run -and $run.Public)) { exit 1 }
    Exit-Gate 2
}

$findings = [System.Collections.Generic.List[string]]::new()

function Test-Text([string]$Text, [string]$Where) {
    $lineNumber = 0
    foreach ($line in ($Text -split '\r?\n')) {
        $lineNumber++
        foreach ($rule in $rules) {
            if ($rule.Regex.IsMatch($line)) { $findings.Add(("  {0}:{1}  rule {2}" -f $Where, $lineNumber, $rule.Number)) }
        }
    }
}

function Test-Name([string]$Text, [string]$Label) {
    foreach ($rule in $rules) {
        if ($rule.Regex.IsMatch($Text)) { $findings.Add(("  {0}  rule {1}" -f $Label, $rule.Number)) }
    }
}

function Test-BinaryFile([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $buffer = [byte[]]::new(8000)
        $read = $stream.Read($buffer, 0, $buffer.Length)
        return [Array]::IndexOf($buffer, [byte]0, 0, $read) -ge 0
    }
    finally { $stream.Dispose() }
}

$tracked = @(git -C $RepoRoot ls-files 2>$null) + @(git -C $RepoRoot diff --cached --name-only --diff-filter=A 2>$null)
if ($LASTEXITCODE -ne 0 -and $tracked.Count -eq 0) {
    Write-Host "Private terms could not be checked: $RepoRoot is not a git repository, so the tracked files are unknown." -ForegroundColor Yellow
    Write-Host 'FIX: Run the gate inside the git repository.'
    Exit-Gate 2
}
$tracked = @($tracked | Where-Object { $_ } | Select-Object -Unique)
$listFull = if ($listFile) { [IO.Path]::GetFullPath($listFile) } else { $null }
$checkedFiles = 0
$hidden = 0
foreach ($rel in $tracked) {
    $full = [IO.Path]::GetFullPath((Join-Path $RepoRoot $rel))
    if ($listFull -and $full -eq $listFull) { continue }
    $where = $rel
    if (@($rules | Where-Object { $_.Regex.IsMatch($rel) }).Count -gt 0) {
        $hidden++
        $where = "(file name hidden, $hidden)"
        Test-Name $rel "a tracked file name (file name hidden, $hidden)"
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
    if (Test-BinaryFile $full) { continue }
    $checkedFiles++
    $lineNumber = 0
    foreach ($line in [IO.File]::ReadLines($full)) {
        $lineNumber++
        foreach ($rule in $rules) {
            if ($rule.Regex.IsMatch($line)) { $findings.Add(("  {0}:{1}  rule {2}" -f $where, $lineNumber, $rule.Number)) }
        }
    }
}

if (-not $BaseRef) {
    git -C $RepoRoot rev-parse --verify --quiet origin/main *> $null
    if ($LASTEXITCODE -eq 0) { $BaseRef = 'origin/main' }
}
$commits = 0
if ($BaseRef) {
    $log = (git -C $RepoRoot log --format='%h%x1f%B%x1e' "$BaseRef..HEAD" 2>$null) -join "`n"
    foreach ($record in ($log -split [char]0x1e)) {
        $parts = $record.Trim() -split [char]0x1f, 2
        if ($parts.Count -lt 2 -or -not $parts[0]) { continue }
        $commits++
        Test-Text $parts[1] "commit $($parts[0].Trim())"
    }
}

$branch = $env:PR_SOURCE_BRANCH
if (-not $branch) { $branch = [string](git -C $RepoRoot branch --show-current 2>$null) }
if ($branch) { Test-Name $branch.Trim() 'the branch name' }
if ($env:PR_TITLE) { Test-Name $env:PR_TITLE 'the pull request title' }
if ($env:PR_DESCRIPTION) { Test-Text $env:PR_DESCRIPTION 'the pull request description' }

if ($findings.Count -gt 0) {
    Write-Host 'Private terms: this public repository holds text from the private term list. The matched text is not printed.' -ForegroundColor Red
    foreach ($finding in $findings) { Write-Host $finding }
    foreach ($number in $invalid) { Write-Host "  rule $number is not a valid regular expression" }
    Write-Host 'FIX: Look up each rule by its number in your private list, then remove or reword the text it names. Reword a commit message or a branch name too.' -ForegroundColor Red
    Write-Host ("Found {0} finding(s) in {1} file(s), {2} commit message(s) and the pull request text." -f $findings.Count, $checkedFiles, $commits) -ForegroundColor Red
    exit 1
}

if ($invalid.Count -gt 0) {
    Write-Host 'Private terms could not be checked in full: the list holds rules that are not valid regular expressions.' -ForegroundColor Yellow
    foreach ($number in $invalid) { Write-Host "  rule $number is not a valid regular expression" }
    Write-Host 'FIX: Correct each rule by its number in the private list, so every rule can be checked.'
    Exit-Gate 2
}

Write-Host ("Private terms OK: {0} file(s), {1} commit message(s), the branch name and the pull request text checked against {2} rule(s) from {3}." -f $checkedFiles, $commits, $rules.Count, $listSource)
Exit-Gate 0
