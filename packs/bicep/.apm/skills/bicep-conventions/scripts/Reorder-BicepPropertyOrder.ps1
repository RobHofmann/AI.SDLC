#requires -Version 7.4

<#
.SYNOPSIS
Reorders top-level declarations and resource/module body properties in Bicep files.

.DESCRIPTION
By default, this script runs in dry-run mode and reports which files would change.
Use -Apply to write the reordered content back to disk.

.EXAMPLE
./.claude/skills/bicep-conventions/scripts/Reorder-BicepPropertyOrder.ps1 -Path ./infra
Runs a dry run across all .bicep files under ./infra.

.EXAMPLE
./.claude/skills/bicep-conventions/scripts/Reorder-BicepPropertyOrder.ps1 -Path ./infra -Apply
Applies the reordering changes to files.

.EXAMPLE
./.claude/skills/bicep-conventions/scripts/Reorder-BicepPropertyOrder.ps1 -Path ./infra/modules -Include "*.bicep", "*.bicepparam"
Runs on a specific folder and file patterns.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Path = ".",

    [Parameter()]
    [switch]$Apply,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$Include = @("*.bicep")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LineWithEndingRegex = [System.Text.RegularExpressions.Regex]::new('.*(?:\r\n|\n|$)', [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:TopLevelKeywordRegex = [System.Text.RegularExpressions.Regex]::new('^(targetScope|metadata|param|func|var|resource|module|output)\b', [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:PropertyRegex = [System.Text.RegularExpressions.Regex]::new('^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:', [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:InnerResourceRegex = [System.Text.RegularExpressions.Regex]::new('^\s*resource\s+', [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:ModuleOrResourceRegex = [System.Text.RegularExpressions.Regex]::new('^\s*(module|resource)\b', [System.Text.RegularExpressions.RegexOptions]::Compiled -bor [System.Text.RegularExpressions.RegexOptions]::Multiline)
$script:DecoratorRegex = [System.Text.RegularExpressions.Regex]::new('^@', [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:ExistingResourceRegex = [System.Text.RegularExpressions.Regex]::new('\bexisting\b', [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:PreferredFileOrder = @('targetScope', 'metadata', 'param', 'var', 'func', 'resource_existing', 'deployable', 'output')
$script:PreferredModuleBodyOrder = @('scope', 'name', 'params')
$script:PreferredResourceBodyOrder = @('parent', 'scope', 'name', 'location', 'extendedLocation', 'zones', 'sku', 'kind', 'scale', 'plan', 'identity', 'dependsOn', 'tags', 'properties')

function Get-LineEnding {
    param([string]$Text)

    if ($Text.Contains("`r`n")) {
        return "`r`n"
    }

    return "`n"
}

function Get-CodeOnlyText {
    param([string]$Text)

    $sb = [System.Text.StringBuilder]::new()
    $inString = $false
    $inBlockComment = $false

    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        $next = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }

        if ($inBlockComment) {
            if ($c -eq '*' -and $next -eq '/') {
                $inBlockComment = $false
                $i++
            }
            continue
        }

        if (-not $inString -and $c -eq '/' -and $next -eq '*') {
            $inBlockComment = $true
            $i++
            continue
        }

        if (-not $inString -and $c -eq '/' -and $next -eq '/') {
            break
        }

        if ($c -eq "'") {
            if ($inString) {
                if ($next -eq "'") {
                    $i++
                    continue
                }

                $inString = $false
                continue
            }

            $inString = $true
            continue
        }

        if (-not $inString) {
            [void]$sb.Append($c)
        }
    }

    return $sb.ToString()
}

function Get-LinesWithEndings {
    param([string]$Text)

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($match in $script:LineWithEndingRegex.Matches($Text)) {
        if ($match.Value.Length -gt 0) {
            $lines.Add($match.Value)
        }
    }

    return $lines
}

function Get-BraceDepthDelta {
    param([string]$CodeOnly)

    $delta = 0
    for ($i = 0; $i -lt $CodeOnly.Length; $i++) {
        $ch = $CodeOnly[$i]
        if ($ch -eq '{') {
            $delta++
        }
        elseif ($ch -eq '}') {
            $delta--
        }
    }

    return $delta
}

function Get-OrderedSegments {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IEnumerable]$Segments,
        [Parameter(Mandatory = $true)]
        [string[]]$PreferredOrder,
        [Parameter(Mandatory = $true)]
        [string]$NameProperty
    )

    $segmentList = [System.Collections.Generic.List[object]]::new()
    foreach ($segment in $Segments) {
        $segmentList.Add($segment)
    }

    $used = [System.Collections.Generic.HashSet[int]]::new()
    $ordered = [System.Collections.Generic.List[object]]::new()

    foreach ($name in $PreferredOrder) {
        for ($i = 0; $i -lt $segmentList.Count; $i++) {
            if ($used.Contains($i)) {
                continue
            }

            if ($segmentList[$i].$NameProperty -eq $name) {
                [void]$used.Add($i)
                [void]$ordered.Add($segmentList[$i])
            }
        }
    }

    for ($i = 0; $i -lt $segmentList.Count; $i++) {
        if (-not $used.Contains($i)) {
            [void]$ordered.Add($segmentList[$i])
        }
    }

    return $ordered
}

function Add-BodySegment {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Segments,
        [Parameter(Mandatory = $true)]
        [ref]$CurrentName,
        [Parameter(Mandatory = $true)]
        [ref]$CurrentText
    )

    if ($null -eq $CurrentName.Value) {
        return
    }

    $Segments.Add([pscustomobject]@{
            Name = $CurrentName.Value
            Text = $CurrentText.Value.ToString()
        })

    $CurrentName.Value = $null
    $CurrentText.Value = [System.Text.StringBuilder]::new()
}

function Find-NextOpeningBrace {
    param(
        [string]$Text,
        [int]$StartIndex
    )

    $inString = $false
    $inBlockComment = $false

    for ($i = $StartIndex; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        $next = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }

        if ($inBlockComment) {
            if ($c -eq '*' -and $next -eq '/') {
                $inBlockComment = $false
                $i++
            }
            continue
        }

        if (-not $inString -and $c -eq '/' -and $next -eq '*') {
            $inBlockComment = $true
            $i++
            continue
        }

        if (-not $inString -and $c -eq '/' -and $next -eq '/') {
            while ($i -lt $Text.Length -and $Text[$i] -ne "`n") {
                $i++
            }
            continue
        }

        if ($c -eq "'") {
            if ($inString) {
                if ($next -eq "'") {
                    $i++
                    continue
                }

                $inString = $false
                continue
            }

            $inString = $true
            continue
        }

        if (-not $inString -and $c -eq '{') {
            return $i
        }
    }

    return -1
}

function Find-MatchingBrace {
    param(
        [string]$Text,
        [int]$OpenBraceIndex
    )

    $depth = 0
    $inString = $false
    $inBlockComment = $false

    for ($i = $OpenBraceIndex; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        $next = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }

        if ($inBlockComment) {
            if ($c -eq '*' -and $next -eq '/') {
                $inBlockComment = $false
                $i++
            }
            continue
        }

        if (-not $inString -and $c -eq '/' -and $next -eq '*') {
            $inBlockComment = $true
            $i++
            continue
        }

        if (-not $inString -and $c -eq '/' -and $next -eq '/') {
            while ($i -lt $Text.Length -and $Text[$i] -ne "`n") {
                $i++
            }
            continue
        }

        if ($c -eq "'") {
            if ($inString) {
                if ($next -eq "'") {
                    $i++
                    continue
                }

                $inString = $false
                continue
            }

            $inString = $true
            continue
        }

        if (-not $inString) {
            if ($c -eq '{') {
                $depth++
            }
            elseif ($c -eq '}') {
                $depth--
                if ($depth -eq 0) {
                    return $i
                }
            }
        }
    }

    return -1
}

function Get-BicepFileDeclarations {
    param([string]$Text)

    $lines = Get-LinesWithEndings -Text $Text

    $depth = 0
    $declarations = [System.Collections.Generic.List[object]]::new()
    $pendingLines = [System.Text.StringBuilder]::new()
    $currentType = $null
    $currentText = [System.Text.StringBuilder]::new()
    $headerText = [System.Text.StringBuilder]::new()
    $inDeclaration = $false
    $inPreamble = $false

    foreach ($line in $lines) {
        $trimmed = $line.TrimEnd("`r", "`n").Trim()
        $codeOnly = Get-CodeOnlyText -Text $line

        if (-not $inDeclaration) {
            $isBlank = ($trimmed -eq '')
            $isDecorator = $script:DecoratorRegex.IsMatch($trimmed)
            $keywordMatch = $script:TopLevelKeywordRegex.Match($trimmed)

            if ($isBlank) {
                [void]$pendingLines.Append($line)
            }
            elseif ($isDecorator) {
                $inPreamble = $true
                [void]$pendingLines.Append($line)
            }
            elseif ($keywordMatch.Success) {
                $keyword = $keywordMatch.Groups[1].Value
                $type = $keyword
                if ($keyword -eq 'resource') {
                    if ($script:ExistingResourceRegex.IsMatch($trimmed)) {
                        $type = 'resource_existing'
                    }
                    else {
                        $type = 'deployable'
                    }
                }
                elseif ($keyword -eq 'module') {
                    $type = 'deployable'
                }

                if ($declarations.Count -eq 0 -and -not $inPreamble) {
                    [void]$headerText.Append($pendingLines.ToString())
                    $pendingLines = [System.Text.StringBuilder]::new()
                }

                $currentType = $type
                [void]$currentText.Append($pendingLines.ToString())
                $pendingLines = [System.Text.StringBuilder]::new()
                $inPreamble = $false
                [void]$currentText.Append($line)
                $inDeclaration = $true
            }
            else {
                if ($declarations.Count -eq 0 -and -not $inPreamble) {
                    [void]$headerText.Append($pendingLines.ToString())
                    $pendingLines = [System.Text.StringBuilder]::new()
                    [void]$headerText.Append($line)
                }
                else {
                    [void]$pendingLines.Append($line)
                }
            }
        }
        else {
            [void]$currentText.Append($line)
        }

        $depth += Get-BraceDepthDelta -CodeOnly $codeOnly

        if ($inDeclaration -and $depth -eq 0) {
            $declarations.Add([pscustomobject]@{
                    Type = $currentType
                    Text = $currentText.ToString()
                })
            $currentText = [System.Text.StringBuilder]::new()
            $currentType = $null
            $inDeclaration = $false
        }
    }

    return [pscustomobject]@{
        Header       = $headerText.ToString()
        Declarations = $declarations
        Trailing     = $pendingLines.ToString()
    }
}

function Test-FileNameIncluded {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName,
        [Parameter(Mandatory = $true)]
        [string[]]$Patterns
    )

    foreach ($pattern in $Patterns) {
        if ($FileName -like $pattern) {
            return $true
        }
    }

    return $false
}

function Get-FilteredBicepFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [string[]]$Patterns
    )

    return @(Get-ChildItem -LiteralPath $RootPath -Recurse -File |
        Where-Object {
            Test-FileNameIncluded -FileName $_.Name -Patterns $Patterns
        } |
        Sort-Object -Property FullName)
}

function Reorder-FileDeclarations {
    param([string]$Text)

    $parsed = Get-BicepFileDeclarations -Text $Text
    $declarations = $parsed.Declarations

    if ($declarations.Count -le 1) {
        return [pscustomobject]@{
            Text    = $Text
            Changed = $false
        }
    }

    $ordered = Get-OrderedSegments -Segments $declarations -PreferredOrder $script:PreferredFileOrder -NameProperty 'Type'

    $rebuilt = [System.Text.StringBuilder]::new()
    [void]$rebuilt.Append($parsed.Header)
    foreach ($decl in $ordered) {
        [void]$rebuilt.Append($decl.Text)
    }
    [void]$rebuilt.Append($parsed.Trailing)

    $newText = $rebuilt.ToString()
    return [pscustomobject]@{
        Text    = $newText
        Changed = ($newText -ne $Text)
    }
}

function Reorder-DeclarationBody {
    param(
        [string]$Body,
        [ValidateSet('module', 'resource')]
        [string]$Kind
    )

    $preferredOrder = if ($Kind -eq 'module') { $script:PreferredModuleBodyOrder } else { $script:PreferredResourceBodyOrder }

    $lines = Get-LinesWithEndings -Text $Body

    $depth = 0
    $preamble = [System.Text.StringBuilder]::new()
    $segments = [System.Collections.Generic.List[object]]::new()
    $currentName = $null
    $currentText = [System.Text.StringBuilder]::new()

    foreach ($line in $lines) {
        if ($depth -eq 0) {
            $propertyMatch = $script:PropertyRegex.Match($line)
            $innerResourceMatch = $script:InnerResourceRegex.Match($line)
            if ($propertyMatch.Success) {
                Add-BodySegment -Segments $segments -CurrentName ([ref]$currentName) -CurrentText ([ref]$currentText)
                $currentName = $propertyMatch.Groups[1].Value
                [void]$currentText.Append($line)
            }
            elseif ($innerResourceMatch.Success) {
                Add-BodySegment -Segments $segments -CurrentName ([ref]$currentName) -CurrentText ([ref]$currentText)
                $currentName = '__innerResource__'
                [void]$currentText.Append($line)
            }
            else {
                if ($null -ne $currentName) {
                    [void]$currentText.Append($line)
                }
                else {
                    [void]$preamble.Append($line)
                }
            }
        }
        else {
            if ($null -ne $currentName) {
                [void]$currentText.Append($line)
            }
            else {
                [void]$preamble.Append($line)
            }
        }

        $codeOnly = Get-CodeOnlyText -Text $line
        $depth += Get-BraceDepthDelta -CodeOnly $codeOnly
    }

    Add-BodySegment -Segments $segments -CurrentName ([ref]$currentName) -CurrentText ([ref]$currentText)

    if ($segments.Count -eq 0) {
        return [pscustomobject]@{
            Body = $Body
            Changed = $false
        }
    }

    $ordered = Get-OrderedSegments -Segments $segments -PreferredOrder $preferredOrder -NameProperty 'Name'

    $rebuilt = [System.Text.StringBuilder]::new()
    [void]$rebuilt.Append($preamble.ToString())
    foreach ($segment in $ordered) {
        [void]$rebuilt.Append($segment.Text)
    }

    $newBody = $rebuilt.ToString()

    return [pscustomobject]@{
        Body = $newBody
        Changed = ($newBody -ne $Body)
    }
}

function Process-BicepText {
    param([string]$Text)

    $working = $Text
    $reorderedDeclarations = 0

    $fileResult = Reorder-FileDeclarations -Text $working
    if ($fileResult.Changed) {
        $working = $fileResult.Text
        $reorderedDeclarations++
    }

    $bodyMatches = $script:ModuleOrResourceRegex.Matches($working)

    for ($m = $bodyMatches.Count - 1; $m -ge 0; $m--) {
        $match = $bodyMatches[$m]
        $kind = $match.Groups[1].Value

        $openBrace = Find-NextOpeningBrace -Text $working -StartIndex $match.Index
        if ($openBrace -lt 0) {
            continue
        }

        $closeBrace = Find-MatchingBrace -Text $working -OpenBraceIndex $openBrace
        if ($closeBrace -lt 0) {
            continue
        }

        $bodyStart = $openBrace + 1
        $bodyLength = $closeBrace - $bodyStart
        $body = if ($bodyLength -gt 0) { $working.Substring($bodyStart, $bodyLength) } else { '' }

        $reorderResult = Reorder-DeclarationBody -Body $body -Kind $kind
        if ($reorderResult.Changed) {
            $working = $working.Remove($bodyStart, $bodyLength).Insert($bodyStart, $reorderResult.Body)
            $reorderedDeclarations++
        }
    }

    return [pscustomobject]@{
        Text = $working
        Changed = ($working -ne $Text)
        ReorderedDeclarations = $reorderedDeclarations
    }
}

if (-not (Test-Path -LiteralPath $Path)) {
    throw "Path '$Path' was not found."
}

$allFiles = @(Get-FilteredBicepFiles -RootPath $Path -Patterns $Include)

if ($allFiles.Count -eq 0) {
    Write-Host "No matching files found under '$Path'."
    exit 0
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$totalChangedFiles = 0
$totalReorderedDeclarations = 0

foreach ($file in $allFiles) {
    $original = [System.IO.File]::ReadAllText($file.FullName)
    $lineEnding = Get-LineEnding -Text $original

    $result = Process-BicepText -Text $original
    if (-not $result.Changed) {
        continue
    }

    $outputText = $result.Text
    if ($lineEnding -eq "`r`n") {
        $outputText = $outputText -replace "(?<!`r)`n", "`r`n"
    }

    if ($Apply) {
        [System.IO.File]::WriteAllText($file.FullName, $outputText, $utf8NoBom)
        Write-Host "Updated: $($file.FullName) (reordered declarations: $($result.ReorderedDeclarations))"
    }
    else {
        Write-Host "Would update: $($file.FullName) (reordered declarations: $($result.ReorderedDeclarations))"
    }

    $totalChangedFiles++
    $totalReorderedDeclarations += $result.ReorderedDeclarations
}

if ($Apply) {
    Write-Host "Done. Files updated: $totalChangedFiles. Declarations reordered: $totalReorderedDeclarations."
}
else {
    Write-Host "Dry run complete. Files that would be updated: $totalChangedFiles. Declarations to reorder: $totalReorderedDeclarations."
    Write-Host "Run with -Apply to write changes."
}
