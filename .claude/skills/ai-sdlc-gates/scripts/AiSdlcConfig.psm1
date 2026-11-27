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
    Get-AiSdlcKnowledgeRoot -RepoRoot C:/src/repo/.claude/worktrees/fix
    Returns the full path of paths.knowledgeRoot. In a linked git worktree it falls back to the folder
    next to the main checkout, so ../Knowledge is found from .claude/worktrees/<name> too.

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
    secretScan     = [ordered]@{
        allowPaths = @()
    }
    git            = [ordered]@{
        allowTrunkPush = $false
    }
    tracker        = [ordered]@{
        repository        = ''
        keyPattern        = ''
        refinedLabel      = 'refined'
        toRefineLabel     = 'to-refine'
        sizeLabelPrefix   = 'size:'
        inReviewLabel     = 'in-review'
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
        units                 = @()
        unitExclude           = @()
        lastCheckedMaxAgeDays = 0
    }
    repoGates      = @()
}

function Find-AiSdlcRepoRoot {
    [CmdletBinding()]
    param([string]$StartPath = (Get-Location).Path)

    # ProviderPath: .Path keeps the FileSystem:: prefix on a UNC path, and git cannot read that (#29).
    $dir = (Resolve-Path -LiteralPath $StartPath).ProviderPath
    if (Test-Path -LiteralPath $dir -PathType Leaf) { $dir = Split-Path $dir -Parent }

    while ($dir) {
        if (Test-Path -LiteralPath (Join-Path $dir $script:ConfigFileName) -PathType Leaf) { return $dir }
        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }

    $top = git -C (Resolve-Path -LiteralPath $StartPath).ProviderPath rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $top) { return (Resolve-Path -LiteralPath $top).ProviderPath }
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

