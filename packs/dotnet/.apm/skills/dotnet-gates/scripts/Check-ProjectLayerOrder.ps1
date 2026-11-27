#Requires -Version 7
<#
.SYNOPSIS
    Gate: each project reference that the change adds, or that a plan names, points to a lower layer.

.DESCRIPTION
    A repository can name the layers of its projects in dotnet.layers in aisdlc.json. The list runs from
    the lowest layer to the highest one. Each layer has a name and projects, a list of path globs that
    are matched against the repo-relative path of a project file, with the matcher of
    pullRequest.sizeExclude (Test-AiSdlcPathGlob in ChangedFiles.psm1): ** crosses folders, and the case
    is ignored on Windows only. A project belongs to the layers that hold its path. A glob that matches no
    project does nothing.

    Example:

      "dotnet": { "layers": [
        { "name": "Kernel", "projects": ["src/Kernel/*.csproj"] },
        { "name": "Domain", "projects": ["src/Domain*/*.csproj"] },
        { "name": "Tests",  "projects": ["tests/**/*.csproj"] } ] }

    A project may only reference a project in a lower layer. A reference inside one layer is a finding
    too. In the default mode the gate judges only a ProjectReference whose Include line the change adds in
    a changed .csproj file, read with Get-DotnetAddedProjectReference in DotnetTestScope.psm1, so an old
    reference against the order is not named again. With -All it judges every reference of every project
    file, and it uses no git. A reference is judged also when ReferenceOutputAssembly is false or
    OutputItemType is Analyzer. The target needs only its path, so a project file that is not a .csproj
    file (a .sqlproj file) is layered by its path.

    A project that no layer holds is named, and each reference of it or to it is not judged. A project that
    two layers hold is a setting problem that is named on every run, also when the change adds no
    reference, and its references are not judged. The setting is read from aisdlc.json in the working tree.

    With -From and -To the gate judges one planned reference from the project file -From to the project
    file -To, with the same layers and the same texts as for a reference that a change adds. It reads
    no git, no project file and no project graph, so both projects may not exist yet. Each path is
    repo-relative: a backslash counts as a slash, and a leading ./ or / is dropped. A rooted path or a
    path with a .. part cannot be checked. -From and -To go together, and they do not go with -All,
    -ChangedFiles or -BaseRef. A project elsewhere in the repository that two layers hold is not named
    in this mode, because it reads no project graph; a run without -From and -To names it.

    ADVISORY: exit 1 is a warning, not a block. A reference against the order may be a choice that the
    team still has to make.

    Exit codes follow the gate contract: 0 checked and clean, 1 a finding, 2 could not check (aisdlc.json
    cannot be read, dotnet.layers has the wrong shape, a project that two layers hold, the change cannot
    be listed, a project file cannot be read, a reference cannot be followed, a project is in no layer, or
    -From and -To are not a valid pair of paths),
    3 not applicable (dotnet.layers is not set, the repository holds no .csproj file, or no changed project
    file adds a project reference). With -From and -To, exit 0 means the planned reference points to a
    lower layer, and exit 1 means it does not.

.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script.

.PARAMETER BaseRef
    The ref the change is measured against when no explicit file list is given. Defaults to origin/<github.trunk> from aisdlc.json (Get-AiSdlcMainBranch),
    origin/main unless the repository names another trunk.

.PARAMETER ChangedFiles
    Explicit repository-relative paths, bypassing the git file list. With no base to diff against, the
    whole of each listed file counts as added. When a base resolves, only the lines that differ from it count.
    Falls back to the newline-separated CHANGED_FILES environment variable, which the pipeline sets from
    the pull request diff.

.PARAMETER All
    Judge every project reference of every project file, with no git.

.PARAMETER From
    The project file of a planned reference, as a repo-relative path. Needs -To.

.PARAMETER To
    The project file that the planned reference points to, as a repo-relative path. Needs -From.

.EXAMPLE
    pwsh .claude/skills/dotnet-gates/scripts/Check-ProjectLayerOrder.ps1

.EXAMPLE
    pwsh .claude/skills/dotnet-gates/scripts/Check-ProjectLayerOrder.ps1 -All

