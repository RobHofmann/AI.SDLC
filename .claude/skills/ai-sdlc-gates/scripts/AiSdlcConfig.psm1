#Requires -Version 7
<#
.SYNOPSIS
    Reads aisdlc.json, the file that tells the shared AI-SDLC where a repository keeps its things.

.DESCRIPTION
    The shared skills, hooks and gates work in any repository that installs them. They never name a
    repository's folders themselves. They ask this module instead, and this module reads the answer
    from aisdlc.json at the repository root.

    The packs a repository uses are not in aisdlc.json. They come from apm.yml at the repository root,
    because that file decides what APM installs: each dependency whose path ends in packs/<name> is a
    pack. A "packs" key that an older aisdlc.json still holds is ignored.

    The repository root is the nearest folder, from the start path upwards, that holds aisdlc.json.
    With no aisdlc.json anywhere above the start path, the git top level is the root and every value
    comes from the defaults below, so a repository without the file still gets a working answer.

.PARAMETER StartPath
    Where the search for aisdlc.json starts. Defaults to the current location.

.PARAMETER RepoRoot
    The repository root, when the caller already knows it. The search is then skipped.

.PARAMETER Name
    The name of a value under "paths" in aisdlc.json, for example docsRoots or solution.

.PARAMETER Pack
    The name of a pack, for example dotnet or bicep.

.EXAMPLE
    Import-Module ./AiSdlcConfig.psm1
    $config = Get-AiSdlcConfig
    $config.paths.docsRoots

.EXAMPLE
    Get-AiSdlcPath -Name solution -RepoRoot C:/src/repo

.EXAMPLE
    if (Test-AiSdlcPack -Name dotnet) { dotnet build (Get-AiSdlcPath -Name solution) }

.EXAMPLE
    'Fixes #42' -match (Get-AiSdlcStoryPattern)
    The story key pattern comes from tracker.keyPattern. Without one, a GitHub issue key matches:
    #42, or owner/repo#42 for an issue in another repository.

.EXAMPLE
    Get-AiSdlcBranchStoryKey -Branch feature/42-short-name
    Returns #42. A branch whose last segment does not start with digits returns nothing.

.EXAMPLE
    Get-AiSdlcStoryKey -Text 'Fixes contoso/portal#0042'
    Returns contoso/portal#42, the first story key in the text.

.EXAMPLE
    Get-AiSdlcPackage | Where-Object Setup
    Lists the gates.json of every package that runs, with its gates and its setup, preflight and
    postEdit hooks. -All also lists the packages apm.yml does not name.

.PARAMETER Branch
    For Get-AiSdlcBranchStoryKey: the branch name, with or without refs/heads/.

.PARAMETER Text
    For Get-AiSdlcStoryKey: the text to search for a story key.

.PARAMETER Pattern
    For Get-AiSdlcStoryKey: the pattern to use instead of the one from aisdlc.json.

.PARAMETER SkillsRoot
    For Get-AiSdlcPackage: where the packages are installed. Defaults to <RepoRoot>/.claude/skills.
#>

$script:ConfigFileName = 'aisdlc.json'
$script:ApmFileName = 'apm.yml'
$script:DefaultStoryPattern = '(?<![\w&/#])(?:[\w.-]+/[\w.-]+)?#\d+\b'

$script:Defaults = [ordered]@{
    repository     = ''
    visibility     = 'private'
    packs          = @()
    paths          = [ordered]@{
        toolsFolder      = 'tools'
        docsRoots        = @('docs')
        technicalDocs    = 'docs'
        functionalDocs   = ''
        adrFolder        = 'docs/adrs'
        historyPaths     = @()
        constitution     = 'docs/constitution.md'
        agentsFile       = 'AGENTS.md'
        solution         = ''
        sourceRoot       = ''
        testRoot         = ''
        runSettings      = ''
        coverageBaseline = ''
        pipelinesFolder  = ''
        codeAnalysisPipeline  = ''
        packagesProps         = ''
        specsRoot             = 'specs'
        languagePage          = ''
        personNameAllowlist   = 'docs/.person-name-allowlist'
        readingLevelAllowlist = 'docs/.reading-level-allowlist'
        readingLevelRoots     = @('docs')
        sectionRefRoots       = @('docs')
        codeAreasPage         = ''
        sourceExtensions      = @()
        sourceDocMap          = @()
        preflightReceipts     = 'temp/preflight'
        bicepRoot             = 'building-blocks'
        platformKnowledge     = 'docs/platform-knowledge'
        knowledgeRoot         = '../Knowledge'
        privateTermsFile      = ''
        discoveryRoot         = 'docs-functional/discovery'
    }
    commands       = [ordered]@{
        build = ''
        test  = ''
    }
    tracker        = [ordered]@{
        repository        = ''
        keyPattern        = ''
        refinedLabel      = 'refined'
        toRefineLabel     = 'to-refine'
        sizeLabelPrefix   = 'size:'
        labels            = @()
        dataModelPatterns = @()
        acceptedRepositories = @()
    }
    github         = [ordered]@{
        repository = ''
        trunk      = 'main'
    }
    sonarcloud     = [ordered]@{
        organization = ''
        projectKey   = ''
    }
    knowledge      = [ordered]@{
        repository = ''
    }
    dotnet         = [ordered]@{
        graphifyBenchmarkCases = ''
        externalContractPaths  = @()
        wireNameAllowlist      = @()
        portalAppComponent     = ''
        routePageFolders       = @('docs/api/')
    }
    docs           = [ordered]@{
        units       = @()
        unitExclude = @()
    }
    repoGates      = @()
}

