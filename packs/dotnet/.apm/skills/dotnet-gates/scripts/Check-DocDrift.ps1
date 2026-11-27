#Requires -Version 7
<#
.SYNOPSIS
    Reports documentation that has fallen behind the code it documents, by comparing what a page says
    against what the source files it cites actually declare.

.DESCRIPTION
    A stale page is worse than a missing one, because it answers with confidence. It needs no code graph
    and no AI tooling, only git and the files, so the pre-push hook runs it for everyone.

    Six signals: [missing] a public constant a cited file declares and the page never names, [stale] a
    cited file that no longer exists, [phantom] a backticked identifier that exists nowhere, [route] a
    documented endpoint no route-carrying file names, [service] a service in the documented project the
    page never names, and [thin] a project page that names few of its project's public methods, which is
    informational and never drift.

    A test of a shared script that the page names is not [stale] when its name is in sharedTests of the
    installed sync manifest: AI.SDLC keeps those tests and does not install them.

    It judges only the lines the change adds or changes (Get-AiSdlcLineChange in ChangedFiles.psm1), measured
    against the base ref. Drift the change caused fails: a public constant or a service that the change adds
    and the page does not name; a cited file, symbol or route that the change removed or renamed; and a name
    cited on a page line that the change adds or changes. Older drift is printed under a not blocking heading
    and never fails the run. [thin] is informational as before.

    Exit 0 clean, or only older drift; 1 drift the change caused, with -FailOnDrift; 2 could not check
    (aisdlc.json names no paths.sourceRoot, or the change cannot be told because there is no merge base,
    also in a local run; the output has a FIX: line). It never judges every page instead. Exit 3 is not used.

    Advisory by default; -FailOnDrift exits non-zero. What it checks, what it deliberately does not, the
    measured coverage and the alternatives that were tried and rejected are all in
    .claude/skills/dotnet-code-graph/references/code-graph.md, under "Finding documentation that has fallen behind".

.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script.

.PARAMETER BaseRef
    The ref the change is measured against. Defaults to origin/<github.trunk> from aisdlc.json
    (Get-AiSdlcMainBranch), origin/main unless the repository names another trunk. In a pull request
    build the shared action sets CHANGED_FILES and PR_TARGET_BRANCH, which Get-AiSdlcChange reads.

.PARAMETER DocRoots
    Directories to scan for documentation. Defaults to paths.docsRoots in aisdlc.json.

.PARAMETER Doc
    Check only pages whose path contains this fragment. Useful when working on one area.

.PARAMETER RecordPattern
    Path fragments whose pages are point-in-time records rather than reference pages. They are checked
    for broken file references only. Defaults to the record folders DocSurface.psm1 declares, which are
    the ADR and story folders.

.PARAMETER MinimumCitationsForProject
    How many files a page must cite from one project before that project is treated as the one it
    documents. Defaults to 2. This is the fallback; a page in a project page folder is matched by name
    first. The project page folders come from paths.sourceDocMap in aisdlc.json (see DocSurface.psm1).

.PARAMETER ThinPageMethodPercent
    A project page that names fewer than this percentage of its project's public
    methods is reported as [thin]. Defaults to 25. Informational, never a drift finding on its own.

.PARAMETER ServiceCheckFolder
    Only pages under these path fragments are asked to name the services of the project they document.
    Defaults to the project page folders DocSurface.psm1 reads from paths.sourceDocMap in aisdlc.json.

.PARAMETER SkipSymbolCheck
    Skip the [phantom] signal, which reports a backticked identifier that exists nowhere in the repository.

.PARAMETER SkipRouteCheck
    Skip the [route] signal, which reads the HTTP routes an API page documents and reports one whose
    path no route-carrying file names. The API page folders come from dotnet.routePageFolders in
    aisdlc.json, and default to docs/api/.

.PARAMETER SkipServiceCheck
    Skip the [service] signal, which reads every source file in the projects a page documents.

.PARAMETER KnownExternalType
    Identifiers that are real but declared outside this repository, so the [phantom] signal leaves them
    alone.

