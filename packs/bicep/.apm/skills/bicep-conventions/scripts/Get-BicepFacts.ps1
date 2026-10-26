#Requires -Version 7
<#
.SYNOPSIS
    Reads what a Bicep building block deploys: the scope, the parameters, the outputs, the resource
    types and the modules it calls. The documentation tools send these facts to the model.

.DESCRIPTION
    The code graph reads no Bicep, so a Bicep repository has no graph to draft a page from. This script
    gives it the same kind of facts, read from the templates and not guessed. It builds each .bicep
    file of the unit with the Bicep CLI (or az bicep) into a temporary file, never to stdout, the same
    way Invoke-BicepPreflight.ps1 does, and reads the compiled ARM template:

      - the target scope, from the template schema;
      - each parameter with its type, whether it has a default, and its @description; a parameter of
        a user-defined type carries the name of that type;
      - each output with its type and its @description;
      - each resource type with its API version, and how often it appears;
      - each module the template calls, read from the Bicep source, because the compiled template
        holds a nested deployment and not the path.

    A template that does not build is read from its source instead, and the facts say so. Other files
    in the unit are listed by name; a PowerShell script also gives the first line of its .SYNOPSIS.

    New-DocCandidate.ps1 in the adopt-docs skill runs this script as the facts source of the
    bicep pack (docFacts in gates.json). It sends nothing anywhere itself.

.PARAMETER Unit
    The building block folder, or one .bicep file, relative to RepoRoot.

.PARAMETER RepoRoot
    The repository root. Defaults to the folder that holds aisdlc.json.

.PARAMETER AsObject
    Return one object per template instead of the fact lines.

.PARAMETER Builder
    Test seam: a scriptblock that takes a template path and returns the compiled ARM JSON as a string,
    or $null when the template does not build.

.EXAMPLE
    pwsh .claude/skills/bicep-conventions/scripts/Get-BicepFacts.ps1 -Unit building-blocks/vwan-infra
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Unit,
    [string]$RepoRoot,
    [switch]$AsObject,
    [scriptblock]$Builder
)

$ErrorActionPreference = 'Stop'
$gates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $gates)) { $gates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $gates 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$target = Join-Path $RepoRoot $Unit
if (-not (Test-Path -LiteralPath $target)) { throw "Get-BicepFacts: '$Unit' does not exist under $RepoRoot." }
$targetFull = (Resolve-Path -LiteralPath $target).Path
if (-not $targetFull.StartsWith($RepoRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "Get-BicepFacts: '$Unit' resolves outside the repository." }

if (-not $Builder) {
    $outFile = Join-Path ([IO.Path]::GetTempPath()) ('bicep-facts-' + [guid]::NewGuid().ToString('n') + '.json')
    $tool = if (Get-Command bicep -ErrorAction SilentlyContinue) { 'bicep' } elseif (Get-Command az -ErrorAction SilentlyContinue) { 'az' } else { $null }
    $Builder = {
        param($Path)
        if (-not $tool) { return $null }
        if ($tool -eq 'bicep') { bicep build $Path --outfile $outFile *> $null } else { az bicep build --file $Path --outfile $outFile *> $null }
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $outFile)) { return $null }
        $json = Get-Content -LiteralPath $outFile -Raw -Encoding utf8
        Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
        return $json
    }.GetNewClosure()
}

function Get-TemplateScope {
    param([string]$Schema)
    switch -Regex ($Schema) {
        'tenantDeploymentTemplate' { return 'tenant' }
        'managementGroupDeploymentTemplate' { return 'managementGroup' }
        'subscriptionDeploymentTemplate' { return 'subscription' }
        'deploymentTemplate' { return 'resourceGroup' }
        default { return 'unknown' }
    }
}

function Get-TemplateTypeName {
    param($Declaration)
    if ($Declaration.type) { return [string]$Declaration.type }
    if ($Declaration.Contains('$ref')) { return ([string]$Declaration['$ref'] -split '/')[-1] }
    return 'object'
}

function Get-ResourceList {
    param($Resources)
    if ($null -eq $Resources) { return @() }
    if ($Resources -is [System.Collections.IDictionary]) { return @($Resources.Values) }
    return @($Resources)
}

function Get-TemplateResourceType {
    param($Resources)
    foreach ($resource in (Get-ResourceList $Resources)) {
        if ($resource.existing) { continue }
        "$($resource.type)@$($resource.apiVersion)"
        if ($resource.type -eq 'Microsoft.Resources/deployments' -and $resource.properties.template) {
            Get-TemplateResourceType $resource.properties.template.resources
        }
    }
}

