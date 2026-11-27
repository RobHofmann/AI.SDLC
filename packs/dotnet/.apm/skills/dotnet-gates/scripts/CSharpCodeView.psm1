#Requires -Version 7
<#
.SYNOPSIS
    Reads C# source as code only: a string, a comment and a path filter that the gates of this skill share.

.DESCRIPTION
    Get-CodeView takes the lines of a C# file and gives one line back for each line in. The text of a
    string literal, also a raw or verbatim string over several lines, becomes an empty string. The text
    of a block comment, also over several lines, is removed. A line comment stays, because a gate may read
    a marker in it. So a gate that looks for a name or a brace in the code never matches text in a string
    or in a block comment, and the line numbers stay the same.

    Test-CheckedPath tells whether a repo-relative path is a C# file that a gate reads. It rejects a file that
    is not .cs and a generated file: *.Designer.cs, *.g.cs, *.g.i.cs and anything under bin/ or obj/.

.PARAMETER Lines
    The lines of one C# file.

.PARAMETER Path
    A repo-relative path with forward slashes.

.EXAMPLE
    $code = @(Get-CodeView -Lines @(Get-Content -LiteralPath $file))
.EXAMPLE
    if (Test-CheckedPath 'src/Orders/OrderService.cs') { 'read it' }
#>

$script:SkipPatterns = @('\.Designer\.cs$', '\.g\.cs$', '\.g\.i\.cs$', '(^|/)(bin|obj)/')
$script:LiteralPattern = '\$*(?<q>"{3,})(?:(?!\k<q>).)*\k<q>|(?:\$@|@\$|@)"(?:[^"]|"")*"|\$"(?:[^"\\{}]|\\.|\{\{|\}\}|\{(?:[^{}"]|"(?:[^"\\]|\\.)*")*\})*"|\$?"(?:[^"\\]|\\.)*"|''(?:[^''\\]|\\.)'''

$script:MaxLineLength = 4000
$script:LiteralRegex = [regex]::new($script:LiteralPattern, [System.Text.RegularExpressions.RegexOptions]::None, [TimeSpan]::FromSeconds(1))

function Split-OpenString {
    param([string]$Code)
    $raw = [regex]::Match($Code, '(?<q>"{3,})\s*$')
    if ($raw.Success) { return [pscustomobject]@{ Before = $Code.Substring(0, $raw.Index); End = $raw.Groups['q'].Value } }
    $verbatim = [regex]::Match($Code, '(?:\$@|@\$|@)"')
    if ($verbatim.Success) { return [pscustomobject]@{ Before = $Code.Substring(0, $verbatim.Index); End = 'verbatim' } }
    return [pscustomobject]@{ Before = $Code; End = $null }
}

function Close-OpenString {
    param([string]$Text, [string]$End)
    $close = if ($End -eq 'verbatim') { [regex]::Match(($Text -replace '""', '__'), '"') } else { [regex]::Match($Text, [regex]::Escape($End)) }
    if (-not $close.Success) { return $null }
    return $Text.Substring($close.Index + $close.Length)
}

function Get-CodeView {
    <#
    .SYNOPSIS
        Returns each C# line with its comments and string contents removed, so a pattern matches code only.
        A line over 4000 characters, or one the string pattern cannot read within 1 second, comes back as
        an empty line, so a hostile file cannot stall a gate.
    .PARAMETER Lines
        The lines of one C# file, in order, because a block comment or a raw string can span lines.
    #>
    param([string[]]$Lines)
    $end = $null
    foreach ($line in $Lines) {
        if ($line.Length -gt $script:MaxLineLength) { ''; continue }
        $text = $line
        if ($end) {
            $rest = if ($end -eq '*/') {
                $close = $text.IndexOf('*/')
                if ($close -ge 0) { $text.Substring($close + 2) }
            }
            else { Close-OpenString -Text $text -End $end }
            if ($null -eq $rest) { ''; continue }
            $text = $rest
            $end = $null
        }
        $code = try { [regex]::Replace($script:LiteralRegex.Replace($text, '""'), '/\*.*?\*/', ' ') }
        catch [System.Text.RegularExpressions.RegexMatchTimeoutException] { $null }
        if ($null -eq $code) { ''; continue }
        $block = $code.IndexOf('/*')
        $lineComment = $code.IndexOf('//')
        $open = Split-OpenString $code
        $stringAt = if ($open.End) { $open.Before.Length } else { -1 }
        $first = @(@($block, $lineComment, $stringAt) | Where-Object { $_ -ge 0 } | Sort-Object)[0]
        if ($null -eq $first -or $first -eq $lineComment) { $code; continue }
        if ($first -eq $block) {
            $end = '*/'
            $code.Substring(0, $block)
            continue
        }
        $end = $open.End
        $open.Before
    }
}

function Test-CheckedPath {
    <#
    .SYNOPSIS
        True for a .cs file the gate reads, false for a generated file or one under bin or obj.
    .PARAMETER Path
        The repository-relative path of the file.
    #>
    param([string]$Path)
    if ($Path -notmatch '\.cs$') { return $false }
    return -not ($script:SkipPatterns | Where-Object { $Path -match $_ })
}

Export-ModuleMember -Function Get-CodeView, Test-CheckedPath
