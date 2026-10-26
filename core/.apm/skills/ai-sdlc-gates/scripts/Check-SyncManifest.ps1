#Requires -Version 7
<#
.SYNOPSIS
    Gate: every file of every installed AI.SDLC package is in .claude/, unchanged, and no stale file is left.

.DESCRIPTION
    AI.SDLC ships sync-manifest.json with the core: each file a package delivers, with its git hash, and
    each hook it merges into .claude/settings.json. The drift check of APM compares a repository with
    apm.lock.yaml, which APM writes itself, so a file APM skips is missing from both and passes. This gate
    checks against the manifest instead, which AI.SDLC builds from its own source.

    It reads the installed packages from apm.yml (core and each packs/<name>), then fails on:
    - a package in apm.yml that the manifest does not know;
    - a file of the manifest that is missing, or whose content differs;
    - a hook of the manifest that is missing from .claude/settings.json (APM writes an empty matcher as
      "*", so the two count as the same);
    - a file in the folder of an installed skill that the manifest does not list, for example a file
      that a newer version removed;
    - a skill folder under .claude/skills, or an agent file under .claude/agents, that an older version
      left behind: its name is in the retired list of the manifest (a skill that a release renamed), or
      a package of the manifest delivers it and apm.yml does not install that package.
      Any other skill or agent belongs to the repository itself, and passes.

    The hash is the git blob hash (git hash-object), so CRLF in a Windows working copy is no change.
    Exit 0 when everything matches, 1 on any finding, 2 when apm.yml or the manifest is missing.

    A repository that installs the core from a folder of its own tree (apm.yml names ./core, as AI.SDLC
    itself does) checks against the manifest in that folder. The installed manifest would agree with
    an install that is out of date, so a change to the source without a new apm install would pass.

.PARAMETER RepoRoot
    The repository root. Defaults to the folder that holds aisdlc.json, found from this script.

.PARAMETER ManifestPath
    Test seam: the manifest to check against. Defaults to the source manifest of a core that apm.yml
    installs from inside the repository, and otherwise to the one installed next to this script.

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Check-SyncManifest.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$ManifestPath
)

Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }
$sourceManifest = $false
if (-not $ManifestPath -and (Test-Path -LiteralPath (Join-Path $RepoRoot 'apm.yml'))) {
    foreach ($line in Get-Content -LiteralPath (Join-Path $RepoRoot 'apm.yml')) {
        if ($line -notmatch '^\s*-\s*\./(?<path>(?:[A-Za-z0-9._-]+/)*core)\s*$' -or $Matches.path -match '(^|/)\.\.(/|$)') { continue }
        $candidate = Join-Path $RepoRoot $Matches.path '.apm' 'skills' 'ai-sdlc-gates' 'sync-manifest.json'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $ManifestPath = $candidate; $sourceManifest = $true; break }
    }
}
if (-not $ManifestPath) { $ManifestPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'sync-manifest.json' }

$ErrorActionPreference = 'Stop'

$apmFile = Join-Path $RepoRoot 'apm.yml'
if (-not (Test-Path -LiteralPath $apmFile)) { Write-Output "::warning::The AI.SDLC sync could not be checked: $apmFile does not exist."; exit 2 }
if (-not (Test-Path -LiteralPath $ManifestPath)) { Write-Output "::warning::The AI.SDLC sync could not be checked: $ManifestPath does not exist."; exit 2 }

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -AsHashtable
$installed = [System.Collections.Generic.List[string]]::new()
foreach ($line in Get-Content -LiteralPath $apmFile) {
    if ($line -match '(?:^|[\s/:])(?:core|packs/(?<pack>[A-Za-z0-9._-]+))\s*$') {
        $name = if ($Matches.pack) { $Matches.pack } else { 'core' }
        if ($name -notin $installed) { $installed.Add($name) }
    }
}

$findings = [System.Collections.Generic.List[string]]::new()
$expected = [ordered]@{}
$hooks = [System.Collections.Generic.List[object]]::new()
foreach ($name in $installed) {
    if (-not $manifest.packages.Contains($name)) { $findings.Add("package $name is in apm.yml but not in the manifest of this AI.SDLC version"); continue }
    foreach ($path in $manifest.packages[$name].files.Keys) { $expected[$path] = $manifest.packages[$name].files[$path] }
    foreach ($hook in @($manifest.packages[$name].hooks)) { if ($hook) { $hooks.Add($hook) } }
}

$present = @($expected.Keys | Where-Object { Test-Path -LiteralPath (Join-Path $RepoRoot $_) -PathType Leaf })
foreach ($path in $expected.Keys) { if ($path -notin $present) { $findings.Add("missing: $path") } }
if ($present.Count -gt 0) {
    Push-Location $RepoRoot
    try { $actual = @($present | git hash-object --stdin-paths) }
    finally { Pop-Location }
    if ($LASTEXITCODE -ne 0 -or $actual.Count -ne $present.Count) { Write-Output '::warning::The AI.SDLC sync could not be checked: git hash-object failed.'; exit 2 }
    for ($i = 0; $i -lt $present.Count; $i++) {
        if ($actual[$i] -ne $expected[$present[$i]]) { $findings.Add("changed: $($present[$i])") }
    }
}

