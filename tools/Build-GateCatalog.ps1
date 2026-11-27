#Requires -Version 7
<#
.SYNOPSIS
    Writes the two pages that describe every gate, or checks they are current.

.DESCRIPTION
    Each gate is an entry in a gates.json file of a package, or in repoGates of aisdlc.json, and each entry
    carries a checks text and a fix text. This script turns those entries into two pages, so one place
    always says what each gate is about and nothing is written by hand:

      - core/.apm/skills/ai-sdlc-gates/references/gate-catalog.md holds the gates of the core and of every
        pack, one section per package. A consumer gets it with the core, so it names no repository path.
      - docs/gates.md holds the repository gates of aisdlc.json, and links the shared page.

    Each gate shows its name, clause, mode, where it runs, the script and the checks and fix texts. The
    core comes first and the packs follow in the order of their names. Inside a package the gates keep
    the order of the skill folders and of each file. A package with no gate has no section. The pages
    carry LF line endings and no date, so a second run changes nothing.

    With -Check the script writes nothing, prints each page that differs or is missing as "path : text"
    with a FIX line, and exits 1. Exit codes follow the gate contract: 0 current (or written), 1 out of
    date, 2 could not check (no core or packs folder, a gates.json or aisdlc.json that cannot be read, or
    a gate with no checks or fix text), 3 not applicable (no gate in any gates.json file or in repoGates).

.PARAMETER RepoRoot
    The AI.SDLC repository root. Defaults to the folder above this script.

.PARAMETER Check
    Compare only. Exit 1 when a page differs from the gates.

.EXAMPLE
    pwsh tools/Build-GateCatalog.ps1

.EXAMPLE
    pwsh tools/Build-GateCatalog.ps1 -Check
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'

function Stop-NotChecked([string]$Reason, [string]$Fix) {
    Write-Host "Could not check: $Reason" -ForegroundColor Yellow
    Write-Host "FIX: $Fix" -ForegroundColor Yellow
    exit 2
}

$rerun = 'Run pwsh tools/Build-GateCatalog.ps1 and commit both pages.'
$fromRoot = 'Run the tool from the AI.SDLC repository, or pass -RepoRoot with its root.'
if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot 'core') -PathType Container)) { Stop-NotChecked "no core folder under $RepoRoot." $fromRoot }
if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot 'packs') -PathType Container)) { Stop-NotChecked "no packs folder under $RepoRoot." $fromRoot }

function Sort-Ordinal([string[]]$Values) {
    $copy = [string[]]@($Values)
    [Array]::Sort($copy, [StringComparer]::Ordinal)
    return $copy
}

function Read-Json([string]$Path) {
    try { return Get-Content -LiteralPath $Path -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { Stop-NotChecked "$([IO.Path]::GetRelativePath($RepoRoot, $Path).Replace('\', '/')) could not be read: $($_.Exception.Message)" 'Make the file valid JSON.' }
}

function Get-RunsIn {
    param($Entry)

    if ($Entry.mode -eq 'Off') { return 'nowhere (the gate is Off)' }
    if ($Entry.requires -eq 'CoverageFile') { return 'only when the run gets a coverage file' }
    if ($Entry.mode -eq 'Advisory') { return 'pull request action (as a warning), local run' }
    return 'pre-push hook, pull request action, local run'
}

function Assert-GateText {
    param($Entry, [string]$Source)

    foreach ($field in @('name', 'checks', 'fix')) {
        if ($Entry[$field] -isnot [string] -or [string]::IsNullOrWhiteSpace($Entry[$field])) {
            $label = if ($Entry.name -is [string] -and $Entry.name) { "'$($Entry.name)'" } else { "an entry of $Source" }
            Stop-NotChecked "the gate $label in $Source has no $field text." "Add a $field text to the entry, then run pwsh tools/Build-GateCatalog.ps1."
        }
    }
}

function Get-GateSection {
    param($Entry, [string]$ScriptPath, [string]$Source, [string]$DefaultClause)

    Assert-GateText -Entry $Entry -Source $Source
    $mode = if ($Entry.mode) { [string]$Entry.mode } else { 'Blocking' }
    $canonical = @('Blocking', 'Advisory', 'Off') | Where-Object { $_ -eq $mode }
    if ($canonical) { $mode = $canonical }
    $withMode = @{} + $Entry
    $withMode.mode = $mode
    $inputsLine = $null
    if (@($Entry.inputs | Where-Object { $_ }).Count -gt 0) {
        $globs = @($Entry.inputs | ForEach-Object { '`' + $_ + '`' }) -join ', '
        $inputsLine = "- Runs locally when the change touches: $globs, or the skill or tool folder of its script"
    }
    return @(
        "### $($Entry.name.Trim())"
        ''
        "- Clause: $(if ($Entry.clause) { $Entry.clause } else { $DefaultClause })"
        "- Mode: $mode"
        "- Runs in: $(Get-RunsIn -Entry $withMode)"
        $inputsLine
        "- Script: ``$ScriptPath``"
        "- Checks: $($Entry.checks.Trim())"
        "- Fix: $($Entry.fix.Trim())"
        ''
    ) | Where-Object { $null -ne $_ }
}

$packages = [ordered]@{}
$packages['core'] = Join-Path $RepoRoot 'core'
foreach ($name in (Sort-Ordinal @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'packs') -Directory | ForEach-Object Name))) { $packages[$name] = Join-Path $RepoRoot 'packs' $name }

