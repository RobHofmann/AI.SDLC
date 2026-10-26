#Requires -Version 7
<#
.SYNOPSIS
    Gate: a text that points at a section of another page points at a section that is there.

.DESCRIPTION
    A Pester test file (*.Tests.ps1) is skipped: its fixtures hold pointers that break on purpose.

    Check-DocsWiki.ps1 checks that a link resolves to a file. Check-DocDrift.ps1 checks that a file
    or symbol a page names still exists. Neither reads what comes after the file name, so "see the X
    section of page.md" survives the section being renamed, moved or deleted. A reader then follows
    the pointer, does not find the rule, and either guesses or gives up.

    That is not a theory. `Update-DocFromGraph.ps1` sent a reader to "The documentation updater
    credentials" in docs/local-development.md, where the heading reads "The documentation updater's
    credentials". One apostrophe, no check, months in the tree. And `fix-pr-feedback` told the
    reader that a repository id was cached in AGENTS.md, which it never was.

    Three forms are read, because these are the three the repository uses:

      A. NAMED SECTION.  the `## Communication` section of `AGENTS.md`, where the name sits in
                         backticks; or the bare shape, which has to start with the word "the".
                         The target must carry a HEADING with that text. Two shapes, because a
                         looser one starts matching in the middle of a sentence and takes the prose
                         in front of it as the section name.
      B. QUOTED SECTION. `example-page.md`, "Example Section"  or  `other-page.md` ("Other Section").
                         The target must contain that text somewhere. This is on purpose weaker than
                         form A: the quote is not always a heading, and a rule that demanded one would
                         fire on correct pages.
      C. LINK ANCHOR.    a markdown link whose target carries a #fragment. The target must carry a
                         heading that turns into that anchor.

    One more form is read in a script (.ps1, .psm1 or .yml), and not in a page:

      D. DECISION RECORD. a path into the adrFolder of aisdlc.json, in the form <adrFolder>/NNNN-name.md.
                         That file must exist. A help block is outside the wiki gate, so an ADR that
                         was renamed or removed would leave the script pointing at nothing. The dotnet
                         drift check reads pages only, and a repository without that pack has no check
                         at all.

    A file name it cannot resolve to exactly one file is skipped in silence. Whether a file that a page
    names exists at all is Check-DocDrift.ps1's question, and this gate does not answer it twice.

    The name-to-file index is built from the files git tracks, not from what is on disk. A developer
    with git worktrees under .claude/worktrees has a second copy of every page, which made the name
    ambiguous and silently skipped the check on that machine while CI, with one copy, reported it.
    A gate whose answer depends on which machine runs it is worse than no gate.

    In a .ps1 or .psm1 file a doubled apostrophe is read as one, because that is how PowerShell
    escapes an apostrophe inside a single-quoted string. Without that, a pointer at a heading with an
    apostrophe in it could never be written in a PowerShell message.

    Exit 0 clean, 1 a finding. Blocking: it was green on the whole repository the day it was written,
    so it carries no old debt, and every finding is a one-line fix in the text that points.

.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script.

.PARAMETER Path
    Limit the scan to this file or folder, relative to RepoRoot. Without it the gate scans
    paths.sectionRefRoots in aisdlc.json and the root pages AGENTS.md, CLAUDE.md, README.md and ONBOARDING.md, and .claude/CLAUDE.md.

.PARAMETER Detail
    Print every finding as file:line, which is the default, plus the headings the target does carry.

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Check-DocSectionRefs.ps1

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Check-DocSectionRefs.ps1 -Path .claude/skills -Detail
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$Path,
    [switch]$Detail
)

Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

$ErrorActionPreference = 'Stop'

$script:ScanRoots = @(Get-AiSdlcPath -Name sectionRefRoots -RepoRoot $RepoRoot -Relative)
$script:ScanFiles = @('AGENTS.md', 'CLAUDE.md', '.claude/CLAUDE.md', 'README.md', 'ONBOARDING.md')
$script:ScanExtensions = @('.md', '.ps1', '.psm1', '.yml')

