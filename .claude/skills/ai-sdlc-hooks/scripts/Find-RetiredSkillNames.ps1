#Requires -Version 7
<#
.SYNOPSIS
    Lists the lines in the repository's own files that still name a skill by a name that a release
    retired, each with the new name. Advisory: it never fails.

.DESCRIPTION
    A release can rename a skill. APM moves the installed folder, and Sync-AgentsFile.ps1 rewrites the
    shared parts of AGENTS.md. But the repository's own text, such as its own part of AGENTS.md,
    CLAUDE.md or an onboarding page, still names the old skill, and no gate sees it. An agent that
    reads such a line looks for a skill that is gone.

    This script reads the retired names from the installed sync-manifest.json ("retired": each old
    name with its new name). Then it reads every file git tracks, except the files the installed
    packages deliver, and prints each line that names an old name as a whole name. So a skill or an
    agent of the repository's own under .claude/ is read too. A step: line, as in the front matter of an ADR, is left
    out: it records the step that made the file, it is history, and guide-me reads the old names.

    The folder of the decision records (paths.adrFolder in aisdlc.json, docs/adrs by default) is left
    out as a whole. An ADR records a decision as it was made, so changing a skill name in it would
    rewrite history. An ADR outside that folder is still read, except its step: line.

    A repository can mark more files as history in paths.historyPaths of aisdlc.json: paths and glob
    patterns from the repository root, such as a change list that gives the old text on purpose. The
    script leaves out the places in those files, and prints one line with how many it left out. A
    pattern that matches no file gives a warning, so a typo does not hide anything.

    Update-AiSdlc.ps1 runs this after the install. Run it by hand at any time. It changes no file and
    always exits 0. When the new name is an internal step (user-invocable: false), the hit says so, and
    names the command a person types instead when the skill gives one.

.PARAMETER RepoRoot
    The repository root. Defaults to the git root of this script.

.PARAMETER ManifestPath
    Test seam: the manifest to read. Defaults to the installed one in the ai-sdlc-gates skill.

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-hooks/scripts/Find-RetiredSkillNames.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$ManifestPath
)

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = (git -C $PSScriptRoot rev-parse --show-toplevel).Trim() }
if (-not $ManifestPath) { $ManifestPath = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'sync-manifest.json' }

if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    Write-Host "Retired skill names not checked: $ManifestPath does not exist."
    exit 0
}
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -AsHashtable
$retired = @{}
if ($manifest.Contains('retired') -and $manifest.retired) {
    foreach ($old in $manifest.retired.Keys) { $retired[[string]$old] = [string]$manifest.retired[$old] }
}
if ($retired.Count -eq 0) { exit 0 }

# A new name can be an internal step (user-invocable: false in its front matter): skills call it, and
# Claude Code keeps it out of the slash-command list. Say so next to the hit, so a person does not type
# it. When the skill names the command a person types instead ("a person types `/x`"), name it too.
$notes = @{}
foreach ($new in @($retired.Values | Sort-Object -Unique)) {
    $skillFile = Join-Path $RepoRoot '.claude' 'skills' $new 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillFile -PathType Leaf)) { continue }
    $text = Get-Content -LiteralPath $skillFile -Raw
    $front = [regex]::Match($text, '\A---\r?\n(?<fm>[\s\S]*?)\r?\n---')
    if (-not $front.Success -or $front.Groups['fm'].Value -notmatch '(?m)^user-invocable:\s*false\s*$') { continue }
    $typed = [regex]::Match($text, 'a person types `/(?<cmd>[a-z0-9-]+)`')
    $notes[$new] = if ($typed.Success) { " (an internal step: skills call it; a person types /$($typed.Groups['cmd'].Value))" }
                   else { ' (an internal step: skills call it, a person does not type it)' }
}

$names = @($retired.Keys | Sort-Object { $_.Length } -Descending | ForEach-Object { [regex]::Escape($_) })
$regex = [regex]::new('(?<![A-Za-z0-9_-])(' + ($names -join '|') + ')(?![A-Za-z0-9_-])')
$stepLine = [regex]::new('^\s*step:\s*[''"]?[A-Za-z0-9_-]+[''"]?\s*$')