.EXAMPLE
    pwsh .claude/skills/dotnet-gates/scripts/Check-ProjectLayerOrder.ps1 -From src/Domain/Domain.csproj -To src/Kernel/Kernel.csproj
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$BaseRef,
    [string[]]$ChangedFiles,
    [switch]$All,
    [string]$From,
    [string]$To
)

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
Import-Module (Join-Path $aiSdlcGates 'ChangedFiles.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DotnetTestScope.psm1') -Force

$ErrorActionPreference = 'Stop'

$script:Problems = [System.Collections.Generic.List[string]]::new()

function Add-Problem {
    param([string]$Text)

    if (-not $script:Problems.Contains($Text)) { $script:Problems.Add($Text) }
}

function Write-NotChecked {
    param([string[]]$Reason, [string]$Fix)

    Write-Host 'Could not check:' -ForegroundColor Yellow
    foreach ($line in @($script:Problems) + $Reason) { Write-Host "  $line" -ForegroundColor Yellow }
    Write-Host "FIX: $Fix" -ForegroundColor Yellow
    exit 2
}

function Get-LayerShapeProblem {
    param([object]$Layers)

    if ($Layers -isnot [System.Collections.IList]) { return @('aisdlc.json : dotnet.layers must be a list of layers') }
    $found = [System.Collections.Generic.List[string]]::new()
    $names = @{}
    for ($index = 0; $index -lt $Layers.Count; $index++) {
        $layer = $Layers[$index]
        $where = "aisdlc.json : dotnet.layers[$index]"
        if ($layer -isnot [System.Collections.IDictionary]) { $found.Add("$where must be an object with a name and projects"); continue }
        $name = if ($layer.Contains('name')) { $layer['name'] } else { $null }
        if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name)) { $found.Add("$where.name must be a string that is not blank") }
        elseif ($names.ContainsKey($name)) { $found.Add("$where.name '$name' is already used by dotnet.layers[$($names[$name])]") }
        else { $names[$name] = $index }
        $projects = $null
        if ($layer.Contains('projects')) { $projects = $layer['projects'] }
        if ($projects -isnot [System.Collections.IList] -or $projects.Count -eq 0) { $found.Add("$where.projects must be a list of one or more path globs"); continue }
        for ($glob = 0; $glob -lt $projects.Count; $glob++) {
            if ($projects[$glob] -isnot [string] -or [string]::IsNullOrWhiteSpace($projects[$glob])) { $found.Add("$where.projects[$glob] must be a path glob that is not blank") }
        }
    }
    return $found.ToArray()
}

function Get-ProjectLayer {
    param([string]$Path)

    $held = [System.Collections.Generic.List[int]]::new()
    for ($index = 0; $index -lt $script:Layers.Count; $index++) {
        foreach ($glob in $script:Layers[$index]['projects']) {
            if (Test-AiSdlcPathGlob -Path $Path -Glob $glob) { $held.Add($index); break }
        }
    }
    return , $held.ToArray()
}

function Add-AmbiguousProblem {
    param([string]$Path, [int[]]$Held)

    $quoted = @($Held | ForEach-Object { "'$($script:Layers[$_]['name'])'" })
    $list = if ($quoted.Count -eq 2) { "$($quoted[0]) and $($quoted[1])" } else { ($quoted[0..($quoted.Count - 2)] -join ', ') + " and $($quoted[-1])" }
    $quantity = if ($quoted.Count -eq 2) { 'both' } else { 'all' }
    Add-Problem "$Path : layers $list of dotnet.layers $quantity hold this project"
}

function Get-ReferenceVerdict {
    param([string]$From, [string]$To)

    $fromHeld = Get-ProjectLayer -Path $From
    $toHeld = Get-ProjectLayer -Path $To
    if ($fromHeld.Count -gt 1 -or $toHeld.Count -gt 1) {
        if ($fromHeld.Count -gt 1) { Add-AmbiguousProblem -Path $From -Held $fromHeld }
        if ($toHeld.Count -gt 1) { Add-AmbiguousProblem -Path $To -Held $toHeld }
        return [pscustomobject]@{ Kind = 'ambiguous'; Detail = $null }
    }
    if ($fromHeld.Count -eq 0 -or $toHeld.Count -eq 0) {
        if ($fromHeld.Count -eq 0) { Add-Problem "$From : no layer of dotnet.layers holds this project, so $From -> $To is not judged" }
        if ($toHeld.Count -eq 0) { Add-Problem "$To : no layer of dotnet.layers holds this project, so $From -> $To is not judged" }
        return [pscustomobject]@{ Kind = 'no layer'; Detail = $null }
    }
    $detail = "from layer '$($script:Layers[$fromHeld[0]]['name'])' ($($fromHeld[0])) to layer '$($script:Layers[$toHeld[0]]['name'])' ($($toHeld[0]))"
    $kind = if ($toHeld[0] -ge $fromHeld[0]) { 'not lower' } else { 'lower' }
    return [pscustomobject]@{ Kind = $kind; Detail = $detail }
}

