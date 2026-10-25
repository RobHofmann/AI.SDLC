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

      1. A changed .cs or .razor file under the source root (paths.sourceRoot in aisdlc.json) is read for an HTTP surface: a [Route(...)],
         an [HttpGet/Post/Put/Patch/Delete(...)] attribute, or a minimal-API Map* call.
      2. Its resource tokens are the literal segments of its route templates (api, v1, and the
         [controller] and [action] tokens are dropped), plus the kebab-case form of a *Controller
         class name (OrderLinesController -> order-lines).
      3. A spec under specs/ that contains one of those tokens covers that file. If no file under
         specs/ changed in the same diff, that is the finding.

    ADVISORY for now: exit 1 is a warning, not a block. A controller can change in a way the wire
    shape does not see, for example a log line or an injected service, and this gate cannot tell that
    apart. Turn it blocking once the team has seen how often that happens.

    Exit 0 clean or nothing to check, 1 a finding.

.PARAMETER RepoRoot
    Repository root that holds the source root and, when there are specs, the specs folder. Defaults to
    the folder that holds aisdlc.json, found from this script.

.PARAMETER BaseRef
    The ref the change is measured against when no explicit file list is given. Defaults to origin/main.

.PARAMETER ChangedFiles
    Explicit repository-relative paths, bypassing git. Falls back to the newline-separated
    CHANGED_FILES environment variable, which the pipeline sets from the pull request diff.

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
    [string]$BaseRef = 'origin/main',
    [string[]]$ChangedFiles,
    [string]$SpecsDir
)

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }
$aiSdlc = Get-AiSdlcConfig -RepoRoot $RepoRoot
if (-not $SpecsDir) { $SpecsDir = $aiSdlc.paths.specsRoot }
$script:SourcePrefix = if ($aiSdlc.paths.sourceRoot) { ([string]$aiSdlc.paths.sourceRoot).TrimEnd('/') + '/' } else { $null }

$ErrorActionPreference = 'Stop'

$script:RouteAttribute = '\[\s*(?:Route|Http(?:Get|Post|Put|Patch|Delete|Head|Options))\s*\(\s*"([^"]*)"'
$script:MinimalApi = '\.Map(?:Get|Post|Put|Patch|Delete)\s*\(\s*"([^"]*)"'
$script:IgnoredSegments = @('api', 'v1', 'v2', '[controller]', '[action]', '')

function Get-ChangedFileList {
    param([string]$Root, [string]$Base, [string[]]$Explicit)

    if ($Explicit) { return $Explicit }
    if ($env:CHANGED_FILES) { return @($env:CHANGED_FILES -split "`r?`n" | Where-Object { $_.Trim() }) }

    Push-Location $Root
    try {
        $mergeBase = & git merge-base $Base HEAD 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $mergeBase) { return @() }
        $tracked = & git diff --name-only $mergeBase HEAD 2>$null
        $staged = & git diff --name-only --cached 2>$null
        $working = & git diff --name-only 2>$null
        return @($tracked) + @($staged) + @($working) | Where-Object { $_ } | Sort-Object -Unique
    }
    finally { Pop-Location }
}

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
    param([string]$FullPath, [string]$Relative)

    $text = Get-Content -LiteralPath $FullPath -Raw -Encoding utf8
    if (-not $text) { return @() }

    $templates = @(Get-RouteTemplate -Text $text)
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

function Get-SpecFile {
    param([string]$Root, [string]$Dir)

    $full = Join-Path $Root $Dir
    if (-not (Test-Path -LiteralPath $full)) { return @() }
    return @(Get-ChildItem -Path $full -Recurse -Include *.openapi.yaml, *.yaml, *.yml -File -ErrorAction SilentlyContinue)
}

$changed = @(Get-ChangedFileList -Root $RepoRoot -Base $BaseRef -Explicit $ChangedFiles)
$specFiles = Get-SpecFile -Root $RepoRoot -Dir $SpecsDir

if ($specFiles.Count -eq 0) {
    Write-Host "Spec drift: no specs yet ($SpecsDir/ is absent or holds no YAML), so no endpoint is covered by one and nothing can drift. A spec is written when an endpoint moves, never backwards."
    exit 0
}

if ($changed.Count -eq 0) {
    Write-Host "Spec drift: no changed files to check."
    exit 0
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

    $full = Join-Path $RepoRoot $normalised
    if (-not (Test-Path -LiteralPath $full)) { continue }

    foreach ($token in (Get-ResourceToken -FullPath $full -Relative $normalised)) {
        foreach ($rel in $specText.Keys) {
            if ($specText[$rel] -match ('(?i)[/"''\s:]' + [regex]::Escape($token) + '(?![a-z0-9-])')) {
                $findings.Add([pscustomobject]@{ File = $normalised; Token = $token; Spec = $rel })
            }
        }
    }
}

$unique = @($findings | Sort-Object File, Spec -Unique)
if ($unique.Count -gt 0) {
    Write-Host "Spec drift: an endpoint moved and the spec that describes it did not." -ForegroundColor Yellow
    foreach ($finding in $unique) {
        Write-Host ("  {0} carries the resource '{1}', which {2} describes, and no spec file changed." -f $finding.File, $finding.Token, $finding.Spec)
    }
    Write-Host "FIX: Run /write-api-spec to bring the spec up to the wire shape, or say in the pull request why the contract is unchanged."
    Write-Output "::warning::Spec drift: $($unique.Count) changed file(s) with an HTTP surface a spec already describes, while no spec changed. Update the spec in the same change."
    exit 1
}

Write-Host "Spec drift OK: no changed file carries an HTTP surface that one of the $($specFiles.Count) spec(s) already describes."
exit 0
