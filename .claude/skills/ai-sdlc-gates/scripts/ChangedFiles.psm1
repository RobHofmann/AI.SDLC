#Requires -Version 7
<#
.SYNOPSIS
    One answer to "which files did this change touch", for every gate that asks.

.DESCRIPTION
    A gate that checks only what a change touched needs the list of those files. This module gives one
    list, so the gates agree. The list holds the committed changes since the base, which is the work a
    push or a pull request sends. A staged edit, an unstaged edit and a new file that is not committed
    are not counted, because they may never be pushed.

    Get-AiSdlcChange takes the first source that has an answer:
      1. -Explicit, a list the caller passes. The tests use it.
      2. The CHANGED_FILES environment variable, newline-separated repo-relative paths. The shared pull
         request action sets it from the pull request diff.
      3. git: the files that differ between the merge base of the base ref and HEAD.
    The base ref is -BaseRef when given. Otherwise it is origin/ plus PR_TARGET_BRANCH, which the shared
    pull request action sets, and without that origin/main. A gate passes the result of
    Get-AiSdlcMainBranch in AiSdlcConfig.psm1 as -BaseRef, so github.trunk in aisdlc.json names the
    trunk. The module never reads aisdlc.json itself.

    The answer says whether the change could be read. Without git, outside a repository, or with no merge
    base, Readable is false and Reason says what failed. A gate then exits 2 (could not check). It never
    treats an unreadable change as an empty one. Deleted lists the files of the list that the change
    removed. It is empty for -Explicit. With CHANGED_FILES set, git tells the deleted files by looking for
    each path in HEAD; when git cannot do that, Readable is false.

    With -IncludeWorkingTree the list also holds the files that are staged, edited or new and not
    ignored. The gate runner uses it to pick which gates a local run starts, because a local run must
    also check the work that is not committed yet. A gate that judges what a push sends does not use it.

    Get-AiSdlcChangedLine returns the lines one file gained or lost since the base, for a gate that must
    tell a change in a route from a change in a log line. It returns nothing when there is no base.

    Get-AiSdlcLineChange is for a gate that judges only the lines a change adds or changes. It returns
    Added, the numbers of the added or changed lines in the file as it is on disk, and Removed, the text
    of the removed lines. It diffs the base against the working tree, so the numbers match the file the
    gate reads, and it follows a rename, so a moved file does not count as all added. It returns null
    when there is no base. With -AssumeNew and no base, every line counts as added; a gate passes that
    only for a file the caller listed itself.

    Get-AiSdlcChangeBase reads AISDLC_CHANGE_BASE, the commit that Invoke-Preflight.ps1 sets to the last
    green pre-flight. It gives that commit only when it is a full commit hash in the history of HEAD.
    Otherwise Base is null and Reason says why, and the caller measures from the merge base. So a wrong
    or stale value checks more, never less.

    Test-AiSdlcPathGlob tells whether a repo-relative path matches one of a list of globs. A glob is a
    path from the repository root with forward slashes. A star or a question mark stays inside one
    folder, and a double star stands for any number of folders, also none. The match ignores case only
    on Windows, like the file system there.

.PARAMETER RepoRoot
    The repository root.

.PARAMETER BaseRef
    The ref the change is measured against. Overrides PR_TARGET_BRANCH and origin/main.

.PARAMETER Explicit
    Repo-relative paths, bypassing git and the environment.

.PARAMETER IncludeWorkingTree
    For Get-AiSdlcChange: also list the staged, edited and new files that git does not ignore.

.EXAMPLE
    Import-Module ./AiSdlcConfig.psm1, ./ChangedFiles.psm1
    $change = Get-AiSdlcChange -RepoRoot $RepoRoot -BaseRef (Get-AiSdlcMainBranch -RepoRoot $RepoRoot)
    if (-not $change.Readable) { Write-Host "Could not check: $($change.Reason)"; exit 2 }
#>

function ConvertTo-ChangePath {
    param([string[]]$Text)

    return @($Text | ForEach-Object { if ($_) { $_.Trim().Replace('\', '/') } } | Where-Object { $_ } | Sort-Object -Unique -CaseSensitive)
}

function Resolve-ChangeBase {
    param([string]$RepoRoot, [string]$BaseRef)

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Base = $null; Reason = 'git is not installed or not on the PATH' }
    }
    if (-not $BaseRef) {
        $target = ([string]$env:PR_TARGET_BRANCH) -replace '^refs/heads/', ''
        if (-not $target) { $target = 'main' }
        $BaseRef = "origin/$target"
    }
    $mergeBase = & git -C $RepoRoot merge-base $BaseRef HEAD 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $mergeBase) {
        $global:LASTEXITCODE = 0
        return [pscustomobject]@{ Base = $null; Reason = "no merge base between $BaseRef and HEAD" }
    }
    return [pscustomobject]@{ Base = ([string]@($mergeBase)[0]).Trim(); Reason = $null }
}

function Get-AiSdlcDeletedPath {
    param([string]$RepoRoot, [string[]]$Path)

    if (-not $Path) { return [pscustomobject]@{ Deleted = @(); Reason = $null } }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Deleted = @(); Reason = 'git is not installed or not on the PATH, so deleted files cannot be told from changed files' }
    }
    & git -C $RepoRoot rev-parse --verify --quiet 'HEAD^{commit}' *>$null
    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject]@{ Deleted = @(); Reason = 'HEAD cannot be read, so deleted files cannot be told from changed files' }
    }
    $answers = @($Path | ForEach-Object { "HEAD:$_" } | & git -C $RepoRoot cat-file --batch-check 2>$null)
    if ($LASTEXITCODE -ne 0 -or $answers.Count -ne $Path.Count) {
        return [pscustomobject]@{ Deleted = @(); Reason = 'git cat-file failed, so deleted files cannot be told from changed files' }
    }
    $deleted = @()
    for ($i = 0; $i -lt $Path.Count; $i++) { if ($answers[$i] -match ' missing$') { $deleted += $Path[$i] } }
    return [pscustomobject]@{ Deleted = $deleted; Reason = $null }
}

