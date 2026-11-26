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
    a line is removed when it starts with Co-authored-by: (in any case) and names a tool or vendor from
    the pattern in this script. The names live only in that pattern, so that clause C10 holds for the
    comments (#53). A Co-authored-by line that names a person stays. Blank lines left at the end are
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

# A short list on purpose: a word that is also a common first name would remove the trailer of a person.
$toolName = '(?i)\b(copilot|claude|anthropic|openai|chatgpt|gpt(-\d|\b)|codex|gemini|cursor|aider|ai)\b'

try {
    if (-not (Test-Path -LiteralPath $MessageFile -PathType Leaf)) { exit 0 }
    $text = [System.IO.File]::ReadAllText($MessageFile)
    $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = @($text -split '\r?\n')
    $end = $lines.Count - 1
    while ($end -ge 0 -and [string]::IsNullOrWhiteSpace($lines[$end])) { $end-- }
    $start = $end
    while ($start -gt 0 -and -not [string]::IsNullOrWhiteSpace($lines[$start - 1])) { $start-- }
    $isTrailerBlock = $start -gt 0 -and $end -ge $start -and -not @($lines[$start..$end] | Where-Object { $_ -notmatch '^[A-Za-z0-9-]+:\s' }).Count
    $kept = [System.Collections.Generic.List[string]]::new()
    $removed = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($isTrailerBlock -and $i -ge $start -and $i -le $end -and $line -match '^co-authored-by:(?<who>.*)$' -and $Matches['who'] -match $toolName) { $removed.Add($line.Trim()); continue }
        $kept.Add($line)
    }
    if ($removed.Count -eq 0) { exit 0 }
    while ($kept.Count -gt 0 -and [string]::IsNullOrWhiteSpace($kept[$kept.Count - 1])) { $kept.RemoveAt($kept.Count - 1) }
    [System.IO.File]::WriteAllText($MessageFile, (($kept -join $newline) + $newline))
    foreach ($line in $removed) { [Console]::Error.WriteLine("commit-msg: removed '$line'; nothing we keep names a coding tool as an author.") }
}
catch {
    [Console]::Error.WriteLine("commit-msg: could not check the message for a co-author trailer of a coding tool: $($_.Exception.Message)")
}
exit 0
