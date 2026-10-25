#Requires -Version 7
<#
.SYNOPSIS
    Gate: the version field of every apm.yml of AI.SDLC matches the newest release in CHANGELOG.md.

.DESCRIPTION
    One tag covers the whole repository, and CHANGELOG.md names each release in a heading such as
    "## v2.0.0 - 2026-10-20", newest first. APM reads the version field of each package from its apm.yml.
    So the core and every pack carry the version of the release they are part of, and the field moves
    with the CHANGELOG. This gate reads the first "## vX.Y.Z" heading, a release candidate such as
    v3.0.0-rc.1 included, and fails on an apm.yml under core/ or packs/<name>/ whose version differs or
    is missing.

    It also fails when apm.lock.yaml records a version for a local package (local_path ./core or
    ./packs/<name>) that differs from the apm.yml of that package. After a version bump the first apm
    install records the version of the old copy in apm_modules/, with or without --refresh; a second
    apm install writes the new one. Without an apm.lock.yaml at the repository root the lock check is
    skipped, and the gate prints a line that says so.

    Exit codes follow the gate contract: 0 every version matches, 1 a version differs or is missing,
    2 could not check (no CHANGELOG.md, no version heading, or no apm.yml).

.PARAMETER RepoRoot
    The AI.SDLC repository root. Defaults to the folder above this script.

.EXAMPLE
    pwsh tools/Check-PackageVersion.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot
)

if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$changelog = Join-Path $RepoRoot 'CHANGELOG.md'
if (-not (Test-Path -LiteralPath $changelog -PathType Leaf)) {
    Write-Host "Could not check: $changelog does not exist." -ForegroundColor Yellow
    exit 2
}
$heading = Select-String -LiteralPath $changelog -Pattern '^## v(\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?)\b' | Select-Object -First 1
if (-not $heading) {
    Write-Host 'Could not check: CHANGELOG.md has no heading such as "## v2.0.0 - <date>".' -ForegroundColor Yellow
    exit 2
}
$release = $heading.Matches[0].Groups[1].Value

$manifests = @(@(Join-Path $RepoRoot 'core' 'apm.yml') + @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'packs') -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'apm.yml' }) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
if ($manifests.Count -eq 0) {
    Write-Host 'Could not check: there is no apm.yml under core/ or packs/<name>/.' -ForegroundColor Yellow
    exit 2
}

$versions = @{}
$findings = foreach ($manifest in $manifests) {
    $relative = [IO.Path]::GetRelativePath($RepoRoot, $manifest).Replace('\', '/')
    $line = Select-String -LiteralPath $manifest -Pattern '^version:\s*(.*?)\s*$' | Select-Object -First 1
    $version = if ($line) { $line.Matches[0].Groups[1].Value.Trim('"', "'") } else { '' }
    $versions[$relative -replace '/apm\.yml$', ''] = $version
    if (-not $version) { "${relative}: no version, CHANGELOG.md says $release" }
    elseif ($version -ne $release) { "${relative}: version $version, CHANGELOG.md says $release" }
}

$lockFile = Join-Path $RepoRoot 'apm.lock.yaml'
$lockFindings = @()
if (Test-Path -LiteralPath $lockFile -PathType Leaf) {
    $entries = [System.Collections.Generic.List[hashtable]]::new()
    $entry = $null
    foreach ($line in Get-Content -LiteralPath $lockFile) {
        if ($line -match '^-\s+(?<key>[A-Za-z_]+):\s*(?<value>.*)$') {
            $entry = @{ $Matches.key = $Matches.value.Trim().Trim('"', "'") }
            $entries.Add($entry)
        }
        elseif ($entry -and $line -match '^  (?<key>[A-Za-z_]+):\s*(?<value>\S.*)$') {
            if (-not $entry.ContainsKey($Matches.key)) { $entry[$Matches.key] = $Matches.value.Trim().Trim('"', "'") }
        }
        elseif ($line -match '^\S') { $entry = $null }
    }
    $lockFindings = foreach ($e in $entries) {
        if (-not $e.local_path) { continue }
        $folder = $e.local_path.Replace('\', '/') -replace '^\./', '' -replace '/+$', ''
        if (-not $versions[$folder]) { continue }
        if ($e.version -ne $versions[$folder]) {
            $shown = if ($e.version) { "version $($e.version)" } else { 'no version' }
            "apm.lock.yaml: ./$folder has $shown, $folder/apm.yml says $($versions[$folder])"
        }
    }
}
else {
    Write-Host 'Lock check skipped: there is no apm.lock.yaml at the repository root, so only the apm.yml files were checked.'
}

if ($findings) {
    Write-Host "Package versions differ from the newest release in CHANGELOG.md (v$release):" -ForegroundColor Red
    foreach ($finding in $findings) { Write-Host "  $finding" }
    Write-Host "FIX: Set version: `"$release`" in each apm.yml above, so every package carries the release that CHANGELOG.md names." -ForegroundColor Red
}
if ($lockFindings) {
    Write-Host 'Local package versions in apm.lock.yaml differ from their apm.yml:' -ForegroundColor Red
    foreach ($finding in $lockFindings) { Write-Host "  $finding" }
    Write-Host 'FIX: Run apm install again, so the lock file records the version of each apm.yml, and commit apm.lock.yaml.' -ForegroundColor Red
}
if ($findings -or $lockFindings) { exit 1 }
Write-Host "Package versions OK: $($manifests.Count) package(s) at $release, the newest release in CHANGELOG.md."
exit 0
