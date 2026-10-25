#Requires -Version 7
<#
.SYNOPSIS
    Enforces constitution clause C02: documentation must not cite source by line number.

.DESCRIPTION
    Scans AGENTS.md and docs/ for source line-number citations (file.ext:NN or "line NN"),
    which rot on the next edit and silently mislead. Reference code by file path and symbol
    name instead. Exits non-zero (fails the build) when any citation is found.

    Two files are allow-listed because they DESCRIBE the rule rather than violate it:
    the constitution page and the ADR index (paths.constitution and paths.adrFolder in aisdlc.json).

.PARAMETER RepoRoot
    Repository root that contains AGENTS.md and docs/. Defaults to the folder that holds aisdlc.json, found from this script.

.PARAMETER Path
    One or more markdown files or folders to check instead of AGENTS.md and docs/, relative to
    RepoRoot. A value may hold several paths split by commas, for example "core,packs,README.md". A
    path that does not exist exits 2 (could not check). The allow list still applies.

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Check-DocLineCitations.ps1 -Path "core,packs,README.md"
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string[]]$Path
)

Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

$ErrorActionPreference = 'Stop'

$config = Get-AiSdlcConfig -RepoRoot $RepoRoot
$allowList = @(
    $config.paths.constitution,
    "$($config.paths.adrFolder)/README.md"
)

$patterns = @(
    '\.(?:cs|ts|tsx|razor|bicep|yml|yaml|json|ps1|psm1|py|toml|js|css|sln|csproj):\d+',  # file.ext:NN
    '\b[Ll]ines?\s+\d+'                                                      # line NN / lines NN-MM
)

$targets = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
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
            Get-ChildItem -LiteralPath $item.FullName -Recurse -Force -Filter *.md -File |
                Where-Object { $_.FullName -notmatch '[\\/](bin|obj|node_modules|\.git)[\\/]' } |
                ForEach-Object { $targets.Add($_) }
        }
        else { $targets.Add($item) }
    }
    $scope = $paths -join ', '
}
else {
    $agents = Join-Path $RepoRoot $config.paths.agentsFile
    if (Test-Path $agents) { $targets.Add((Get-Item $agents)) }
    $docsDir = Join-Path $RepoRoot $config.paths.technicalDocs
    if (Test-Path $docsDir) { Get-ChildItem -Path $docsDir -Recurse -Filter *.md -File | ForEach-Object { $targets.Add($_) } }
    $scope = 'AGENTS.md or docs/'
}

$violations = [System.Collections.Generic.List[object]]::new()
foreach ($file in $targets) {
    $rel = [IO.Path]::GetRelativePath($RepoRoot, $file.FullName).Replace('\', '/')
    if ($allowList -contains $rel) { continue }
    $n = 0
    foreach ($line in Get-Content -LiteralPath $file.FullName) {
        $n++
        foreach ($p in $patterns) {
            if ($line -match $p) {
                $violations.Add([pscustomobject]@{ File = $rel; Line = $n; Text = $line.Trim() })
                break
            }
        }
    }
}

if ($violations.Count -gt 0) {
    Write-Host "C02 violation: documentation must not cite source line numbers." -ForegroundColor Red
    Write-Host "FIX: Replace the line number with the file path and the symbol name, which survive the next edit (clause C02)." -ForegroundColor Red
    foreach ($v in $violations) { Write-Host ("  {0}:{1}  {2}" -f $v.File, $v.Line, $v.Text) }
    Write-Host ("Found {0} line-number citation(s)." -f $violations.Count) -ForegroundColor Red
    exit 1
}

Write-Host "C02 OK: no source line-number citations in $scope."
exit 0
