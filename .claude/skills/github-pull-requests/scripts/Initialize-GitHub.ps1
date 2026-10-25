#Requires -Version 7
<#
.SYNOPSIS
    The GitHub setup step of Initialize-AiSdlc.ps1: the GitHub CLI is installed, and it is signed in.

.DESCRIPTION
    Initialize-AiSdlc.ps1 in the ai-sdlc-hooks skill runs this script, because
    github-pull-requests/gates.json names it as the setup of this skill. It returns rows with Step,
    Status and Detail for the one summary table.

    The allow rules of the pull request scripts are in the allow list of
    github-pull-requests/gates.json. Sync-AllowRules.ps1 of the core writes them into
    .claude/settings.json.

    It only checks; it changes nothing on the machine. The check is advisory: a missing gh or a
    missing sign-in gives a WARN row with the command to run, and the setup goes on. It never fails.

.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script.

.PARAMETER Plan
    Return the name of the step this script would take, and check nothing.

.EXAMPLE
    pwsh .claude/skills/github-pull-requests/scripts/Initialize-GitHub.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$RepoRoot,
    [switch]$Plan
)

if ($Plan) { return 'GitHub CLI check' }

function New-Row([string]$Step, [string]$Status, [string]$Detail) {
    [pscustomobject]@{ Step = $Step; Status = $Status; Detail = $Detail }
}

$target = 'GitHub'
try {
    $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
    if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
    Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
    if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }
    $github = (Get-AiSdlcConfig -RepoRoot $RepoRoot).github
    if ($github -and $github.repository) { $target = [string]$github.repository }
}
catch {
    $target = 'GitHub'
}

Write-Host "GitHub CLI ($target)..." -ForegroundColor Cyan
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    New-Row 'GitHub CLI' 'WARN' 'gh not on PATH; install it from https://cli.github.com, then run: gh auth login'
    New-Row 'GitHub sign-in' 'WARN' 'not checked, because gh is not installed'
    return
}

$version = (& gh --version 2>$null | Select-Object -First 1)
New-Row 'GitHub CLI' 'OK' $(if ($version) { [string]$version } else { 'gh is on PATH' })

$status = & gh auth status 2>&1 | Out-String
if ($LASTEXITCODE -eq 0) {
    New-Row 'GitHub sign-in' 'OK' 'gh auth status: signed in; pull requests and checks are reachable'
}
else {
    New-Row 'GitHub sign-in' 'WARN' 'gh is not signed in; run: gh auth login'
    Write-Host ($status.Trim()) -ForegroundColor Yellow
}
