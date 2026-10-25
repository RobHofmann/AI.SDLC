#Requires -Version 7
<#
.SYNOPSIS
    House-style doc lint: documentation must not contain the em-dash character (U+2014).

.DESCRIPTION
    Scans AGENTS.md and the documentation wiki layers (docs/ and docs-functional/) for the em-dash
    character (U+2014). The house style uses a spaced hyphen ' - ', commas, colons, or parentheses
    instead. Em-dashes drift in from pasted or model-generated prose and are easy to miss by eye,
    so they are caught mechanically. Exits non-zero (fails the build) when any em-dash is found.

    Sibling of Check-DocLineCitations.ps1 (clause C02) and Check-DocsWiki.ps1: the same shared
    script is run locally by Invoke-LocalGates.ps1 and the pre-push hook, and by the CI gate, so the
    rule lives in one place.

.PARAMETER RepoRoot
    Repository root that contains AGENTS.md, docs/, and docs-functional/. Defaults to the folder that
    holds aisdlc.json, found from this script.

.PARAMETER Path
    One or more markdown files or folders to check instead of AGENTS.md and the doc layers, relative
    to RepoRoot. A value may hold several paths split by commas, for example "core,packs,README.md".
    A path that does not exist exits 2 (could not check). Without it the gate reads what aisdlc.json
    names, as before.

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Check-DocEmDashes.ps1 -Path "core,packs,README.md"
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string[]]$Path
)

Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

$ErrorActionPreference = 'Stop'

$emDash = [char]0x2014

$targets = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
$config = Get-AiSdlcConfig -RepoRoot $RepoRoot
$paths = @($Path | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($paths) {
    $missing = @($paths | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RepoRoot $_)) })
    if ($missing) {
        Write-Host ("Could not check: the path(s) {0} do not exist under {1}." -f ($missing -join ', '), $RepoRoot) -ForegroundColor Yellow
        exit 2
    }
    foreach ($p in $paths) {
        $item = Get-Item -LiteralPath (Join-Path $RepoRoot $p) -Force
        if ($item.PSIsContainer) {
            Get-ChildItem -LiteralPath $item.FullName -Recurse -Force -Include *.md, *.markdown -File |
                Where-Object { $_.FullName -notmatch '[\\/](bin|obj|node_modules|\.git)[\\/]' } |
                ForEach-Object { $targets.Add($_) }
        }
        else { $targets.Add($item) }
    }
    $scope = $paths -join ', '
}
else {
    $layers = @(Get-AiSdlcPath -Name docsRoots -RepoRoot $RepoRoot -Relative)
    if (-not @($layers | Where-Object { Test-Path (Join-Path $RepoRoot $_) })) {
        Write-Host ("Could not check: none of the doc layers in aisdlc.json exists ({0})." -f ($layers -join ', ')) -ForegroundColor Yellow
        exit 2
    }
    $agents = Join-Path $RepoRoot $config.paths.agentsFile
    if (Test-Path $agents) { $targets.Add((Get-Item $agents)) }
    foreach ($layer in $layers) {
        $dir = Join-Path $RepoRoot $layer
        if (Test-Path $dir) {
            Get-ChildItem -Path $dir -Recurse -Include *.md, *.markdown -File | ForEach-Object { $targets.Add($_) }
        }
    }
    $scope = (@($config.paths.agentsFile) + @($layers | ForEach-Object { "$_/" })) -join ', '
}

$violations = [System.Collections.Generic.List[object]]::new()
foreach ($file in $targets) {
    $rel = [IO.Path]::GetRelativePath($RepoRoot, $file.FullName).Replace('\', '/')
    $n = 0
    foreach ($line in Get-Content -LiteralPath $file.FullName) {
        $n++
        if ($line.Contains($emDash)) {
            $violations.Add([pscustomobject]@{ File = $rel; Line = $n; Text = $line.Trim() })
        }
    }
}

if ($violations.Count -gt 0) {
    Write-Host "Doc house-style violation: documentation must not contain the em-dash character (U+2014)." -ForegroundColor Red
    Write-Host "FIX: Replace each em-dash with a spaced hyphen ' - ', a comma, a colon, or parentheses." -ForegroundColor Red
    foreach ($v in $violations) { Write-Host ("  {0}:{1}  {2}" -f $v.File, $v.Line, $v.Text) }
    Write-Host ("Found {0} line(s) containing an em-dash." -f $violations.Count) -ForegroundColor Red
    exit 1
}

Write-Host ("Em-dash OK: no em-dash (U+2014) characters in {0}." -f $scope)
exit 0
