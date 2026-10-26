#Requires -Version 7
<#
.SYNOPSIS
    The rules three documentation tools share for reading a page and reading the code it cites. One
    copy, because the copies drifted.

.DESCRIPTION
    Check-DocDrift.ps1, Invoke-DocGraphLink.ps1 and Update-DocFromGraph.ps1 all have to answer the same
    questions: which files does this page cite, which types does this source declare, is this type
    service-shaped, and which project does this page document. They each carried their own copy of the
    answer, and in one afternoon the copies disagreed three times: a fix excluding model types from the
    service heuristic had to be applied twice, a fix reading a file name at a name boundary had to be
    applied twice, and the project-attribution rule was corrected in the drift check while the updater
    kept the old one, which is how an API reference page came to be told to document 49 domain services.

    A duplicated rule is not a smaller change than a shared one, it is the same change made repeatedly
    and eventually made inconsistently. So the rules live here and nowhere else.

    Nothing in here reads the network or a model. It is regular expressions over text plus a file-name
    convention, which is why it can run on every push for everyone.

.NOTES
    Imported with Import-Module by the three tools next to it. Its own tests are in DocSurface.Tests.ps1.
.PARAMETER Text
    The page text, for the readers that take a page: Get-NamedSourceFile, Get-DocumentedRoute and
    Get-NamedSymbol.

.PARAMETER Source
    The source file text, for the readers that take code: Get-PublicMemberName, Get-PublicTypeName and
    Get-PublicMethodName.

.PARAMETER TypeName
    The declared type name Test-ServiceShaped judges, with SourceFile for the path it lives at.

.PARAMETER DocPath
    The page path Resolve-ProjectByPageName matches against ProjectName, the candidate project names.

.PARAMETER Family
    The project families Resolve-ProjectByPageName reads a page name against: each one a page folder
    and the project name prefix its pages document. Get-ProjectFamily builds them from
    paths.sourceDocMap in aisdlc.json: an entry whose source is the source root plus a name prefix
    ending in a dot, such as "src/Shared.", makes its docs folders project page folders.

.PARAMETER RepoRoot
    The repository whose source root Get-SourceRoot and Get-RepositoryProjectName read from
    paths.sourceRoot in aisdlc.json.

.EXAMPLE
    Import-Module ./DocSurface.psm1
    Get-NamedSourceFile -Text (Get-Content -Raw docs/libraries/ledger.md)

.EXAMPLE
    Resolve-ProjectByPageName -DocPath 'docs/libraries/stock-level.md' -ProjectName @('Shared.StockLevel')
#>

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1')

function Get-SourceRoot {
    [CmdletBinding()]
    param([string]$RepoRoot)

    if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }
    return ([string](Get-AiSdlcConfig -RepoRoot $RepoRoot).paths.sourceRoot).Replace('\', '/').TrimEnd('/')
}

$script:TestDoublePrefix = '^(Mock|Fake|Stub|Test)'

$script:PlaceholderName = @('Foo', 'Bar', 'Baz', 'Qux')

function Remove-FencedBlock {
    param([Parameter(Mandatory)][string]$Text)

    return [regex]::Replace($Text, '(?ms)^[ \t]*(```|~~~).*?^[ \t]*\1[ \t]*\r?$', '')
}

function Test-PlaceholderName {
    param([Parameter(Mandatory)][string]$Name)

    $stem = ($Name -split '\.')[0]
    return ($stem -cin $script:PlaceholderName) -or ($stem -cmatch '^(My|Your)[A-Z]')
}

function Remove-Url {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    return ($Text -replace 'https?://\S+', ' ')
}

function Get-NamedSourceFile {
    param([Parameter(Mandatory)][string]$Text)

    $pattern = '(?<![A-Za-z0-9_.-])[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*\.(?:cs|razor|ps1|bicep)(?![A-Za-z0-9_])'
    $names = [System.Collections.Generic.HashSet[string]]::new()
    $readable = Remove-Url -Text (Remove-FencedBlock -Text $Text)
    foreach ($match in [regex]::Matches($readable, $pattern)) {
        if (Test-PlaceholderName -Name $match.Value) { continue }
        [void]$names.Add($match.Value)
    }
    return $names
}

function Get-DocumentedRoute {
    param([Parameter(Mandatory)][string]$Text)

    $routes = [System.Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches((Remove-FencedBlock -Text $Text), '(?m)(?<![A-Za-z])(GET|POST|PUT|PATCH|DELETE)\s+`?(/[A-Za-z0-9_{}/-]*)')) {
        $routes.Add("$($match.Groups[1].Value) $($match.Groups[2].Value)")
    }
    return $routes
}

