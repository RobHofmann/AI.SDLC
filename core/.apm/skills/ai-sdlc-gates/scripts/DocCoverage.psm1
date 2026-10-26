#Requires -Version 7
<#
.SYNOPSIS
    Finds the units of a repository that need a documentation page, and the pages that cover them.

.DESCRIPTION
    A unit is a part of the repository that a reader looks for by name: a .NET project, a Bicep
    building block, a package. Each pack names its units in its gates.json under "docUnits", and a
    repository can replace that list with docs.units in aisdlc.json. Each entry holds a folder glob
    and, when needed, the file a folder must hold to count:

        { "glob": "{sourceRoot}/*", "contains": ["*.csproj"], "kind": "project", "folder": "projects" }

    A token in braces is a value under "paths" in aisdlc.json. An entry whose token is empty is
    skipped, so a pack costs nothing in a repository that has none of its units.

    A page covers a unit when one of three things holds. Its front matter names the unit path under
    "unit:" or "units:". Its H1 is the unit name. Or its file name is the unit name, when both are
    read without case and without punctuation. The first form is the one to use when the page name
    and the unit name differ.

    Check-DocCoverage.ps1 (the gate) and New-DocCandidate.ps1 (the adopt-docs tool) both use
    this module, so the gate and the tool agree on what a missing page is. Get-DocUnverifiedSymbol
    lists the names a drafted page uses that its facts do not hold; Test-DocCandidate.ps1 runs it.
#>

Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1')

function ConvertTo-DocUnitKey {
    param([string]$Name)
    return ($Name -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
}

function ConvertTo-DocPageName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $text = $Name -creplace '([a-z0-9])([A-Z])', '$1-$2'
    $text = $text -replace '[^A-Za-z0-9]+', '-'
    return $text.Trim('-').ToLowerInvariant()
}

