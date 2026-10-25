#Requires -Version 7
<#
.SYNOPSIS
    Reads the C# and Razor lines a change adds, for the comment gates of the dotnet pack.
.DESCRIPTION
    Check-CommentHygiene.ps1 and Check-XmlDocs.ps1 read the change, not the tree. This module holds the
    part they share: it asks git for the diff of the working tree against the merge base of a base ref
    and HEAD, adds untracked .cs and .razor files whole, and splits a unified diff into lines. Each line
    knows its file, its line number in the new file, and whether the change added it or git sent it as
    context. Generated files (*.Designer.cs, *.g.cs, *.g.i.cs and anything under bin/ or obj/) are
    skipped by Test-CodeDiffPath.
#>

$script:GeneratedPatterns = @('\.Designer\.cs$', '\.g\.cs$', '\.g\.i\.cs$', '(^|/)(bin|obj)/')

<#
.SYNOPSIS
    Splits a unified diff into added and context lines.
.PARAMETER Diff
    The unified diff text.
.EXAMPLE
    Get-CodeDiffLine -Diff (git diff --unified=30 origin/main)
#>
function Get-CodeDiffLine {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Diff)

    $file = $null
    $lineNo = 0
    $afterOldHeader = $false
    foreach ($raw in ($Diff -split '\r?\n')) {
        if ($afterOldHeader -and $raw -match '^\+\+\+ (?:b/)?(.+)$') { $file = $matches[1].Trim(); $afterOldHeader = $false; continue }
        $afterOldHeader = $raw.StartsWith('--- ')
        if ($afterOldHeader -or $raw.StartsWith('diff --git')) { continue }
        if ($raw -match '^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@') { $lineNo = [int]$matches[1]; continue }
        if (-not $file -or $file -eq '/dev/null') { continue }
        if ($raw.StartsWith('+')) {
            [pscustomobject]@{ File = $file; Line = $lineNo; Text = $raw.Substring(1); IsAdded = $true }
            $lineNo++
        }
        elseif ($raw.StartsWith(' ')) {
            [pscustomobject]@{ File = $file; Line = $lineNo; Text = $raw.Substring(1); IsAdded = $false }
            $lineNo++
        }
    }
}

<#
.SYNOPSIS
    Tells whether a path is a C# or Razor file the gates read, so not a generated one.
.PARAMETER Path
    The repository-relative path, with forward or back slashes.
.PARAMETER Extension
    The extensions to accept. Defaults to .cs and .razor.
.EXAMPLE
    Test-CodeDiffPath -Path 'src/Api/Foo.cs'
#>
function Test-CodeDiffPath {
    [CmdletBinding()]
    param([string]$Path, [string[]]$Extension = @('.cs', '.razor'))

    $normal = $Path.Replace('\', '/')
    if (-not ($Extension | Where-Object { $normal.EndsWith($_) })) { return $false }
    return -not ($script:GeneratedPatterns | Where-Object { $normal -match $_ })
}

<#
.SYNOPSIS
    Gets the diff of the C# and Razor files a change touches, untracked files included.
.DESCRIPTION
    Returns an object with Text (the unified diff) and Problem. Problem is empty when the diff was read,
    and says why not when git is missing, there is no merge base, or git diff failed.
.PARAMETER RepoRoot
    Repository root.
.PARAMETER BaseRef
    The ref the change is measured against.
.PARAMETER ContextLines
    The number of context lines git sends around each change.
.EXAMPLE
    Get-CodeDiffText -RepoRoot . -BaseRef origin/main -ContextLines 30
#>
function Get-CodeDiffText {
    [CmdletBinding()]
    param([string]$RepoRoot, [string]$BaseRef, [int]$ContextLines = 30)

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Text = ''; Problem = 'git is not available, so the change could not be read' }
    }
    $base = git -C $RepoRoot merge-base $BaseRef HEAD 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $base) {
        return [pscustomobject]@{ Text = ''; Problem = "no merge base with '$BaseRef', so the change could not be read. Fetch the base branch, or pass -BaseRef" }
    }
    $diff = git -C $RepoRoot -c core.quotepath=off diff --unified=$ContextLines --no-color --no-ext-diff $base.Trim() -- '*.cs' '*.razor' 2>$null
    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject]@{ Text = ''; Problem = "git diff against $($base.Trim()) failed" }
    }
    $text = ($diff -join "`n")
    $untracked = git -C $RepoRoot -c core.quotepath=off ls-files --others --exclude-standard -- '*.cs' '*.razor' 2>$null
    foreach ($u in @($untracked | Where-Object { $_ })) {
        $content = @(Get-Content -LiteralPath (Join-Path $RepoRoot $u))
        $text += "`n--- /dev/null`n+++ b/$u`n@@ -0,0 +1,$($content.Count) @@`n" + (($content | ForEach-Object { "+$_" }) -join "`n")
    }
    return [pscustomobject]@{ Text = $text; Problem = '' }
}

Export-ModuleMember -Function Get-CodeDiffLine, Test-CodeDiffPath, Get-CodeDiffText
