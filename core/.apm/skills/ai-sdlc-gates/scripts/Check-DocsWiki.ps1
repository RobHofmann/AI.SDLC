#Requires -Version 7
<#
.SYNOPSIS
    Validates wiki integrity for the docs/ and docs-functional/ layers (orphans, broken relative links and isolated pages).

.DESCRIPTION
    Enforces three of the docs-wiki lint rules from .claude/skills/ai-sdlc-handbook/references/docs-wiki.md over the two wiki layers,
    docs/ (technical) and docs-functional/ (functional), across their .md and .markdown pages:

      1. Broken relative links - every inline markdown link [text](target) whose target is a relative
         path to a local file must resolve to an existing file. External links (http://, https://,
         mailto:) and pure #anchor links are ignored; for a path#anchor target the #anchor is stripped
         and only the path is validated. The target is resolved relative to the linking page's folder.

      2. Orphans - a page is an orphan when it is BOTH (a) not linked from its layer's index file
         (docs/index.md or docs-functional/index.md) AND (b) not linked by any other wiki page via a
         relative link. Entry-point files (any index.md and any README.md) are exempt. If a layer's
         index file is absent, part (a) is treated as "not indexed" for that layer and a note is
         printed; part (b) still applies.

      3. Connectivity (the graph check) - the wiki must be an interlinked graph, not merely an
         index-reachable star, so this check requires page-to-page cross-links and, unlike the orphan
         check, does NOT count links from index.md / README.md. An isolated page (no cross-link to or
         from any other content page) and a page with no outbound cross-link are reported. Advisory by
         default; pass -Strict to turn isolated pages into build-failing violations. gates.json passes it.

    This checker deliberately does NOT verify index drift (that is Build-DocsIndex.ps1 in -Check mode)
    nor artifact-graph front-matter (that is Check-ArtifactGraph.ps1). Exits non-zero on any violation.

.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script. The wiki layers come from paths.docsRoots in aisdlc.json.

.PARAMETER Strict
    Treat connectivity findings (isolated pages) as build-failing violations rather than advisories.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [switch]$Strict
)

Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

$ErrorActionPreference = 'Stop'

$layers = @(Get-AiSdlcPath -Name docsRoots -RepoRoot $RepoRoot -Relative)
if (-not @($layers | Where-Object { Test-Path (Join-Path $RepoRoot $_) })) {
    Write-Host ("Could not check: none of the doc layers in aisdlc.json exists ({0})." -f ($layers -join ', ')) -ForegroundColor Yellow
    exit 2
}$linkPattern = '\[[^\]]*\]\(\s*([^)\s]+)\s*\)'

function Get-RelPath([string]$root, [string]$full) {
    return [IO.Path]::GetRelativePath($root, $full).Replace('\', '/')
}

function Test-IsExternalOrAnchor([string]$target) {
    if ($target -match '^(?i:https?://|mailto:)') { return $true }
    if ($target.StartsWith('#')) { return $true }
    return $false
}

function Get-LinkTargets([string]$text) {
    $targets = [System.Collections.Generic.List[string]]::new()
    foreach ($m in [regex]::Matches($text, $linkPattern)) {
        $targets.Add($m.Groups[1].Value)
    }
    return $targets
}

function Resolve-LinkPath([string]$pageDir, [string]$target) {
    $pathPart = ($target -split '#', 2)[0]
    if ([string]::IsNullOrWhiteSpace($pathPart)) { return $null }
    $decoded = [uri]::UnescapeDataString($pathPart)
    $combined = [IO.Path]::Combine($pageDir, $decoded)
    return [IO.Path]::GetFullPath($combined)
}

function Remove-Code([string]$text) {
    # Drop fenced code blocks and inline code spans so links shown as examples are not scanned as links.
    # Normalize line endings first: with CRLF, the closing-fence anchor ('^[ \t]*```[ \t]*$') fails to
    # match because a \r sits before the \n, leaving the fence unstripped and its example links scanned.
    $normalized = $text -replace "`r`n", "`n" -replace "`r", "`n"
    $noFence = [regex]::Replace($normalized, '(?ms)^[ \t]*(`{3,}|~{3,}).*?^[ \t]*\1[ \t]*$', '')
    return [regex]::Replace($noFence, '`[^`\r\n]+`', '')
}

function Test-IsEntryName([string]$name) {
    return ($name -ieq 'index.md') -or ($name -ieq 'readme.md') -or ($name -ilike '*template*')
}

$pages = [System.Collections.Generic.List[object]]::new()
foreach ($layer in $layers) {
    $layerRoot = Join-Path $RepoRoot $layer
    if (-not (Test-Path $layerRoot)) { continue }
    foreach ($file in (Get-ChildItem -Path $layerRoot -Recurse -Include *.md, *.markdown -File)) {
        $pages.Add([pscustomobject]@{
            Layer    = $layer
            FullPath = $file.FullName
            Dir      = $file.DirectoryName
            Rel      = Get-RelPath $RepoRoot $file.FullName
            Name     = $file.Name
            Text     = Remove-Code (Get-Content -LiteralPath $file.FullName -Raw)
        })
    }
}

$violations = [System.Collections.Generic.List[string]]::new()
$notes = [System.Collections.Generic.List[string]]::new()

$linkedTargets = [System.Collections.Generic.HashSet[string]]::new()
$indexedTargets = @{}
foreach ($layer in $layers) { $indexedTargets[$layer] = [System.Collections.Generic.HashSet[string]]::new() }

foreach ($page in $pages) {
    foreach ($target in (Get-LinkTargets $page.Text)) {
        if (Test-IsExternalOrAnchor $target) { continue }

        $resolved = Resolve-LinkPath $page.Dir $target
        if ($null -eq $resolved) { continue }

        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            $violations.Add(("{0} : broken relative link -> '{1}' (does not resolve to a file)" -f $page.Rel, $target))
            continue
        }

        $resolvedKey = (Get-RelPath $RepoRoot $resolved).ToLowerInvariant()
        $isIndex = ($page.Name -ieq 'index.md')
        if ($isIndex) {
            [void]$indexedTargets[$page.Layer].Add($resolvedKey)
        }
        else {
            [void]$linkedTargets.Add($resolvedKey)
        }
    }
}