function ConvertTo-Matcher {
    param($Matcher)
    if ([string]::IsNullOrEmpty([string]$Matcher)) { return '*' }
    return [string]$Matcher
}

if ($hooks.Count -gt 0) {
    $settingsPath = Join-Path $RepoRoot '.claude' 'settings.json'
    $settings = if (Test-Path -LiteralPath $settingsPath) { Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
    $deployed = [System.Collections.Generic.HashSet[string]]::new()
    if ($settings.hooks) {
        foreach ($event in $settings.hooks.Keys) {
            foreach ($group in @($settings.hooks[$event])) {
                foreach ($hook in @($group.hooks)) { [void]$deployed.Add("$event|$(ConvertTo-Matcher $group.matcher)|$([string]$hook.if)|$([string]$hook.command)") }
            }
        }
    }
    foreach ($hook in $hooks) {
        if (-not $deployed.Contains("$($hook.event)|$(ConvertTo-Matcher $hook.matcher)|$($hook.if)|$($hook.command)")) {
            $findings.Add("missing hook in .claude/settings.json: $($hook.event) $($hook.matcher) $($hook.command)")
        }
    }
}

$skillFolders = @($expected.Keys | Where-Object { $_ -match '^\.claude/skills/[^/]+/' } | ForEach-Object { ($_ -split '/')[0..2] -join '/' } | Sort-Object -Unique)
if ($skillFolders.Count -gt 0) {
    $onDisk = @(git -C $RepoRoot ls-files --cached --others --exclude-standard -- @($skillFolders) 2>$null)
    if ($LASTEXITCODE -eq 0) {
        foreach ($path in $onDisk) { if ($path -ne '.claude/skills/ai-sdlc-gates/sync-manifest.json' -and -not $expected.Contains($path)) { $findings.Add("not in this AI.SDLC version: $path") } }
    }
}

# A skill folder or an agent file was left behind by an older version when its name is retired, or when a
# package that apm.yml does not install delivers it. Any other one belongs to the repository, and passes.
$retired = @{}
if ($manifest.Contains('retired') -and $manifest.retired) {
    foreach ($old in $manifest.retired.Keys) { $retired[[string]$old] = [string]$manifest.retired[$old] }
}
$owner = @{}
foreach ($package in $manifest.packages.Keys) {
    foreach ($path in $manifest.packages[$package].files.Keys) {
        if ($path -match '^(\.claude/skills/[^/]+)/') { $owner[$Matches[1]] = $package }
        elseif ($path -match '^\.claude/agents/[^/]+$') { $owner[$path] = $package }
    }
}
$leftBehind = 0
$units = @(git -C $RepoRoot ls-files --cached --others --exclude-standard -- .claude/skills .claude/agents 2>$null |
    ForEach-Object { if ($_ -match '^(\.claude/skills/[^/]+)/') { $Matches[1] } elseif ($_ -match '^\.claude/agents/[^/]+$') { $_ } } |
    Sort-Object -Unique)
if ($LASTEXITCODE -eq 0) {
    foreach ($unit in $units) {
        $isSkill = $unit.StartsWith('.claude/skills/')
        $shown = if ($isSkill) { "$unit/" } else { $unit }
        if ($owner.ContainsKey($unit)) {
            if ($owner[$unit] -notin $installed) {
                $findings.Add("of package $($owner[$unit]), which apm.yml does not install: $shown")
                $leftBehind++
            }
            continue
        }
        $name = (Split-Path $unit -Leaf) -replace '\.md$', ''
        if ($retired.ContainsKey($name)) {
            $findings.Add("retired, now $($retired[$name]): $shown")
            $leftBehind++
        }
    }
}

if ($findings.Count -gt 0) {
    Write-Host "AI.SDLC sync: .claude/ does not match the installed packages ($($installed -join ', ')):" -ForegroundColor Red
    foreach ($f in $findings) { Write-Host "  $f" }
    if ($leftBehind -gt 0) {
        Write-Host 'FIX: Delete each skill folder or agent file above that an older AI.SDLC version left behind, and commit that. Move a file you added there yourself to the new skill first.' -ForegroundColor Red
    }
    if ($findings.Count -gt $leftBehind -and $sourceManifest) {
        Write-Host "FIX: The packages are installed from this repository, and .claude/ is behind the source. Run tools/Update-SyncManifest.ps1, then apm install, and commit what they change." -ForegroundColor Red
    }
    elseif ($findings.Count -gt $leftBehind) {
        Write-Host 'FIX: Run apm install to install the pinned version again, and commit what it changes. If the files are still wrong, apm install skips them: report it on AI.SDLC.' -ForegroundColor Red
    }
    exit 1
}

$against = if ($sourceManifest) { "the source manifest $([IO.Path]::GetRelativePath($RepoRoot, $ManifestPath).Replace('\', '/'))" } else { 'the manifest' }
Write-Host "AI.SDLC sync OK: $($expected.Count) file(s) and $($hooks.Count) hook(s) of $($installed.Count) package(s) match $against."
exit 0