.PARAMETER FailOnDrift
    Exit 1 when any page has drifted. Off by default so the script can be run to read its report
    without failing a shell, but both the local aggregator and CI pass it and treat the gate as
    blocking.

.EXAMPLE
    ./Check-DocDrift.ps1

.EXAMPLE
    ./Check-DocDrift.ps1 -Doc libraries/ledger -FailOnDrift
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$BaseRef,
    [string[]]$DocRoots,
    [string]$Doc,
    [string[]]$RecordPattern,
    [int]$MinimumCitationsForProject = 2,
    [int]$ThinPageMethodPercent = 25,
    [string[]]$ServiceCheckFolder,
    [switch]$SkipServiceCheck,
    [switch]$SkipRouteCheck,
    [switch]$SkipSymbolCheck,
    [string[]]$KnownExternalType = @('WebApplicationBuilder', 'IFunctionsWorkerApplicationBuilder', 'MvcOptions', 'TypeInfoResolver', 'IHostApplicationBuilder', 'JsonSerializerOptions', 'ServiceCollectionExtensions', 'ValidateAndThrowAsync', 'ValidationContext', 'CancellationToken', 'HttpContext', 'ClaimsPrincipal'),
    [switch]$FailOnDrift
)

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
Import-Module (Join-Path $aiSdlcGates 'ChangedFiles.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }
if (-not $BaseRef) { $BaseRef = Get-AiSdlcMainBranch -RepoRoot $RepoRoot }

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'DocSurface.psm1') -Force
Import-Module (Join-Path $aiSdlcGates 'ToolOutput.psm1') -Force

if (Test-Path -LiteralPath $RepoRoot) { $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path }

$script:AiSdlc = Get-AiSdlcConfig -RepoRoot $RepoRoot
if (-not $DocRoots) { $DocRoots = @(Get-AiSdlcPath -Name docsRoots -RepoRoot $RepoRoot -Relative) }
$script:SourceRel = ([string]$script:AiSdlc.paths.sourceRoot).TrimEnd('/')
$script:TestRel = ([string]$script:AiSdlc.paths.testRoot).TrimEnd('/')
if (-not $script:SourceRel) {
    Write-Host 'Could not check: aisdlc.json names no paths.sourceRoot, so there is no code to hold the pages against.' -ForegroundColor Yellow
    Write-Host 'FIX: Set paths.sourceRoot in aisdlc.json to the folder that holds the source code.' -ForegroundColor Yellow
    exit 2
}

if (-not $RecordPattern) { $RecordPattern = Get-RecordFolder -RepoRoot $RepoRoot }
if (-not $ServiceCheckFolder) { $ServiceCheckFolder = Get-ProjectPageFolder -RepoRoot $RepoRoot }

$script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture

$script:RoutePageFolder = @($script:AiSdlc.dotnet.routePageFolders | Where-Object { $_ })
if ($script:RoutePageFolder.Count -eq 0) { $script:RoutePageFolder = @('docs/api/') }

