#Requires -Version 7
<#
.SYNOPSIS
    Gate: a pull request stays at or below the size in changed lines that its repository sets.
.DESCRIPTION
    A big pull request is hard to review well, and a reviewer misses more in it. This gate warns when a
    change is bigger than the limit, so the author can split the story before review starts.

    The size is the number of changed lines: the lines added plus the lines removed in the commits since
    the merge base with the target branch. An edit that is not committed does not count. A moved file
    counts only by what changed in it. The files that apm.lock.yaml at the base lists under
    deployed_files do not count, because the install wrote them (Get-AiSdlcInstalledPath in
    ChangedFiles.psm1).

    The limit and the exclude patterns come from aisdlc.json:
      pullRequest.sizeLimit   a whole number above 0. With no value, the gate does not check.
      pullRequest.sizeExclude a list of path globs, such as docs/** or **/*.Tests.ps1. A file that one
                              of them matches does not count (Test-AiSdlcPathGlob in ChangedFiles.psm1).
    Both are read from aisdlc.json at the merge base, never from the working tree, so a change cannot
    raise its own limit or leave out its own files. A change that adds or changes the setting is
    measured against the setting of the base.

    A file that git sees as binary has no line count. When no pattern leaves it out, it is named as not
    measured, so a .gitattributes mark cannot hide the size of a text file.

    It fails closed. Exit codes follow ADR 0019: 0 the change is at or below the limit, 1 the change is
    above the limit, 2 the change or the setting could not be read, the setting is not valid, or a binary
    file was not measured, so the size is not known, 3 aisdlc.json at the base sets no limit, so nothing
    was checked. When the measured lines alone are above the limit, it exits 1 even with a binary file
    not measured: the size can only be bigger, so the finding is certain. It still names that file.
.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script.
.PARAMETER BaseRef
    The ref the change is measured against. Defaults to origin/ plus the pull request target branch
    (PR_TARGET_BRANCH), or origin/<github.trunk> from aisdlc.json when there is none.
.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Check-PrSize.ps1
.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Check-PrSize.ps1 -BaseRef origin/main
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$BaseRef
)

Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ChangedFiles.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$ErrorActionPreference = 'Stop'

function Write-NotChecked {
    param([string]$Reason, [string]$Fix)
    Write-Host "Pull request size: $Reason, so NOTHING WAS CHECKED." -ForegroundColor Yellow
    Write-Host "FIX: $Fix" -ForegroundColor Yellow
    exit 2
}

function Read-BaseSetting {
    param([string]$Base)
    $listed = & git -C $RepoRoot ls-tree --name-only $Base -- aisdlc.json 2>$null
    if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ Error = "git cannot read aisdlc.json at $Base"; Values = $null } }
    if (-not $listed) { return [pscustomobject]@{ Error = $null; Values = $null } }
    $text = & git -C $RepoRoot show "${Base}:aisdlc.json" 2>$null
    if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ Error = "git cannot read aisdlc.json at $Base"; Values = $null } }
    try {
        $values = (@($text) -join "`n") | ConvertFrom-Json -AsHashtable
    }
    catch {
        return [pscustomobject]@{ Error = "aisdlc.json at $Base is not valid JSON"; Values = $null }
    }
    if ($values -isnot [System.Collections.IDictionary]) { return [pscustomobject]@{ Error = "aisdlc.json at $Base is not a JSON object"; Values = $null } }
    return [pscustomobject]@{ Error = $null; Values = $values }
}

function Get-NumStat {
    param([string]$Base)
    # -z keeps a path with a tab or a quote whole; a rename adds two more tokens for the old and new path.
    $raw = & git -C $RepoRoot -c core.quotepath=off diff --numstat -z -M --no-color --no-ext-diff $Base HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $tokens = @((@($raw) -join "`n") -split "`0")
    $rows = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $token = $tokens[$i].TrimStart("`n")
        if (-not $token) { continue }
        $parts = $token -split "`t", 3
        if ($parts.Count -lt 3) { return $null }
        $path = $parts[2]
        if (-not $path) {
            if ($i + 2 -ge $tokens.Count) { return $null }
            $path = $tokens[$i + 2]
            $i += 2
        }
        $binary = $parts[0] -eq '-' -or $parts[1] -eq '-'
        $rows.Add([pscustomobject]@{
                Path    = $path.Replace('\', '/')
                Binary  = $binary
                Added   = if ($binary) { 0 } else { [int]$parts[0] }
                Removed = if ($binary) { 0 } else { [int]$parts[1] }
            })
    }
    return , $rows.ToArray()
}

# The pull request target branch, when the shared action sets it, wins over the trunk of aisdlc.json.
if (-not $BaseRef -and -not $env:PR_TARGET_BRANCH) {
    try { $BaseRef = Get-AiSdlcMainBranch -RepoRoot $RepoRoot }
    catch { Write-NotChecked -Reason "aisdlc.json could not be read ($($_.Exception.Message))" -Fix 'Make aisdlc.json valid JSON, then run this check again.' }
}

