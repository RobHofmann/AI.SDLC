#Requires -Version 7
<#
.SYNOPSIS
    The pre-flight receipt: the proof that Invoke-Preflight.ps1 passed on the exact commit about to be
    pushed, written by that script and read by the push hook Deny-IncompletePush.ps1.
.DESCRIPTION
    Invoke-Preflight.ps1 writes temp/preflight/<tree>.json when no check failed on a clean working tree
    (a REVIEW row, such as a build warning on a changed file, does not stop it; a gitleaks finding
    outside the baseline is a FAIL row and does), where <tree> is the tree hash of HEAD. The agent push hook looks for the receipt of
    the tree it is about to push and refuses the push when there is none, so an agent never pushes a
    commit without a green pre-flight of that tree (see .claude/skills/ai-sdlc-handbook/references/orchestration.md).
    The git pre-push hook does not read the receipt, so a push from a terminal needs none.
    The tree hash, not the commit hash, is the key, so an amended commit message keeps its receipt and
    any change to a file needs a new run. Initialize-AiSdlc.ps1 makes git ignore temp/ (through
    .git/info/exclude when no rule covers it), and also the folder paths.preflightReceipts names when it
    is outside temp/. So a receipt never leaves the machine.
    A push that sends nothing new needs no receipt and no gate: Test-PushSendsNothingNew is true when
    every pushed commit is a delete (all zeros) or is reachable from the remote-tracking refs of the
    remote being pushed to. Only that remote counts, never another one. Both push hooks call it, the
    agent hook directly and the git pre-push hook through Test-PushSendsNothingNew.ps1.
#>

function Get-HeadTree {
    param([string]$RepoRoot = (Get-Location).Path)

    try { return ([string](git -C $RepoRoot rev-parse 'HEAD^{tree}' 2>$null)).Trim() } catch { return '' }
}

function Test-CleanTree {
    param([string]$RepoRoot = (Get-Location).Path)

    try { $status = @(git -C $RepoRoot status --porcelain --untracked-files=no 2>$null) } catch { return $false }
    return ($LASTEXITCODE -eq 0 -and $status.Count -eq 0)
}

function Get-ReceiptPath {
    param([Parameter(Mandatory)][string]$ReceiptRoot, [Parameter(Mandatory)][string]$Tree)

    return Join-Path -Path $ReceiptRoot -ChildPath "$Tree.json"
}

function Write-PreflightReceipt {
    param(
        [Parameter(Mandatory)][string]$ReceiptRoot,
        [Parameter(Mandatory)][string]$Tree,
        [Parameter(Mandatory)][ValidateSet('PASS', 'FAIL')][string]$Status,
        [string]$Commit = '',
        [string[]]$Checks = @()
    )

    New-Item -ItemType Directory -Path $ReceiptRoot -Force | Out-Null
    $path = Get-ReceiptPath -ReceiptRoot $ReceiptRoot -Tree $Tree
    [ordered]@{
        Tree    = $Tree
        Commit  = $Commit
        Status  = $Status
        Checks  = $Checks
        Written = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $path -Encoding utf8
    return $path
}

function Test-PreflightReceipt {
    param([Parameter(Mandatory)][string]$ReceiptRoot, [AllowEmptyString()][string]$Tree)

    if ([string]::IsNullOrWhiteSpace($Tree)) { return $false }
    $path = Get-ReceiptPath -ReceiptRoot $ReceiptRoot -Tree $Tree
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    try { $receipt = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { return $false }
    return ([string]$receipt.Status -eq 'PASS' -and [string]$receipt.Tree -eq $Tree)
}

function Test-PushSendsNothingNew {
    param(
        [string]$RepoRoot = (Get-Location).Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Remote,
        [string[]]$Commit = @()
    )

    $pushed = @($Commit | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ -and $_ -notmatch '^0+$' })
    if ($pushed.Count -eq 0) { return $true }
    if ($Remote -notmatch '^[^\s*?\[\\]+$') { return $false }
    try {
        $remotes = @(git -C $RepoRoot remote 2>$null)
        if ($LASTEXITCODE -ne 0 -or $Remote -notin $remotes) { return $false }
        $missing = @(git -C $RepoRoot rev-list @pushed --not "--remotes=$Remote" 2>$null)
        return ($LASTEXITCODE -eq 0 -and $missing.Count -eq 0)
    }
    catch { return $false }
}

Export-ModuleMember -Function Get-HeadTree, Test-CleanTree, Get-ReceiptPath, Write-PreflightReceipt, Test-PreflightReceipt, Test-PushSendsNothingNew