function Read-BicepSource {
    param([string]$Text)

    $modules = @([regex]::Matches($Text, "(?m)^\s*module\s+\w+\s+'(?<path>[^']+)'") | ForEach-Object { $_.Groups['path'].Value } | Sort-Object -Unique)
    $scope = [regex]::Match($Text, "(?m)^\s*targetScope\s*=\s*'(?<s>\w+)'")
    $params = foreach ($match in [regex]::Matches($Text, "(?m)(?:^\s*@description\('(?<d>[^']*)'\)\s*\r?\n)?^\s*param\s+(?<n>\w+)\s+(?<t>[\w.]+)(?<def>\s*=)?")) {
        [pscustomobject]@{ Name = $match.Groups['n'].Value; Type = $match.Groups['t'].Value; HasDefault = $match.Groups['def'].Success; Description = $match.Groups['d'].Value }
    }
    $outputs = foreach ($match in [regex]::Matches($Text, "(?m)(?:^\s*@description\('(?<d>[^']*)'\)\s*\r?\n)?^\s*output\s+(?<n>\w+)\s+(?<t>[\w.]+)")) {
        [pscustomobject]@{ Name = $match.Groups['n'].Value; Type = $match.Groups['t'].Value; Description = $match.Groups['d'].Value }
    }
    $types = @([regex]::Matches($Text, "(?m)^\s*resource\s+\w+\s+'(?<t>[^']+)'(?!\s+existing)") | ForEach-Object { $_.Groups['t'].Value })
    return [pscustomobject]@{
        Scope   = if ($scope.Success) { $scope.Groups['s'].Value } else { 'resourceGroup' }
        Params  = @($params)
        Outputs = @($outputs)
        Types   = $types
        Modules = $modules
    }
}

function Read-Template {
    param([System.IO.FileInfo]$File)

    $source = Get-Content -LiteralPath $File.FullName -Raw -Encoding utf8
    if ($null -eq $source) { $source = '' }
    $fromSource = Read-BicepSource -Text $source
    $json = & $Builder $File.FullName
    $rel = [IO.Path]::GetRelativePath($RepoRoot, $File.FullName).Replace('\', '/')

    if (-not $json) {
        return [pscustomobject]@{
            File = $rel; ReadFrom = 'source (it did not build here)'; Scope = $fromSource.Scope
            Parameters = $fromSource.Params; Outputs = $fromSource.Outputs; ResourceTypes = @($fromSource.Types); Modules = $fromSource.Modules
        }
    }

    $arm = $json | ConvertFrom-Json -AsHashtable
    $parameters = foreach ($name in @($arm.parameters.Keys | Sort-Object)) {
        $p = $arm.parameters[$name]
        [pscustomobject]@{ Name = $name; Type = Get-TemplateTypeName $p; HasDefault = $p.Contains('defaultValue'); Description = [string]$p.metadata.description }
    }
    $outputs = foreach ($name in @($arm.outputs.Keys | Sort-Object)) {
        $o = $arm.outputs[$name]
        [pscustomobject]@{ Name = $name; Type = Get-TemplateTypeName $o; Description = [string]$o.metadata.description }
    }
    return [pscustomobject]@{
        File = $rel; ReadFrom = 'the compiled template'; Scope = Get-TemplateScope ([string]$arm['$schema'])
        Parameters = @($parameters); Outputs = @($outputs)
        ResourceTypes = @(Get-TemplateResourceType $arm.resources | Where-Object { $_ -notlike 'Microsoft.Resources/deployments@*' })
        Modules = $fromSource.Modules
    }
}

$files = if (Test-Path -LiteralPath $targetFull -PathType Leaf) { @(Get-Item -LiteralPath $targetFull) } else { @(Get-ChildItem -LiteralPath $targetFull -Recurse -File | Sort-Object FullName) }
$templates = @($files | Where-Object { $_.Extension -eq '.bicep' } | ForEach-Object { Read-Template -File $_ })
$others = @($files | Where-Object { $_.Extension -ne '.bicep' })

if ($AsObject) { return $templates }

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("UNIT: $Unit")
foreach ($t in $templates) {
    $lines.Add('')
    $lines.Add("TEMPLATE: $($t.File) (scope: $($t.Scope); read from $($t.ReadFrom))")
    foreach ($p in $t.Parameters) {
        $default = if ($p.HasDefault) { ', has a default' } else { ', required' }
        $description = if ($p.Description) { " - $($p.Description)" } else { '' }
        $lines.Add("  param $($p.Name): $($p.Type)$default$description")
    }
    foreach ($o in $t.Outputs) {
        $description = if ($o.Description) { " - $($o.Description)" } else { '' }
        $lines.Add("  output $($o.Name): $($o.Type)$description")
    }
    foreach ($group in ($t.ResourceTypes | Group-Object | Sort-Object Name)) {
        $count = if ($group.Count -gt 1) { " (x$($group.Count))" } else { '' }
        $lines.Add("  deploys $($group.Name)$count")
    }
    foreach ($module in $t.Modules) { $lines.Add("  calls module $module") }
}
if ($others.Count -gt 0) {
    $lines.Add('')
    $lines.Add('OTHER FILES:')
    foreach ($file in $others) {
        $rel = [IO.Path]::GetRelativePath($RepoRoot, $file.FullName).Replace('\', '/')
        $synopsis = ''
        if ($file.Extension -eq '.ps1') {
            $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
            $match = [regex]::Match([string]$text, '(?s)\.SYNOPSIS\s*\r?\n\s*(?<s>[^\r\n]+)')
            if ($match.Success) { $synopsis = " - $($match.Groups['s'].Value.Trim())" }
        }
        $lines.Add("  $rel$synopsis")
    }
}
return $lines.ToArray()
