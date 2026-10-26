#Requires -Version 7
<#
.SYNOPSIS
    Gate: every local package that apm.yml or apm.lock.yaml names is a folder that git tracks.

.DESCRIPTION
    A repository can install a package of its own from a folder in the repository: a line such as
    - ./packs/video-course in apm.yml. APM records it in apm.lock.yaml with local_path. When that
    folder is not in git, a fresh clone, the pull request pipeline and the update to a new AI.SDLC
    version do not have it. Then apm audit --ci fails on an orphaned package, and the update opens no
    pull request. A lock entry also stays behind when the folder moves and nobody removes the entry.

    This gate reads each local path from apm.yml (a list item that starts with ./, ../ or a full path)
    and each local_path from apm.lock.yaml. It fails on a path that is missing, and on a path that
    git does not track (git ls-files). A path outside the repository is not checked: it is the form of
    a local AI.SDLC clone, which the handbook says never to commit.

    Exit 0 when every local path inside the repository is in git, 1 on any finding, 2 when apm.yml is
    missing or git cannot answer.

.PARAMETER RepoRoot
    The repository root. Defaults to the folder that holds aisdlc.json, found from this script.

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Check-LocalPackages.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot
)

Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

$ErrorActionPreference = 'Stop'

$apmFile = Join-Path $RepoRoot 'apm.yml'
$lockFile = Join-Path $RepoRoot 'apm.lock.yaml'
if (-not (Test-Path -LiteralPath $apmFile)) { Write-Output "::warning::Local packages could not be checked: $apmFile does not exist."; exit 2 }

function ConvertFrom-YamlScalar {
    param([string]$Value)
    return $Value.Trim().Trim('"', "'")
}

# Each local package: where it is named, its name, and its path as written.
$packages = [System.Collections.Generic.List[object]]::new()
foreach ($line in Get-Content -LiteralPath $apmFile) {
    if ($line -match '^\s*-\s+(?<path>["'']?(?:\.{1,2}/|/|[A-Za-z]:[\\/])[^#]*?)\s*(?:#.*)?$') {
        $path = ConvertFrom-YamlScalar $Matches.path
        $packages.Add([pscustomobject]@{ Source = 'apm.yml'; Name = $path; Path = $path })
    }
}

if (Test-Path -LiteralPath $lockFile) {
    # A lock entry starts with "- " at the left edge; its fields follow, indented.
    $entry = $null
    $entries = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($line in Get-Content -LiteralPath $lockFile) {
        if ($line -match '^-\s+(?<key>[A-Za-z_]+):\s*(?<value>.*)$') {
            $entry = @{ $Matches.key = (ConvertFrom-YamlScalar $Matches.value) }
            $entries.Add($entry)
        }
        elseif ($entry -and $line -match '^\s+(?<key>[A-Za-z_]+):\s*(?<value>\S.*)$') {
            if (-not $entry.ContainsKey($Matches.key)) { $entry[$Matches.key] = ConvertFrom-YamlScalar $Matches.value }
        }
        elseif ($line -match '^\S') { $entry = $null }
    }
    foreach ($e in $entries) {
        if (-not $e.local_path) { continue }
        $name = if ($e.name) { $e.name } elseif ($e.repo_url) { $e.repo_url } else { $e.local_path }
        $packages.Add([pscustomobject]@{ Source = 'apm.lock.yaml'; Name = $name; Path = $e.local_path })
    }
}

$rootFull = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
$findings = [System.Collections.Generic.List[string]]::new()
$checked = 0
$outside = 0
foreach ($package in $packages) {
    # Join-Path would glue a full path such as C:/clone/core onto the root, so a full path stays as it is.
    $full = [IO.Path]::GetFullPath([IO.Path]::Combine($rootFull, $package.Path)).TrimEnd('\', '/')
    $inside = $full -eq $rootFull -or $full.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
    if (-not $inside) { $outside++; continue }
    $checked++
    $rel = [IO.Path]::GetRelativePath($rootFull, $full).Replace('\', '/')
    $what = "$($package.Source) names local package $($package.Name) at $($package.Path)"
    if (-not (Test-Path -LiteralPath $full)) {
        $findings.Add("$what, and that path does not exist")
        continue
    }
    $tracked = @(git -C $rootFull ls-files -- $rel 2>$null)
    if ($LASTEXITCODE -ne 0) { Write-Output "::warning::Local packages could not be checked: git ls-files failed in $rootFull."; exit 2 }
    if ($tracked.Count -eq 0) { $findings.Add("$what, and git does not track that path") }
}

if ($findings.Count -gt 0) {
    Write-Host "Local packages: $($findings.Count) local package path(s) are not in git, so a fresh clone and the update to a new AI.SDLC version do not have them:" -ForegroundColor Red
    foreach ($f in $findings) { Write-Host "  $f" }
    Write-Host 'FIX: Add the folder to git and commit it. Or, when the package is gone or moved, remove its entry from apm.yml, and its dependency from apm.lock.yaml when it is still there; then run apm install and apm audit --ci, and commit the result.' -ForegroundColor Red
    Write-Host '     Keep skills, agents and hooks of the repository itself in the root .apm/ folder next to apm.yml: /.claude/skills/ai-sdlc-handbook/references/consumer-own.md' -ForegroundColor Red
    exit 1
}

$note = if ($outside -gt 0) { " $outside path(s) outside the repository are not checked." } else { '' }
Write-Host "Local packages OK: $checked local package path(s) are in git.$note"
exit 0