$change = Get-AiSdlcChange -RepoRoot $RepoRoot -BaseRef $BaseRef
if (-not $change.Readable -or -not $change.Base) {
    $reason = if ($change.Reason) { $change.Reason } else { 'there is no merge base with the target branch' }
    Write-NotChecked -Reason "the change could not be read ($reason)" -Fix 'Fetch the target branch (git fetch origin <branch>), or pass -BaseRef with a ref that exists, then run this check again.'
}

$setting = Read-BaseSetting -Base $change.Base
if ($setting.Error) {
    Write-NotChecked -Reason $setting.Error -Fix 'Fix aisdlc.json on the target branch, or fetch it again, then run this check again.'
}
$pullRequest = if ($setting.Values) { $setting.Values['pullRequest'] } else { $null }
if ($null -ne $pullRequest -and $pullRequest -isnot [System.Collections.IDictionary]) {
    Write-NotChecked -Reason 'pullRequest in aisdlc.json at the base is not a JSON object' -Fix 'Make pullRequest an object with sizeLimit and sizeExclude, on the target branch.'
}
$limit = if ($pullRequest) { $pullRequest['sizeLimit'] } else { $null }
if ($null -eq $limit) {
    Write-Host 'Pull request size: NOT CHECKED, because aisdlc.json on the target branch sets no pullRequest.sizeLimit. Set it there to get a warning on a pull request that is too big.'
    exit 3
}
if (-not ($limit -is [int] -or $limit -is [long]) -or $limit -le 0) {
    Write-NotChecked -Reason "pullRequest.sizeLimit in aisdlc.json at the base is '$limit', which is not a whole number above 0" -Fix 'Set pullRequest.sizeLimit to a whole number of changed lines, such as 400, on the target branch.'
}
$exclude = @()
if ($pullRequest.Contains('sizeExclude') -and $null -ne $pullRequest['sizeExclude']) {
    $value = $pullRequest['sizeExclude']
    if ($value -isnot [System.Collections.IList] -or @($value | Where-Object { $_ -isnot [string] }).Count -gt 0) {
        Write-NotChecked -Reason 'pullRequest.sizeExclude in aisdlc.json at the base is not a list of path patterns' -Fix 'Set pullRequest.sizeExclude to a list of strings, such as ["docs/**", "**/*.Tests.ps1"], on the target branch.'
    }
    $exclude = @($value)
}

$installed = Get-AiSdlcInstalledPath -RepoRoot $RepoRoot -Base $change.Base
if (-not $installed.Readable) {
    Write-NotChecked -Reason "the list of installed files could not be read ($($installed.Reason))" -Fix 'Fetch the target branch (git fetch origin <branch>), or pass -BaseRef with a commit that exists, then run this check again.'
}

$rows = Get-NumStat -Base $change.Base
if ($null -eq $rows) {
    Write-NotChecked -Reason "git could not count the changed lines since $($change.Base)" -Fix 'Run the check inside the git clone of the change, with the target branch fetched, then run it again.'
}

$counted = [System.Collections.Generic.List[object]]::new()
$unmeasured = [System.Collections.Generic.List[string]]::new()
$leftOut = 0
foreach ($row in $rows) {
    if ($installed.Paths.Contains($row.Path) -or ($exclude.Count -gt 0 -and (Test-AiSdlcPathGlob -Path $row.Path -Glob $exclude))) {
        $leftOut++
        continue
    }
    if ($row.Binary) { $unmeasured.Add($row.Path); continue }
    $counted.Add($row)
}
$added = [int](($counted | Measure-Object -Property Added -Sum).Sum)
$removed = [int](($counted | Measure-Object -Property Removed -Sum).Sum)
$size = $added + $removed
$summary = "{0} changed lines ({1} added, {2} removed) in {3} file(s), {4} file(s) left out by pullRequest.sizeExclude or as installed" -f $size, $added, $removed, $counted.Count, $leftOut

if ($size -gt $limit) {
    Write-Host ("Pull request size: the change has {0}, above the limit of {1} that aisdlc.json sets in pullRequest.sizeLimit. A pull request this big is hard to review well." -f $summary, $limit) -ForegroundColor Yellow
    Write-Host 'FIX: Split the story into smaller stories, each with its own pull request. Or say in the pull request why it cannot be split.' -ForegroundColor Yellow
    foreach ($row in @($counted | Sort-Object { $_.Added + $_.Removed } -Descending | Select-Object -First 10)) {
        # Two leading spaces keep a path that starts with '::' from reading as a workflow command.
        Write-Host ("  {0}  +{1} -{2}" -f $row.Path, $row.Added, $row.Removed)
    }
}
if ($unmeasured.Count -gt 0) {
    Write-Host 'Pull request size: git sees these file(s) as binary, so their size was NOT MEASURED:' -ForegroundColor Yellow
    foreach ($path in $unmeasured) { Write-Host "  $path" }
    Write-Host 'FIX: Add a pattern for each real binary file, such as **/*.png, to pullRequest.sizeExclude in aisdlc.json. A text file that .gitattributes marks as binary is counted only when that mark is removed.' -ForegroundColor Yellow
}
if ($size -gt $limit) { exit 1 }
if ($unmeasured.Count -gt 0) { exit 2 }

Write-Host ("Pull request size OK: {0}, at or below the limit of {1}." -f $summary, $limit)
exit 0
