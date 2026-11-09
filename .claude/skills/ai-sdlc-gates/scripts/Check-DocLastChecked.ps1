#Requires -Version 7
<#
.SYNOPSIS
    Docs lint: lists the pages whose facts were last checked too long ago.

.DESCRIPTION
    A page that copies facts from the outside world (versions, hosts, lists) says when someone last
    checked them, as "Last checked: 2026-11-09". This gate reads AGENTS.md and the doc layers in
    aisdlc.json and lists every such date that is older than docs.lastCheckedMaxAgeDays, with the file
    and the line. A page without such a date is left alone.

    The setting is off by default. Only a positive whole number in aisdlc.json switches it on; any
    other value, such as "30" as a string, counts as off.

    Exit 0 when the setting is off or no date is too old, and 1 when one is. The gate is Advisory, so
    the runner shows a finding as a warning. The pre-push hook runs this script itself with -Quiet, so
    the warning also shows on a push, which never fails on it.

.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script.

.PARAMETER Today
    The date to measure the age against. Defaults to today. A test passes a fixed date.

.PARAMETER Quiet
    Print nothing unless a date is too old. The pre-push hook uses it.

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Check-DocLastChecked.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [datetime]$Today = (Get-Date).Date,
    [switch]$Quiet
)

Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

$config = Get-AiSdlcConfig -RepoRoot $RepoRoot
$maxAge = $config.docs['lastCheckedMaxAgeDays']
if (-not (($maxAge -is [int] -or $maxAge -is [long]) -and $maxAge -gt 0)) {
    if (-not $Quiet) { Write-Host 'Last checked: off. Set docs.lastCheckedMaxAgeDays in aisdlc.json to a number of days to switch it on.' }
    exit 0
}

$files = [System.Collections.Generic.List[string]]::new()
$agents = Join-Path $RepoRoot $config.paths.agentsFile
if (Test-Path -LiteralPath $agents) { $files.Add($agents) }
foreach ($layer in @(Get-AiSdlcPath -Name docsRoots -RepoRoot $RepoRoot -Relative)) {
    $dir = Join-Path $RepoRoot $layer
    if (Test-Path -LiteralPath $dir) {
        Get-ChildItem -LiteralPath $dir -Recurse -Include *.md, *.markdown -File | ForEach-Object { $files.Add($_.FullName) }
    }
}

$pattern = [regex]'(?i)\blast checked:?\s*(\d{4}-\d{2}-\d{2})'
$old = [System.Collections.Generic.List[string]]::new()
foreach ($file in $files) {
    $relative = [IO.Path]::GetRelativePath($RepoRoot, $file).Replace('\', '/')
    $number = 0
    foreach ($line in [IO.File]::ReadLines($file)) {
        $number++
        foreach ($match in $pattern.Matches($line)) {
            $date = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($match.Groups[1].Value, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture, 'None', [ref]$date)) { continue }
            $age = ($Today.Date - $date.Date).Days
            if ($age -gt $maxAge) { $old.Add("${relative}:$number last checked $($match.Groups[1].Value), $age days ago") }
        }
    }
}

if ($old.Count) {
    Write-Host "Last checked: $($old.Count) page date(s) are older than $maxAge days (docs.lastCheckedMaxAgeDays):" -ForegroundColor Yellow
    foreach ($o in $old) { Write-Host "  $o" }
    Write-Host 'Check those facts against their source, fix what changed, and set the date to today.'
    exit 1
}
if (-not $Quiet) { Write-Host "Last checked: every date is at most $maxAge days old." }
exit 0
