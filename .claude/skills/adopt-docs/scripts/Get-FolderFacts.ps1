#Requires -Version 7
<#
.SYNOPSIS
    Reads what a folder holds, for a unit that no pack reads: the skills and agents with their
    descriptions, the scripts with their synopsis, the gates, and the other files by name.

.DESCRIPTION
    A pack reads its own units: the dotnet pack reads a project, the bicep pack a building block. A
    unit that no pack names, such as a package of AI.SDLC or a folder of scripts, gets its facts
    here. New-DocCandidate.ps1 uses this script when no installed pack claims the unit.

    It reads, without running anything:

      - a SKILL.md or an agent file: its name and its description from the front matter;
      - a .ps1 or .psm1 file that is not a test: the first line of its .SYNOPSIS;
      - a gates.json: the name and the mode of each gate;
      - any other markdown file: its H1;
      - every other file: its path.

    The list is capped, so the request to the model stays small.

.PARAMETER Unit
    The folder, relative to RepoRoot.

.PARAMETER RepoRoot
    The repository root. Defaults to the folder that holds aisdlc.json, or the git top level.

.PARAMETER MaximumFiles
    How many files to read. Defaults to 400.

.EXAMPLE
    pwsh .claude/skills/adopt-docs/scripts/Get-FolderFacts.ps1 -Unit packs/bicep
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Unit,
    [string]$RepoRoot,
    [int]$MaximumFiles = 400
)

$ErrorActionPreference = 'Stop'
$gates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
Import-Module (Join-Path $gates 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$folder = Join-Path $RepoRoot $Unit
if (-not (Test-Path -LiteralPath $folder -PathType Container)) { throw "Get-FolderFacts: '$Unit' is not a folder under $RepoRoot." }
$folder = (Resolve-Path -LiteralPath $folder).Path
if (-not $folder.StartsWith($RepoRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "Get-FolderFacts: '$Unit' resolves outside the repository." }

function Get-FrontMatterField {
    param([string]$Text, [string]$Name)
    $fm = [regex]::Match($Text, '\A﻿?---\r?\n(?<fm>.*?)\r?\n---', 'Singleline')
    if (-not $fm.Success) { return '' }
    $block = $fm.Groups['fm'].Value
    $inline = [regex]::Match($block, "(?m)^$Name[ \t]*:[ \t]*(?<v>[^\s>|][^\r\n]*)$")
    if ($inline.Success) { return $inline.Groups['v'].Value.Trim().Trim('"', "'") }
    $folded = [regex]::Match($block, "(?ms)^$Name\s*:\s*[>|]-?\s*\r?\n(?<v>(?:[ \t]+[^\r\n]*\r?\n?)+)")
    if ($folded.Success) { return (($folded.Groups['v'].Value -split '\r?\n' | ForEach-Object { $_.Trim() }) -join ' ').Trim() }
    return ''
}

$files = @(Get-ChildItem -LiteralPath $folder -Recurse -File -Force |
        Where-Object { $_.FullName -notmatch '[\\/](\.git|bin|obj|node_modules|apm_modules)[\\/]' } |
        Sort-Object FullName)

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("UNIT: $Unit ($($files.Count) files)")
$read = 0
foreach ($file in $files) {
    if ($read -ge $MaximumFiles) { $lines.Add("  ... and $($files.Count - $read) more files, capped so the request stays small"); break }
    $read++
    $rel = [IO.Path]::GetRelativePath($RepoRoot, $file.FullName).Replace('\', '/')
    $name = $file.Name
    if ($name -like '*.Tests.ps1' -or $name -like '*.tests.ps1') { $lines.Add("  test: $rel"); continue }
    switch -Regex ($name) {
        '^SKILL\.md$' {
            $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
            $lines.Add("  skill $(Get-FrontMatterField $text 'name'): $(Get-FrontMatterField $text 'description') ($rel)")
            break
        }
        '\.agent\.md$' {
            $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
            $lines.Add("  agent $(Get-FrontMatterField $text 'name'): $(Get-FrontMatterField $text 'description') ($rel)")
            break
        }
        '\.(ps1|psm1)$' {
            $text = [string](Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8)
            $synopsis = [regex]::Match($text, '(?s)\.SYNOPSIS\s*\r?\n\s*(?<s>[^\r\n]+)')
            $what = if ($synopsis.Success) { " - $($synopsis.Groups['s'].Value.Trim())" } else { '' }
            $lines.Add("  script: $rel$what")
            break
        }
        '^gates\.json$' {
            $data = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
            $lines.Add("  gates of package $($data.package) ($rel):")
            foreach ($gate in @($data.gates)) { $lines.Add("    $($gate.mode) gate: $($gate.name)") }
            break
        }
        '\.md$' {
            $text = [string](Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8)
            $h1 = [regex]::Match($text, '(?m)^#\s+(?<t>.+?)\s*$')
            $title = if ($h1.Success) { " - $($h1.Groups['t'].Value)" } else { '' }
            $lines.Add("  page: $rel$title")
            break
        }
        default { $lines.Add("  file: $rel") }
    }
}
return $lines.ToArray()