function Test-RoutePage {
    param([Parameter(Mandatory)][string]$DocPath)

    $normalised = $DocPath.Replace('\', '/')
    foreach ($folder in $script:RoutePageFolder) {
        if ($normalised -like "*$(([string]$folder).Replace('\', '/'))*") { return $true }
    }
    return $false
}


function Show-Coverage {
    Write-Host ''
    Write-Host 'How much of the documented surface this check actually verifies:'
    if ($script:DeclaredMembers -gt 0) {
        $share = [math]::Round(($script:NamedMembers / $script:DeclaredMembers) * 100, 0)
        Write-Invariant -Template '  named constants  : {0:N0} of {1:N0} declared appear on a page ({2:N0}%). CHECKED.' -Values @($script:NamedMembers, $script:DeclaredMembers, $share)
    }
    if ($script:DeclaredMethods -gt 0) {
        $share = [math]::Round(($script:NamedMethods / $script:DeclaredMethods) * 100, 0)
        Write-Invariant -Template '  public methods   : {0:N0} of {1:N0} declared appear on a page ({2:N0}%). NOT CHECKED, reported only.' -Values @($script:NamedMethods, $script:DeclaredMethods, $share)
    }
    if ($script:DeclaredServices -gt 0) {
        $share = [math]::Round(($script:NamedServices / $script:DeclaredServices) * 100, 0)
        Write-Invariant -Template '  services/clients : {0:N0} of {1:N0} declared appear on a page ({2:N0}%). CHECKED.' -Values @($script:NamedServices, $script:DeclaredServices, $share)
    }
    if ($script:UnattributedProject.Count -gt 0) {
        Write-Invariant -Template '  {0:N0} project(s) have no page that documents them, so their services are NOT CHECKED at all:' -Values @($script:UnattributedProject.Count)
        Write-Invariant -Template '    {0}' -Values @((($script:UnattributedProject | Sort-Object) -join ', '))
    }
    if (-not $SkipRouteCheck) {
        Write-Invariant -Template '  API routes       : {0:N0} documented route(s) read; each must be named by a file that carries a route. CHECKED.' -Values @($script:DocumentedRoutes)
    }
    if (-not $SkipSymbolCheck) {
        Write-Invariant -Template '  named symbols    : {0:N0} identifier(s) matched as symbols and checked page-to-code. A SAMPLE, NOT THE PAGE.' -Values @($script:DocumentedSymbols)
        Write-Host '                     Only an Add* extension, a name ending Async, or a service-shaped suffix is read.'
        Write-Host '                     A backticked model or plain method name is not, so a clean run leaves most of a page unread.'
    }
    Write-Host '  behaviour, config keys, prose: NOT CHECKED and not measurable here.'
    Write-Host '  A clean run means the checked signals are right, not that the pages are correct.'
}

Push-Location -LiteralPath $RepoRoot
try {
    $tracked = @(& git ls-files 2>$null)
    if ($LASTEXITCODE -ne 0) {
        Write-Host "'$RepoRoot' is not inside a git working tree." -ForegroundColor Red
        exit 1
    }
}
finally { Pop-Location }

$change = Get-AiSdlcChange -RepoRoot $RepoRoot -BaseRef $BaseRef
if (-not $change.Readable -or -not $change.Base) {
    $why = if ($change.Reason) { $change.Reason } else { "no merge base between $BaseRef and HEAD" }
    Write-Host "Could not check: the lines that the change adds or removes are unknown ($why)." -ForegroundColor Yellow
    Write-Host 'FIX: Fetch the target branch with full history (for example fetch-depth: 0 in the checkout step), then run the gate again.' -ForegroundColor Yellow
    exit 2
}

$script:ChangedPath = [System.Collections.Generic.HashSet[string]]::new([string[]]@($change.Files))
$script:ChangeTextCache = @{}

# The text a change added to one file, as it is on disk, and the text it removed. Empty for a file the change did not touch.
function Get-ChangeText {
    param([Parameter(Mandatory)][string]$Path)

    if ($script:ChangeTextCache.ContainsKey($Path)) { return $script:ChangeTextCache[$Path] }
    $result = [pscustomobject]@{ Added = ''; Removed = '' }
    if ($script:ChangedPath.Contains($Path)) {
        $lineChange = Get-AiSdlcLineChange -RepoRoot $RepoRoot -Base $change.Base -Path $Path
        if ($lineChange) {
            $full = Join-Path $RepoRoot $Path
            if ($lineChange.Added.Count -gt 0 -and (Test-Path -LiteralPath $full -PathType Leaf)) {
                $fileLines = @(Get-Content -LiteralPath $full -Encoding utf8)
                $result.Added = (@($lineChange.Added | Where-Object { $_ -ge 1 -and $_ -le $fileLines.Count } | ForEach-Object { $fileLines[$_ - 1] })) -join "`n"
            }
            $result.Removed = @($lineChange.Removed) -join "`n"
        }
    }
    $script:ChangeTextCache[$Path] = $result
    return $result
}

function Test-NameInText {
    param([string]$Name, [string]$Text)

    if (-not $Text) { return $false }
    return [bool]($Text -match ('\b' + [regex]::Escape($Name) + '\b'))
}

# The file names the repository held at the base: a cited name that was here then and is gone now was removed or renamed by the change.
$script:BaseNames = [System.Collections.Generic.HashSet[string]]::new()
foreach ($path in @(& git -C $RepoRoot -c core.quotepath=off ls-tree -r --name-only $change.Base 2>$null)) {
    if ($path) { [void]$script:BaseNames.Add([System.IO.Path]::GetFileName(([string]$path).Replace('\', '/'))) }
}

$trackedNames = [System.Collections.Generic.HashSet[string]]::new()
$syncManifest = Join-Path $RepoRoot '.claude' 'skills' 'ai-sdlc-gates' 'sync-manifest.json'
if (Test-Path -LiteralPath $syncManifest -PathType Leaf) {
    foreach ($name in @((Get-Content -LiteralPath $syncManifest -Raw | ConvertFrom-Json).sharedTests)) { if ($name) { [void]$trackedNames.Add([string]$name) } }
}
$sourceByName = @{}
foreach ($path in $tracked) {
    if (-not $path) { continue }
    $name = [System.IO.Path]::GetFileName($path)
    [void]$trackedNames.Add($name)
    if ([System.IO.Path]::GetExtension($path).ToLowerInvariant() -ne '.cs') { continue }
    if (-not $sourceByName.ContainsKey($name)) { $sourceByName[$name] = [System.Collections.Generic.List[string]]::new() }
    $sourceByName[$name].Add(($path -replace '\\', '/'))
}

$filesByProject = @{}
foreach ($path in $tracked) {
    if (-not $path) { continue }
    $norm = $path -replace '\\', '/'
    if (-not $norm.StartsWith("$($script:SourceRel)/")) { continue }
    if ([System.IO.Path]::GetExtension($norm).ToLowerInvariant() -ne '.cs') { continue }
    $project = ($norm.Substring($script:SourceRel.Length + 1) -split '/')[0]
    if (-not $filesByProject.ContainsKey($project)) { $filesByProject[$project] = [System.Collections.Generic.List[string]]::new() }
    $filesByProject[$project].Add($norm)
}

$docPaths = [System.Collections.Generic.List[string]]::new()
foreach ($relative in $DocRoots) {
    $full = Join-Path $RepoRoot $relative
    if (-not (Test-Path -LiteralPath $full)) { continue }
    foreach ($file in (Get-ChildItem -LiteralPath $full -Recurse -Filter '*.md' -File)) {
        $docPaths.Add(($file.FullName.Substring($RepoRoot.Length).TrimStart('\', '/') -replace '\\', '/'))
    }
}

$isRecordByDoc = @{}
$uncitedDocs = 0
$filesByDoc = @{}
foreach ($docPath in $docPaths) {
    if ($Doc -and ($docPath -notlike "*$Doc*")) { continue }

    $isRecord = $false
    foreach ($pattern in $RecordPattern) {
        if ($docPath -like "*$pattern*") { $isRecord = $true; break }
    }
    $isRecordByDoc[$docPath] = $isRecord

    $docFull = Join-Path $RepoRoot $docPath
    $docText = Get-Content -LiteralPath $docFull -Raw -Encoding utf8
    if (-not $docText) { continue }

    $names = Get-NamedSourceFile -Text $docText
    if ($names.Count -eq 0) {
        $wantsRoutes = (-not $SkipRouteCheck) -and (Test-RoutePage -DocPath $docPath)
        $wantsSymbols = (-not $SkipSymbolCheck) -and (-not $isRecord)
        if ($wantsRoutes -or $wantsSymbols) {
            $filesByDoc[$docPath] = [System.Collections.Generic.HashSet[string]]::new()
            $uncitedDocs++
        }
        continue
    }

    $filesByDoc[$docPath] = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($name in $names) {
        if (-not $sourceByName.ContainsKey($name)) { continue }
        if ($sourceByName[$name].Count -gt 1) { continue }
        [void]$filesByDoc[$docPath].Add($sourceByName[$name][0])
    }
}

if ($filesByDoc.Count -eq 0) {
    Write-Host 'No documentation pages matched.' -ForegroundColor Yellow
    exit 0
}

$findings = [System.Collections.Generic.List[object]]::new()
$olderFindings = [System.Collections.Generic.List[object]]::new()
function Test-RouteCarrier {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Source
    )

    if ($FileName -like '*Controller*.cs') { return $true }
    if ($Source -match 'HttpTrigger') { return $true }
    if ($Source -match '\bMap(Get|Post|Put|Patch|Delete|Methods|Hub|Group)\s*[(<]') { return $true }
    if ($Source -match '\[(Route|Http(Get|Post|Put|Patch|Delete))\s*\(') { return $true }
    if ($Source -match '(?m)Path\w*\s*=\s*"/') { return $true }
    return $false
}

$script:RepositoryProject = Get-RepositoryProjectName -RepoRoot $RepoRoot
$script:GeneratedPath = '[\\/](obj|bin)[\\/]'
$script:SourceCorpus = ''
$script:RouteCarrierSource = ''
if (-not ($SkipSymbolCheck -and $SkipRouteCheck)) {
    $corpusParts = [System.Collections.Generic.List[string]]::new()
    $routeParts = [System.Collections.Generic.List[string]]::new()
    foreach ($area in @($script:SourceRel, $script:TestRel | Where-Object { $_ })) {
        $areaRoot = Join-Path $RepoRoot $area
        if (-not (Test-Path -LiteralPath $areaRoot)) { continue }
        foreach ($file in (Get-ChildItem -LiteralPath $areaRoot -Recurse -File)) {
            if ($file.Extension -notin @('.cs', '.razor', '.csproj')) { continue }
            if ($file.FullName -match $script:GeneratedPath) { continue }
            $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
            if (-not $text) { continue }
            if (-not $SkipSymbolCheck) { $corpusParts.Add($text) }
            if (-not $SkipRouteCheck -and $area -eq $script:SourceRel -and $file.Extension -eq '.cs' -and
                (Test-RouteCarrier -FileName $file.Name -Source $text)) {
                $routeParts.Add($text)
            }
        }
    }
    $script:SourceCorpus = $corpusParts -join "`n"
    $script:RouteCarrierSource = $routeParts -join "`n"
}

$script:RemovedCorpus = ''
$removedParts = foreach ($path in @($change.Files)) {
    if ([System.IO.Path]::GetExtension($path).ToLowerInvariant() -notin @('.cs', '.razor', '.csproj')) { continue }
    $inArea = $false
    foreach ($area in @($script:SourceRel, $script:TestRel | Where-Object { $_ })) { if ($path.StartsWith("$area/")) { $inArea = $true } }
    if ($inArea) { (Get-ChangeText -Path $path).Removed }
}
$script:RemovedCorpus = @($removedParts | Where-Object { $_ }) -join "`n"

$checkedDocs = 0
$checkedRecords = 0
$script:DeclaredMembers = 0
$script:NamedMembers = 0
$script:DeclaredMethods = 0
$script:NamedMethods = 0
$script:DeclaredServices = 0
$script:NamedServices = 0
$script:AttributedProject = [System.Collections.Generic.HashSet[string]]::new()
$script:DocumentedRoutes = 0
$script:DocumentedSymbols = 0

foreach ($docPath in ($filesByDoc.Keys | Sort-Object)) {
    $docFull = Join-Path $RepoRoot $docPath
    if (-not (Test-Path -LiteralPath $docFull)) { continue }
    $docText = Get-Content -LiteralPath $docFull -Raw -Encoding utf8
    if (-not $docText) { continue }
    $checkedDocs++
    $isRecord = [bool]$isRecordByDoc[$docPath]
    if ($isRecord) { $checkedRecords++ }

    $causedItem = [System.Collections.Generic.HashSet[string]]::new()
    $pageAdded = (Get-ChangeText -Path $docPath).Added
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($sourceFile in ($filesByDoc[$docPath] | Sort-Object)) {
        if ([System.IO.Path]::GetExtension($sourceFile).ToLowerInvariant() -ne '.cs') { continue }
        $sourceFull = Join-Path $RepoRoot $sourceFile
        if (-not (Test-Path -LiteralPath $sourceFull)) { continue }
        $source = Get-Content -LiteralPath $sourceFull -Raw -Encoding utf8
        if (-not $source) { continue }

        $addedSource = (Get-ChangeText -Path $sourceFile).Added
        $addedMember = if ($addedSource) { @(Get-PublicMemberName -Source $addedSource) } else { @() }
        foreach ($member in (Get-PublicMemberName -Source $source)) {
            $script:DeclaredMembers++
            if ($docText -match ('\b' + [regex]::Escape($member) + '\b')) { $script:NamedMembers++ }
            elseif (-not $isRecord) {
                $item = "$member ($([System.IO.Path]::GetFileName($sourceFile)))"
                $missing.Add($item)
                if ($addedMember -contains $member) { [void]$causedItem.Add("missing|$item") }
            }
        }
        foreach ($method in (Get-PublicMethodName -Source $source)) {
            $script:DeclaredMethods++
            if ($docText -match ('\b' + [regex]::Escape($method) + '\b')) { $script:NamedMethods++ }
        }
    }

    $stale = [System.Collections.Generic.List[string]]::new()
    if ($docText -notmatch '(?s)^.{0,400}\*\*Removed\.\*\*') {
        foreach ($name in (Get-NamedSourceFile -Text $docText)) {
            if (-not $trackedNames.Contains($name)) {
                $stale.Add($name)
                if ($script:BaseNames.Contains($name) -or (Test-NameInText -Name $name -Text $pageAdded)) { [void]$causedItem.Add("stale|$name") }
            }
        }
    }

    $badRoutes = [System.Collections.Generic.List[string]]::new()
    if (-not $isRecord -and -not $SkipRouteCheck -and (Test-RoutePage -DocPath $docPath) -and $docText -notmatch '(?s)^.{0,400}\*\*Removed\.\*\*') {
        foreach ($route in (Get-DocumentedRoute -Text $docText)) {
            $script:DocumentedRoutes++
            $literals = @(Get-RouteLiteral -Route $route)
            if ($literals.Count -eq 0) { continue }
            $last = $literals[-1]
            if ($script:RouteCarrierSource -match ('\b' + [regex]::Escape($last) + '\b')) { continue }
            $badRoutes.Add($route)
            $routePath = ($route -split '\s+', 2)[1]
            if (($pageAdded -and $pageAdded.Contains($routePath)) -or (Test-NameInText -Name $last -Text $script:RemovedCorpus)) { [void]$causedItem.Add("route|$route") }
        }
    }

    $phantoms = [System.Collections.Generic.List[string]]::new()
    if (-not $isRecord -and -not $SkipSymbolCheck -and $docText -notmatch '(?s)^.{0,400}\*\*Removed\.\*\*') {
        foreach ($symbol in (Get-NamedSymbol -Text $docText)) {
            if ($KnownExternalType -contains $symbol) { continue }
            $script:DocumentedSymbols++
            if ($script:SourceCorpus -match ('\b' + [regex]::Escape($symbol) + '\b')) { continue }
            $phantoms.Add($symbol)
            if ((Test-NameInText -Name $symbol -Text $pageAdded) -or (Test-NameInText -Name $symbol -Text $script:RemovedCorpus)) { [void]$causedItem.Add("phantom|$symbol") }
        }
    }

    $documentsAProject = $false
    foreach ($folder in $ServiceCheckFolder) {
        if ($docPath -like "*$folder*") { $documentsAProject = $true; break }
    }

    $undocumented = [System.Collections.Generic.List[string]]::new()
    $projects = @()
    $pageDeclaredMethods = 0
    $pageNamedMethods = 0
    if (-not $isRecord -and -not $SkipServiceCheck -and $documentsAProject) {
        $citedPerProject = Get-CitedProjectVote -CitedFile @($filesByDoc[$docPath]) -SourceRoot $script:SourceRel

        $documented = Resolve-DocumentedProject -DocPath $docPath -ProjectName @($script:RepositoryProject) `
            -Vote $citedPerProject -MinimumVotes $MinimumCitationsForProject -RepoRoot $RepoRoot
        if ($documented) { $projects = @($documented) }
        foreach ($project in $projects) { [void]$script:AttributedProject.Add($project) }

        foreach ($project in $projects) {
            if (-not $filesByProject.ContainsKey($project)) { continue }
            foreach ($sourceFile in $filesByProject[$project]) {
                $sourceFull = Join-Path $RepoRoot $sourceFile
                if (-not (Test-Path -LiteralPath $sourceFull)) { continue }
                $source = Get-Content -LiteralPath $sourceFull -Raw -Encoding utf8
                if (-not $source) { continue }
                foreach ($method in (Get-PublicMethodName -Source $source)) {
                    $pageDeclaredMethods++
                    if ($docText -match ('\b' + [regex]::Escape($method) + '\b')) { $pageNamedMethods++ }
                }
                $addedSource = (Get-ChangeText -Path $sourceFile).Added
                $addedType = if ($addedSource) { @(Get-PublicTypeName -Source $addedSource) } else { @() }
                foreach ($type in (Get-PublicTypeName -Source $source)) {
                    if (-not (Test-ServiceShaped -TypeName $type -SourceFile $sourceFile)) { continue }
                    $script:DeclaredServices++
                    if ($docText -match ('\b' + [regex]::Escape($type) + '\b')) { $script:NamedServices++ }
                    else {
                        $undocumented.Add("$type ($project)")
                        if ($addedType -contains $type) { [void]$causedItem.Add("service|$type ($project)") }
                    }
                }
            }
        }
    }

    $thin = $null
    if ($documentsAProject -and -not $SkipServiceCheck -and $pageDeclaredMethods -ge 8) {
        $share = [math]::Round(($pageNamedMethods / $pageDeclaredMethods) * 100, 0)
        if ($share -lt $ThinPageMethodPercent) {
            $thin = [string]::Format($script:Invariant, 'names {0:N0} of {1:N0} public methods in {2} ({3:N0}%)', $pageNamedMethods, $pageDeclaredMethods, ($projects -join ', '), $share)
        }
    }

    foreach ($side in @($true, $false)) {
        $pick = {
            param($items, $tag)
            @($items | Where-Object { $causedItem.Contains("$tag|$_") -eq $side } | Sort-Object -Unique)
        }
        $part = [pscustomobject]@{
            Doc          = $docPath
            IsRecord     = $isRecord
            Missing      = & $pick $missing 'missing'
            Stale        = & $pick $stale 'stale'
            Undocumented = & $pick $undocumented 'service'
            BadRoutes    = & $pick $badRoutes 'route'
            Phantoms     = & $pick $phantoms 'phantom'
            Thin         = if ($side) { $thin } else { $null }
        }
        if ($part.Missing.Count -gt 0 -or $part.Stale.Count -gt 0 -or $part.Undocumented.Count -gt 0 -or $part.BadRoutes.Count -gt 0 -or $part.Phantoms.Count -gt 0 -or $part.Thin) {
            if ($side) { $findings.Add($part) } else { $olderFindings.Add($part) }
        }
    }
}

$script:UnattributedProject = [System.Collections.Generic.List[string]]::new()
$familyPrefix = @((Get-ProjectFamily -RepoRoot $RepoRoot) | ForEach-Object Prefix | Select-Object -Unique)
if (-not $SkipServiceCheck -and -not $Doc) {
    foreach ($project in ($filesByProject.Keys | Sort-Object)) {
        $inFamily = $false
        foreach ($prefix in $familyPrefix) { if ($project.StartsWith($prefix)) { $inFamily = $true; break } }
        if (-not $inFamily) { continue }
        if ($script:AttributedProject.Contains($project)) { continue }
        $script:UnattributedProject.Add($project)
    }
}

Write-Invariant -Template 'Pages checked: {0:N0} ({1:N0} of them point-in-time records, checked for broken references only; {2:N0} cite no source file and are read for routes and named symbols only)' -Values @($checkedDocs, $checkedRecords, $uncitedDocs)
Write-Host ''

if ($findings.Count -eq 0 -and $olderFindings.Count -eq 0) {
    Write-Host 'No drift found: every cited member is named, and every cited file still exists.' -ForegroundColor Green
    Show-Coverage
    exit 0
}

function Show-Finding {
    param([Parameter(Mandatory)][object]$finding)

    Write-Invariant -Template '{0}' -Values @($finding.Doc) -ForegroundColor Yellow
    foreach ($item in $finding.Missing) {
        Write-Invariant -Template '   [missing] declared in code, absent from the page: {0}' -Values @($item)
    }
    foreach ($item in $finding.Stale) {
        Write-Invariant -Template '   [stale]   named on the page, no longer in the repo: {0}' -Values @($item)
    }
    foreach ($item in $finding.Undocumented) {
        Write-Invariant -Template '   [service] in this project, documented nowhere on the page: {0}' -Values @($item)
    }
    foreach ($item in $finding.BadRoutes) {
        Write-Invariant -Template '   [route]   documented, but nothing that carries a route names that path: {0}' -Values @($item)
    }
    foreach ($item in $finding.Phantoms) {
        Write-Invariant -Template '   [phantom] named on the page, but no such symbol exists anywhere: {0}' -Values @($item)
    }
    if ($finding.Thin) {
        Write-Invariant -Template '   [thin]    passes every check and still says little: {0}. Open the source, or run the generator.' -Values @($finding.Thin)
    }
}

foreach ($finding in ($findings | Sort-Object { -($_.Missing.Count + $_.Stale.Count) })) { Show-Finding -finding $finding }

$thinOnly = @($findings | Where-Object { $_.Thin -and $_.Missing.Count -eq 0 -and $_.Stale.Count -eq 0 -and $_.Undocumented.Count -eq 0 -and $_.BadRoutes.Count -eq 0 -and $_.Phantoms.Count -eq 0 }).Count
$totalMissing = ($findings | ForEach-Object { $_.Missing.Count } | Measure-Object -Sum).Sum
$totalStale = ($findings | ForEach-Object { $_.Stale.Count } | Measure-Object -Sum).Sum

Write-Host ''
if ($findings.Count -gt 0) {
    Write-Invariant -Template '{0:N0} page(s) have drifted: {1:N0} missing member(s), {2:N0} stale file reference(s). {3:N0} more are thin but not wrong.' -Values @(($findings.Count - $thinOnly), $totalMissing, $totalStale, $thinOnly) -ForegroundColor Yellow
}
else {
    Write-Host 'The change caused no drift.' -ForegroundColor Green
}
if ($olderFindings.Count -gt 0) {
    Write-Host ''
    Write-Invariant -Template 'Older drift, not blocking: {0:N0} page(s) hold drift that the change did not cause. It is listed so it can be fixed, and it never fails the run.' -Values @($olderFindings.Count) -ForegroundColor Yellow
    foreach ($finding in ($olderFindings | Sort-Object { -($_.Missing.Count + $_.Stale.Count) })) { Show-Finding -finding $finding }
}

Show-Coverage
if ($FailOnDrift -and ($findings.Count - $thinOnly) -gt 0) {
    Write-Host "FIX: Bring the page up to the code it names: drop a file or symbol that is gone, and add the constant or service the page leaves out. /write-docs does this for a page."
    exit 1
}
exit 0