function Get-AiSdlcChange {
    <#
    .SYNOPSIS
        Lists the files a change touched, with the base commit, or says why it cannot.
    .PARAMETER RepoRoot
        The repository root.
    .PARAMETER BaseRef
        The ref the change is measured against.
    .PARAMETER Explicit
        Repo-relative paths, bypassing git and the environment.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$BaseRef,
        [string[]]$Explicit,
        [switch]$IncludeWorkingTree
    )

    $resolved = Resolve-ChangeBase -RepoRoot $RepoRoot -BaseRef $BaseRef

    if ($Explicit) {
        return [pscustomobject]@{ Readable = $true; Files = @(ConvertTo-ChangePath $Explicit); Deleted = @(); Base = $resolved.Base; Reason = $null }
    }
    if ($env:CHANGED_FILES) {
        $listed = @(ConvertTo-ChangePath ($env:CHANGED_FILES -split "`r?`n"))
        $found = Get-AiSdlcDeletedPath -RepoRoot $RepoRoot -Path $listed
        if ($found.Reason) {
            return [pscustomobject]@{ Readable = $false; Files = @(); Deleted = @(); Base = $resolved.Base; Reason = $found.Reason }
        }
        return [pscustomobject]@{ Readable = $true; Files = $listed; Deleted = @($found.Deleted); Base = $resolved.Base; Reason = $null }
    }
    if (-not $resolved.Base) {
        return [pscustomobject]@{ Readable = $false; Files = @(); Deleted = @(); Base = $null; Reason = $resolved.Reason }
    }

    $names = & git -C $RepoRoot -c core.quotepath=off diff --name-only $resolved.Base HEAD 2>$null
    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject]@{ Readable = $false; Files = @(); Deleted = @(); Base = $resolved.Base; Reason = "git diff against $($resolved.Base) failed" }
    }
    $deletedNames = & git -C $RepoRoot -c core.quotepath=off diff --name-only --diff-filter=D $resolved.Base HEAD 2>$null
    if ($IncludeWorkingTree) {
        $edited = @(& git -C $RepoRoot -c core.quotepath=off diff --name-only HEAD 2>$null); $editedOk = $LASTEXITCODE -eq 0
        $new = @(& git -C $RepoRoot -c core.quotepath=off ls-files --others --exclude-standard 2>$null); $newOk = $LASTEXITCODE -eq 0
        $removed = @(& git -C $RepoRoot -c core.quotepath=off diff --name-only --diff-filter=D HEAD 2>$null); $removedOk = $LASTEXITCODE -eq 0
        if (-not ($editedOk -and $newOk -and $removedOk)) {
            return [pscustomobject]@{ Readable = $false; Files = @(); Deleted = @(); Base = $resolved.Base; Reason = 'git cannot list the staged, edited or new files of the working tree' }
        }
        $names = @($names) + $edited + $new
        $deletedNames = @($deletedNames) + $removed
    }
    return [pscustomobject]@{ Readable = $true; Files = @(ConvertTo-ChangePath @($names)); Deleted = @(ConvertTo-ChangePath @($deletedNames)); Base = $resolved.Base; Reason = $null }
}