function Get-RouteLiteral {
    param([Parameter(Mandatory)][string]$Route)

    $path = ($Route -split '\s+', 2)[1]
    if (-not $path) { return @() }
    return @($path.Trim('/') -split '/' | Where-Object { $_ -and -not $_.StartsWith('{') })
}

$script:SymbolSuffix = 'Service|Client|Repository|Controller|Handler|Factory|Options|Builder|Provider|Strategy|Middleware|Extensions|Formatter|Executor|Resolver|Orchestrator|Watcher|Evaluator|Classifier|Sanitizer|Publisher|Reporter|Trigger|Hub|Queue|Job|Reader|Writer|Validator|Converter|Sender|Listener|Store|Cache|Manager|Mapper|Parser|Serializer|Guard|Filter|Policy|Context|State|Activity|Step|Task|Rule'

function Get-NamedSymbol {
    param([Parameter(Mandatory)][string]$Text)

    $names = [System.Collections.Generic.HashSet[string]]::new()
    $inner = '(?<![A-Za-z0-9_])(?:Add[A-Z][A-Za-z0-9_]*|[A-Z][A-Za-z0-9_]{2,}Async|I?[A-Z][A-Za-z0-9_]*(?:' + $script:SymbolSuffix + '))\b(?!\.(?:cs|razor|ps1|psm1|bicep|json|csproj))'
    $span = '`([^`\r\n]{1,400})`'
    foreach ($match in [regex]::Matches((Remove-FencedBlock -Text $Text), $span)) {
        foreach ($symbol in [regex]::Matches($match.Groups[1].Value, $inner)) {
            [void]$names.Add($symbol.Value)
        }
    }
    return $names
}

function Get-PublicMemberName {
    param([Parameter(Mandatory)][string]$Source)

    $names = [System.Collections.Generic.HashSet[string]]::new()
    $patterns = @(
        'public\s+const\s+\w[\w<>\[\],\s\.]*?\s+(\w+)\s*=',
        'public\s+static\s+readonly\s+\w[\w<>\[\],\s\.]*?\s+(\w+)\s*='
    )
    foreach ($pattern in $patterns) {
        foreach ($match in [regex]::Matches($Source, $pattern)) {
            [void]$names.Add($match.Groups[1].Value)
        }
    }
    return $names
}

function Get-PublicTypeName {
    param([Parameter(Mandatory)][string]$Source)

    $names = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($match in [regex]::Matches($Source, '(?m)^\s*public\s+(?:sealed\s+|abstract\s+|static\s+|partial\s+)*(?:class|interface|record|enum|struct)\s+(\w+)')) {
        [void]$names.Add($match.Groups[1].Value)
    }
    return $names
}

function Get-PublicMethodName {
    param([Parameter(Mandatory)][string]$Source)

    $names = [System.Collections.Generic.HashSet[string]]::new()
    $pattern = '(?m)^\s*public\s+(?:async\s+|static\s+|virtual\s+|override\s+|sealed\s+|new\s+)*[\w<>\[\],\.\?]+\s+(\w+)\s*\('
    foreach ($match in [regex]::Matches($Source, $pattern)) {
        $name = $match.Groups[1].Value
        if ($name -in @('get', 'set', 'if', 'return', 'while', 'for', 'foreach', 'switch', 'lock', 'using')) { continue }
        [void]$names.Add($name)
    }
    return $names
}

function Test-ServiceShaped {
    param(
        [Parameter(Mandatory)][string]$TypeName,
        [Parameter(Mandatory)][string]$SourceFile
    )

    if (Test-IsTestDouble -Name $TypeName) { return $false }
    if ($SourceFile -match '/Models/') { return $false }
    if ($TypeName -match 'Exception$') { return $false }
    if ($TypeName -match '(Service|Client|Builder|Factory|Repository|Orchestrator|Provider|Handler|Strategy)$') { return $true }
    if ($TypeName -match '^I.*(Service|Client|Builder|Factory|Repository|Orchestrator|Provider)$') { return $true }
    return ($SourceFile -match '/Services/')
}