function Resolve-AiSdlcSourceRoot {
    <#
    .SYNOPSIS
        The full path of a source folder from aisdlc.json, kept inside the repository.

    .DESCRIPTION
        A pull request can change aisdlc.json, so a gate that reads a source folder must not leave the
        repository. This resolves the folder against the repository root and throws when it lies outside
        it, or when an existing folder on the way is a link (a reparse point). It returns an empty string
        when no folder is set, and the full path without a trailing separator otherwise.

    .PARAMETER RepoRoot
        The repository root.

    .PARAMETER Path
        The folder as aisdlc.json writes it, relative to the root or absolute.

    .EXAMPLE
        Resolve-AiSdlcSourceRoot -RepoRoot C:/src/repo -Path src
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [AllowEmptyString()][string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $separators = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $root = [IO.Path]::GetFullPath($RepoRoot).TrimEnd($separators)
    $full = [IO.Path]::GetFullPath($Path, $root).TrimEnd($separators)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $inside = $full.Equals($root, $comparison) -or $full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, $comparison)
    if (-not $inside) { throw "the folder '$Path' is outside the repository" }
    $walk = $full
    while ($walk.Length -gt $root.Length) {
        $item = Get-Item -LiteralPath $walk -Force -ErrorAction SilentlyContinue
        if ($item -and $item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) { throw "the folder '$Path' is a link, so it may point outside the repository" }
        $walk = [IO.Path]::GetDirectoryName($walk)
    }
    return $full
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
    $config['repoRoot'] = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
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

function Get-AiSdlcKnowledgeRoot {
    # Returns the full path of paths.knowledgeRoot, or $null when it is empty. An absolute value is used
    # as it is. A relative value is resolved against the repository root first. In a linked git worktree,
    # such as .claude/worktrees/<name>, the default ../Knowledge points inside the main clone, where no
    # knowledge clone is (#31). So when the folder is not there and the repository is a linked worktree,
    # the value is resolved against the main checkout as well, and that folder is used when it exists.
    # When neither folder exists, the path next to the repository root comes back, so a message can name it.
    [CmdletBinding()]
    param([string]$RepoRoot)

    $config = Get-AiSdlcConfig -RepoRoot $RepoRoot
    $root = [string]$config.paths.knowledgeRoot
    if (-not $root) { return $null }
    if ([IO.Path]::IsPathRooted($root)) { return $root }

    $local = [IO.Path]::GetFullPath((Join-Path $config.repoRoot $root))
    if (Test-Path -LiteralPath $local -PathType Container) { return $local }

    $mainRoot = Get-AiSdlcMainCheckoutRoot -RepoRoot $config.repoRoot
    if (-not $mainRoot) { return $local }
    $main = [IO.Path]::GetFullPath((Join-Path $mainRoot $root))
    if (Test-Path -LiteralPath $main -PathType Container) { return $main }
    return $local
}

function Get-AiSdlcMainCheckoutRoot {
    # Returns the folder in the main checkout that matches RepoRoot in a linked git worktree, or $null
    # when RepoRoot is not in a linked worktree. Get-AiSdlcKnowledgeRoot resolves against it (#31), and
    # Sync-AllowRules.ps1 accepts a knowledge folder next to it (#32).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $git = @(git -C $RepoRoot rev-parse --path-format=absolute --git-dir --git-common-dir --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or $git.Count -ne 3) { return $null }
    $gitDir = [IO.Path]::GetFullPath($git[0])
    $commonDir = [IO.Path]::GetFullPath($git[1])
    $top = [IO.Path]::GetFullPath($git[2])
    # Only a linked worktree has a git dir apart from the common dir. A bare repository or a submodule
    # keeps its common dir in no folder named .git, so it has no main checkout to fall back to.
    if ($gitDir -eq $commonDir -or (Split-Path $commonDir -Leaf) -ne '.git') { return $null }

    $mainTop = Split-Path $commonDir -Parent
    $offset = [IO.Path]::GetRelativePath($top, $RepoRoot)
    return [IO.Path]::GetFullPath((Join-Path $mainTop $offset))
}

function Test-AiSdlcPathExcluded {
    <#
    .SYNOPSIS
        True when a file sits below a folder whose name is on an exclusion list.

    .DESCRIPTION
        Only the folders between the repository root and the file count, so a folder above the
        repository never excludes a file. A git worktree under .claude/worktrees/ therefore keeps its
        files (#88). The match ignores case. A file whose own name equals an excluded name is not
        excluded.

    .PARAMETER RepoRoot
        The repository root.

    .PARAMETER FullName
        The full path of the file.

    .PARAMETER Folder
        The folder names to leave out, such as node_modules. An empty list excludes nothing.

    .EXAMPLE
        Test-AiSdlcPathExcluded -RepoRoot $root -FullName $file -Folder '.claude', '.git'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$FullName,
        [string[]]$Folder
    )

    $names = @($Folder | Where-Object { $_ })
    if ($names.Count -eq 0) { return $false }
    $segments = @([IO.Path]::GetRelativePath($RepoRoot, $FullName).Replace('\', '/') -split '/')
    if ($segments.Count -lt 2) { return $false }
    foreach ($parent in $segments[0..($segments.Count - 2)]) {
        foreach ($name in $names) { if ($parent -ieq $name) { return $true } }
    }
    return $false
}

function Get-AiSdlcMainBranch {
    # Returns the remote-tracking ref of the main branch, such as origin/main, for the scripts that
    # compare a change with it. github.trunk in aisdlc.json names the branch, main by default; it is the
    # one setting for the trunk (C12). When origin/<trunk> does not exist in the clone, the first of
    # origin/main, origin/master and origin/HEAD that does exist wins, so a repository whose trunk is
    # master still gets a base. With none of them, it returns origin/<trunk>, and the caller reports that
    # git has no merge base with it.
    [CmdletBinding()]
    param([string]$RepoRoot)

    $config = Get-AiSdlcConfig -RepoRoot $RepoRoot
    $trunk = [string]$config.github['trunk']
    if ([string]::IsNullOrWhiteSpace($trunk)) { $trunk = 'main' }
    $trunk = $trunk.Trim() -replace '^origin/', ''
    $candidates = @("origin/$trunk") + @('origin/main', 'origin/master', 'origin/HEAD' | Where-Object { $_ -ne "origin/$trunk" })
    foreach ($candidate in $candidates) {
        $null = git -C $config.repoRoot rev-parse --verify --quiet $candidate 2>$null
        if ($LASTEXITCODE -eq 0) { return $candidate }
    }
    $global:LASTEXITCODE = 0
    return "origin/$trunk"
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

function Test-AiSdlcTrunkPushAllowed {
    # True only when aisdlc.json sets git.allowTrunkPush to the JSON value true. A string such as "true"
    # does not count, so a typo never opens the trunk. The push hooks still refuse a delete or a force push.
    # With -Ref, the file is read from that commit, not from the working tree. The push hooks pass the
    # remote-tracking ref of the branch they guard, such as refs/remotes/origin/main, so a change in the
    # working tree cannot switch the setting on: it counts only once it is on the remote main branch.
    # A missing ref, a missing file or a file that is not valid JSON counts as false.
    [CmdletBinding()]
    param([string]$RepoRoot, [string]$Ref)

    if ($Ref) {
        if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot }
        $text = git -C $RepoRoot show "$($Ref):$($script:ConfigFileName)" 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $text) { return $false }
        try { $values = ($text -join "`n") | ConvertFrom-Json -AsHashtable } catch { return $false }
        $section = if ($values -is [System.Collections.IDictionary]) { $values['git'] } else { $null }
        $value = if ($section -is [System.Collections.IDictionary]) { $section['allowTrunkPush'] } else { $null }
        return ($value -is [bool]) -and $value
    }

    $config = Get-AiSdlcConfig -RepoRoot $RepoRoot
    $value = $config.git['allowTrunkPush']
    return ($value -is [bool]) -and $value
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

# The gates that always run Blocking. Two guard a break that cannot be taken back once it is pushed: a
# secret (C03), or a private term in a public repository (ADR 0011). The third, the sync manifest
# check, guards the installed gates.json files themselves, so turning it off would let a package entry
# turn off the other two. Neither gateModes nor a package or repoGates entry can make them weaker.
$script:ProtectedGateScripts = @('Test-GitleaksBaseline.ps1', 'Check-PrivateTerms.ps1', 'Check-SyncManifest.ps1')

function Get-AiSdlcGateMode {
    <#
    .SYNOPSIS
        The mode of a gate entry: Blocking, Advisory or Off, or nothing when the entry holds another value.
    .DESCRIPTION
        A missing mode, a null mode and an empty text mean Blocking. A text that equals Blocking,
        Advisory or Off, in any case, gives that name in its canonical case. Any other value gives
        nothing, so the caller can refuse the entry.
    .PARAMETER Entry
        A gate entry from a gates.json or from repoGates, as a hashtable or an object.
    .EXAMPLE
        Get-AiSdlcGateMode -Entry @{ mode = 'off' }
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Entry)

    $hasMode = if ($Entry -is [System.Collections.IDictionary]) { $Entry.Contains('mode') } else { [bool]$Entry.PSObject.Properties['mode'] }
    if (-not $hasMode) { return 'Blocking' }
    $value = $Entry.mode
    if ($null -eq $value -or ($value -is [string] -and $value -eq '')) { return 'Blocking' }
    if ($value -isnot [string]) { return $null }
    $canonical = @('Blocking', 'Advisory', 'Off') | Where-Object { $_ -eq $value }
    if ($canonical) { return $canonical }
    return $null
}

function Format-AiSdlcGateModeValue {
    param($Value)

    if ($Value -is [string]) { return $Value }
    return (ConvertTo-Json -InputObject $Value -Compress -Depth 4)
}

function Get-AiSdlcGateModeSetting {
    <#
    .SYNOPSIS
        Reads and checks the gateModes object of aisdlc.json, once, against the gates that run.
    .DESCRIPTION
        A repository can set the mode of a shared gate in gateModes in its own aisdlc.json: an object
        whose keys are gate names and whose values are Blocking, Advisory or Off, in any case. A gate
        name matches without regard to case.

        Override holds one item for each shared gate of a package that runs which gateModes names, with
        Key, Value, Mode (or nothing when the value is not allowed) and Problem. A value weaker than
        Blocking for the secret scan or the private-terms gate is a problem too, because those gates
        guard a break that cannot be taken back after a push.

        Problem holds one item for each thing in gateModes that cannot attach to a shared gate that runs:
        a gateModes that is not an object, a name that no gate has, the name of a repository gate (it
        sets its mode in repoGates), the name of a gate of a pack that apm.yml does not list, and two
        keys that differ only in case. A missing or null gateModes leaves both parts empty.
    .PARAMETER Config
        The result of Get-AiSdlcConfig.
    .PARAMETER Package
        The result of Get-AiSdlcPackage -All, so that a gate of a pack that does not run is known by name.
    .EXAMPLE
        Get-AiSdlcGateModeSetting -Config (Get-AiSdlcConfig) -Package @(Get-AiSdlcPackage -All)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Package
    )

    $override = [hashtable]::new([StringComparer]::OrdinalIgnoreCase)
    $problems = [System.Collections.Generic.List[object]]::new()
    $setting = [pscustomobject]@{ Override = $override; Problem = $problems }

    $property = $Config.PSObject.Properties['gateModes']
    $modes = $null
    if ($property) { $modes = $property.Value }
    if ($null -eq $modes) { return $setting }
    if ($modes -isnot [System.Collections.IDictionary]) {
        $json = ConvertTo-Json -InputObject $modes -Compress -Depth 4
        $problems.Add([pscustomobject]@{ Key = $null; Value = $modes; Text = ("gateModes is '{0}', and it must be an object of gate names and modes" -f $json) })
        return $setting
    }

    $running = [hashtable]::new([StringComparer]::OrdinalIgnoreCase)
    $runningScript = [hashtable]::new([StringComparer]::OrdinalIgnoreCase)
    $unlisted = [hashtable]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in @($Package | Where-Object { $_ })) {
        foreach ($entry in @($item.Gates | Where-Object { $_ -and $_.name -is [string] })) {
            if ($item.Runs) {
                $running[$entry.name] = $item.Package
                $runningScript[$entry.name] = if ($entry.script -is [string]) { Split-Path -Leaf $entry.script } else { '' }
            }
            else { $unlisted[$entry.name] = $item.Package }
        }
    }
    $repository = [hashtable]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($Config.repoGates | Where-Object { $_ -and $_.name -is [string] })) { $repository[$entry.name] = $true }

    $groups = @($modes.Keys | Group-Object { ([string]$_).ToLowerInvariant() })
    foreach ($group in $groups) {
        $keys = @($group.Group | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)
        $first = $keys[0]
        $values = @($keys | ForEach-Object { Format-AiSdlcGateModeValue -Value $modes[$_] })
        $valueText = ($values | ForEach-Object { "'$_'" }) -join ' and '
        $keyText = ($keys | ForEach-Object { "'$_'" }) -join ' and '
        $twice = $keys.Count -gt 1

        if ($running.ContainsKey($first)) {
            $found = [pscustomobject]@{ Key = $first; Value = $modes[$first]; Mode = $null; Problem = $null }
            if ($twice) {
                $found.Problem = ("gateModes sets this gate twice, as {0}, to {1}" -f $keyText, $valueText)
            }
            else {
                $value = $modes[$first]
                if ($value -is [string] -and $value -ne '') { $found.Mode = Get-AiSdlcGateMode -Entry @{ mode = $value } }
                if (-not $found.Mode) { $found.Problem = ("gateModes sets '{0}' to '{1}', and the allowed values are Blocking, Advisory and Off" -f $first, (Format-AiSdlcGateModeValue -Value $value)) }
                elseif ($found.Mode -ne 'Blocking' -and $runningScript[$first] -in $script:ProtectedGateScripts) {
                    $found.Problem = ("gateModes sets '{0}' to '{1}', but this gate guards a secret, a private term or the installed gate files, so it stays Blocking" -f $first, $found.Mode)
                    $found.Mode = $null
                }
            }
            $override[$first] = $found
            continue
        }

        $subject = if ($twice) { ("gateModes sets this name twice, as {0}, to {1}" -f $keyText, $valueText) } else { ("gateModes sets '{0}' to '{1}'" -f $first, $values[0]) }
        if ($repository.ContainsKey($first)) { $reason = 'the name is a repository gate, so set its mode in repoGates' }
        elseif ($unlisted.ContainsKey($first)) { $reason = ("the name is a gate of the pack {0}, which apm.yml does not list" -f $unlisted[$first]) }
        else { $reason = 'no shared gate that runs has this name' }
        $problems.Add([pscustomobject]@{ Key = $first; Value = $modes[$first]; Text = ("{0}, but {1}" -f $subject, $reason) })
    }
    return $setting
}