function Find-AiSdlcRepoRoot {
    [CmdletBinding()]
    param([string]$StartPath = (Get-Location).Path)

    $dir = (Resolve-Path -LiteralPath $StartPath).Path
    if (Test-Path -LiteralPath $dir -PathType Leaf) { $dir = Split-Path $dir -Parent }

    while ($dir) {
        if (Test-Path -LiteralPath (Join-Path $dir $script:ConfigFileName) -PathType Leaf) { return $dir }
        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }

    $top = git -C (Resolve-Path -LiteralPath $StartPath).Path rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $top) { return (Resolve-Path -LiteralPath $top).Path }
    return $null
}

function Merge-AiSdlcDefaults {
    param([System.Collections.IDictionary]$Defaults, [System.Collections.IDictionary]$Values)

    $merged = [ordered]@{}
    foreach ($key in $Defaults.Keys) {
        $default = $Defaults[$key]
        if ($Values -and $Values.Contains($key) -and $null -ne $Values[$key]) {
            if ($default -is [System.Collections.IDictionary] -and $Values[$key] -is [System.Collections.IDictionary]) {
                $merged[$key] = Merge-AiSdlcDefaults -Defaults $default -Values $Values[$key]
            }
            else {
                $merged[$key] = $Values[$key]
            }
        }
        else {
            $merged[$key] = $default
        }
    }
    if ($Values) {
        foreach ($key in $Values.Keys) {
            if (-not $merged.Contains($key)) { $merged[$key] = $Values[$key] }
        }
    }
    return $merged
}

