#Requires -Version 7
<#
.SYNOPSIS
    Gate: the source of a .NET repository uses the shared parts, not its own copy of a settings class, an HTTP client, an Azure credential or a base exception.
.DESCRIPTION
    A repository that splits its code into services needs one answer for four things. Each service
    reads its settings through an options class, takes an HttpClient from the factory, gets an Azure
    credential from one helper and derives its exceptions from one base exception. The rule is in
    .claude/skills/csharp-conventions/references/house-style.md, section "Shared parts". This gate finds
    the code that breaks it, and it is Advisory: a finding is a warning and never stops a push.

    It reads every .cs file under paths.sourceRoot, as code only: the text of a string, a `//` comment,
    a `///` comment and a `/* */` comment never counts (CSharpCodeView.psm1). It looks for four kinds:
      - settings: a class takes IConfiguration, and nothing else such as IConfigurationSection,
        IConfigurationRoot or IOptions<T>, as a parameter of a primary constructor or of a constructor
        that is named like its class;
      - HttpClient: new HttpClient(), new HttpClient { }, new System.Net.Http.HttpClient(), also with
        global:: in front, and a target-typed new() for a variable of type HttpClient. HttpClientHandler
        is not an HttpClient;
      - credential: new for one of the credential classes of Azure.Identity, or a target-typed new() for
        a variable of that type. The classes are AuthorizationCodeCredential, AzureCliCredential,
        AzureDeveloperCliCredential, AzurePipelinesCredential, AzurePowerShellCredential,
        ChainedTokenCredential, ClientAssertionCredential, ClientCertificateCredential,
        ClientSecretCredential, DefaultAzureCredential, DeviceCodeCredential, EnvironmentCredential,
        InteractiveBrowserCredential, ManagedIdentityCredential, OnBehalfOfCredential,
        VisualStudioCodeCredential, VisualStudioCredential and WorkloadIdentityCredential. These 18 are
        on https://learn.microsoft.com/en-us/dotnet/api/azure.identity?view=azure-dotnet. The gate adds
        UsernamePasswordCredential and SharedTokenCacheCredential, which older versions have. The class that
        dotnet.credentialHelper names is the one place that may create them;
      - exception: a class whose name ends in Exception and that derives straight from Exception,
        System.Exception or global::System.Exception, with or without arguments, also when the base type
        is on the next line. The class that dotnet.baseException names is the shared base and is exempt.
    Both settings are type names without a namespace. When one is empty or missing in aisdlc.json, the
    gate skips that kind and says so in one line.

    The gate does not read: files under paths.testRoot, files of a project that is a test project (the
    deepest project folder wins, as in DotnetTestScope.psm1), files named Program.cs or Startup.cs,
    generated files (*.Designer.cs, *.g.cs, *.g.i.cs and anything under bin/ or obj/), and the body of a
    static extension method on IServiceCollection, IHostBuilder, IHostApplicationBuilder,
    HostApplicationBuilder, WebApplicationBuilder, IWebHostBuilder or IFunctionsWorkerApplicationBuilder,
    because the place where a service is wired up must create these parts. The same code in a static
    method that is not such an extension is read.

    A finding counts as added when the line that holds the offending text is an added line of the change
    (Get-AiSdlcLineChange in ChangedFiles.psm1). The output lists the findings that this change adds first.
    The findings that were in the code before are listed below them as existing debt, not blocking.

    Exit codes follow ADR 0019: 0 checked and no finding on an added line, also when only older debt
    exists, 1 a finding on an added line, 2 could not check (aisdlc.json names no paths.sourceRoot, the
    change cannot be read, or the lines of a file cannot be read), and the output holds a FIX line, 3 the
    source folder is missing, or it holds no .cs file that the gate reads.

    A pull request author controls the files the gate reads, so its run time grows only with the file
    size. A signature or class header is read for at most 40 lines, and a parameter list for at most
    100 lines. A form that spans more lines is not seen. A .cs file over 1 MB, or one that is a link,
    is skipped with a note. paths.sourceRoot must lie inside the repository (Resolve-AiSdlcSourceRoot),
    and dotnet.credentialHelper and dotnet.baseException must be type names; otherwise the gate exits 2.
    A printed path has a space between each pair of colons, so a file name cannot make a line that GitHub
    reads as a workflow command.