function Get-ProjectFamily {
    [CmdletBinding()]
    param([string]$RepoRoot)

    if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }
    if (-not $RepoRoot) { return , @() }
    $config = Get-AiSdlcConfig -RepoRoot $RepoRoot
    $sourceRoot = ([string]$config.paths.sourceRoot).Replace('\', '/').TrimEnd('/')
    if (-not $sourceRoot) { return , @() }
    $families = foreach ($entry in @($config.paths.sourceDocMap)) {
        if (-not $entry) { continue }
        $source = ([string]$entry.source).Replace('\', '/')
        if (-not $source.StartsWith("$sourceRoot/")) { continue }
        $prefix = $source.Substring($sourceRoot.Length + 1)
        if (-not $prefix.EndsWith('.') -or $prefix.Contains('/')) { continue }
        foreach ($folder in @($entry.docs)) {
            $folder = ([string]$folder).Replace('\', '/')
            if (-not $folder.EndsWith('/')) { continue }
            [pscustomobject]@{ Folder = $folder; Prefix = $prefix }
        }
    }
    return , @($families)
}

function Resolve-ProjectByPageName {
    param(
        [Parameter(Mandatory)][string]$DocPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ProjectName,
        [object[]]$Family,
        [string]$RepoRoot
    )

    if ($null -eq $Family) { $Family = Get-ProjectFamily -RepoRoot $RepoRoot }
    $normalised = $DocPath.Replace([char]92, '/')
    $prefix = $null
    foreach ($entry in $Family) {
        if ($normalised -like "*$($entry.Folder)*") { $prefix = $entry.Prefix; break }
    }
    if (-not $prefix) { return $null }

    $stem = [System.IO.Path]::GetFileNameWithoutExtension($normalised).Replace('-', '')
    foreach ($project in $ProjectName) {
        if ($project -notlike "$prefix*") { continue }
        $short = $project.Substring($prefix.Length).Replace('.', '')
        if ($short -eq $stem) { return $project }
    }
    return $null
}

function Test-IsTestDouble {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)

    return ($Name -match $script:TestDoublePrefix)
}

function Get-RecordFolder {
    [CmdletBinding()]
    param([string]$RepoRoot)

    $adrFolder = 'docs/adrs'
    if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }
    if ($RepoRoot) {
        $configured = [string](Get-AiSdlcConfig -RepoRoot $RepoRoot).paths.adrFolder
        if ($configured) { $adrFolder = $configured }
    }
    return , @(($adrFolder.Replace('\', '/').TrimEnd('/') + '/'), 'docs/stories/')
}

function Get-ProjectPageFolder {
    [CmdletBinding()]
    param([string]$RepoRoot)

    return , @((Get-ProjectFamily -RepoRoot $RepoRoot) | ForEach-Object Folder | Select-Object -Unique)
}

function Get-RepositoryProjectName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $sourceRoot = Get-SourceRoot -RepoRoot $RepoRoot
    if (-not $sourceRoot) { return , @() }
    $srcRoot = Join-Path $RepoRoot $sourceRoot
    if (-not (Test-Path -LiteralPath $srcRoot)) { return , @() }
    return , @(Get-ChildItem -LiteralPath $srcRoot -Directory | ForEach-Object { $_.Name })
}

function Resolve-DocumentedProject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DocPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ProjectName,
        [hashtable]$Vote = @{},
        [int]$MinimumVotes = 2,
        [string]$RepoRoot
    )

    $byName = Resolve-ProjectByPageName -DocPath $DocPath -ProjectName $ProjectName -RepoRoot $RepoRoot
    if ($byName) { return $byName }
    return Resolve-TopProject -Vote $Vote -MinimumVotes $MinimumVotes
}

function Get-CitedProjectVote {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$CitedFile,
        [string]$SourceRoot = (Get-SourceRoot)
    )

    $vote = @{}
    if (-not $SourceRoot) { return $vote }
    $prefix = $SourceRoot.TrimEnd('/') + '/'
    foreach ($file in $CitedFile) {
        if (-not $file.StartsWith($prefix)) { continue }
        $candidate = ($file.Substring($prefix.Length) -split '/')[0]
        if (-not $candidate) { continue }
        if (-not $vote.ContainsKey($candidate)) { $vote[$candidate] = 0 }
        $vote[$candidate]++
    }
    return $vote
}

function Resolve-TopProject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Vote,
        [int]$MinimumVotes = 2
    )

    if ($Vote.Count -eq 0) { return $null }
    $top = @($Vote.GetEnumerator() | Sort-Object -Property Value -Descending)[0]
    if ($top.Value -ge $MinimumVotes) { return $top.Key }
    return $null
}

Export-ModuleMember -Function @(
    'Get-RecordFolder',
    'Get-ProjectPageFolder',
    'Get-ProjectFamily',
    'Get-RepositoryProjectName',
    'Resolve-DocumentedProject',
    'Get-CitedProjectVote',
    'Resolve-TopProject',
    'Test-IsTestDouble',
    'Get-NamedSourceFile',
    'Get-DocumentedRoute',
    'Get-NamedSymbol',
    'Get-RouteLiteral',
    'Get-PublicMemberName',
    'Get-PublicTypeName',
    'Get-PublicMethodName',
    'Test-ServiceShaped',
    'Resolve-ProjectByPageName',
    'Get-SourceRoot'
)
