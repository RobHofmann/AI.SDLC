#Requires -Version 7
<#
.SYNOPSIS
    Collects what the code actually declares for one documentation page and writes it to a facts file,
    so a subagent can draft additions to the page. With -Check it checks that draft. It never edits the
    page and never calls a model.

.DESCRIPTION
    The direction matters: this reads the CODE and proposes additions to the page, never the other way
    round. It reads one page inside this repository and the source files the graph says that page cites,
    plus the public types in the project the page never names, so a thin page can still learn what exists.

    It refuses decision records and story files, because those are point-in-time records. It writes the
    facts to doc-candidates/<page>.facts.md at the repository root, which is gitignored. The facts file
    names the page, the path for the candidate, the drafting rules and the check list. The drafting rules
    forbid the row that carries no fact, which once filled 467 lines, and forbid removing a file
    reference, because the facts are a partial view and absence is not deletion.

    The agent in the session hands the facts file to a subagent that drafts the candidate through
    write-docs, or drafts it inline when subagents are not available. This script calls no model and
    needs no secret.

    -Check reads the drafted candidate, the page and the facts file. It refuses a candidate that keeps
    fewer words than the page allows, because the first design silently gutted pages. It refuses a
    candidate that drops a heading, or that names more identifiers than allowed that match neither the
    facts nor the page. It lists those identifiers under UNVERIFIED. It replaces an em-dash in the
    candidate. What it produces, where it lands, and how much to trust the output are in
    .claude/skills/dotnet-code-graph/references/code-graph.md, under "Proposing an update from the graph".

.PARAMETER DocPath
    The page to propose additions for, relative to the repository root.

.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script.

.PARAMETER GraphPath
    Path to graph.json. Defaults to graphify-out/graph.json under the repository root.

.PARAMETER OutputPath
    Where the candidate is drafted. Defaults to doc-candidates/ with the page path flattened into the name.

.PARAMETER FactsPath
    Where the facts file is written. Defaults to the candidate path with .facts.md in place of .md.

.PARAMETER Check
    Check the drafted candidate at OutputPath against the page and the facts file, instead of collecting
    the facts. Needs no graph.

.PARAMETER MinimumWordsKeptPercent
    The candidate must keep at least this percentage of the page's words, or -Check refuses it. Defaults to 98.

.PARAMETER MaximumUnverifiedSymbols
    How many added identifiers that match nothing may appear before -Check refuses the candidate. Defaults to 12.

.PARAMETER MaximumUnnamedTypes
    How many of the project's unnamed public types to write as facts. Defaults to 60, so the facts stay
    small on the largest projects.

.PARAMETER AllowContentLoss
    Accept a candidate shorter than the page in -Check. For the rare case where the page really should shrink.

.PARAMETER AllowStaleGraph
    Collect facts from a graph that is out of date with the working tree. Off by default: the facts turn
    graph relationships into sentences on a page, so a stale graph writes a claim that is false and then
    reads as verified.

.PARAMETER DryRun
    Assemble the facts and print them; write nothing.

.EXAMPLE
    ./Update-DocFromGraph.ps1 -DocPath docs/libraries/ledger.md -DryRun

.EXAMPLE
    ./Update-DocFromGraph.ps1 -DocPath docs/libraries/ledger.md

.EXAMPLE
    ./Update-DocFromGraph.ps1 -DocPath docs/libraries/ledger.md -Check
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DocPath,
    [string]$RepoRoot,
    [string]$GraphPath,
    [string]$OutputPath,
    [string]$FactsPath,
    [switch]$Check,
    [int]$MinimumWordsKeptPercent = 98,
    [int]$MaximumUnverifiedSymbols = 12,
    [int]$MaximumUnnamedTypes = 60,
    [switch]$AllowContentLoss,
    [switch]$AllowStaleGraph,
    [switch]$DryRun
)

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' '..' 'dotnet-gates' 'scripts' 'DocSurface.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CodeGraph.psm1') -Force
Import-Module (Join-Path $aiSdlcGates 'ToolOutput.psm1') -Force

if (Test-Path -LiteralPath $RepoRoot) { $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path }

