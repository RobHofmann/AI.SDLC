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

.PARAMETER RepoRoot
    The repository root.

.PARAMETER BaseRef
    The ref the change is measured against. Overrides PR_TARGET_BRANCH and origin/main.

.PARAMETER Explicit
    Repo-relative paths, bypassing git and the environment.

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
        [string[]]$Explicit
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
    return [pscustomobject]@{ Readable = $true; Files = @(ConvertTo-ChangePath @($names)); Deleted = @(ConvertTo-ChangePath @($deletedNames)); Base = $resolved.Base; Reason = $null }
}

Export-ModuleMember -Function Get-AiSdlcChange
