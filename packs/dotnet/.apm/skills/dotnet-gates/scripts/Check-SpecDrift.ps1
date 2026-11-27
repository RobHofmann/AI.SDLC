#Requires -Version 7
<#
.SYNOPSIS
    Gate: when a change moves an endpoint that a spec already describes, the spec moves with it.

.DESCRIPTION
    A spec that describes last month's payload is worse than no spec, because walk-substrate then
    reports contract drift on every later change and people learn to ignore it. This gate asks one
    question about the diff: did a file that carries an HTTP surface change, while the spec that
    already covers that resource stood still?

    It fires ONLY where a spec already exists. Nothing is asked of an endpoint that never had one,
    so no spec has to be written backwards for the API as it stands today. The cover grows by itself:
    the first time an endpoint moves, write-api-spec writes its spec, and from then on this gate
    watches that resource.

    How a changed file is matched to a spec, with no YAML parser in the way:

      1. A changed .cs or .razor file under the source root (paths.sourceRoot in aisdlc.json) is read
         for an HTTP surface: a [Route(...)], an [HttpGet/Post/Put/Patch/Delete(...)] attribute, or a
         minimal-API Map* call. It judges only the lines the change adds or removes (Get-AiSdlcLineChange
         in ChangedFiles.psm1), so a route that the change did not touch is not read, and a route that
         the change removed is.
      2. Its resource tokens are the literal segments of the route templates on those lines (api, v1,
         and the [controller] and [action] tokens are dropped), plus the kebab-case form of a
         *Controller class name (OrderLinesController -> order-lines) when a route line changed.
         The names of the class, record, struct and enum types that those lines declare are DTO tokens.
      3. A spec under specs/ that contains one of those tokens covers that file. If no file under
         specs/ changed in the same diff, that is the finding.

    ADVISORY for now: exit 1 is a warning, not a block. A route line can change in a way the wire
    shape does not see, and this gate cannot tell that apart. Turn it blocking once the team has seen
    how often that happens.

    Exit 0 clean, 1 a finding, 2 could not check (CHANGED_FILES is set but there is no merge base, so
    the lines of the change cannot be told; the output has a FIX: line), 3 not applicable (no spec, or no
    changed file to check, also in a local run with no merge base). With an explicit -ChangedFiles list
    and no merge base, every line of the listed files counts as added.

.PARAMETER RepoRoot
    Repository root that holds the source root and, when there are specs, the specs folder. Defaults to
    the folder that holds aisdlc.json, found from this script.

.PARAMETER BaseRef
    The ref the change is measured against when no explicit file list is given. Defaults to origin/<github.trunk> from aisdlc.json (Get-AiSdlcMainBranch), origin/main unless the repository names another trunk.

.PARAMETER ChangedFiles
    Explicit repository-relative paths, bypassing git for the file list. Falls back to the
    newline-separated CHANGED_FILES environment variable, which the pipeline sets from the pull request
    diff, and then to git.

.PARAMETER SpecsDir
    The folder holding the specs, relative to RepoRoot. Defaults to paths.specsRoot in aisdlc.json.

.EXAMPLE
    pwsh .claude/skills/dotnet-gates/scripts/Check-SpecDrift.ps1