$sharedLines = [System.Collections.Generic.List[string]]::new()
$sharedLines.AddRange([string[]]@(
        '# Gate list'
        ''
        'Every gate of the core and of each pack, with what it checks and how to fix a finding. A script makes this page from the `gates.json` files of the packages, so do not edit it by hand.'
        ''
        'A gate that fails or cannot check prints its checks text before its own output. Run `Invoke-LocalGates.ps1 -List` to see the same texts for the gates of one repository. A package with no gate has no section.'
        ''
    ))
$gateCount = 0
foreach ($package in $packages.Keys) {
    $skills = Join-Path $packages[$package] '.apm' 'skills'
    if (-not (Test-Path -LiteralPath $skills -PathType Container)) { continue }
    $sections = [System.Collections.Generic.List[string]]::new()
    foreach ($skill in (Sort-Ordinal @(Get-ChildItem -LiteralPath $skills -Directory | ForEach-Object Name))) {
        $manifest = Join-Path $skills $skill 'gates.json'
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { continue }
        $data = Read-Json $manifest
        $source = [IO.Path]::GetRelativePath($RepoRoot, $manifest).Replace('\', '/')
        foreach ($entry in @($data.gates)) {
            if (-not $entry) { continue }
            $scriptPath = ".claude/skills/$skill/$($entry.script)"
            $sections.AddRange([string[]]@(Get-GateSection -Entry $entry -ScriptPath $scriptPath -Source $source -DefaultClause $package))
            $gateCount++
        }
    }
    if ($sections.Count -eq 0) { continue }
    $sharedLines.Add("## $package")
    $sharedLines.Add('')
    $sharedLines.AddRange($sections)
}
$sharedLines.AddRange([string[]]@(
        '## Related'
        ''
        '- [AI-SDLC gates](../SKILL.md) - the gates, the exit codes and the runner.'
    ))

$configPath = Join-Path $RepoRoot 'aisdlc.json'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { Stop-NotChecked "no aisdlc.json under $RepoRoot." $fromRoot }
$config = Read-Json $configPath
$localLines = [System.Collections.Generic.List[string]]::new()
$localLines.AddRange([string[]]@(
        '# Repository gates'
        ''
        'The gates that only AI.SDLC runs, from `repoGates` in `aisdlc.json`. A script makes this page from that list, so do not edit it by hand.'
        ''
        'The gates of the core and of the packs are on the [shared gate list](../core/.apm/skills/ai-sdlc-gates/references/gate-catalog.md). A gate that fails or cannot check prints its checks text before its own output.'
        ''
        '## Gates'
        ''
    ))
$repoCount = 0
foreach ($entry in @($config.repoGates)) {
    if (-not $entry) { continue }
    $localLines.AddRange([string[]]@(Get-GateSection -Entry $entry -ScriptPath ([string]$entry.script) -Source 'aisdlc.json' -DefaultClause 'repo'))
    $repoCount++
}
$localLines.AddRange([string[]]@(
        '## Related'
        ''
        '- [Tools](tools.md) - the scripts of this repository, including the tool that writes this page.'
        '- [Shared gate list](../core/.apm/skills/ai-sdlc-gates/references/gate-catalog.md) - the gates of every package.'
    ))

if ($gateCount + $repoCount -eq 0) {
    Write-Host 'Not applicable: no gate in any gates.json file or in repoGates of aisdlc.json, so there is no gate page to build or compare.'
    exit 3
}

$pages = [ordered]@{
    'core/.apm/skills/ai-sdlc-gates/references/gate-catalog.md' = (($sharedLines -join "`n") + "`n")
    'docs/gates.md'                                             = (($localLines -join "`n") + "`n")
}

$stale = [System.Collections.Generic.List[string]]::new()
$missing = [System.Collections.Generic.List[string]]::new()
foreach ($relative in $pages.Keys) {
    $target = Join-Path $RepoRoot $relative
    $exists = Test-Path -LiteralPath $target -PathType Leaf
    if ($Check -and -not $exists) { $stale.Add($relative); $missing.Add($relative); continue }
    try { $current = if ($exists) { (Get-Content -LiteralPath $target -Raw -Encoding utf8 -ErrorAction Stop) -replace "`r`n", "`n" } else { '' } }
    catch { Stop-NotChecked "the page $relative could not be read: $($_.Exception.Message)" $rerun }
    if ($current -ceq $pages[$relative]) { continue }
    $stale.Add($relative)
}

if ($stale.Count -eq 0) {
    Write-Host ("Gate pages current: {0} package gate(s), {1} repository gate(s)." -f $gateCount, $repoCount)
    exit 0
}

if ($Check) {
    Write-Host 'Gate pages out of date: a gate was added, changed or removed since the pages were written.' -ForegroundColor Red
    Write-Host "FIX: $rerun" -ForegroundColor Red
    foreach ($relative in $stale) { Write-Host ("  {0} : {1}" -f $relative, $(if ($relative -in $missing) { 'missing' } else { 'differs from the gates' })) }
    exit 1
}

foreach ($relative in $stale) {
    $target = Join-Path $RepoRoot $relative
    New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($target, $pages[$relative], [Text.UTF8Encoding]::new($false))
    Write-Host "Gate page written: $relative"
}
exit 0