function Resolve-AiSdlcGateMode {
    <#
    .SYNOPSIS
        The mode in force for one gate entry, where it comes from, and what is wrong with it.
    .DESCRIPTION
        A shared gate has the mode of its gates.json entry, unless gateModes of aisdlc.json names it. A
        repository gate always has the mode of its own entry in repoGates. The result has Mode (Blocking,
        Advisory or Off), Source (package, or aisdlc.json) and Problem (a text, or nothing). Any problem
        makes the mode Blocking, so a gate with a problem never passes by being skipped.
    .PARAMETER Entry
        A gate entry from a gates.json or from repoGates, as a hashtable or an object.
    .PARAMETER Package
        The package of the entry, or repo for an entry of repoGates.
    .PARAMETER Setting
        The result of Get-AiSdlcGateModeSetting. Without it, no gateModes applies.
    .EXAMPLE
        Resolve-AiSdlcGateMode -Entry @{ name = 'docs'; mode = 'Blocking' } -Package core -Setting $setting
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$Package,
        $Setting
    )

    $problems = [System.Collections.Generic.List[string]]::new()
    $mode = Get-AiSdlcGateMode -Entry $Entry
    if (-not $mode) {
        $problems.Add(("the mode is '{0}', and the allowed values are Blocking, Advisory and Off" -f $Entry.mode))
        $mode = 'Blocking'
    }

    $source = if ($Package -eq 'repo') { 'aisdlc.json' } else { 'package' }
    $named = if ($Package -ne 'repo' -and $Setting) { $Setting.Override[[string]$Entry.name] } else { $null }
    if ($named) {
        $source = 'aisdlc.json'
        if ($named.Problem) { $problems.Add([string]$named.Problem) }
        elseif ($problems.Count -eq 0) { $mode = $named.Mode }
    }

    $leaf = if ($Entry.script -is [string]) { Split-Path -Leaf $Entry.script } else { '' }
    if ($leaf -in $script:ProtectedGateScripts -and $mode -ne 'Blocking' -and -not ($named -and $named.Problem)) {
        $problems.Add(("the mode is '{0}', but {1} guards a secret, a private term or the installed gate files, so it always runs Blocking" -f $mode, $leaf))
    }

    if ($problems.Count -gt 0) { $mode = 'Blocking' }
    return [pscustomobject]@{
        Mode    = $mode
        Source  = $source
        Problem = if ($problems.Count -gt 0) { $problems -join '; ' } else { $null }
    }
}

