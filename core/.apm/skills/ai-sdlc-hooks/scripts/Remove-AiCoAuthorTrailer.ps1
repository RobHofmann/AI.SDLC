#Requires -Version 7
<#
.SYNOPSIS
    Removes a Co-authored-by trailer that names a coding tool from a commit message, before git saves it.

.DESCRIPTION
    Nothing we keep names an AI tool as its author or helper (the language rule in the handbook). Some
    coding tools add such a trailer to every commit on their own, unless a person turns it off. The git
    hook githooks/commit-msg calls this script with the path of the message file, so the rule holds for
    every tool and for a commit from a terminal.

    Only the trailer block counts: the last paragraph of the message, when every line in it is a git
    trailer (Key: value). A line in the body, such as a quoted trailer, is never touched. In that block,
    a line is removed when it starts with Co-authored-by: (in any case) and either its whole name is a
    tool name from the pattern in this script, maybe with a model or version word, or its address is
    one of the fixed bot addresses there. A word inside a name or an address does not count, so a person
    who shares a first name with a tool keeps the trailer. The names live only in the patterns, so that
    clause C10 holds for the comments (#53). A Co-authored-by line that names a person stays.

    A commit made in an editor gives git's comment lines and, with --verbose, a scissors line and the
    diff below it. Those lines are left in place for git to remove, and the trailer block is the last
    paragraph above them. Blank lines left at the end are
    trimmed. The script never fails a commit: a missing or unreadable file is left alone, and it always
    exits 0. When it removes a line, it says so on the error stream.

.PARAMETER MessageFile
    The commit message file that git passes to the commit-msg hook.

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-hooks/scripts/Remove-AiCoAuthorTrailer.ps1 -MessageFile .git/COMMIT_EDITMSG
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MessageFile
)

# The whole name must be a tool name, maybe followed by model or version words, so "Claude Dupont" stays.
$toolName = '(?i)^(github copilot|copilot|claude|anthropic|openai|chatgpt|gpt-\S+|codex|gemini|cursor|aider|ai|ai assistant)( (code|opus|sonnet|haiku|agent|assistant|cli|\d\S*))*$'
$toolAddress = '(?i)^(noreply@anthropic\.com|\d*\+?copilot@users\.noreply\.github\.com|[^@]+@openai\.com|[^@]+@cursor\.(com|sh))$'

function Test-ToolCoAuthor([string]$Who) {
    $match = [regex]::Match($Who.Trim(), '^(?<name>[^<]*?)\s*(<(?<mail>[^>]*)>)?$')
    if (-not $match.Success) { return $false }
    return ($match.Groups['name'].Value.Trim() -match $toolName) -or ($match.Groups['mail'].Value.Trim() -match $toolAddress)
}

try {
    if (-not (Test-Path -LiteralPath $MessageFile -PathType Leaf)) { exit 0 }
    $text = [System.IO.File]::ReadAllText($MessageFile)
    $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = @($text -split '\r?\n')
    $comment = [string](git config --get core.commentChar 2>$null)
    if (-not $comment -or $comment -eq 'auto') { $comment = '#' }
    $end = $lines.Count - 1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match ('^' + [regex]::Escape($comment) + ' -+ >8 -+$')) { $end = $i - 1; break }
    }
    while ($end -ge 0 -and ([string]::IsNullOrWhiteSpace($lines[$end]) -or $lines[$end].StartsWith($comment))) { $end-- }
    $start = $end
    while ($start -gt 0 -and -not [string]::IsNullOrWhiteSpace($lines[$start - 1])) { $start-- }
    $isTrailerBlock = $start -gt 0 -and $end -ge $start -and -not @($lines[$start..$end] | Where-Object { $_ -notmatch '^[A-Za-z0-9-]+:\s' }).Count
    $kept = [System.Collections.Generic.List[string]]::new()
    $removed = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($isTrailerBlock -and $i -ge $start -and $i -le $end -and $line -match '^co-authored-by:(?<who>.*)$' -and (Test-ToolCoAuthor $Matches['who'])) { $removed.Add($line.Trim()); continue }
        $kept.Add($line)
    }
    if ($removed.Count -eq 0) { exit 0 }
    # A blank line right above the removed block would stay as an empty paragraph, so it goes too.
    $tail = [System.Collections.Generic.List[string]]::new()
    while ($kept.Count -gt 0 -and ([string]::IsNullOrWhiteSpace($kept[$kept.Count - 1]) -or $kept[$kept.Count - 1].StartsWith($comment))) {
        if (-not [string]::IsNullOrWhiteSpace($kept[$kept.Count - 1])) { $tail.Insert(0, $kept[$kept.Count - 1]) }
        $kept.RemoveAt($kept.Count - 1)
    }
    if ($tail.Count -gt 0) { $kept.Add(''); $kept.AddRange($tail) }
    [System.IO.File]::WriteAllText($MessageFile, (($kept -join $newline) + $newline))
    foreach ($line in $removed) { [Console]::Error.WriteLine("commit-msg: removed '$line'; nothing we keep names a coding tool as an author.") }
}
catch {
    [Console]::Error.WriteLine("commit-msg: could not check the message for a co-author trailer of a coding tool: $($_.Exception.Message)")
}
exit 0
