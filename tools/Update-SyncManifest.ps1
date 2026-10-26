#Requires -Version 7
<#
.SYNOPSIS
    Writes the sync manifest: every file each AI.SDLC package delivers to a consumer, with its git hash.
    With -Check it only checks the manifest is current.

.DESCRIPTION
    The manifest is the independent record of what a consumer must have after apm install. The gate
    Check-SyncManifest.ps1 in the core compares a consumer against it in every pull request build. The
    lockfile cannot do that job, because APM writes the lockfile itself: a file APM skips is missing from
    both, and the drift check stays green.

    The script knows how APM deploys each kind of file:
    - skills/<path> becomes .claude/skills/<path>, byte for byte;
    - agents/<name>.agent.md becomes .claude/agents/<name>.md, byte for byte;
    - hooks/<file>.json is merged into .claude/settings.json, so the manifest lists each hook.
    Any other file under .apm/ stops the script, so a new kind of file can never ship unchecked.

    The manifest also lists the retired skill names from config/retired-skill-names.txt, each with its
    new name. Check-SyncManifest.ps1 uses that list to find the folder of a renamed skill that an older
    version left behind in a consumer, and the update script uses it to point at text that still uses
    an old name.

    The hash is the git blob hash (git hash-object), so CRLF in a Windows working copy does not count as
    a change. The manifest is written to core/.apm/skills/ai-sdlc-gates/sync-manifest.json and leaves
    itself out, because it cannot hold its own hash.

.PARAMETER RepoRoot
    The AI.SDLC repository root. Defaults to the folder above this script.

.PARAMETER Check
    Compare only. Exit 1 when the manifest differs from the packages.

.EXAMPLE
    pwsh tools/Update-SyncManifest.ps1

.EXAMPLE
    pwsh tools/Update-SyncManifest.ps1 -Check
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$manifestRelative = 'core/.apm/skills/ai-sdlc-gates/sync-manifest.json'
$target = Join-Path $RepoRoot $manifestRelative

$packages = [ordered]@{ core = 'core' }
foreach ($pack in Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'packs') -Directory | Sort-Object Name) {
    $packages[$pack.Name] = "packs/$($pack.Name)"
}

$manifest = [ordered]@{ packages = [ordered]@{} }
$unknown = [System.Collections.Generic.List[string]]::new()
foreach ($name in $packages.Keys) {
    $apmRelative = "$($packages[$name])/.apm"
    $apm = Join-Path $RepoRoot $apmRelative
    $files = [ordered]@{}
    $hooks = [System.Collections.Generic.List[object]]::new()
    $sources = @(Get-ChildItem -LiteralPath $apm -Recurse -File -ErrorAction SilentlyContinue |
        ForEach-Object { [IO.Path]::GetRelativePath($apm, $_.FullName).Replace('\', '/') } |
        Sort-Object -CaseSensitive)
    $copied = [System.Collections.Generic.List[object]]::new()
    foreach ($relative in $sources) {
        $source = "$apmRelative/$relative"
        if ($source -eq $manifestRelative) { continue }
        if ($relative -like 'skills/*') { $copied.Add(@($source, ".claude/$relative")) }
        elseif ($relative -match '^agents/(?<name>[^/]+)\.agent\.md$') { $copied.Add(@($source, ".claude/agents/$($Matches.name).md")) }
        elseif ($relative -match '^hooks/[^/]+\.json$') {
            $data = Get-Content -LiteralPath (Join-Path $RepoRoot $source) -Raw | ConvertFrom-Json -AsHashtable
            foreach ($event in $data.hooks.Keys) {
                foreach ($group in @($data.hooks[$event])) {
                    foreach ($hook in @($group.hooks)) {
                        $hooks.Add([ordered]@{ event = $event; matcher = [string]$group.matcher; if = [string]$hook.if; command = [string]$hook.command })
                    }
                }
            }
        }
        else { $unknown.Add($source) }
    }
    if ($copied.Count -gt 0) {
        $hashes = @($copied | ForEach-Object { $_[0] } | git -C $RepoRoot hash-object --stdin-paths)
        if ($LASTEXITCODE -ne 0 -or $hashes.Count -ne $copied.Count) { throw "git hash-object failed for package $name." }
        for ($i = 0; $i -lt $copied.Count; $i++) { $files[$copied[$i][1]] = $hashes[$i] }
    }
    $manifest.packages[$name] = [ordered]@{ files = $files; hooks = @($hooks) }
}

$retiredPath = Join-Path $RepoRoot 'config' 'retired-skill-names.txt'
$retired = [ordered]@{}
if (Test-Path -LiteralPath $retiredPath -PathType Leaf) {
    foreach ($line in Get-Content -LiteralPath $retiredPath) {
        $text = $line.Trim()
        if (-not $text -or $text.StartsWith('#')) { continue }
        $parts = @($text -split '\s+')
        if ($parts.Count -ne 2) { throw "'$text' in $retiredPath is not an old name and a new name." }
        $retired[$parts[0]] = $parts[1]
    }
}
$manifest.retired = $retired

if ($unknown.Count -gt 0) {
    Write-Host 'Sync manifest: these files are of a kind the manifest does not know how APM deploys:' -ForegroundColor Red
    foreach ($u in $unknown) { Write-Host "  $u" }
    Write-Host 'FIX: Teach tools/Update-SyncManifest.ps1 and Check-SyncManifest.ps1 where APM puts this kind of file, or move the file.' -ForegroundColor Red
    exit 1
}

$json = (($manifest | ConvertTo-Json -Depth 6) -replace "`r`n", "`n") + "`n"
$current = if (Test-Path -LiteralPath $target) { (Get-Content -LiteralPath $target -Raw) -replace "`r`n", "`n" } else { '' }
$fileCount = @($manifest.packages.Values | ForEach-Object { $_.files.Count } | Measure-Object -Sum).Sum
if ($current -ceq $json) {
    Write-Host "Sync manifest OK: $($packages.Count) package(s), $fileCount file(s)."
    exit 0
}

if ($Check) {
    Write-Host 'Sync manifest out of date: a file under core/.apm or packs/*/.apm changed since the manifest was written.' -ForegroundColor Red
    Write-Host 'FIX: Run pwsh tools/Update-SyncManifest.ps1 and commit the manifest.' -ForegroundColor Red
    Write-Host "  $manifestRelative  differs from the packages"
    exit 1
}

[IO.File]::WriteAllText($target, $json, [Text.UTF8Encoding]::new($false))
Write-Host "Sync manifest written: $target ($fileCount file(s))"
exit 0