function Get-AiSdlcApmPack {
    param([string]$RepoRoot)

    $file = Join-Path $RepoRoot $script:ApmFileName
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return @() }

    # A dependency names a pack as "path: packs/<name>" or as a local path or shorthand that ends in
    # packs/<name>, with an optional #ref. A comment after the value is not part of it.
    $names = foreach ($line in Get-Content -LiteralPath $file) {
        $value = ($line -replace '\s+#.*$', '').Trim().Trim('''', '"')
        $match = [regex]::Match($value, '(?:^|[\s/:''"])packs/(?<name>[A-Za-z0-9._-]+)(?:#\S*)?[''"]?$')
        if ($match.Success) { $match.Groups['name'].Value }
    }
    return @($names | Select-Object -Unique)
}

function Get-AiSdlcConfig {
    [CmdletBinding()]
    param(
        [string]$RepoRoot,
        [string]$StartPath = (Get-Location).Path
    )

    if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $StartPath }
    if (-not $RepoRoot) { throw "No repository found from '$StartPath': no $($script:ConfigFileName) above it and no git repository." }

    $file = Join-Path $RepoRoot $script:ConfigFileName
    $values = $null
    if (Test-Path -LiteralPath $file -PathType Leaf) {
        try {
            $values = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
        }
        catch {
            throw "$file is not valid JSON: $($_.Exception.Message)"
        }
    }

    $config = Merge-AiSdlcDefaults -Defaults $script:Defaults -Values $values
    $config['packs'] = Get-AiSdlcApmPack -RepoRoot $RepoRoot
    $config['repoRoot'] = (Resolve-Path -LiteralPath $RepoRoot).Path
    $config['configFile'] = if ($values) { $file } else { $null }
    return [pscustomobject]$config
}

function Get-AiSdlcPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$RepoRoot,
        [switch]$Relative
    )

    $config = Get-AiSdlcConfig -RepoRoot $RepoRoot
    if (-not $config.paths.Contains($Name)) { throw "aisdlc.json has no path named '$Name'. Known names: $($config.paths.Keys -join ', ')." }

    $values = @($config.paths[$Name] | Where-Object { $_ })
    if ($Relative) { return $values }
    return $values | ForEach-Object { Join-Path $config.repoRoot $_ }
}

function Test-AiSdlcPack {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$RepoRoot
    )

    if ($Name -eq 'core') { return $true }
    $config = Get-AiSdlcConfig -RepoRoot $RepoRoot
    return @($config.packs) -contains $Name
}

function Get-AiSdlcStoryPattern {
    [CmdletBinding()]
    param([string]$RepoRoot)

    $config = Get-AiSdlcConfig -RepoRoot $RepoRoot
    if ($config.tracker.keyPattern) { return [string]$config.tracker.keyPattern }
    return $script:DefaultStoryPattern
}

function Get-AiSdlcBranchStoryKey {
    [CmdletBinding()]
    param([AllowEmptyString()][AllowNull()][string]$Branch)

    if (-not $Branch) { return $null }
    $leaf = (($Branch -replace '^refs/heads/', '') -split '/')[-1]
    $match = [regex]::Match($leaf, '^(?<n>\d+)(?:-|$)')
    if (-not $match.Success) { return $null }
    return '#' + [int64]$match.Groups['n'].Value
}

function Get-AiSdlcStoryKey {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][AllowNull()][string]$Text,
        [string]$RepoRoot,
        [string]$Pattern
    )

    if (-not $Text) { return $null }
    if (-not $Pattern) {
        $Pattern = if ($RepoRoot) { Get-AiSdlcStoryPattern -RepoRoot $RepoRoot } else { $script:DefaultStoryPattern }
    }
    $match = [regex]::Match($Text, $Pattern)
    if (-not $match.Success) { return $null }
    $value = $match.Value
    $hash = [regex]::Match($value, '^(?<repo>[\w.-]+/[\w.-]+)?#(?<n>\d+)$')
    if ($hash.Success) {
        $prefix = if ($hash.Groups['repo'].Success) { $hash.Groups['repo'].Value } else { '' }
        return $prefix + '#' + [int64]$hash.Groups['n'].Value
    }
    return $value
}

function ConvertTo-AiSdlcStoryKey {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][AllowNull()][string]$Value,
        [string]$RepoRoot,
        [string]$Pattern
    )

    $raw = if ($Value) { $Value.Trim() } else { '' }
    if (-not $raw -or $raw.StartsWith('#')) { return [pscustomobject]@{ Status = 'empty'; Key = $null; Value = $raw } }
    $text = $raw.Trim('"', "'").Trim()
    if (-not $text) { return [pscustomobject]@{ Status = 'empty'; Key = $null; Value = $raw } }
    if ($text -match '^\d+$') { $text = '#' + [int64]$text }
    if (-not $Pattern) {
        $Pattern = if ($RepoRoot) { Get-AiSdlcStoryPattern -RepoRoot $RepoRoot } else { $script:DefaultStoryPattern }
    }
    if ($text -cnotmatch ('^(?:' + $Pattern + ')$')) { return [pscustomobject]@{ Status = 'invalid'; Key = $null; Value = $text } }
    $hash = [regex]::Match($text, '^(?<repo>[\w.-]+/[\w.-]+)?#(?<n>\d+)$')
    if ($hash.Success) {
        $prefix = if ($hash.Groups['repo'].Success) { $hash.Groups['repo'].Value } else { '' }
        $text = $prefix + '#' + [int64]$hash.Groups['n'].Value
    }
    return [pscustomobject]@{ Status = 'ok'; Key = $text; Value = $text }
}

function Get-AiSdlcPackage {
    [CmdletBinding()]
    param(
        [string]$RepoRoot,
        [string]$SkillsRoot,
        [switch]$All
    )

    $config = Get-AiSdlcConfig -RepoRoot $RepoRoot
    if (-not $SkillsRoot) { $SkillsRoot = Join-Path $config.repoRoot '.claude' 'skills' }

    $manifests = @(Get-ChildItem -LiteralPath $SkillsRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'gates.json' } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Sort-Object)

    foreach ($manifest in $manifests) {
        $data = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json -AsHashtable
        $runs = ($data.package -eq 'core') -or (@($config.packs) -contains $data.package)
        if (-not $runs -and -not $All) { continue }
        $folder = Split-Path $manifest -Parent
        $postEdit = $null
        if ($data.postEdit) {
            $postEdit = [pscustomobject]@{
                Extensions = @($data.postEdit.extensions | ForEach-Object { ([string]$_).ToLowerInvariant() })
                Script     = Join-Path $folder $data.postEdit.script
            }
        }
        [pscustomobject]@{
            Package     = $data.package
            Skill       = Split-Path $folder -Leaf
            SkillFolder = $folder
            Manifest    = $manifest
            Runs        = $runs
            Gates       = @($data.gates | Where-Object { $_ })
            Setup       = if ($data.setup) { Join-Path $folder $data.setup } else { $null }
            Preflight   = if ($data.preflight) { Join-Path $folder $data.preflight } else { $null }
            PostEdit    = $postEdit
            DocUnits    = @($data.docUnits | Where-Object { $_ })
            DocFacts    = if ($data.docFacts) { Join-Path $folder $data.docFacts } else { $null }
            Allow       = @($data.allow | Where-Object { $_ })
        }
    }
}

Export-ModuleMember -Function Find-AiSdlcRepoRoot, Get-AiSdlcConfig, Get-AiSdlcPath, Test-AiSdlcPack, Get-AiSdlcStoryPattern, Get-AiSdlcBranchStoryKey, Get-AiSdlcStoryKey, ConvertTo-AiSdlcStoryKey, Get-AiSdlcPackage
