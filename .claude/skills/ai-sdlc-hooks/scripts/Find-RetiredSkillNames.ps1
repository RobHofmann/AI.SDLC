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

    In the folder of the decision records (paths.adrFolder in aisdlc.json, docs/adrs by default) only
    paths are read. One is the target of a markdown link, also one whose text wraps to the next line.
    Another is a path in the relates: block or the intent.hypothesis line of the front matter. The link and the
    artifact graph gates fail on such a path, so it must change. The rest of an ADR records a decision
    as it was made, so a skill name in its text stays, and so does a link inside code. A hit in an ADR
    says so. An ADR outside that folder is read like any other file, except its step: line.

    A docs index that Build-DocsIndex.ps1 wrote is left out, found by its generated header in the first
    5 lines. An index.md written by hand, with no such header, is read like any other file.

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
$linkTitle = '(?:\s+(?:"[^"]*"|''[^'']*''|\([^)]*\)))?'
$inlineLink = [regex]::new('\[[^\]]*\]\(\s*(?:<(?<t>[^>\r\n]+)>|(?<t>[^)\s]+))' + $linkTitle + '\s*\)')
$definitionLink = [regex]::new('(?m)^[ ]{0,3}\[(?!\^)[^\]\r\n]+\]:[ \t]*(?:<(?<t>[^>\r\n]+)>|(?<t>\S+))')
$adrNote = ' (a path in a decision record: change the path, not the decision)'
# The header Build-DocsIndex.ps1 writes as the first line of a docs index it generated.
$generatedIndexHeader = '<!-- Generated by .claude/skills/ai-sdlc-gates/scripts/Build-DocsIndex.ps1; do not edit by hand. Run the script to regenerate. -->'

<#
.SYNOPSIS
    Returns the paths that a decision record holds, by line index.
.DESCRIPTION
    Reads the front matter (the entries under relates: and the hypothesis: line under intent:) and the
    markdown link targets of the body. A fenced code block and an inline code span count as no link.
    A link whose text wraps is reported on the line of its target.
.PARAMETER Lines
    The lines of the ADR.
#>
function Get-DecisionRecordPath([string[]]$Lines) {
    $found = @{}
    $add = { param([int]$At, [string]$Text) if (-not $found.ContainsKey($At)) { $found[$At] = @() }; $found[$At] += $Text }
    $bodyStart = 0
    if ($Lines.Count -gt 0 -and $Lines[0].TrimEnd() -eq '---') {
        $close = -1
        for ($i = 1; $i -lt $Lines.Count; $i++) { if ($Lines[$i].TrimEnd() -eq '---') { $close = $i; break } }
        if ($close -gt 0) {
            $block = ''
            for ($i = 1; $i -lt $close; $i++) {
                $line = $Lines[$i]
                if ($line -match '^(?<key>[A-Za-z0-9_-]+):') { $block = $Matches['key']; continue }
                if ($block -eq 'relates' -and $line -match '^\s+(?:-\s+)?(?:[A-Za-z0-9_-]+:\s+)?(?<v>\S.*?)\s*$') { & $add $i $Matches['v'] }
                elseif ($block -eq 'intent' -and $line -match '^\s+hypothesis:\s*(?<v>\S.*?)\s*$') { & $add $i $Matches['v'] }
            }
            $bodyStart = $close + 1
        }
    }

    $body = [string[]]::new($Lines.Count)
    $fence = $null
    for ($i = $bodyStart; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if ($fence) {
            if ($line -match "^ {0,3}$([regex]::Escape([string]$fence[0])){$($fence.Length),}\s*$") { $fence = $null }
            continue
        }
        if ($line -match '^ {0,3}(`{3,}|~{3,})') { $fence = $Matches[1]; continue }
        $body[$i] = [regex]::Replace($line, '`[^`]*`', '')
    }
    $starts = [int[]]::new($Lines.Count)
    $offset = 0
    for ($i = 0; $i -lt $Lines.Count; $i++) { $starts[$i] = $offset; $offset += ([string]$body[$i]).Length + 1 }
    $joined = ($body | ForEach-Object { [string]$_ }) -join "`n"
    foreach ($rx in $inlineLink, $definitionLink) {
        foreach ($m in $rx.Matches($joined)) {
            $group = $m.Groups['t']
            $at = [Array]::BinarySearch($starts, $group.Index)
            if ($at -lt 0) { $at = (-bnot $at) - 1 }
            & $add $at $group.Value
        }
    }
    return $found
}

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
# In the decision records only paths count. The files the repository marks as history
# (paths.historyPaths) are left out. A broken aisdlc.json falls back to the default folder and no history
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
$files = @($tracked | Where-Object { -not $installed.Contains($_) })
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
    if (@($lines | Select-Object -First 5 | ForEach-Object { $_.TrimEnd() }) -contains $generatedIndexHeader) { continue }
    $isAdr = $rel.StartsWith($adrPrefix, [StringComparison]::OrdinalIgnoreCase)
    $decisionPaths = if ($isAdr) { Get-DecisionRecordPath $lines } else { $null }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($stepLine.IsMatch($lines[$i])) { continue }
        $texts = if ($null -eq $decisionPaths) { @($lines[$i]) } elseif ($decisionPaths.ContainsKey($i)) { $decisionPaths[$i] } else { @() }
        foreach ($text in $texts) {
            foreach ($m in $regex.Matches($text)) {
                if ($history.Contains($rel)) { $historyHits++; continue }
                $newName = $retired[$m.Groups[1].Value]
                $findings.Add(('  {0}:{1}  {2} -> {3}{4}{5}' -f $rel, ($i + 1), $m.Groups[1].Value, $newName, $notes[$newName], $(if ($isAdr) { $adrNote })))
            }
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