.EXAMPLE
    pwsh .claude/skills/dotnet-gates/scripts/Check-SpecDrift.ps1 -ChangedFiles 'src/Api/Controllers/OrdersController.cs'
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$BaseRef,
    [string[]]$ChangedFiles,
    [string]$SpecsDir
)

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
Import-Module (Join-Path $aiSdlcGates 'ChangedFiles.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }
if (-not $BaseRef) { $BaseRef = Get-AiSdlcMainBranch -RepoRoot $RepoRoot }
$aiSdlc = Get-AiSdlcConfig -RepoRoot $RepoRoot
if (-not $SpecsDir) { $SpecsDir = $aiSdlc.paths.specsRoot }
$script:SourcePrefix = if ($aiSdlc.paths.sourceRoot) { ([string]$aiSdlc.paths.sourceRoot).TrimEnd('/') + '/' } else { $null }

$ErrorActionPreference = 'Stop'

$script:RouteAttribute = '\[\s*(?:Route|Http(?:Get|Post|Put|Patch|Delete|Head|Options))\s*\(\s*"([^"]*)"'
$script:MinimalApi = '\.Map(?:Get|Post|Put|Patch|Delete)\s*\(\s*"([^"]*)"'
$script:IgnoredSegments = @('api', 'v1', 'v2', '[controller]', '[action]', '')

$script:TypeDeclaration = '\b(?:class|record(?:\s+(?:class|struct))?|struct|enum)\s+([A-Za-z_]\w*)'

function ConvertTo-KebabCase {
    param([string]$Name)

    $stripped = $Name -replace 'Controller$', ''
    if (-not $stripped) { return $null }
    return (($stripped -creplace '(?<!^)([A-Z])', '-$1').ToLowerInvariant())
}

function Get-RouteTemplate {
    param([string]$Text)

    $templates = [System.Collections.Generic.List[string]]::new()
    foreach ($pattern in @($script:RouteAttribute, $script:MinimalApi)) {
        foreach ($match in [regex]::Matches($Text, $pattern)) { $templates.Add($match.Groups[1].Value) }
    }
    return $templates.ToArray()
}

function Split-RouteTemplate {
    param([string]$Template)

    $segments = [System.Collections.Generic.List[string]]::new()
    foreach ($segment in ($Template -split '/')) {
        $clean = $segment.Trim().ToLowerInvariant()
        if ($clean -in $script:IgnoredSegments) { continue }
        if ($clean -match '^\{.*\}$') { continue }
        $segments.Add($clean)
    }
    return $segments.ToArray()
}

function Get-ResourceToken {
    # The text is only the lines the change added or removed, so an old route is never read.
    param([string]$Text, [string]$Relative)

    if (-not $Text) { return @() }

    $templates = @(Get-RouteTemplate -Text $Text)
    if ($templates.Count -eq 0) { return @() }

    $tokens = [System.Collections.Generic.List[string]]::new()
    foreach ($template in $templates) {
        foreach ($segment in (Split-RouteTemplate -Template $template)) { $tokens.Add($segment) }
    }

    $leaf = [IO.Path]::GetFileNameWithoutExtension($Relative)
    if ($leaf -like '*Controller') {
        $kebab = ConvertTo-KebabCase -Name $leaf
        if ($kebab) { $tokens.Add($kebab) }
    }

    return @($tokens | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-TypeToken {
    param([string]$Text)

    if (-not $Text) { return @() }
    $names = foreach ($match in [regex]::Matches($Text, $script:TypeDeclaration)) {
        if ($match.Groups[1].Value -notlike '*Controller') { $match.Groups[1].Value }
    }
    return @($names | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-SpecFile {
    param([string]$Root, [string]$Dir)

    $full = Join-Path $Root $Dir
    if (-not (Test-Path -LiteralPath $full)) { return @() }
    return @(Get-ChildItem -Path $full -Recurse -Include *.openapi.yaml, *.yaml, *.yml -File -ErrorAction SilentlyContinue)
}

$change = Get-AiSdlcChange -RepoRoot $RepoRoot -BaseRef $BaseRef -Explicit $ChangedFiles
$changed = @($change.Files)
$specFiles = Get-SpecFile -Root $RepoRoot -Dir $SpecsDir

if ($specFiles.Count -eq 0) {
    Write-Host "Spec drift: not applicable, no specs yet ($SpecsDir/ is absent or holds no YAML), so no endpoint is covered by one and nothing can drift. A spec is written when an endpoint moves, never backwards."
    exit 3
}

# A list the caller passes has no base to measure lines against, so its files count as new. A list from
# the pipeline must have a base, because judging the whole file would blame the change for old code.
$listedByCaller = [bool]$ChangedFiles
if ($env:CHANGED_FILES -and -not $listedByCaller -and (-not $change.Readable -or -not $change.Base)) {
    $why = if ($change.Reason) { $change.Reason } else { "no merge base between $BaseRef and HEAD" }
    Write-Host "Spec drift could not be checked: CHANGED_FILES is set, but the lines of the change cannot be told ($why)." -ForegroundColor Yellow
    Write-Host "FIX: Fetch the target branch with full history (for example fetch-depth: 0 in the checkout step), then run the gate again."
    exit 2
}

if ($changed.Count -eq 0) {
    Write-Host "Spec drift: not applicable, no changed files to check."
    exit 3
}

$specPrefix = "$($SpecsDir.TrimEnd('/'))/"
$specChanged = @($changed | Where-Object { $_.Replace('\', '/').StartsWith($specPrefix) })
if ($specChanged.Count -gt 0) {
    Write-Host "Spec drift: $($specChanged.Count) spec file(s) changed with the code."
    exit 0
}

$specText = @{}
foreach ($spec in $specFiles) {
    $rel = [IO.Path]::GetRelativePath($RepoRoot, $spec.FullName).Replace('\', '/')
    $specText[$rel] = (Get-Content -LiteralPath $spec.FullName -Raw -Encoding utf8)
}

$findings = [System.Collections.Generic.List[object]]::new()
foreach ($file in $changed) {
    $normalised = $file.Replace('\', '/')
    if (-not $script:SourcePrefix -or -not $normalised.StartsWith($script:SourcePrefix)) { continue }
    if ($normalised -notmatch '\.(cs|razor)$') { continue }

    $lineChange = Get-AiSdlcLineChange -RepoRoot $RepoRoot -Base $change.Base -Path $normalised -AssumeNew:$listedByCaller
    if (-not $lineChange) { continue }

    $full = Join-Path $RepoRoot $normalised
    $addedText = ''
    if ($lineChange.Added.Count -gt 0 -and (Test-Path -LiteralPath $full -PathType Leaf)) {
        $fileLines = @(Get-Content -LiteralPath $full -Encoding utf8)
        $addedText = (@($lineChange.Added | Where-Object { $_ -ge 1 -and $_ -le $fileLines.Count } | ForEach-Object { $fileLines[$_ - 1] })) -join "`n"
    }
    $changedText = (@($addedText, ($lineChange.Removed -join "`n")) | Where-Object { $_ }) -join "`n"

    foreach ($token in (Get-ResourceToken -Text $changedText -Relative $normalised)) {
        foreach ($rel in $specText.Keys) {
            if ($specText[$rel] -match ('(?i)[/"''\s:]' + [regex]::Escape($token) + '(?![a-z0-9-])')) {
                $findings.Add([pscustomobject]@{ File = $normalised; Kind = 'resource'; Token = $token; Spec = $rel })
            }
        }
    }
    foreach ($token in (Get-TypeToken -Text $changedText)) {
        foreach ($rel in $specText.Keys) {
            if ($specText[$rel] -cmatch ('(?<![A-Za-z0-9_])' + [regex]::Escape($token) + '(?![A-Za-z0-9_])')) {
                $findings.Add([pscustomobject]@{ File = $normalised; Kind = 'type'; Token = $token; Spec = $rel })
            }
        }
    }
}

$unique = @($findings | Sort-Object File, Kind, Token, Spec -Unique)
if ($unique.Count -gt 0) {
    Write-Host "Spec drift: an endpoint moved and the spec that describes it did not." -ForegroundColor Yellow
    foreach ($finding in $unique) {
        $what = if ($finding.Kind -eq 'type') { "declares the type '$($finding.Token)'" } else { "carries the resource '$($finding.Token)'" }
        Write-Host ("  {0} {1}, which {2} describes, and no spec file changed." -f $finding.File, $what, $finding.Spec)
    }
    Write-Host "FIX: Run /write-api-spec to bring the spec up to the wire shape, or say in the pull request why the contract is unchanged."
    exit 1
}

Write-Host "Spec drift OK: no changed file carries an HTTP surface that one of the $($specFiles.Count) spec(s) already describes."
exit 0