# Skip the files the packages deliver, and the manifest itself. A skill or an agent of the
# repository's own under .claude/ is not in the manifest, so it is read like any other file.
$installed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
[void]$installed.Add('.claude/skills/ai-sdlc-gates/sync-manifest.json')
if ($manifest.Contains('packages') -and $manifest.packages) {
    foreach ($package in $manifest.packages.Keys) {
        $delivered = $manifest.packages[$package]
        if ($delivered -is [System.Collections.IDictionary] -and $delivered.Contains('files') -and $delivered.files) {
            foreach ($path in $delivered.files.Keys) { [void]$installed.Add([string]$path) }
        }
    }
}
# The decision records are history, so their folder is left out. So are the files the repository marks
# as history (paths.historyPaths). A broken aisdlc.json falls back to the default folder and no history
# paths, because this script never fails.
$adrFolder = 'docs/adrs'
$historyPatterns = @()
try {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts' 'AiSdlcConfig.psm1') -Force
    $config = Get-AiSdlcConfig -RepoRoot $RepoRoot
    $configured = [string]$config.paths.adrFolder
    if ($configured) { $adrFolder = $configured }
    $historyPatterns = @($config.paths.historyPaths | Where-Object { $_ } | ForEach-Object { ([string]$_).Replace('\', '/') -replace '^\./', '' } | ForEach-Object { $_.Trim('/') } | Where-Object { $_ })
}
catch { Write-Verbose "aisdlc.json not read, so $adrFolder is the ADR folder: $($_.Exception.Message)" }
$adrPrefix = ($adrFolder.Replace('\', '/') -replace '^\./', '').Trim('/') + '/'

# One rule for every history pattern: * and ? stay inside one folder, ** crosses folders, and a pattern
# that names a folder covers every file under it.
$historyRules = foreach ($pattern in $historyPatterns) {
    $body = ([regex]::Escape($pattern) -replace '\\\*\\\*/', '(?:.*/)?' -replace '\\\*\\\*', '.*' -replace '\\\*', '[^/]*' -replace '\\\?', '[^/]')
    [pscustomobject]@{ Pattern = $pattern; Regex = [regex]::new("^$body(?:/.*)?$", 'IgnoreCase'); Matched = $false }
}
function Test-HistoryPath([string]$Rel) {
    $hit = $false
    foreach ($rule in $historyRules) {
        if ($rule.Regex.IsMatch($Rel)) { $rule.Matched = $true; $hit = $true }
    }
    return $hit
}

$tracked = @(git -C $RepoRoot ls-files 2>$null)
$history = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($rel in $tracked) { if (Test-HistoryPath $rel) { [void]$history.Add($rel) } }
foreach ($rule in $historyRules | Where-Object { -not $_.Matched }) {
    Write-Warning "paths.historyPaths in aisdlc.json: '$($rule.Pattern)' matches no file. Check the pattern for a typo."
}
$files = @($tracked | Where-Object { -not $installed.Contains($_) -and -not $_.StartsWith($adrPrefix, [StringComparison]::OrdinalIgnoreCase) })
$findings = [System.Collections.Generic.List[string]]::new()
$historyHits = 0
foreach ($rel in $files) {
    $full = Join-Path $RepoRoot $rel
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
    try {
        $bytes = [IO.File]::ReadAllBytes($full)
        if ([Array]::IndexOf($bytes, [byte]0) -ge 0) { continue }
        $lines = [Text.Encoding]::UTF8.GetString($bytes) -split "`r?`n"
    }
    catch { continue }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($stepLine.IsMatch($lines[$i])) { continue }
        foreach ($m in $regex.Matches($lines[$i])) {
            if ($history.Contains($rel)) { $historyHits++; continue }
            $newName = $retired[$m.Groups[1].Value]
            $findings.Add(('  {0}:{1}  {2} -> {3}{4}' -f $rel, ($i + 1), $m.Groups[1].Value, $newName, $notes[$newName]))
        }
    }
}

$historyLine = "Retired skill names: $historyHits place(s) in files marked as history in aisdlc.json (paths.historyPaths) are left out."
if ($findings.Count -eq 0) {
    Write-Host 'Retired skill names: no file of the repository uses an old skill name.'
    if ($historyHits) { Write-Host $historyLine }
    exit 0
}

Write-Host "Retired skill names: $($findings.Count) place(s) in the repository's own files still use an old skill name." -ForegroundColor Yellow
Write-Host 'Change each to the new name, in this update or soon after. The AI-SDLC never changes these files itself.' -ForegroundColor Yellow
foreach ($f in $findings) { Write-Host $f }
if ($historyHits) { Write-Host $historyLine }
exit 0