$script:Planned = $PSBoundParameters.ContainsKey('From') -or $PSBoundParameters.ContainsKey('To')
if ($script:Planned) {
    $argumentFix = 'Pass -From and -To together, each a repo-relative project path without a drive letter or a .. part, and not with -All, -ChangedFiles or -BaseRef.'
    if (-not ($PSBoundParameters.ContainsKey('From') -and $PSBoundParameters.ContainsKey('To'))) {
        Write-NotChecked -Reason @('-From and -To must be given together') -Fix $argumentFix
    }
    if ($All -or $PSBoundParameters.ContainsKey('ChangedFiles') -or $PSBoundParameters.ContainsKey('BaseRef')) {
        Write-NotChecked -Reason @('-From and -To cannot be used with -All, -ChangedFiles or -BaseRef') -Fix $argumentFix
    }
    $plannedPath = @{}
    foreach ($name in 'From', 'To') {
        $value = [string]$PSBoundParameters[$name]
        $clean = $value.Trim().Replace('\', '/')
        if ($clean -match '^[A-Za-z]:') { Add-Problem "-$name '$value' is a rooted path, so it cannot be a repo-relative project path"; continue }
        $clean = $clean -replace '^(\./|/)+', ''
        if ([string]::IsNullOrWhiteSpace($clean)) { Add-Problem "-$name is blank, so it names no project"; continue }
        if ($clean.Split('/') -contains '..') { Add-Problem "-$name '$value' has a .. part, so it cannot be a repo-relative project path"; continue }
        $plannedPath[$name] = $clean
    }
    if ($script:Problems.Count -gt 0) { Write-NotChecked -Reason @() -Fix $argumentFix }
}

$aiSdlcError = $null
try { $aiSdlc = Get-AiSdlcConfig -RepoRoot $RepoRoot -StartPath $PSScriptRoot }
catch { $aiSdlcError = $_.Exception.Message }
if ($aiSdlcError) { Write-NotChecked -Reason @("aisdlc.json cannot be read ($aiSdlcError)") -Fix 'Make aisdlc.json valid JSON, then run the gate again.' }
if (-not $RepoRoot) { $RepoRoot = $aiSdlc.repoRoot }

$dotnet = $aiSdlc.dotnet
if ($null -ne $dotnet -and $dotnet -isnot [System.Collections.IDictionary]) {
    Write-NotChecked -Reason @('aisdlc.json : dotnet.layers cannot be read because dotnet is not an object') -Fix 'Make dotnet an object in aisdlc.json, then run the gate again.'
}
$rawLayers = $null
if ($dotnet -and $dotnet.Contains('layers')) { $rawLayers = $dotnet['layers'] }
if ($null -eq $rawLayers -or ($rawLayers -is [System.Collections.IList] -and $rawLayers.Count -eq 0)) {
    Write-Host 'Not applicable: aisdlc.json sets no dotnet.layers.'
    exit 3
}
$shape = @(Get-LayerShapeProblem -Layers $rawLayers)
if ($shape.Count -gt 0) {
    Write-NotChecked -Reason $shape -Fix 'Fix dotnet.layers in aisdlc.json, a list of layers from the lowest to the highest, each with a name and a list of project globs, then run the gate again.'
}
$script:Layers = $rawLayers

$findings = [System.Collections.Generic.List[string]]::new()
$judged = 0
$plannedOk = $null

if ($script:Planned) {
    $verdict = Get-ReferenceVerdict -From $plannedPath['From'] -To $plannedPath['To']
    if ($verdict.Kind -eq 'not lower') { $findings.Add("$($plannedPath['From']) -> $($plannedPath['To']) : $($verdict.Detail), which is not a lower layer") }
    elseif ($verdict.Kind -eq 'lower') { $plannedOk = "Project layer order OK: $($plannedPath['From']) -> $($plannedPath['To']) : $($verdict.Detail), which is a lower layer." }
}
else {
    $graph = @(Get-DotnetProjectGraph -RepoRoot $RepoRoot)
    if ($graph.Count -eq 0) {
        Write-Host 'Not applicable: the repository holds no .csproj file, so there is no project reference to check.'
        exit 3
    }

    foreach ($project in $graph) {
        $held = Get-ProjectLayer -Path $project.Path
        if ($held.Count -gt 1) { Add-AmbiguousProblem -Path $project.Path -Held $held }
    }

    $candidates = [System.Collections.Generic.List[object]]::new()

    if ($All) {
        foreach ($project in $graph) {
            if ($project.Error -eq 'cannot be read') { Add-Problem "$($project.Path) cannot be read"; continue }
            foreach ($item in $project.ReferenceItems) { $candidates.Add([pscustomobject]@{ Project = $project; Item = $item }) }
        }
    }
    else {
        if (-not $BaseRef) { $BaseRef = Get-AiSdlcMainBranch -RepoRoot $RepoRoot }
        $script:MainBranch = $BaseRef -replace '^origin/', ''
        $change = Get-AiSdlcChange -RepoRoot $RepoRoot -BaseRef $BaseRef -Explicit $ChangedFiles
        if (-not $change.Readable) {
            Write-NotChecked -Reason @("$($change.Reason), so the change cannot be listed.") -Fix "Fetch the base branch (git fetch origin $($script:MainBranch)), or pass -BaseRef with a ref that exists."
        }
        $added = Get-DotnetAddedProjectReference -RepoRoot $RepoRoot -Projects $graph -Files @($change.Files) -Base $change.Base -AssumeNew:([bool]$ChangedFiles)
        if (@($added.LinesUnknown).Count -gt 0) {
            Write-NotChecked -Reason @(("there is no base to diff against, so the lines this change adds to {0} cannot be read." -f (@($added.LinesUnknown) -join ', '))) -Fix "Fetch the base branch (git fetch origin $($script:MainBranch)), or pass -BaseRef with a ref that exists."
        }
        foreach ($file in @($added.Unreadable)) { Add-Problem "$file cannot be read" }
        foreach ($row in @($added.References)) { $candidates.Add($row) }
    }

    if ($candidates.Count -eq 0 -and $script:Problems.Count -eq 0) {
        $scope = if ($All) { 'the repository holds no project reference' } else { 'no changed project file adds a project reference' }
        Write-Host "Not applicable: $scope."
        exit 3
    }

    foreach ($candidate in $candidates) {
        $source = $candidate.Project.Path
        $item = $candidate.Item
        if (-not $item.Path) { Add-Problem "$source : references $($item.Include), which cannot be followed"; continue }
        $target = $item.Path
        $verdict = Get-ReferenceVerdict -From $source -To $target
        if ($verdict.Kind -in 'ambiguous', 'no layer') { continue }
        $judged++
        if ($verdict.Kind -eq 'not lower') {
            $text = "$source -> $target : $($verdict.Detail), which is not a lower layer"
            if (-not $findings.Contains($text)) { $findings.Add($text) }
        }
    }
}

$problemText = @($script:Problems)

if ($findings.Count -gt 0) {
    Write-Host 'Project layer order: a project reference does not point to a lower layer.' -ForegroundColor Yellow
    foreach ($finding in $findings) { Write-Host "  $finding" }
    if ($problemText.Count -gt 0) {
        Write-Host 'Could not check:' -ForegroundColor Yellow
        foreach ($problem in $problemText) { Write-Host "  $problem" }
    }
    Write-Host 'FIX: Remove the reference or point it at a project in a lower layer, or fix dotnet.layers in aisdlc.json when the order itself is wrong.'
    Write-Host ("Project layer order: {0} project reference(s) do not point to a lower layer." -f $findings.Count)
    exit 1
}

if ($problemText.Count -gt 0) {
    Write-Host 'Could not check:' -ForegroundColor Yellow
    foreach ($problem in $problemText) { Write-Host "  $problem" -ForegroundColor Yellow }
    Write-Host 'FIX: Repair the file or the reference named above, or add the project to exactly one layer of dotnet.layers, then run the gate again.' -ForegroundColor Yellow
    exit 2
}

if ($plannedOk) { Write-Host $plannedOk }
else { Write-Host ("Project layer order OK: {0} project reference(s) checked, and each points to a lower layer." -f $judged) }
exit 0