$script:RecordFolders = Get-RecordFolder -RepoRoot $RepoRoot
$script:ServiceCheckFolder = Get-ProjectPageFolder -RepoRoot $RepoRoot


$normalised = ($DocPath -replace '\\', '/')
foreach ($folder in $script:RecordFolders) {
    if ($normalised -like "*$folder*") {
        Write-Host "Refusing '$DocPath': it is a point-in-time record, not a reference page." -ForegroundColor Red
        Write-Host 'Rewriting the conclusions of an ADR or a story file is a rule violation, not an update.' -ForegroundColor Red
        Write-Host 'An ADR is append-only: a changed decision gets a new ADR that supersedes the old one.' -ForegroundColor Red
        exit 1
    }
}

if (-not $GraphPath) { $GraphPath = Join-Path $RepoRoot 'graphify-out' 'graph.json' }
$docFull = Join-Path $RepoRoot $normalised

$repoFull = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd([char]92, '/')
$pageFull = [System.IO.Path]::GetFullPath($docFull)
if (-not $pageFull.StartsWith($repoFull + [char]92, [System.StringComparison]::OrdinalIgnoreCase) -and
    -not $pageFull.StartsWith($repoFull + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Host "Refusing '$DocPath': it resolves outside the repository." -ForegroundColor Red
    Write-Host 'The facts file carries content from the page and its sources, so the page it reads is' -ForegroundColor Red
    Write-Host 'bounded deliberately rather than by whatever the graph happens not to contain.' -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath $docFull)) {
    Write-Host "No page at '$docFull'." -ForegroundColor Red
    exit 1
}

if (-not $OutputPath) {
    $candidateDir = Join-Path $RepoRoot 'doc-candidates'
    $OutputPath = Join-Path $candidateDir (($normalised -replace '[\\/]', '_'))
}
if (-not $FactsPath) { $FactsPath = ($OutputPath -replace '\.md$', '') + '.facts.md' }

function Get-UnverifiedSymbol {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Candidate,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Facts,
        [AllowEmptyString()][string]$Page = ''
    )

    $known = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($match in [regex]::Matches($Facts, '\b[A-Z][A-Za-z0-9_]{2,}\b')) { [void]$known.Add($match.Value) }
    foreach ($match in [regex]::Matches($Page, '`([^`\r\n]{1,120})`')) {
        foreach ($token in [regex]::Matches($match.Groups[1].Value, '\b[A-Z][A-Za-z0-9_]{2,}\b')) { [void]$known.Add($token.Value) }
    }

    $invented = [System.Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches($Candidate, '`([^`\r\n]{1,120})`')) {
        foreach ($token in [regex]::Matches($match.Groups[1].Value, '\b[A-Z][A-Za-z0-9_]{2,}\b')) {
            if (-not $known.Contains($token.Value)) { $invented.Add($token.Value) }
        }
    }
    return , @($invented | Sort-Object -Unique)
}

