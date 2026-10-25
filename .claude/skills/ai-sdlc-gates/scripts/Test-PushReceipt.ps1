#Requires -Version 7
<#
.SYNOPSIS
    Says whether the tip commit of each pushed ref has a passing pre-flight receipt for its tree.

.DESCRIPTION
    The pre-flight writes a receipt for the tree of HEAD when a full run passes on a clean working tree
    (PreflightReceipt.psm1). The receipt shows that the gates, the tests and gitleaks passed on exactly
    that tree. The pre-push git hook calls this script with the tip commit of each pushed ref, the
    new value git gives the hook for that ref. It does not check the commits below a tip. That is as
    strong as a gate run, because the gates check one tree too. When each tip has a receipt, the hook
    does not run the blocking gates a second time; the pull request build still runs them.

    Exit 0 when every given commit has a passing receipt for its tree. Exit 1 when a commit has none, when
    its receipt did not pass, when git does not know the commit, or when no commit was given.

.PARAMETER RepoRoot
    The repository root. Defaults to the folder that holds aisdlc.json, found from the current folder.

.PARAMETER Commit
    The commits to check. A value may hold several, split by commas or spaces, because a git hook
    passes them as one argument.

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Test-PushReceipt.ps1 -Commit (git rev-parse HEAD)
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string[]]$Commit = @()
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PreflightReceipt.psm1') -Force

$config = Get-AiSdlcConfig -RepoRoot $RepoRoot -StartPath (Get-Location).Path
$receiptRoot = Join-Path $config.repoRoot $config.paths.preflightReceipts
$commits = @($Commit | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ })
if ($commits.Count -eq 0) {
    Write-Host 'No commit to check, so no receipt covers the push.'
    exit 1
}

foreach ($sha in $commits) {
    $tree = [string](git -C $config.repoRoot rev-parse --verify --quiet "$sha^{tree}" 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not (Test-PreflightReceipt -ReceiptRoot $receiptRoot -Tree $tree.Trim())) {
        Write-Host ("No passing pre-flight receipt for commit {0}." -f $sha.Substring(0, [Math]::Min(8, $sha.Length)))
        exit 1
    }
}
Write-Host ("A passing pre-flight receipt covers each of the {0} pushed commit(s)." -f $commits.Count)
exit 0