.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script.
.PARAMETER BaseRef
    The ref the change is measured against. Defaults to the pull request target branch, or the main
    branch when there is none.
.PARAMETER ChangedFiles
    Repo-relative paths of the change, read instead of asking git. Without a base, every line of a
    listed file counts as added. Used by the tests.
.EXAMPLE
    pwsh .claude/skills/dotnet-gates/scripts/Check-SharedParts.ps1
.EXAMPLE
    pwsh .claude/skills/dotnet-gates/scripts/Check-SharedParts.ps1 -BaseRef HEAD~3
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$BaseRef,
    [string[]]$ChangedFiles
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$aiSdlcGates = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', 'ai-sdlc-gates', 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', '..', '..', '..', '..', 'core', '.apm', 'skills', 'ai-sdlc-gates', 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
Import-Module (Join-Path $aiSdlcGates 'ChangedFiles.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CSharpCodeView.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DotnetTestScope.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }
# A bad aisdlc.json makes the config read throw; the check of paths.sourceRoot below reports it as exit 2.
if (-not $BaseRef) { $BaseRef = try { Get-AiSdlcMainBranch -RepoRoot $RepoRoot } catch { 'origin/main' } }

$credentialTypes = @(
    'AuthorizationCodeCredential', 'AzureCliCredential', 'AzureDeveloperCliCredential', 'AzurePipelinesCredential',
    'AzurePowerShellCredential', 'ChainedTokenCredential', 'ClientAssertionCredential', 'ClientCertificateCredential',
    'ClientSecretCredential', 'DefaultAzureCredential', 'DeviceCodeCredential', 'EnvironmentCredential',
    'InteractiveBrowserCredential', 'ManagedIdentityCredential', 'OnBehalfOfCredential', 'VisualStudioCodeCredential',
    'VisualStudioCredential', 'WorkloadIdentityCredential', 'UsernamePasswordCredential', 'SharedTokenCacheCredential'
)
$builderTypes = @(
    'IServiceCollection', 'IHostBuilder', 'IHostApplicationBuilder', 'HostApplicationBuilder',
    'WebApplicationBuilder', 'IWebHostBuilder', 'IFunctionsWorkerApplicationBuilder'
)
$credentialAlternation = $credentialTypes -join '|'
$builderAlternation = $builderTypes -join '|'
$declaredNew = '\??\s+\w+\s*(?:\{[^{}]*\}\s*)?=\s*new\s*\('
$httpClientPattern = '\bnew\s+(?:(?:global::)?System\.Net\.Http\.)?(?<type>HttpClient)\s*[({]|(?<![\w.])(?:(?:global::)?System\.Net\.Http\.)?HttpClient' + $declaredNew
$credentialPattern = "\bnew\s+(?:(?:global::)?Azure\.Identity\.)?(?<type>$credentialAlternation)\s*[({]|(?<![\w.])(?:(?:global::)?Azure\.Identity\.)?(?:$credentialAlternation)" + $declaredNew
$extensionPattern = "\bstatic\b[^;{]*?\(\s*(?:\[[^\]\r\n]*\]\s*)*this\s+(?:global::)?(?:\w+\.)*(?:$builderAlternation)\b"
$configurationPattern = '(?<![\w<])IConfiguration\??\s+\w+'
$maxSpan = 40
$maxParameterLines = 100
$parentheses = [char[]]'()'
$typeDeclarationPattern = '\b(?:class|record(?:\s+class)?)\s+(?<name>\w+)'
$primaryConstructorPattern = '\b(?:class|record(?:\s+class)?)\s+(?<name>\w+)\s*(?:<[^>]*>)?\s*\('
$exceptionPattern = '\bclass\s+(?<name>\w+Exception)\s*(?:<[^>]*>)?\s*(?:\((?>[^()]+|\((?<depth>)|\)(?<-depth>))*(?(depth)(?!))\))?\s*:\s*(?<base>(?:global::)?(?:System\.)?Exception)(?![\w.<])'

$rulePath = '.claude/skills/csharp-conventions/references/house-style.md, section "Shared parts"'

function ConvertTo-RepoRelative {
    param([string]$Full)
    return [IO.Path]::GetRelativePath($RepoRoot, $Full).Replace('\', '/')
}

function Find-BlockEnd {
    param([string[]]$Code, [int]$From)

    $depth = 0
    $opened = $false
    for ($i = $From; $i -lt $Code.Count; $i++) {
        # A signature that opens no block within the span is no block, and a longer scan costs time on each match.
        if (-not $opened -and $i - $From -gt $maxSpan) { return $From }
        foreach ($ch in $Code[$i].ToCharArray()) {
            if ($ch -eq '{') { $depth++; $opened = $true }
            elseif ($ch -eq '}') {
                $depth--
                if ($opened -and $depth -le 0) { return $i }
            }
            elseif ($ch -eq ';' -and -not $opened) { return $i }
        }
    }
    return $Code.Count - 1
}

function Join-CodeLine {
    param([string[]]$Code, [int]$From, [int]$To)

    $builder = [System.Text.StringBuilder]::new()
    $starts = [System.Collections.Generic.List[int]]::new()
    for ($i = $From; $i -le $To; $i++) {
        $starts.Add($builder.Length)
        [void]$builder.Append($Code[$i]).Append("`n")
    }
    return [pscustomobject]@{ Text = $builder.ToString(); Starts = $starts; From = $From }
}

function Get-JoinedLineNumber {
    param([object]$Joined, [int]$Offset)

    $index = $Joined.Starts.BinarySearch($Offset)
    if ($index -lt 0) { $index = (-bnot $index) - 1 }
    return $Joined.From + [Math]::Max(0, $index) + 1
}

function Get-ExemptLine {
    param([string[]]$Code)

    $exempt = [System.Collections.Generic.HashSet[int]]::new()
    for ($i = 0; $i -lt $Code.Count; $i++) {
        if ($Code[$i] -notmatch '\bstatic\b') { continue }
        $last = $i
        while ($last -lt $Code.Count - 1 -and $last - $i -lt $maxSpan -and $Code[$last] -notmatch '[{;]|=>') { $last++ }
        $signature = ($Code[$i..$last] -join ' ')
        $match = [regex]::Match($signature, $extensionPattern)
        if (-not $match.Success) { continue }
        $end = Find-BlockEnd -Code $Code -From $i
        for ($n = $i; $n -le $end; $n++) { [void]$exempt.Add($n + 1) }
    }
    return , $exempt
}

function Get-ClassLineRange {
    param([string[]]$Code, [string]$Name)

    $pattern = '\b(?:class|record|struct)\s+' + [regex]::Escape($Name) + '(?!\w)'
    $found = [System.Collections.Generic.HashSet[int]]::new()
    $joined = Join-CodeLine -Code $Code -From 0 -To ($Code.Count - 1)
    foreach ($m in [regex]::Matches($joined.Text, $pattern)) {
        $start = (Get-JoinedLineNumber -Joined $joined -Offset $m.Index) - 1
        $end = Find-BlockEnd -Code $Code -From $start
        for ($n = $start; $n -le $end; $n++) { [void]$found.Add($n + 1) }
    }
    return , $found
}

function Get-ParameterSpan {
    param([object]$Joined, [System.Collections.Generic.List[int]]$Openings)

    $text = $Joined.Text
    $close = @{}
    $stack = [System.Collections.Generic.Stack[int]]::new()
    $pos = $text.IndexOfAny($parentheses)
    while ($pos -ge 0) {
        if ($text[$pos] -eq '(') { $stack.Push($pos) }
        elseif ($stack.Count -gt 0) { $close[$stack.Pop()] = $pos }
        $pos = $text.IndexOfAny($parentheses, $pos + 1)
    }
    $spans = [System.Collections.Generic.List[object]]::new()
    foreach ($opening in $Openings) {
        $lineIndex = (Get-JoinedLineNumber -Joined $Joined -Offset $opening) - 1
        $lastLine = [Math]::Min($Joined.Starts.Count - 1, $lineIndex + $maxParameterLines)
        $limit = if ($lastLine + 1 -lt $Joined.Starts.Count) { $Joined.Starts[$lastLine + 1] - 1 } else { $text.Length - 1 }
        $end = if ($close.ContainsKey($opening) -and $close[$opening] -le $limit) { $close[$opening] } else { $limit }
        $spans.Add([pscustomobject]@{ Start = $opening; End = $end })
    }
    return , $spans
}

function Find-SettingsFinding {
    param([string[]]$Code)

    $lines = [System.Collections.Generic.HashSet[int]]::new()
    $typeNames = [System.Collections.Generic.HashSet[string]]::new()
    $joined = Join-CodeLine -Code $Code -From 0 -To ($Code.Count - 1)
    foreach ($m in [regex]::Matches($joined.Text, $typeDeclarationPattern)) { [void]$typeNames.Add($m.Groups['name'].Value) }
    $openings = [System.Collections.Generic.List[int]]::new()
    foreach ($m in [regex]::Matches($joined.Text, $primaryConstructorPattern)) { $openings.Add($m.Index + $m.Length - 1) }
    $constructorPattern = '(?m)^[ \t]*(?:\[[^\]\r\n]*\][ \t]*)*(?:(?:public|internal|protected|private|static|unsafe|extern)\s+)*(?<name>\w+)\s*\('
    foreach ($m in [regex]::Matches($joined.Text, $constructorPattern)) {
        if ($typeNames.Contains($m.Groups['name'].Value)) { $openings.Add($m.Index + $m.Length - 1) }
    }
    if ($openings.Count -eq 0) { return @() }
    $spans = @((Get-ParameterSpan -Joined $joined -Openings $openings) | Sort-Object Start)
    $starts = [int[]]@($spans | ForEach-Object { $_.Start })
    $widest = [int[]]::new($spans.Count)
    for ($i = 0; $i -lt $spans.Count; $i++) {
        $widest[$i] = if ($i -eq 0) { $spans[0].End } else { [Math]::Max($widest[$i - 1], $spans[$i].End) }
    }
    foreach ($m in [regex]::Matches($joined.Text, $configurationPattern)) {
        $index = [Array]::BinarySearch($starts, $m.Index)
        if ($index -lt 0) { $index = (-bnot $index) - 1 }
        if ($index -ge 0 -and $widest[$index] -ge $m.Index + $m.Length - 1) {
            [void]$lines.Add((Get-JoinedLineNumber -Joined $joined -Offset $m.Index))
        }
    }
    return @($lines | Sort-Object)
}

function Find-PatternLine {
    param([string[]]$Code, [string]$Pattern)

    $joined = Join-CodeLine -Code $Code -From 0 -To ($Code.Count - 1)
    $lines = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($m in [regex]::Matches($joined.Text, $Pattern)) {
        $offset = if ($m.Groups['type'].Success) { $m.Groups['type'].Index } else { $m.Index + $m.Value.LastIndexOf('new', [StringComparison]::Ordinal) }
        [void]$lines.Add((Get-JoinedLineNumber -Joined $joined -Offset $offset))
    }
    return @($lines | Sort-Object)
}

function Find-ExceptionFinding {
    param([string[]]$Code, [string]$BaseException)

    $lines = [System.Collections.Generic.HashSet[int]]::new()
    $nextStop = [int[]]::new($Code.Count + 1)
    $nextNamed = [int[]]::new($Code.Count + 1)
    $nextStop[$Code.Count] = $Code.Count
    $nextNamed[$Code.Count] = $Code.Count
    for ($i = $Code.Count - 1; $i -ge 0; $i--) {
        $nextStop[$i] = if ($Code[$i].IndexOfAny([char[]]'{;') -ge 0) { $i } else { $nextStop[$i + 1] }
        $nextNamed[$i] = if ($Code[$i].Contains('Exception')) { $i } else { $nextNamed[$i + 1] }
    }
    for ($i = 0; $i -lt $Code.Count; $i++) {
        if ($Code[$i] -notmatch '\bclass\b') { continue }
        $last = [Math]::Min([Math]::Min($nextStop[$i], $i + $maxSpan), $Code.Count - 1)
        if ($nextNamed[$i] -gt $last) { continue }
        $joined = Join-CodeLine -Code $Code -From $i -To $last
        $m = [regex]::Match($joined.Text, $exceptionPattern)
        if (-not $m.Success) { continue }
        if ($m.Groups['name'].Value -ceq $BaseException) { continue }
        [void]$lines.Add((Get-JoinedLineNumber -Joined $joined -Offset $m.Groups['base'].Index))
    }
    return @($lines | Sort-Object)
}

function ConvertTo-SafeText {
    param([string]$Text)
    return $Text.Replace('::', ': :')
}

$aiSdlc = try { Get-AiSdlcConfig -RepoRoot $RepoRoot } catch { $null }
if (-not $aiSdlc) {
    Write-Host ('Could not check: aisdlc.json cannot be used. ' + (ConvertTo-SafeText $Error[0].Exception.Message)) -ForegroundColor Yellow
    Write-Host 'FIX: Make aisdlc.json valid, with paths.sourceRoot set to a folder inside the repository, then run this check again.' -ForegroundColor Yellow
    exit 2
}
$srcRel = ([string]$aiSdlc.paths.sourceRoot).TrimEnd('/')
if (-not $srcRel) {
    Write-Host 'Could not check: aisdlc.json names no paths.sourceRoot.' -ForegroundColor Yellow
    Write-Host 'FIX: Set paths.sourceRoot in aisdlc.json to the folder that holds the source, then run this check again.' -ForegroundColor Yellow
    exit 2
}
try { $srcDir = Resolve-AiSdlcSourceRoot -RepoRoot $RepoRoot -Path $srcRel }
catch {
    Write-Host ('Could not check: aisdlc.json paths.sourceRoot ' + (ConvertTo-SafeText $_.Exception.Message) + '.') -ForegroundColor Yellow
    Write-Host 'FIX: Set paths.sourceRoot in aisdlc.json to a folder inside the repository that is not a link, then run this check again.' -ForegroundColor Yellow
    exit 2
}
foreach ($key in 'credentialHelper', 'baseException') {
    $name = [string]$aiSdlc.dotnet[$key]
    if ($name -and $name -cnotmatch '^\w+(\.\w+)*$') {
        Write-Host "Could not check: aisdlc.json dotnet.$key is not a type name, such as AppException or Shared.AppException." -ForegroundColor Yellow
        Write-Host "FIX: Set dotnet.$key in aisdlc.json to the name of the class, with only letters, digits, underscores and dots." -ForegroundColor Yellow
        exit 2
    }
}
if (-not (Test-Path -LiteralPath $srcDir -PathType Container)) {
    Write-Host "Not applicable: the source folder $(ConvertTo-SafeText $srcRel)/ does not exist in this repository, so there is no code to check."
    exit 3
}

$change = Get-AiSdlcChange -RepoRoot $RepoRoot -BaseRef $BaseRef -Explicit $ChangedFiles
if (-not $change.Readable) {
    Write-Host "Shared parts: the change could not be read ($($change.Reason)), so NOTHING WAS CHECKED." -ForegroundColor Yellow
    $fix = if ($change.PSObject.Properties['Fix']) { $change.Fix } else { 'Fetch the base branch (git fetch origin <branch>), or pass -BaseRef with a ref that exists, then run this check again.' }
    Write-Host "FIX: $fix" -ForegroundColor Yellow
    exit 2
}

$credentialHelper = [string]$aiSdlc.dotnet['credentialHelper']
$baseException = [string]$aiSdlc.dotnet['baseException']
$testRel = ([string]$aiSdlc.paths.testRoot).Trim('/')

$pathComparer = if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
$changedSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($change.Files), $pathComparer)
$pathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$projects = @(Get-DotnetProjectGraph -RepoRoot $RepoRoot)

$maxFileBytes = 1MB
$skippedFiles = [System.Collections.Generic.List[string]]::new()
$candidates = @(Get-ChildItem -LiteralPath $srcDir -Recurse -Filter *.cs -File | ForEach-Object {
        $rel = ConvertTo-RepoRelative -Full $_.FullName
        if ($_.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) { $skippedFiles.Add("$rel : a link, which may point outside the repository"); return }
        if ($_.Length -gt $maxFileBytes) { $skippedFiles.Add("$rel : over 1 MB"); return }
        $rel
    } | Sort-Object)
foreach ($s in $skippedFiles) { Write-Host ('Skipped, not read: ' + (ConvertTo-SafeText $s)) }
$files = [System.Collections.Generic.List[string]]::new()
foreach ($rel in $candidates) {
    if (-not (Test-CheckedPath $rel)) { continue }
    $leaf = [IO.Path]::GetFileName($rel)
    if ($leaf -ceq 'Program.cs' -or $leaf -ceq 'Startup.cs') { continue }
    if ($testRel -and $rel.StartsWith($testRel + '/', $pathComparison)) { continue }
    $owner = $projects | Where-Object { $_.Folder -eq '' -or $rel.StartsWith($_.Folder + '/', $pathComparison) } |
        Sort-Object { $_.Folder.Length } -Descending | Select-Object -First 1
    if ($owner -and $owner.IsTest) { continue }
    $files.Add($rel)
}
if ($files.Count -eq 0) {
    Write-Host "Not applicable: $(ConvertTo-SafeText $srcRel)/ holds no .cs file that this gate reads (test, generated, Program.cs and Startup.cs files are skipped)."
    exit 3
}

if (-not $credentialHelper) { Write-Host 'Credential kind skipped: aisdlc.json names no dotnet.credentialHelper.' }
if (-not $baseException) { Write-Host 'Exception kind skipped: aisdlc.json names no dotnet.baseException.' }

$kinds = @{
    settings   = @{ Rule = 'A class takes its settings as an options class (IOptions<T>), not as IConfiguration.'; Fix = 'Bind the settings to an options class and take IOptions<T> in the constructor.' }
    HttpClient = @{ Rule = 'Code does not create an HttpClient with new.'; Fix = 'Register the client with AddHttpClient and take HttpClient or IHttpClientFactory in the constructor.' }
    credential = @{ Rule = "Code does not create an Azure credential; the shared helper $credentialHelper does."; Fix = "Get the credential from $credentialHelper." }
    exception  = @{ Rule = "An exception class derives from the shared base exception $baseException, not from Exception."; Fix = "Derive the class from $baseException." }
}

$findings = [System.Collections.Generic.List[object]]::new()
$unchecked = [System.Collections.Generic.List[string]]::new()
foreach ($rel in $files) {
    $full = Join-Path $RepoRoot $rel
    $raw = $null
    # .NET reads the path as it is; a cmdlet takes the text before :: in a file name for a provider name.
    try { $raw = @([IO.File]::ReadAllLines($full)) }
    catch {
        $unchecked.Add("$rel : the file cannot be read")
        continue
    }
    if ($raw.Count -eq 0) { continue }
    $added = [System.Collections.Generic.HashSet[int]]::new()
    if ($changedSet.Contains($rel)) {
        $lineChange = Get-AiSdlcLineChange -RepoRoot $RepoRoot -Base $change.Base -Path $rel -AssumeNew:([bool]$ChangedFiles)
        if ($null -eq $lineChange) {
            $unchecked.Add("$rel : git could not list the lines this change adds")
            continue
        }
        $added = [System.Collections.Generic.HashSet[int]]::new([int[]]@($lineChange.Added))
    }
    $view = @(Get-CodeView -Lines $raw)
    if ($view.Count -ne $raw.Count) {
        $unchecked.Add("$rel : the lines cannot be read as code")
        continue
    }
    $code = @($view | ForEach-Object { $_ -replace '//.*$', '' })
    $exempt = Get-ExemptLine -Code $code
    $helperLines = [System.Collections.Generic.HashSet[int]]::new()
    if ($credentialHelper) { $helperLines = Get-ClassLineRange -Code $code -Name $credentialHelper }

    $found = [System.Collections.Generic.List[object]]::new()
    foreach ($n in @(Find-SettingsFinding -Code $code)) { $found.Add(@{ Kind = 'settings'; Line = $n }) }
    foreach ($n in @(Find-PatternLine -Code $code -Pattern $httpClientPattern)) { $found.Add(@{ Kind = 'HttpClient'; Line = $n }) }
    if ($credentialHelper) {
        foreach ($n in @(Find-PatternLine -Code $code -Pattern $credentialPattern)) {
            if (-not $helperLines.Contains($n)) { $found.Add(@{ Kind = 'credential'; Line = $n }) }
        }
    }
    if ($baseException) {
        foreach ($n in @(Find-ExceptionFinding -Code $code -BaseException $baseException)) { $found.Add(@{ Kind = 'exception'; Line = $n }) }
    }
    foreach ($f in $found) {
        if ($exempt.Contains($f.Line)) { continue }
        $findings.Add([pscustomobject]@{ File = $rel; Line = $f.Line; Kind = $f.Kind; IsNew = $added.Contains($f.Line) })
    }
}

if ($unchecked.Count -gt 0) {
    Write-Host 'Shared parts: some files could not be checked, so they were NOT CHECKED.' -ForegroundColor Yellow
    foreach ($u in $unchecked) { Write-Host ('  ' + (ConvertTo-SafeText $u)) }
    Write-Host 'FIX: Check that the files are readable and that git can list the change (git fetch origin <branch>), then run this check again.' -ForegroundColor Yellow
    exit 2
}

function Write-Finding {
    param([object]$Finding)
    $kind = $kinds[$Finding.Kind]
    Write-Host ("  {0}:{1}  {2}: {3} Fix: {4}" -f (ConvertTo-SafeText $Finding.File), $Finding.Line, $Finding.Kind, $kind.Rule, $kind.Fix)
}

$new = @($findings | Where-Object { $_.IsNew } | Sort-Object File, Line, Kind)
$older = @($findings | Where-Object { -not $_.IsNew } | Sort-Object File, Line, Kind)

if ($new.Count -gt 0) {
    Write-Host "Shared parts: $($new.Count) finding(s) on lines that this change adds. The rule is in $rulePath." -ForegroundColor Yellow
    Write-Host 'FIX: Use the shared part named in each finding instead of your own copy.' -ForegroundColor Yellow
    foreach ($f in $new) { Write-Finding -Finding $f }
}
else {
    Write-Host ("Shared parts OK: {0} file(s) checked, and no finding on a line that this change adds." -f $files.Count)
}
if ($older.Count -gt 0) {
    Write-Host "Existing debt, not blocking: $($older.Count) finding(s) in code that this change does not add."
    foreach ($f in $older) { Write-Finding -Finding $f }
}

if ($new.Count -gt 0) { exit 1 }
exit 0