if ($Check) {
    if (-not (Test-Path -LiteralPath $FactsPath)) {
        Write-Host "No facts file at '$FactsPath'. Run this script without -Check first." -ForegroundColor Red
        exit 1
    }
    if (-not (Test-Path -LiteralPath $OutputPath)) {
        Write-Host "No candidate at '$OutputPath'. Draft it from the facts file first." -ForegroundColor Red
        exit 1
    }

    $currentDoc = Get-Content -LiteralPath $docFull -Raw -Encoding utf8
    $factBlock = Get-Content -LiteralPath $FactsPath -Raw -Encoding utf8
    $updated = Get-Content -LiteralPath $OutputPath -Raw -Encoding utf8
    if ([string]::IsNullOrWhiteSpace($updated)) {
        Write-Host 'The candidate is empty; nothing to check.' -ForegroundColor Red
        exit 1
    }

    $beforeWords = @($currentDoc -split '\s+' | Where-Object { $_ }).Count
    $afterWords = @($updated -split '\s+' | Where-Object { $_ }).Count
    $kept = if ($beforeWords -gt 0) { [math]::Round(($afterWords / $beforeWords) * 100, 0) } else { 100 }

    $beforeHeadings = @([regex]::Matches($currentDoc, '(?m)^#{1,6}\s+(.+?)\s*$') | ForEach-Object { $_.Groups[1].Value.Trim() })
    $afterHeadings = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($match in [regex]::Matches($updated, '(?m)^#{1,6}\s+(.+?)\s*$')) { [void]$afterHeadings.Add($match.Groups[1].Value.Trim()) }
    $lostHeadings = @($beforeHeadings | Where-Object { -not $afterHeadings.Contains($_) })

    Write-Invariant -Template 'Page          : {0}' -Values @($normalised)
    Write-Invariant -Template 'Length        : {0:N0} words in, {1:N0} words out ({2:N0}% kept)' -Values @($beforeWords, $afterWords, $kept)

    $invented = Get-UnverifiedSymbol -Candidate $updated -Facts $factBlock -Page $currentDoc

    if ($invented.Count -gt 0) {
        Write-Host ''
        Write-Invariant -Template 'UNVERIFIED: {0:N0} symbol(s) the candidate names are in neither the code facts nor the original page:' -Values @($invented.Count) -ForegroundColor Yellow
        Write-Invariant -Template '  {0}' -Values @((($invented | Select-Object -First 12) -join ', ')) -ForegroundColor Yellow
        Write-Host '  Check each against the source before merging that line, and check the sentences around' -ForegroundColor Yellow
        Write-Host '  them too: this lists names that matched nothing, not every claim that is wrong.' -ForegroundColor Yellow
    }

    $refusals = [System.Collections.Generic.List[string]]::new()
    if ($invented.Count -gt $MaximumUnverifiedSymbols) {
        $refusals.Add("names $($invented.Count) symbols found in neither the facts nor the page, above the $MaximumUnverifiedSymbols allowed before review stops being worthwhile")
    }
    if ($kept -lt $MinimumWordsKeptPercent) {
        $refusals.Add("kept only $kept% of the words, below the $MinimumWordsKeptPercent% floor")
    }
    if ($lostHeadings.Count -gt 0) {
        $refusals.Add("dropped $($lostHeadings.Count) heading(s): $(($lostHeadings | Select-Object -First 4) -join '; ')")
    }

    if ($refusals.Count -gt 0 -and -not $AllowContentLoss) {
        Write-Host ''
        Write-Host 'Refused the candidate. The draft rewrote rather than updated:' -ForegroundColor Red
        foreach ($reason in $refusals) { Write-Host "  - $reason" -ForegroundColor Red }
        Write-Host ''
        Write-Host 'This guard exists because it happened. A run over 20 pages cut one page from 1902 words to 333' -ForegroundColor Yellow
        Write-Host 'while keeping every heading, and the drift check passed it: that check' -ForegroundColor Yellow
        Write-Host 'reads constant names and file references, so it cannot see explanation being deleted.' -ForegroundColor Yellow
        Write-Host 'FIX: Draft the candidate again from the facts file, adding only. Re-run with -AllowContentLoss only if the page genuinely should shrink.' -ForegroundColor Yellow
        exit 1
    }
    if ($refusals.Count -gt 0) {
        Write-Host 'Content loss allowed by request:' -ForegroundColor Yellow
        foreach ($reason in $refusals) { Write-Host "  - $reason" -ForegroundColor Yellow }
    }

    if ($updated.Contains([char]0x2014)) {
        $updated = $updated.Replace([string][char]0x2014, ' - ')
        Set-Content -LiteralPath $OutputPath -Value $updated -Encoding utf8 -NoNewline
        Write-Host 'Note: replaced em-dash characters in the candidate (constitution C06).' -ForegroundColor Yellow
    }

    Write-Invariant -Template 'Candidate checked: {0}' -Values @($OutputPath) -ForegroundColor Green
    Write-Host 'Verify each added claim against the source, merge only what you confirmed, drop the rest.' -ForegroundColor Yellow
    Write-Host 'This script never edits the page and never commits (C09). See the write-docs skill.' -ForegroundColor Yellow
    exit 0
}
if (-not (Test-Path -LiteralPath $GraphPath)) {
    Write-Host "No graph at '$GraphPath'. Run Invoke-GraphifyIndex.ps1 then Invoke-DocGraphLink.ps1." -ForegroundColor Red
    $outDir = Split-Path -Parent $GraphPath
    if ((Test-Path -LiteralPath $outDir) -and (Test-Path -LiteralPath (Join-Path $outDir 'cache'))) {
        Write-Host 'The output folder exists without a graph, which is what a refresh in progress looks like: the' -ForegroundColor Yellow
        Write-Host 'git hooks empty it and rebuild after every commit, merge and checkout, and a build takes about' -ForegroundColor Yellow
        Write-Host '30 seconds. Wait for it, or run Invoke-GraphifyIndex.ps1 yourself.' -ForegroundColor Yellow
    }
    exit 1
}

