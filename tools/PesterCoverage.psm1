#Requires -Version 7
<#
.SYNOPSIS
    Code coverage of the Pester runs, written as a SonarCloud generic coverage file.

.DESCRIPTION
    tools/Invoke-PesterParallel.ps1 -CoverageFile uses this module. Each test file runs in its own process,
    and that process measures the scripts and modules in the folder of the test file. Pester lists every
    command it ran and every command it missed, with the file and the line. This module turns those into
    lines, merges the lines of all processes, and writes the XML that SonarCloud reads through
    sonar.coverageReportPaths.

    A line is covered when one command on it ran in any test file. A script that a test starts in a child
    pwsh is not measured: Pester sees only its own process.
#>

$ErrorActionPreference = 'Stop'

function Get-CoverageTarget {
    <#
    .SYNOPSIS
        The scripts and modules in the folder of a test file, without the test files and the test
        harness modules (*TestHarness.psm1), which SonarCloud reads as test code.
    #>
    param([Parameter(Mandatory)][string]$TestFile)
    $folder = Split-Path -Parent $TestFile
    @(Get-ChildItem -LiteralPath $folder -File -Force |
        Where-Object { $_.Extension -in '.ps1', '.psm1' -and $_.Name -notlike '*.Tests.ps1' -and $_.Name -notlike '*TestHarness.psm1' } |
        Sort-Object Name |
        ForEach-Object FullName)
}

function ConvertTo-CoverageLine {
    <#
    .SYNOPSIS
        One object per file and line from the CodeCoverage result of Invoke-Pester, with its path
        relative to the repository root and whether a command on it ran.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()]$CodeCoverage,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    if (-not $CodeCoverage) { return @() }
    $commands = @(
        @($CodeCoverage.CommandsExecuted) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ File = $_.File; Line = [int]$_.Line; Covered = $true } }
        @($CodeCoverage.CommandsMissed) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ File = $_.File; Line = [int]$_.Line; Covered = $false } }
    )
    $relative = @(foreach ($c in $commands) {
            [pscustomobject]@{ File = [IO.Path]::GetRelativePath($RepoRoot, $c.File).Replace('\', '/'); Line = $c.Line; Covered = $c.Covered }
        })
    Merge-CoverageLine -Line $relative
}

function Merge-CoverageLine {
    <#
    .SYNOPSIS
        One object per file and line: covered when any of the given objects for that line is covered.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Line)
    @($Line | Group-Object { "$($_.File)`n$($_.Line)" } | ForEach-Object {
            $first = $_.Group[0]
            [pscustomobject]@{ File = $first.File; Line = [int]$first.Line; Covered = [bool](@($_.Group | Where-Object Covered).Count) }
        } | Sort-Object File, Line)
}

function ConvertTo-SonarCoverageXml {
    <#
    .SYNOPSIS
        The SonarCloud generic coverage XML for the given lines, one <file> per path.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Line)
    $settings = [Xml.XmlWriterSettings]::new()
    $settings.Indent = $true
    $settings.OmitXmlDeclaration = $true
    $settings.NewLineChars = "`n"
    $text = [Text.StringBuilder]::new()
    $writer = [Xml.XmlWriter]::Create($text, $settings)
    $writer.WriteStartElement('coverage')
    $writer.WriteAttributeString('version', '1')
    foreach ($file in ($Line | Group-Object File | Sort-Object Name)) {
        $writer.WriteStartElement('file')
        $writer.WriteAttributeString('path', $file.Name)
        foreach ($l in ($file.Group | Sort-Object Line)) {
            $writer.WriteStartElement('lineToCover')
            $writer.WriteAttributeString('lineNumber', [string]$l.Line)
            $writer.WriteAttributeString('covered', $(if ($l.Covered) { 'true' } else { 'false' }))
            $writer.WriteEndElement()
        }
        $writer.WriteEndElement()
    }
    $writer.WriteEndElement()
    $writer.Flush()
    $writer.Dispose()
    return "$($text.ToString())`n"
}

Export-ModuleMember -Function Get-CoverageTarget, ConvertTo-CoverageLine, Merge-CoverageLine, ConvertTo-SonarCoverageXml