function Resolve-DocUnitGlob {
    param([string]$Glob, $Config)

    $resolved = $Glob
    foreach ($match in [regex]::Matches($Glob, '\{(?<name>[A-Za-z]+)\}')) {
        $name = $match.Groups['name'].Value
        $value = if ($Config.paths.Contains($name)) { [string](@($Config.paths[$name]) | Select-Object -First 1) } else { '' }
        if (-not $value) { return $null }
        $resolved = $resolved.Replace($match.Value, $value.Replace('\', '/').TrimEnd('/'))
    }
    return $resolved
}

function Get-DocUnitSpec {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $config = Get-AiSdlcConfig -RepoRoot $RepoRoot
    $own = @($config.docs.units | Where-Object { $_ })
    if ($own.Count -gt 0) { return , $own }
    return , @(Get-AiSdlcPackage -RepoRoot $RepoRoot | ForEach-Object { $_.DocUnits } | Where-Object { $_ })
}

function Get-DocUnit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [object[]]$Spec
    )

    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    $config = Get-AiSdlcConfig -RepoRoot $RepoRoot
    if ($null -eq $Spec) { $Spec = Get-DocUnitSpec -RepoRoot $RepoRoot }
    $excluded = @($config.docs.unitExclude | ForEach-Object { ([string]$_).Replace('\', '/').TrimEnd('/') })

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $Spec) {
        $glob = Resolve-DocUnitGlob -Glob ([string]$entry['glob']) -Config $config
        if (-not $glob) { continue }
        $full = Join-Path $RepoRoot $glob
        $folders = if ($glob -match '[*?\[]') {
            @(Get-ChildItem -Path $full -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^(\.|bin$|obj$|node_modules$)' })
        }
        elseif (Test-Path -LiteralPath $full -PathType Container) { @(Get-Item -LiteralPath $full -Force) }
        else { @() }
        foreach ($folder in ($folders | Sort-Object FullName)) {
            $rel = [IO.Path]::GetRelativePath($RepoRoot, $folder.FullName).Replace('\', '/')
            if ($excluded -contains $rel) { continue }
            if (@($entry['exclude'] | Where-Object { $folder.Name -like $_ }).Count -gt 0) { continue }
            $contains = @($entry['contains'] | Where-Object { $_ })
            if ($contains.Count -gt 0) {
                $hit = $false
                foreach ($pattern in $contains) {
                    if (Get-ChildItem -LiteralPath $folder.FullName -Filter $pattern -File -ErrorAction SilentlyContinue | Select-Object -First 1) { $hit = $true; break }
                }
                if (-not $hit) { continue }
            }
            if (-not $seen.Add($rel)) { continue }
            [pscustomobject]@{
                Path   = $rel
                Name   = $folder.Name
                Kind   = if ($entry['kind']) { [string]$entry['kind'] } else { 'unit' }
                Folder = [string]$entry['folder']
            }
        }
    }
}

function Get-DocPageUnitClaim {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $claims = [System.Collections.Generic.List[string]]::new()
    $match = [regex]::Match($Text, '\A﻿?---\r?\n(?<fm>.*?)\r?\n---\r?\n', 'Singleline')
    if ($match.Success) {
        $lines = $match.Groups['fm'].Value -split '\r?\n'
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^units?:\s*(?<value>.*)$') {
                $value = $Matches['value'].Trim()
                if ($value -match '^\[(?<list>.*)\]$') {
                    $Matches['list'] -split ',' | ForEach-Object { $claims.Add($_.Trim().Trim('"', "'")) }
                }
                elseif ($value) { $claims.Add($value.Trim('"', "'")) }
                else {
                    for ($j = $i + 1; $j -lt $lines.Count -and $lines[$j] -match '^\s+-\s*(?<item>.+)$'; $j++) {
                        $claims.Add($Matches['item'].Trim().Trim('"', "'"))
                    }
                }
            }
        }
    }
    return , @($claims | Where-Object { $_ } | ForEach-Object { $_.Replace('\', '/').TrimEnd('/') })
}

function Get-DocPage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Layer
    )

    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    $full = Join-Path $RepoRoot $Layer
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { return }
    $adr = ([string](Get-AiSdlcConfig -RepoRoot $RepoRoot).paths.adrFolder).Replace('\', '/').TrimEnd('/')
    foreach ($file in (Get-ChildItem -LiteralPath $full -Recurse -File -Filter *.md | Sort-Object FullName)) {
        $rel = [IO.Path]::GetRelativePath($RepoRoot, $file.FullName).Replace('\', '/')
        if ($adr -and $rel.StartsWith("$adr/", [StringComparison]::OrdinalIgnoreCase)) { continue }
        $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
        if ($null -eq $text) { $text = '' }
        $title = ''
        $h1 = [regex]::Match($text, '(?m)^#\s+(?<t>.+?)\s*$')
        if ($h1.Success) { $title = $h1.Groups['t'].Value.Replace('`', '').Trim() }
        [pscustomobject]@{
            Path  = $rel
            Stem  = $file.BaseName
            Title = $title
            Units = Get-DocPageUnitClaim -Text $text
        }
    }
}

function Test-DocPageCoversUnit {
    param($Page, $Unit)

    if ($Page.Units -contains $Unit.Path) { return $true }
    if ($Page.Title -and $Page.Title -ieq $Unit.Name) { return $true }
    return (ConvertTo-DocUnitKey $Page.Stem) -eq (ConvertTo-DocUnitKey $Unit.Name)
}

function Get-DocLayerFinding {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $config = Get-AiSdlcConfig -RepoRoot $RepoRoot
    foreach ($layer in @(
            [pscustomobject]@{ Name = 'technical'; Setting = 'technicalDocs'; Path = [string]$config.paths.technicalDocs },
            [pscustomobject]@{ Name = 'functional'; Setting = 'functionalDocs'; Path = [string]$config.paths.functionalDocs })) {
        if (-not $layer.Path) {
            [pscustomobject]@{ Layer = $layer.Name; Problem = "no $($layer.Name) layer: paths.$($layer.Setting) in aisdlc.json is empty" }
            continue
        }
        $full = Join-Path $RepoRoot $layer.Path
        if (-not (Test-Path -LiteralPath $full -PathType Container)) {
            [pscustomobject]@{ Layer = $layer.Name; Problem = "no $($layer.Name) layer: the folder $($layer.Path) does not exist" }
            continue
        }
        if (-not (Test-Path -LiteralPath (Join-Path $full 'index.md') -PathType Leaf)) {
            [pscustomobject]@{ Layer = $layer.Name; Problem = "the $($layer.Name) layer $($layer.Path) has no index.md" }
        }
        $pages = @(Get-ChildItem -LiteralPath $full -Recurse -File -Filter *.md | Where-Object { $_.Name -notin @('index.md', 'README.md') })
        if ($pages.Count -eq 0) {
            [pscustomobject]@{ Layer = $layer.Name; Problem = "the $($layer.Name) layer $($layer.Path) has no page besides its index" }
        }
    }
}

function Get-DocCoverage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [object[]]$Spec
    )

    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    $config = Get-AiSdlcConfig -RepoRoot $RepoRoot
    $technical = ([string]$config.paths.technicalDocs).Replace('\', '/').TrimEnd('/')
    $pages = @(if ($technical) { Get-DocPage -RepoRoot $RepoRoot -Layer $technical })
    foreach ($unit in @(Get-DocUnit -RepoRoot $RepoRoot -Spec $Spec)) {
        $covering = @($pages | Where-Object { Test-DocPageCoversUnit -Page $_ -Unit $unit })
        $folder = if ($unit.Folder) { "$technical/$($unit.Folder)" } else { $technical }
        [pscustomobject]@{
            Unit          = $unit.Path
            Name          = $unit.Name
            Kind          = $unit.Kind
            Pages         = @($covering | ForEach-Object { $_.Path })
            SuggestedPage = "$folder/$(ConvertTo-DocPageName -Name $unit.Name).md"
        }
    }
}

function Get-DocUnverifiedSymbol {
    <#
    .SYNOPSIS
        Returns the names in backticks of a drafted page that the facts do not hold.
    .DESCRIPTION
        A name is a word of three or more characters that starts with a capital letter, inside
        backticks. A name the facts hold, or that the page already names in backticks, is verified.
        The rest is returned once each, sorted, so a person checks it against the source.
    #>
    [CmdletBinding()]
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

Export-ModuleMember -Function Get-DocUnitSpec, Get-DocUnit, Get-DocPage, Get-DocPageUnitClaim, Get-DocLayerFinding, Get-DocCoverage, ConvertTo-DocPageName, Get-DocUnverifiedSymbol