function ConvertTo-GlobRegex {
    param([string]$Glob)

    $parts = ($Glob.Trim().Replace('\', '/').Trim('/')) -split '/'
    $out = [System.Text.StringBuilder]::new('^')
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $last = $i -eq $parts.Count - 1
        if ($parts[$i] -eq '**') {
            [void]$out.Append($(if ($last) { '.*' } else { '(?:[^/]+/)*' }))
            continue
        }
        $segment = [regex]::Escape($parts[$i]).Replace('\*', '[^/]*').Replace('\?', '[^/]')
        [void]$out.Append($segment)
        if (-not $last) { [void]$out.Append('/') }
    }
    [void]$out.Append('$')
    return $out.ToString()
}

function Test-AiSdlcPathGlob {
    <#
    .SYNOPSIS
        True when a repo-relative path matches one of the globs.
    .PARAMETER Path
        The repo-relative path.
    .PARAMETER Glob
        Path globs from the repository root, such as **/*.md.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Glob
    )

    $normal = $Path.Trim().Replace('\', '/').TrimStart('/')
    $caseRule = if ($IsWindows) { '(?i)' } else { '' }
    foreach ($g in $Glob) {
        if (-not $g) { continue }
        if ($normal -cmatch ($caseRule + (ConvertTo-GlobRegex -Glob $g))) { return $true }
    }
    return $false
}

function Get-AiSdlcChangedLine {
    <#
    .SYNOPSIS
        The lines one file gained or lost since the base commit, or null without a base.
    .PARAMETER RepoRoot
        The repository root.
    .PARAMETER Base
        The base commit that Get-AiSdlcChange returned.
    .PARAMETER Path
        The repo-relative path of one file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$Base,
        [Parameter(Mandatory)][string]$Path
    )

    if (-not $Base) { return $null }
    $diff = & git -C $RepoRoot -c core.quotepath=off diff --unified=0 --no-color --no-ext-diff $Base HEAD -- ":(literal)$Path" 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $lines = foreach ($line in @($diff)) {
        $text = [string]$line
        if ($text.StartsWith('+++') -or $text.StartsWith('---')) { continue }
        if ($text.StartsWith('+') -or $text.StartsWith('-')) { $text.Substring(1).TrimEnd("`r") }
    }
    return , @($lines)
}

function Get-AiSdlcLineChange {
    <#
    .SYNOPSIS
        The added line numbers and the removed lines of one file since the base, or null without a base.
    .PARAMETER RepoRoot
        The repository root.
    .PARAMETER Base
        The base commit that Get-AiSdlcChange returned.
    .PARAMETER Path
        The repo-relative path of one file.
    .PARAMETER AssumeNew
        With no base, count every line of the file as added.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$Base,
        [Parameter(Mandatory)][string]$Path,
        [switch]$AssumeNew
    )

    $full = Join-Path $RepoRoot $Path
    if (-not $Base) {
        if (-not $AssumeNew -or -not (Test-Path -LiteralPath $full -PathType Leaf)) { return $null }
        $count = @(Get-Content -LiteralPath $full).Count
        return [pscustomobject]@{ Added = @(if ($count -gt 0) { 1..$count }); Removed = @(); RemovedAt = @() }
    }

    $specs = @(":(literal)$Path")
    $renames = & git -C $RepoRoot -c core.quotepath=off diff -M --name-status --diff-filter=R $Base -- 2>$null
    foreach ($row in @($renames)) {
        $parts = ([string]$row) -split "`t"
        if ($parts.Count -ge 3 -and $parts[2].Replace('\', '/') -eq $Path) { $specs += ":(literal)$($parts[1])" }
    }
    $diff = & git -C $RepoRoot -c core.quotepath=off diff -M --unified=0 --no-color --no-ext-diff $Base -- @specs 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }

    $added = [System.Collections.Generic.List[int]]::new()
    $removed = [System.Collections.Generic.List[string]]::new()
    $removedAt = [System.Collections.Generic.List[int]]::new()
    $inHunk = $false
    $lineNo = 0
    foreach ($raw in @($diff)) {
        $text = [string]$raw
        if ($text -match '^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@') {
            $inHunk = $true
            $lineNo = [int]$matches[1]
            continue
        }
        if ($text.StartsWith('diff --git')) { $inHunk = $false; continue }
        if (-not $inHunk) { continue }
        if ($text.StartsWith('+')) { $added.Add($lineNo); $lineNo++ }
        elseif ($text.StartsWith('-')) { $removed.Add($text.Substring(1).TrimEnd("`r")); $removedAt.Add($lineNo) }
    }
    return [pscustomobject]@{ Added = $added.ToArray(); Removed = $removed.ToArray(); RemovedAt = $removedAt.ToArray() }
}

function Get-AiSdlcChangeBase {
    <#
    .SYNOPSIS
        The last green pre-flight commit from AISDLC_CHANGE_BASE, when it is a full hash in the history of HEAD.
    .PARAMETER RepoRoot
        The repository root.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $value = [string]$env:AISDLC_CHANGE_BASE
    if (-not $value) { return [pscustomobject]@{ Base = $null; Reason = $null } }
    if ($value -notmatch '^[0-9a-f]{40}$') { return [pscustomobject]@{ Base = $null; Reason = 'AISDLC_CHANGE_BASE is not a full commit hash' } }
    & git -C $RepoRoot merge-base --is-ancestor $value HEAD *>$null
    if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0; return [pscustomobject]@{ Base = $null; Reason = 'AISDLC_CHANGE_BASE is not in the history of HEAD' } }
    return [pscustomobject]@{ Base = $value; Reason = $null }
}

Export-ModuleMember -Function Get-AiSdlcChange, Get-AiSdlcChangeBase, Get-AiSdlcChangedLine, Get-AiSdlcLineChange, Test-AiSdlcPathGlob