$script:BacktickedSection = '`(?:#{1,6}\s*)?(?<name>[^`\r\n]{2,60})`\s+section\s+(?:of|in)\s+`?(?<file>[A-Za-z0-9_./-]+\.md)`?'
$script:BareSection = '\bthe\s+(?<name>[A-Za-z][A-Za-z0-9 -]{1,50}?)\s+section\s+(?:of|in)\s+`?(?<file>[A-Za-z0-9_./-]+\.md)`?'
$script:QuotedSection = '`?(?<file>[A-Za-z0-9_./-]+\.md)`?\s*(?:,\s*|\s*\(\s*)"(?<name>[A-Z][^"\r\n]{2,80})"'
$script:LinkAnchor = '\]\(\s*(?<file>[^)\s#]+\.md)#(?<anchor>[A-Za-z0-9_-]+)\s*\)'
$script:ScriptExtensions = @('.ps1', '.psm1', '.yml')
$adrFolder = [string](@(Get-AiSdlcPath -Name adrFolder -RepoRoot $RepoRoot -Relative) | Select-Object -First 1)
$script:AdrPath = if ($adrFolder) { '(?<![A-Za-z0-9_./-])' + [regex]::Escape($adrFolder.Replace('\', '/').Trim('/')) + '/[0-9]{4}-[A-Za-z0-9_.-]+\.md' } else { $null }

function ConvertTo-ReadableLine {
    param([string]$Line, [string]$Extension)

    if ($Extension -in @('.ps1', '.psm1')) { return $Line -replace "''", "'" }
    return $Line
}

function ConvertTo-Slug {
    param([string]$Heading)

    $text = $Heading.ToLowerInvariant()
    $text = $text -replace '`', ''
    $text = $text -replace '[^a-z0-9 \-]', ''
    $text = $text.Trim() -replace '\s+', '-'
    return $text
}

function Get-Heading {
    param([string]$FullPath)

    $headings = [System.Collections.Generic.List[string]]::new()
    $inFence = $false
    foreach ($line in (Get-Content -LiteralPath $FullPath -Encoding utf8)) {
        if ($line -match '^\s*```') { $inFence = -not $inFence; continue }
        if ($inFence) { continue }
        if ($line -match '^\s*(#{1,6})\s+(?<text>.+?)\s*$') { $headings.Add($Matches['text'].Trim()) }
    }
    return $headings.ToArray()
}

function Get-ScanTarget {
    param([string]$Root, [string]$Only)

    $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()

    if ($Only) {
        $full = Join-Path $Root $Only
        if (-not (Test-Path -LiteralPath $full)) { throw "Check-DocSectionRefs: -Path '$Only' does not exist under $Root." }
        $item = Get-Item -LiteralPath $full -Force
        if ($item.PSIsContainer) {
            Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Force |
                Where-Object { $script:ScanExtensions -contains $_.Extension.ToLowerInvariant() } |
                ForEach-Object { $files.Add($_) }
        }
        else { $files.Add($item) }
        return $files.ToArray()
    }

    foreach ($name in $script:ScanFiles) {
        $full = Join-Path $Root $name
        if (Test-Path -LiteralPath $full) { $files.Add((Get-Item -LiteralPath $full -Force)) }
    }
    foreach ($dir in $script:ScanRoots) {
        $full = Join-Path $Root $dir
        if (-not (Test-Path -LiteralPath $full)) { continue }
        Get-ChildItem -LiteralPath $full -Recurse -File -Force |
            Where-Object { $script:ScanExtensions -contains $_.Extension.ToLowerInvariant() -and $_.Name -notlike '*.Tests.ps1' } |
            ForEach-Object { $files.Add($_) }
    }
    return $files.ToArray()
}

function Get-MarkdownIndex {
    param([string]$Root)

    $index = @{}
    $tracked = @(& git -C $Root ls-files '*.md' 2>$null)
    $paths = if ($LASTEXITCODE -eq 0 -and $tracked.Count -gt 0) {
        $tracked | ForEach-Object { Join-Path $Root $_ }
    }
    else {
        foreach ($dir in ($script:ScanRoots + @('.'))) {
            $full = Join-Path $Root $dir
            if (-not (Test-Path -LiteralPath $full)) { continue }
            Get-ChildItem -LiteralPath $full -Recurse -File -Force -Filter *.md | ForEach-Object { $_.FullName }
        }
    }

    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $leaf = [IO.Path]::GetFileName($path).ToLowerInvariant()
        $full = [IO.Path]::GetFullPath($path)
        if (-not $index.ContainsKey($leaf)) { $index[$leaf] = [System.Collections.Generic.List[string]]::new() }
        if (-not $index[$leaf].Contains($full)) { $index[$leaf].Add($full) }
    }
    return $index
}

function Resolve-Target {
    param([string]$Cited, [string]$FromFile, [string]$Root, [hashtable]$Index)

    $candidates = @(
        (Join-Path (Split-Path -Parent $FromFile) $Cited),
        (Join-Path $Root $Cited)
    )
    foreach ($candidate in $candidates) {
        try { $resolved = [IO.Path]::GetFullPath($candidate) } catch { continue }
        if (Test-Path -LiteralPath $resolved -PathType Leaf) { return $resolved }
    }

    $leaf = [IO.Path]::GetFileName($Cited).ToLowerInvariant()
    if ($Index.ContainsKey($leaf) -and $Index[$leaf].Count -eq 1) { return $Index[$leaf][0] }
    return $null
}

$targets = Get-ScanTarget -Root $RepoRoot -Only $Path
if ($targets.Count -eq 0) { throw "Check-DocSectionRefs: nothing to scan under $RepoRoot." }

$index = Get-MarkdownIndex -Root $RepoRoot
$headingCache = @{}
$findings = [System.Collections.Generic.List[object]]::new()
$checked = 0

foreach ($file in $targets) {
    $rel = [IO.Path]::GetRelativePath($RepoRoot, $file.FullName).Replace('\', '/')
    $extension = $file.Extension.ToLowerInvariant()
    $lineNumber = 0
    foreach ($raw in (Get-Content -LiteralPath $file.FullName -Encoding utf8)) {
        $lineNumber++
        $line = ConvertTo-ReadableLine -Line $raw -Extension $extension

        $references = [System.Collections.Generic.List[object]]::new()
        foreach ($pattern in @($script:BacktickedSection, $script:BareSection)) {
            foreach ($match in [regex]::Matches($line, $pattern)) {
                $references.Add([pscustomobject]@{ Kind = 'heading'; File = $match.Groups['file'].Value; Name = $match.Groups['name'].Value.Trim() })
            }
        }
        foreach ($match in [regex]::Matches($line, $script:QuotedSection)) {
            $references.Add([pscustomobject]@{ Kind = 'text'; File = $match.Groups['file'].Value; Name = $match.Groups['name'].Value.Trim() })
        }
        foreach ($match in [regex]::Matches($line, $script:LinkAnchor)) {
            $references.Add([pscustomobject]@{ Kind = 'anchor'; File = $match.Groups['file'].Value; Name = $match.Groups['anchor'].Value })
        }
        if ($script:AdrPath -and $script:ScriptExtensions -contains $extension -and $file.Name -notlike '*.Tests.ps1') {
            foreach ($match in [regex]::Matches($line, $script:AdrPath)) {
                $checked++
                if (Test-Path -LiteralPath (Join-Path $RepoRoot $match.Value) -PathType Leaf) { continue }
                $findings.Add([pscustomobject]@{
                        Where    = "${rel}:${lineNumber}"
                        Kind     = 'record'
                        Target   = $match.Value
                        Name     = $match.Value
                        Headings = @()
                    })
            }
        }
        if ($references.Count -eq 0) { continue }

        foreach ($reference in $references) {
            $resolved = Resolve-Target -Cited $reference.File -FromFile $file.FullName -Root $RepoRoot -Index $index
            if (-not $resolved) { continue }
            if ($resolved -eq $file.FullName -and $reference.Kind -ne 'anchor') { continue }

            if (-not $headingCache.ContainsKey($resolved)) { $headingCache[$resolved] = Get-Heading -FullPath $resolved }
            $headings = $headingCache[$resolved]
            $checked++

            $found = switch ($reference.Kind) {
                'heading' { [bool]($headings | Where-Object { $_.Trim('`', ' ') -ieq $reference.Name.Trim('`', ' ') }) }
                'anchor' { [bool]($headings | Where-Object { (ConvertTo-Slug $_) -eq $reference.Name.ToLowerInvariant() }) }
                default { (Get-Content -LiteralPath $resolved -Raw -Encoding utf8) -like "*$($reference.Name)*" }
            }
            if ($found) { continue }

            $findings.Add([pscustomobject]@{
                    Where   = "${rel}:${lineNumber}"
                    Kind    = $reference.Kind
                    Target  = [IO.Path]::GetRelativePath($RepoRoot, $resolved).Replace('\', '/')
                    Name    = $reference.Name
                    Headings = $headings
                })
        }
    }
}

if ($findings.Count -gt 0) {
    Write-Host "Section references: a text points at a section that is not there." -ForegroundColor Red
    foreach ($finding in $findings) {
        $what = switch ($finding.Kind) {
            'heading' { "names the section '$($finding.Name)' of $($finding.Target), which has no such heading" }
            'anchor' { "links to $($finding.Target)#$($finding.Name), and no heading there makes that anchor" }
            'record' { "names the decision record $($finding.Target), which does not exist" }
            default { "quotes `"$($finding.Name)`" from $($finding.Target), where that text does not appear" }
        }
        Write-Host ("  {0}  {1}" -f $finding.Where, $what)
        if ($Detail -and $finding.Headings.Count -gt 0) {
            Write-Host ("      headings it does have: {0}" -f (($finding.Headings | Select-Object -First 12) -join ' | '))
        }
    }
    Write-Host "FIX: Point at the heading or the decision record as it now reads, or put it back. A pointer that leads nowhere is worse than none, because the reader trusts it."
    Write-Output "::error::Section references: $($findings.Count) pointer(s) name a section or a decision record that is not there. Each one is listed above as file:line."
    exit 1
}

Write-Host "Section references OK: $checked pointer(s) into another page all resolve to a heading or text that is there."
exit 0