function Get-AiSdlcGateScriptMode {
    <#
    .SYNOPSIS
        The mode in force for the gates that a script backs: Off, Advisory or Blocking.
    .DESCRIPTION
        For every caller that starts a gate script outside the gate runner: the pre-flights, the
        post-edit hook and the push hooks. It looks at the gates.json of the packages that run, then at
        repoGates, and takes the mode of each entry from Resolve-AiSdlcGateMode, so gateModes counts. An
        entry matches when its script has the given file name, in any case.

        It returns Off when every matching entry is Off, Advisory when every matching entry is Advisory
        or Off and at least one is Advisory, and Blocking in every other case. It returns Blocking when
        anything cannot be read: a problem in gateModes, a mode that is not allowed, or a script that no
        entry names. It also returns Blocking while git shows an uncommitted change to a gates.json under
        .claude/skills or to aisdlc.json, because the pre-flight receipt covers the committed tree only.
        So an edit to Off counts only once it is committed. A failed git call counts as a change.
    .PARAMETER RepoRoot
        The repository root.
    .PARAMETER SkillsRoot
        Where the packages are installed. Defaults to <RepoRoot>/.claude/skills.
    .PARAMETER Script
        The file name of the gate script, such as Check-ChangeCompleteness.ps1.
    .PARAMETER Commit
        The commits a push sends. When given, the mode is weaker than Blocking only when each of these
        commits holds the same aisdlc.json and the same gates.json files under .claude/skills as the
        working tree. An all-zero commit, a delete, is skipped. A commit git cannot compare counts as
        different.
    .EXAMPLE
        Get-AiSdlcGateScriptMode -RepoRoot C:/src/repo -Script Check-Coverage.ps1
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$SkillsRoot,
        [Parameter(Mandatory)][string]$Script,
        [string[]]$Commit
    )

    try {
        $status = @(git -C $RepoRoot status --porcelain 2>$null)
        if ($LASTEXITCODE -ne 0) { return 'Blocking' }
        if (@($status | Where-Object { $_ -match '(?:^|[\s"/>])(?:\.claude/skills/.*gates\.json|aisdlc\.json)' }).Count -gt 0) { return 'Blocking' }
        foreach ($sha in @($Commit | Where-Object { $_ -and $_ -notmatch '^0+$' })) {
            git -C $RepoRoot diff --quiet $sha -- aisdlc.json ':(glob).claude/skills/**/gates.json' 2>$null
            if ($LASTEXITCODE -ne 0) { return 'Blocking' }
        }

        $config = Get-AiSdlcConfig -RepoRoot $RepoRoot
        $packages = @(Get-AiSdlcPackage -RepoRoot $RepoRoot -SkillsRoot $SkillsRoot -All)
        $setting = Get-AiSdlcGateModeSetting -Config $config -Package $packages
        if ($setting.Problem.Count -gt 0) { return 'Blocking' }

        $candidates = [System.Collections.Generic.List[object]]::new()
        foreach ($item in @($packages | Where-Object { $_.Runs })) {
            foreach ($entry in $item.Gates) { $candidates.Add([pscustomobject]@{ Entry = $entry; Package = $item.Package }) }
        }
        foreach ($entry in @($config.repoGates)) { $candidates.Add([pscustomobject]@{ Entry = $entry; Package = 'repo' }) }
        $matching = @($candidates | Where-Object { $_.Entry -and $_.Entry.script -is [string] -and (Split-Path -Leaf $_.Entry.script) -ieq $Script })
        if ($matching.Count -eq 0) { return 'Blocking' }
        $advisory = $false
        foreach ($candidate in $matching) {
            $resolved = Resolve-AiSdlcGateMode -Entry $candidate.Entry -Package $candidate.Package -Setting $setting
            if ($resolved.Problem) { return 'Blocking' }
            if ($resolved.Mode -ceq 'Advisory') { $advisory = $true }
            elseif ($resolved.Mode -cne 'Off') { return 'Blocking' }
        }
        if ($advisory) { return 'Advisory' }
        return 'Off'
    }
    catch {
        return 'Blocking'
    }
}

