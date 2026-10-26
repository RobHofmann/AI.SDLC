#Requires -Version 7
<#
.SYNOPSIS
    Collects the facts for a new documentation page of one or more units, and writes them to a facts
    file that a drafting subagent reads. It never writes the page and never calls a model.

.DESCRIPTION
    Check-DocCoverage.ps1 lists the units that have no page. This script does the deterministic half of
    the adopt-docs skill for one page, so the agent that drafts the page does not start from an empty
    file. It is the partner of Update-DocFromGraph.ps1 in the dotnet pack, which adds to a page that
    already exists.

    1. It reads the facts of each unit from the pack that names the unit (docFacts in the gates.json
       of that pack): Get-ProjectFacts.ps1 for a .NET project, Get-BicepFacts.ps1 for a Bicep
       building block. A unit no pack names gets its facts from Get-FolderFacts.ps1.
    2. It writes one facts file to doc-candidates/ at the repository root, which is git-ignored. The
       file name comes from the unit, or from the page when the page spans several units:
       doc-candidates/<unit path with slashes as underscores>.facts.md. The file holds the page to
       write, its title and layer, the path for the draft, the rules of the wiki for that layer, the
       pages it may link with their relative links, the facts, and the check list.
    3. The adopt-docs skill hands the facts file to a subagent, which drafts the page through
       write-docs into the draft path. Test-DocCandidate.ps1 then checks the draft against the facts
       file: every backticked name must be in the facts, the H1 and the front matter must be right,
       and the reading level is reported.

    A draft is a proposal. Verify each claim against the source, copy what you confirmed into the page,
    and drop the rest (the adopt-docs skill). This script never edits a page and never commits
    (constitution C09).

    It refuses a page that exists (use write-docs, or Update-DocFromGraph.ps1 in a .NET
    repository), a page in the decision record folder, a page outside the documentation layers, and a
    unit outside the repository. It refuses before it reads a fact.

.PARAMETER Unit
    One or more unit folders, relative to RepoRoot. A technical page usually has one; a functional page
    often spans several.

.PARAMETER Layer
    Technical (the default) or Functional.

.PARAMETER Page
    The page to draft, relative to RepoRoot. Defaults, for one technical unit, to the page
    Check-DocCoverage.ps1 suggests. A functional page must name it.

.PARAMETER Title
    The H1 of the page. Defaults to the unit name for a technical page with one unit, so the coverage
    gate matches the page to the unit.

.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, or the git top level.

.PARAMETER OutputPath
    Where to write the facts file. Defaults to doc-candidates/<unit path with slashes as underscores>.facts.md.

.PARAMETER DryRun
    Print the facts and write nothing.

.EXAMPLE
    pwsh .claude/skills/adopt-docs/scripts/New-DocCandidate.ps1 -Unit building-blocks/hub-network

.EXAMPLE
    pwsh .claude/skills/adopt-docs/scripts/New-DocCandidate.ps1 -Layer Functional -Unit building-blocks/hub-network,building-blocks/private-dns -Page docs-functional/networking.md -Title "Networking"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$Unit,
    [ValidateSet('Technical', 'Functional')][string]$Layer = 'Technical',
    [string]$Page,
    [string]$Title,
    [string]$RepoRoot,
    [string]$OutputPath,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$gates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
