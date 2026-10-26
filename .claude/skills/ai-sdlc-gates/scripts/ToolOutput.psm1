#Requires -Version 7
<#
.SYNOPSIS
    Culture-independent console output for the tools in this folder.

.DESCRIPTION
    A gate that prints 1.234 on one machine and 1,234 on another prints output a reviewer cannot diff
    and a test cannot match, so every number these tools report is formatted against the invariant
    culture. Seven scripts carried a byte-identical copy of this function; this is the one copy.

.PARAMETER Template
    A composite format string, for example 'read {0:N0} of {1:N0}'.

.PARAMETER Values
    The values the template formats.

.PARAMETER ForegroundColor
    Console colour, when the line is a warning or a result rather than plain output.

.EXAMPLE
    Import-Module ./ToolOutput.psm1
    Write-Invariant -Template 'checked {0:N0} page(s)' -Values @(112)

.EXAMPLE
    Write-Invariant -Template '{0:N0} finding(s)' -Values @(3) -ForegroundColor Yellow
#>

$script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture

function Write-Invariant {
    param(
        [Parameter(Mandatory)][string]$Template,
        [object[]]$Values = @(),
        [string]$ForegroundColor
    )

    $text = [string]::Format($script:Invariant, $Template, $Values)
    if ($ForegroundColor) { Write-Host $text -ForegroundColor $ForegroundColor } else { Write-Host $text }
}

Export-ModuleMember -Function Write-Invariant