function Test-AiSdlcGateOff {
    <#
    .SYNOPSIS
        True when the gate that runs a script is Off.
    .DESCRIPTION
        True only when Get-AiSdlcGateScriptMode gives Off for the script. False when anything cannot be
        read, because a mode that cannot be read is not Off.
    .PARAMETER RepoRoot
        The repository root.
    .PARAMETER SkillsRoot
        Where the packages are installed. Defaults to <RepoRoot>/.claude/skills.
    .PARAMETER Script
        The file name of the gate script, such as Check-ChangeCompleteness.ps1.
    .PARAMETER Commit
        The commits a push sends; see Get-AiSdlcGateScriptMode.
    .EXAMPLE
        Test-AiSdlcGateOff -RepoRoot C:/src/repo -Script Check-Coverage.ps1
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$SkillsRoot,
        [Parameter(Mandatory)][string]$Script,
        [string[]]$Commit
    )

    return (Get-AiSdlcGateScriptMode @PSBoundParameters) -ceq 'Off'
}

Export-ModuleMember -Function Find-AiSdlcRepoRoot, Resolve-AiSdlcSourceRoot, Get-AiSdlcConfig, Get-AiSdlcPath, Get-AiSdlcKnowledgeRoot, Get-AiSdlcMainCheckoutRoot, Test-AiSdlcPathExcluded, Test-AiSdlcPack, Test-AiSdlcTrunkPushAllowed, Get-AiSdlcStoryPattern, Get-AiSdlcBranchStoryKey, Get-AiSdlcStoryKey, ConvertTo-AiSdlcStoryKey, Get-AiSdlcPackage, Get-AiSdlcMainBranch, Get-AiSdlcGateMode, Get-AiSdlcGateModeSetting, Resolve-AiSdlcGateMode, Get-AiSdlcGateScriptMode, Test-AiSdlcGateOff