Import-Module (Join-Path $gates 'AiSdlcConfig.psm1') -Force
Import-Module (Join-Path $gates 'DocCoverage.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$config = Get-AiSdlcConfig -RepoRoot $RepoRoot

function Stop-Refused {
    param([string]$Message)
    Write-Host "Refused: $Message" -ForegroundColor Red
    Write-Host 'Nothing was read and nothing was written.' -ForegroundColor Red
    exit 1
}

function Test-InsideRepository {
    param([string]$Relative)
    $full = [IO.Path]::GetFullPath((Join-Path $RepoRoot $Relative))
    return $full.StartsWith($RepoRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith($RepoRoot + '/', [StringComparison]::OrdinalIgnoreCase)
}

$Unit = @($Unit | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().Replace('\', '/').TrimEnd('/') } | Where-Object { $_ })
foreach ($u in $Unit) {
    if (-not (Test-InsideRepository $u)) { Stop-Refused "the unit '$u' resolves outside the repository." }
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $u) -PathType Container)) { Stop-Refused "the unit '$u' is not a folder in the repository." }
}

$layerRoot = if ($Layer -eq 'Technical') { [string]$config.paths.technicalDocs } else { [string]$config.paths.functionalDocs }
$layerRoot = $layerRoot.Replace('\', '/').TrimEnd('/')
if (-not $layerRoot) { Stop-Refused "aisdlc.json names no $($Layer.ToLowerInvariant()) layer (paths.$($Layer.ToLowerInvariant())Docs)." }

if (-not $Page) {
    if ($Layer -eq 'Functional' -or $Unit.Count -ne 1) { Stop-Refused 'a functional page, or a page for more than one unit, needs -Page.' }
    $leaf = Split-Path $Unit[0] -Leaf
    foreach ($candidate in @(Get-DocCoverage -RepoRoot $RepoRoot)) { if ($candidate.Unit -eq $Unit[0]) { $Page = $candidate.SuggestedPage } }
    if (-not $Page) { $Page = "$layerRoot/$(ConvertTo-DocPageName -Name $leaf).md" }
}
$Page = $Page.Replace('\', '/')
if (-not (Test-InsideRepository $Page)) { Stop-Refused "the page '$Page' resolves outside the repository." }
if (-not $Page.StartsWith("$layerRoot/", [StringComparison]::OrdinalIgnoreCase)) { Stop-Refused "the page '$Page' is not in the $($Layer.ToLowerInvariant()) layer $layerRoot/." }
$adr = ([string]$config.paths.adrFolder).Replace('\', '/').TrimEnd('/')
if ($adr -and $Page.StartsWith("$adr/", [StringComparison]::OrdinalIgnoreCase)) { Stop-Refused "the page '$Page' is in the decision record folder; an ADR is written by write-adr, never drafted from code." }
if (Test-Path -LiteralPath (Join-Path $RepoRoot $Page)) { Stop-Refused "the page '$Page' exists. Add to it with write-docs, or with Update-DocFromGraph.ps1 in a .NET repository." }
if (-not $Title) { $Title = if ($Layer -eq 'Technical' -and $Unit.Count -eq 1) { Split-Path $Unit[0] -Leaf } else { Stop-Refused 'a functional page, or a page for more than one unit, needs -Title.' } }

$packages = @(Get-AiSdlcPackage -RepoRoot $RepoRoot | Where-Object { $_.DocFacts -and $_.DocUnits.Count -gt 0 })
$folderFacts = Join-Path $PSScriptRoot 'Get-FolderFacts.ps1'
$facts = [System.Collections.Generic.List[string]]::new()
foreach ($u in $Unit) {
    $source = $folderFacts
    foreach ($package in $packages) {
        if (@(Get-DocUnit -RepoRoot $RepoRoot -Spec $package.DocUnits | Where-Object { $_.Path -eq $u }).Count -gt 0) { $source = $package.DocFacts; break }
    }
    Write-Host "Facts for $u from $(Split-Path $source -Leaf)"
    foreach ($line in @(& $source -Unit $u -RepoRoot $RepoRoot)) { $facts.Add([string]$line) }
    $facts.Add('')
}
$factBlock = $facts -join "`n"

$pageDir = Split-Path $Page -Parent
$linkable = [System.Collections.Generic.List[string]]::new()
foreach ($root in @($config.paths.docsRoots)) {
    foreach ($existing in @(Get-DocPage -RepoRoot $RepoRoot -Layer ([string]$root))) {
        if ((Split-Path $existing.Path -Leaf) -eq 'index.md') { continue }
        $relative = [IO.Path]::GetRelativePath((Join-Path $RepoRoot $pageDir), (Join-Path $RepoRoot $existing.Path)).Replace('\', '/')
        $label = if ($existing.Title) { $existing.Title } else { $existing.Stem }
        $linkable.Add("  [$label]($relative)")
    }
}
$indexLink = [IO.Path]::GetRelativePath((Join-Path $RepoRoot $pageDir), (Join-Path $RepoRoot "$layerRoot/index.md")).Replace('\', '/')
$linkBlock = if ($linkable.Count -gt 0) { $linkable -join "`n" } else { '  (none yet)' }

$frontMatter = if ($Layer -eq 'Technical') { "---`nunits:`n" + (($Unit | ForEach-Object { "  - $_" }) -join "`n") + "`n---`n" } else { '' }

$stem = if ($Unit.Count -eq 1) { $Unit[0] } else { $Page -replace '\.md$', '' }
$stem = $stem -replace '[\\/]', '_'
if (-not $OutputPath) { $OutputPath = Join-Path $RepoRoot 'doc-candidates' "$stem.facts.md" }
$draftPath = 'doc-candidates/' + ($Page -replace '[\\/]', '_')

Write-Host "Page          : $Page ($($Layer.ToLowerInvariant()) layer)"
Write-Host "Units         : $($Unit -join ', ')"
Write-Host "Fact lines    : $($facts.Count)"
Write-Host "Linkable pages: $($linkable.Count)"

if ($DryRun) {
    Write-Host ''
    Write-Host '--- facts ---'
    Write-Host $factBlock
    Write-Host 'Dry run; nothing written.' -ForegroundColor Yellow
    exit 0
}

$layerRules = if ($Layer -eq 'Technical') {
    @"
This is a TECHNICAL page: it tells a developer how the unit is built and how to change it safely.
Use these sections where the facts support them: a first paragraph that says what the unit is for,
"## What it contains" or "## What it deploys", "## Parameters" and "## Outputs" for a template,
"## Dependencies" (what it uses and what uses it), and "## Related".
Start the page with this front matter, exactly as given, then the H1:

``````markdown
$($frontMatter.TrimEnd())
``````
"@
}
else {
    @"
This is a FUNCTIONAL page: it tells the people who use what the repository delivers what they get,
when they need it, and what they must know. Write about outcomes, not about code. Name a code file,
a parameter or a resource type only when the reader must act on it. Use these sections where the
facts support them: a first paragraph that says what this gives the reader, "## What you get",
"## When you need it", "## What to know", and "## Related".
"@
}

$factsRelative = [IO.Path]::GetRelativePath($RepoRoot, [IO.Path]::GetFullPath($OutputPath)).Replace('\', '/')
$content = @"
# Facts for a new page: $Title

- Page: $Page
- Title: $Title
- Layer: $Layer
- Units: $($Unit -join ', ')
- Draft: $draftPath

## How to write the draft

Write one new page from the facts below, through the write-docs skill, into the draft path above.
The facts were read from the repository and are the only truth you have.

$layerRules
Hard rules:

- The H1 is exactly: # $Title
- Every claim comes from the facts. When the facts give a name and a path but no behaviour, write the
  name and where it lives, and stop. Do not guess what something does from its name.
- Never write that something is "not described", "unknown" or "not in the sources". Leave it out.
- Put every code name, file name, parameter and resource type in backticks, exactly as the facts spell it.
- Link other pages only from the list of linkable pages, with the relative link given there. End the
  page with "## Related": the layer index ($indexLink) and two to five pages from the list, each with a
  short reason after " - ".
- English. One main idea per sentence, never more than 25 words, everyday words (CEFR B2 sentences,
  B1 words). Say who does what.
- Never use the em-dash character. Use a comma, a colon, parentheses or " - ".
- Do not name people. Do not add source line numbers.

## Linkable pages

Label and the relative link to use from the new page:

$linkBlock

## Facts

``````text
$factBlock
``````

## Check list

- [ ] The draft is in $draftPath, not in $Page.
- [ ] pwsh .claude/skills/adopt-docs/scripts/Test-DocCandidate.ps1 -Draft $draftPath -FactsFile $factsRelative passes.
- [ ] Each claim is checked against the source; a claim that could not be confirmed is dropped.
- [ ] The docs-reviewer agent has read the page before it is copied into $Page.
"@

$outputDirectory = Split-Path -Parent $OutputPath
if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory)) { New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null }
[IO.File]::WriteAllText($OutputPath, ($content -replace "`r`n", "`n") + "`n", [Text.UTF8Encoding]::new($false))

Write-Host "Facts written to $OutputPath" -ForegroundColor Green
Write-Host "Next: hand the facts file to a drafting subagent (write-docs) that writes $draftPath, then run Test-DocCandidate.ps1 on it." -ForegroundColor Yellow
Write-Host 'This script never edits a page and never commits (C09). See the adopt-docs skill.' -ForegroundColor Yellow
exit 0