$indexPresent = @{}
foreach ($layer in $layers) {
    $layerRoot = Join-Path $RepoRoot $layer
    if (-not (Test-Path $layerRoot)) { continue }
    $indexPath = Join-Path $layerRoot 'index.md'
    $indexPresent[$layer] = Test-Path -LiteralPath $indexPath -PathType Leaf
    if (-not $indexPresent[$layer]) {
        $notes.Add(("note: {0}/index.md is absent - skipping the index check for this layer (orphans judged by inbound links only)" -f $layer))
    }
}

foreach ($page in $pages) {
    if (($page.Name -ieq 'index.md') -or ($page.Name -ieq 'readme.md') -or ($page.Name -ilike '*template*')) { continue }

    $key = $page.Rel.ToLowerInvariant()
    $isIndexed = $indexedTargets[$page.Layer].Contains($key)
    $isLinked = $linkedTargets.Contains($key)

    if ((-not $isIndexed) -and (-not $isLinked)) {
        $violations.Add(("{0} : orphan - not listed in {1}/index.md and not linked by any other wiki page" -f $page.Rel, $page.Layer))
    }
}

# Connectivity (graph) check: the wiki must be an interlinked graph, not just an index-reachable star.
# Index reachability (the orphan check above) is necessary but not sufficient; C05 requires page-to-page
# cross-links. Here index.md and README.md links do NOT count toward connectivity. An isolated page is one
# with no cross-link to or from any other content page. Advisory by default;
# pass -Strict to make isolated pages fail the build; gates.json passes it.
$contentPages = $pages | Where-Object { -not (Test-IsEntryName $_.Name) }
$outDegree = @{}
$inDegree = @{}
foreach ($p in $contentPages) { $outDegree[$p.Rel.ToLowerInvariant()] = 0; $inDegree[$p.Rel.ToLowerInvariant()] = 0 }

foreach ($page in $contentPages) {
    $pageKey = $page.Rel.ToLowerInvariant()
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($target in (Get-LinkTargets $page.Text)) {
        if (Test-IsExternalOrAnchor $target) { continue }
        $resolved = Resolve-LinkPath $page.Dir $target
        if ($null -eq $resolved) { continue }
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { continue }
        if (Test-IsEntryName (Split-Path $resolved -Leaf)) { continue }
        $targetKey = (Get-RelPath $RepoRoot $resolved).ToLowerInvariant()
        if (-not $outDegree.ContainsKey($targetKey)) { continue }
        if ($targetKey -eq $pageKey) { continue }
        if (-not $seen.Add($targetKey)) { continue }
        $outDegree[$pageKey]++
        $inDegree[$targetKey]++
    }
}

$isolatedPages = [System.Collections.Generic.List[string]]::new()
$noOutboundPages = [System.Collections.Generic.List[string]]::new()
foreach ($p in $contentPages) {
    $k = $p.Rel.ToLowerInvariant()
    if (($outDegree[$k] -eq 0) -and ($inDegree[$k] -eq 0)) { $isolatedPages.Add($p.Rel) }
    elseif ($outDegree[$k] -eq 0) { $noOutboundPages.Add($p.Rel) }
}
$edgeCount = [int](($outDegree.Values | Measure-Object -Sum).Sum)

foreach ($iso in ($isolatedPages | Sort-Object)) {
    $msg = "{0} : isolated page - no cross-link to or from any other content page (index/README do not count toward connectivity)" -f $iso
    if ($Strict) { $violations.Add($msg) } else { $notes.Add("graph advisory: $msg") }
}
foreach ($sink in ($noOutboundPages | Sort-Object)) {
    $notes.Add("graph advisory: {0} : no outbound cross-link to another content page (add a Related section)" -f $sink)
}

foreach ($note in $notes) { Write-Host "  $note" -ForegroundColor Yellow }

Write-Host ("Wiki graph: {0} content page(s), {1} cross-link edge(s); {2} isolated, {3} with no outbound cross-link.{4}" -f `
    $contentPages.Count, $edgeCount, $isolatedPages.Count, $noOutboundPages.Count, $(if (-not $Strict) { ' (connectivity advisory; run with -Strict to enforce)' } else { '' }))

if ($violations.Count -gt 0) {
    Write-Host "Docs-wiki violations (see .claude/skills/ai-sdlc-handbook/references/docs-wiki.md):" -ForegroundColor Red
    foreach ($v in ($violations | Sort-Object)) { Write-Host "  $v" }
    Write-Host "FIX: Point each broken link at the page as it is now, and give an orphan page a link in and a link out. Run Build-DocsIndex.ps1 when the index is the one out of step (.claude/skills/ai-sdlc-handbook/references/docs-wiki.md)." -ForegroundColor Red
    Write-Host ("Checked {0} wiki page(s); {1} violation(s)." -f $pages.Count, $violations.Count) -ForegroundColor Red
    exit 1
}

Write-Host ("Docs-wiki OK: {0} wiki page(s) validated, no orphans or broken relative links." -f $pages.Count)
exit 0
