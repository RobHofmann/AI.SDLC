#Requires -Version 7
<#
.SYNOPSIS
    Gate: no shared file or page of AI.SDLC names a skill by a name that a release retired.

.DESCRIPTION
    A renamed skill keeps working only where every reference moved with it. The hygiene gate checks
    "/name" links inside SKILL.md files, but a name in backticks or in plain text passes it, so a stale
    name could tell an agent to load a skill that no longer exists. This gate reads every file and fails
    on any old name from the retired list, in any form: plain, in backticks, after a slash, or in a link.

    The retired list is a text file: one pair per line, the old name, a space, then the new name. Blank
    lines and lines that start with # are skipped. A name counts only as a whole name, so "old-name"
    matches, but "old-name-x" and "x-old-name" do not.

    A Markdown heading line is also checked for an old name of two or more words written with spaces,
    in any case, so "# Old name (the loop)" fails. A normal sentence that says "old name" passes,
    because a title that names a retired skill is what a reader takes as its name.

    The sync manifest is skipped: Update-SyncManifest.ps1 writes the retired names into it on purpose,
    so a consumer can find a folder an older version left behind. CHANGELOG.md is not scanned, because
    its entries are history.

    Exit codes follow the gate contract: 0 nothing found, 1 a finding, 2 could not check.

.PARAMETER RepoRoot
    The AI.SDLC repository root. Defaults to the folder above this script.

.PARAMETER RetiredListPath
    The retired list. Defaults to <RepoRoot>/config/retired-skill-names.txt.

.PARAMETER Path
    The folders and files to scan, relative to RepoRoot. Defaults to core, packs, docs,
    docs-functional, README.md, AGENTS.md, and the committed agent files of this repository:
    .claude/settings.json, .claude/CLAUDE.md and CLAUDE.md. A permission rule there that names an old
    skill folder allows a script that is no longer there.

.EXAMPLE
    pwsh tools/Check-RetiredSkillNames.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string]$RetiredListPath,
    [string[]]$Path = @('core', 'packs', 'docs', 'docs-functional', 'README.md', 'AGENTS.md', '.claude/settings.json', '.claude/CLAUDE.md', 'CLAUDE.md')
)

$ErrorActionPreference = 'Stop'

if (-not $RetiredListPath) { $RetiredListPath = Join-Path $RepoRoot 'config' 'retired-skill-names.txt' }
if (-not (Test-Path -LiteralPath $RetiredListPath -PathType Leaf)) {
    Write-Host "Could not check: the retired list $RetiredListPath does not exist." -ForegroundColor Yellow
    exit 2
}

$retired = [ordered]@{}
foreach ($line in Get-Content -LiteralPath $RetiredListPath) {
    $text = $line.Trim()
    if (-not $text -or $text.StartsWith('#')) { continue }
    $parts = @($text -split '\s+')
    if ($parts.Count -ne 2 -or $parts[0] -notmatch '^[a-z0-9][a-z0-9-]*$' -or $parts[1] -notmatch '^[a-z0-9][a-z0-9-]*$') {
        Write-Host "Could not check: '$text' in $RetiredListPath is not an old name and a new name." -ForegroundColor Yellow
        exit 2
    }
    $retired[$parts[0]] = $parts[1]
}
if ($retired.Count -eq 0) {
    Write-Host "Retired skill names OK: the retired list holds no names, so nothing can name a retired skill."
    exit 0
}

$names = @($retired.Keys | Sort-Object { $_.Length } -Descending | ForEach-Object { [regex]::Escape($_) })
$regex = [regex]::new('(?<![A-Za-z0-9_-])(' + ($names -join '|') + ')(?![A-Za-z0-9_-])')

# A heading names a skill in words: "# Generate code" for generate-code. Only names of two or more words.
$spaced = @{}
foreach ($old in $retired.Keys) {
    if ($old -notmatch '-') { continue }
    $spaced[$old] = [regex]::new('(?<![A-Za-z0-9_-])' + (($old -split '-' | ForEach-Object { [regex]::Escape($_) }) -join '\s+') + '(?![A-Za-z0-9_-])', 'IgnoreCase')
}
$headingRegex = [regex]::new('^\s{0,3}#{1,6}\s')

$files = foreach ($p in $Path) {
    $full = Join-Path $RepoRoot $p
    if (Test-Path -LiteralPath $full -PathType Leaf) { Get-Item -LiteralPath $full -Force }
    elseif (Test-Path -LiteralPath $full) { Get-ChildItem -LiteralPath $full -Recurse -File -Force }
}
$files = @($files | Where-Object { $_.Name -ne 'sync-manifest.json' -and $_.Name -ne 'CHANGELOG.md' })

$findings = [System.Collections.Generic.List[object]]::new()
foreach ($file in $files) {
    $rel = [IO.Path]::GetRelativePath($RepoRoot, $file.FullName).Replace('\', '/')
    $n = 0
    foreach ($line in [IO.File]::ReadLines($file.FullName)) {
        $n++
        foreach ($m in $regex.Matches($line)) {
            $findings.Add([pscustomobject]@{ File = $rel; Line = $n; Old = $m.Groups[1].Value; New = $retired[$m.Groups[1].Value] })
        }
        if ($file.Extension -eq '.md' -and $headingRegex.IsMatch($line)) {
            foreach ($old in $spaced.Keys) {
                $m = $spaced[$old].Match($line)
                if ($m.Success) { $findings.Add([pscustomobject]@{ File = $rel; Line = $n; Old = $m.Value; New = $retired[$old] }) }
            }
        }
    }
}

if ($findings.Count -gt 0) {
    Write-Host 'Retired skill names: these lines still name a skill by its old name.' -ForegroundColor Red
    Write-Host 'FIX: Use the new name on each line below. A link to the skill folder moves with it.' -ForegroundColor Red
    foreach ($f in $findings) { Write-Host ("  {0}:{1}  {2} -> {3}" -f $f.File, $f.Line, $f.Old, $f.New) }
    Write-Host ("Found {0} retired name(s)." -f $findings.Count) -ForegroundColor Red
    exit 1
}

Write-Host ("Retired skill names OK: {0} file(s) checked against {1} retired name(s)." -f $files.Count, $retired.Count)
exit 0