$index = Get-GraphIndex -GraphPath $GraphPath
if ($index.Freshness.State -eq 'Stale' -and -not $AllowStaleGraph) {
    Write-Host 'Refusing to draft from a stale graph. Rebuild it, or pass -AllowStaleGraph to draft anyway.' -ForegroundColor Red
    exit 1
}
$nodeById = $index.Nodes

$cited = [System.Collections.Generic.HashSet[string]]::new()
foreach ($edge in $index.Links) {
    if ($edge.relation -ne 'documents') { continue }
    if ((([string]$edge.source_file) -replace '\\', '/') -ne $normalised) { continue }
    $target = $nodeById[[string]$edge.target]
    if ($target) { [void]$cited.Add((([string]$target.source_file) -replace '\\', '/')) }
}

if ($cited.Count -eq 0) {
    Write-Host "The graph records no source files for '$normalised'. Run Invoke-DocGraphLink.ps1 first." -ForegroundColor Red
    exit 1
}

$facts = [System.Collections.Generic.List[string]]::new()
foreach ($sourceFile in ($cited | Sort-Object)) {
    $sourceFull = Join-Path $RepoRoot $sourceFile
    if (-not (Test-Path -LiteralPath $sourceFull)) { continue }
    $resolvedSource = (Resolve-Path -LiteralPath $sourceFull).Path
    if (-not $resolvedSource.StartsWith($repoFull + [char]92, [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $resolvedSource.StartsWith($repoFull + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "Skipped '$sourceFile': the graph resolves it outside the repository." -ForegroundColor Yellow
        continue
    }
    $source = Get-Content -LiteralPath $sourceFull -Raw -Encoding utf8
    if (-not $source) { continue }

    $types = @(Get-PublicTypeName -Source $source | Sort-Object)
    $members = @(Get-PublicMemberName -Source $source | Sort-Object)
    if ($types.Count -eq 0 -and $members.Count -eq 0) { continue }

    $facts.Add("FILE: $sourceFile")
    if ($types.Count -gt 0) { $facts.Add("  public types: $($types -join ', ')") }
    if ($members.Count -gt 0) { $facts.Add("  public named members: $($members -join ', ')") }
}

$currentDoc = Get-Content -LiteralPath $docFull -Raw -Encoding utf8

$citedPerProject = Get-CitedProjectVote -CitedFile @($cited) -SourceRoot (Get-SourceRoot -RepoRoot $RepoRoot)

$documentsAProject = $false
foreach ($folder in $script:ServiceCheckFolder) {
    if ($normalised -like "*$folder*") { $documentsAProject = $true; break }
}

$documentedProject = $null
$sourceRel = Get-SourceRoot -RepoRoot $RepoRoot
$srcRoot = Join-Path $RepoRoot $sourceRel
if ($documentsAProject -and $sourceRel -and (Test-Path -LiteralPath $srcRoot)) {
    $allProjects = Get-RepositoryProjectName -RepoRoot $RepoRoot
    $documentedProject = Resolve-DocumentedProject -DocPath $normalised -ProjectName @($allProjects) -Vote $citedPerProject -RepoRoot $RepoRoot
}

$undocumentedServices = [System.Collections.Generic.List[string]]::new()
$unnamedTypes = [System.Collections.Generic.List[string]]::new()
if ($documentedProject) {
    $projectRoot = Join-Path $RepoRoot (Join-Path $sourceRel $documentedProject)
    if (Test-Path -LiteralPath $projectRoot) {
        foreach ($file in (Get-ChildItem -LiteralPath $projectRoot -Recurse -Filter '*.cs' -File)) {
            if ($file.FullName -match '[\\/](obj|bin)[\\/]') { continue }
            $rel = ($file.FullName.Substring($RepoRoot.Length).TrimStart([char]92, '/')).Replace([char]92, '/')
            $source = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
            if (-not $source) { continue }
            foreach ($type in (Get-PublicTypeName -Source $source)) {
                if ($currentDoc -match ('\b' + [regex]::Escape($type) + '\b')) { continue }
                if (Test-ServiceShaped -TypeName $type -SourceFile $rel) { $undocumentedServices.Add("  $type  ($rel)") }
                elseif (-not (Test-IsTestDouble -Name $type)) { $unnamedTypes.Add("  $type  ($rel)") }
            }
        }
    }
}

if ($documentedProject) {
    $graphIndex = $null
    try { $graphIndex = Get-GraphIndex -GraphPath $GraphPath }
    catch {
        $graphIndex = $null
        Write-Host "Could not read the graph for relationship facts: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host 'Continuing with names only. Consumers, dependencies and implementations are NOT in the facts.' -ForegroundColor Yellow
    }
    if ($graphIndex) {
        $consumers = @(Get-ProjectConsumer -Index $graphIndex -Project $documentedProject)
        if ($consumers.Count -gt 0) {
            $facts.Add('')
            $facts.Add('WHO CONSUMES THIS PROJECT, from the code graph. These are resolved call and reference')
            $facts.Add('edges, so they include a caller that reaches this project only through an injected')
            $facts.Add('interface and never names the implementation. Say who uses this and what they reach for:')
            foreach ($consumer in $consumers) {
                $reaches = (($consumer.Reaches | Sort-Object | Select-Object -First 6) -join ', ')
                $facts.Add("  $($consumer.Project) reaches $reaches")
            }
        }

        $dependencies = @(Get-ProjectDependency -Index $graphIndex -Project $documentedProject)
        if ($dependencies.Count -gt 0) {
            $facts.Add('')
            $facts.Add('WHAT THIS PROJECT CALLS INTO, from the code graph. A project this one does NOT appear')
            $facts.Add('against here is one it does not touch, whatever its project file references:')
            foreach ($dependency in $dependencies) {
                $uses = (($dependency.Uses | Sort-Object | Select-Object -First 6) -join ', ')
                $facts.Add("  $($dependency.Project): $uses")
            }
        }

        $implementations = @(Get-ProjectImplementation -Index $graphIndex -Project $documentedProject)
        if ($implementations.Count -gt 0) {
            $facts.Add('')
            $facts.Add('WHAT THIS PROJECT IMPLEMENTS, read from the syntax tree. The contract is often declared')
            $facts.Add('in another project, and the line says which, so do not write that this project declares it.')
            $facts.Add('Where a contract has more than one implementation, say so and say which is which:')
            foreach ($pair in $implementations) {
                $where = if ($pair.ContractProject) { " (declared in $($pair.ContractProject))" } else { '' }
                $facts.Add("  $($pair.Contract)$where <- $($pair.Implementations -join ', ')")
            }
        }
    }
}

if ($unnamedTypes.Count -gt 0) {
    $facts.Add('')
    $facts.Add('OTHER PUBLIC TYPES IN THIS PROJECT THE PAGE NEVER NAMES, with the file each lives in. This is')
    $facts.Add('the whole project, not only the files the page already cites, so a page that cites a folder that')
    $facts.Add('no longer exists still sees what is really there. Add the ones a developer would look for; a')
    $facts.Add('request or response model belongs in a models section, an options class under configuration:')
    foreach ($entry in ($unnamedTypes | Sort-Object -Unique | Select-Object -First $MaximumUnnamedTypes)) { $facts.Add($entry) }
    if ($unnamedTypes.Count -gt $MaximumUnnamedTypes) {
        $facts.Add("  ... and $($unnamedTypes.Count - $MaximumUnnamedTypes) more, capped so the request stays small")
    }
}

if ($undocumentedServices.Count -gt 0) {
    $facts.Add('')
    $facts.Add('SERVICES IN THIS PROJECT THAT THE PAGE DOES NOT MENTION. Add an entry for each, in the')
    $facts.Add('section where it belongs, so a reader can find it instead of writing it again:')
    foreach ($entry in ($undocumentedServices | Sort-Object -Unique)) { $facts.Add($entry) }
}

$factBlock = $facts -join "`n"

Write-Invariant -Template 'Page          : {0}' -Values @($normalised)
Write-Invariant -Template 'Source files  : {0:N0}' -Values @($cited.Count)
Write-Invariant -Template 'Fact lines    : {0:N0}' -Values @($facts.Count)

if ($DryRun) {
    Write-Host ''
    Write-Host '--- facts that would be written ---'
    Write-Host $factBlock
    Write-Host ''
    Write-Host 'Dry run; nothing written.' -ForegroundColor Yellow
    exit 0
}

$candidateRel = [IO.Path]::GetRelativePath($RepoRoot, $OutputPath).Replace('\', '/')
$rules = @'
## Drafting rules

You ADD missing entries to an existing reference page. You are not rewriting it.

The facts below come from the source files the page cites. They come from the code and are authoritative.

Your job is additive and surgical:
- Add any public named member from the facts that the page does not already mention, in the section and
  table where it belongs, matching the surrounding rows exactly in shape and style.
- Leave every file name on the page exactly as it is. The facts are a partial view, not an inventory:
  a file can be missing from them and still exist. You have no way to tell a deleted file from one the
  facts simply do not cover, so never drop, rename or "correct" a file reference.
- Change NOTHING ELSE. Keep every existing heading, paragraph, table row, list item, code block and
  sentence exactly as it is, including wording you would have phrased differently.

Hard rules:
- The output must be LONGER than the input, or the same length. If you find yourself shortening,
  summarising, merging sections or dropping detail, you have misunderstood the task.
- Do not invent behaviour. When the facts give you a name and a path but no behaviour, write the entry
  as the name and where it lives, which is a fact you were given and a reader can act on.
- NEVER write that something is "not described in the cited sources", or any phrasing like it. A row
  that carries no fact is worse than no row: it makes the page look complete, it satisfies a checker
  that counts names, and it tells the reader nothing. If you have nothing true to say beyond the name
  and the path, say the name and the path and stop.
- Never use an em-dash character. Use a comma, a colon, parentheses, or " - ".
- Do not name individual people.
- Write only the complete markdown page, with your additions merged in, to the candidate path.
'@

$content = [System.Collections.Generic.List[string]]::new()
$content.Add("# Facts for $normalised")
$content.Add('')
$content.Add("- Page: $normalised")
$content.Add("- Candidate: $candidateRel")
$content.Add('')
$content.Add($rules)
$content.Add('')
$content.Add('## Check list')
$content.Add('')
$content.Add("1. Draft the candidate at $candidateRel from the page and the facts below, through write-docs.")
$content.Add("2. Run Update-DocFromGraph.ps1 -DocPath $normalised -Check. It refuses lost words, a lost heading and too many unverified names.")
$content.Add('3. Check every added claim against the source, starting with the UNVERIFIED list.')
$content.Add('4. Merge line by line into the page, add-only, and delete the candidate and this file.')
$content.Add('')
$content.Add('## Facts from some of the cited source files (a partial view, absence proves nothing)')
$content.Add('')
$content.Add('```text')
$content.Add($factBlock)
$content.Add('```')

$factsDirectory = Split-Path -Parent $FactsPath
if ($factsDirectory -and -not (Test-Path -LiteralPath $factsDirectory)) {
    New-Item -ItemType Directory -Path $factsDirectory -Force | Out-Null
}
Set-Content -LiteralPath $FactsPath -Value ($content -join "`n") -Encoding utf8

Write-Invariant -Template 'Facts written to {0}' -Values @($FactsPath) -ForegroundColor Green
Write-Host 'Hand the facts file to a subagent that drafts the candidate through write-docs, then run this script with -Check.' -ForegroundColor Yellow
Write-Host 'This script never edits the page and never commits (C09). See the write-docs skill.' -ForegroundColor Yellow
exit 0
