#Requires -Version 7
<#
.SYNOPSIS
    PostToolUse hook: after an edit, run the house-style or build check that fits the file, and hand the
    result to the agent while the file is still open.

.DESCRIPTION
    The gates run at the push and in the pull request build. That is minutes after the sentence or
    the line that fails them was written, and by then the agent has moved on. This hook closes that
    gap for the checks that are cheap enough to run on every edit:

      - a markdown file gets the reading-level gate (Check-DocReadingLevel.ps1, on that one file) and
        the em-dash gate (Check-DocEmDashes.ps1), both from the ai-sdlc-gates skill;
      - any other file type is handed to the pack that claims it. A gates.json of an installed pack
        can name a postEdit script with the extensions it takes, for example the dotnet pack builds
        the project that owns an edited C# or Razor file (Invoke-DotnetPostEdit.ps1). The script runs
        once per edit with every file it claims: -File and -Relative are lists in the same order, and
        -RepoRoot is the root. Whatever it writes is the feedback.

    Any other file, a file outside the repository, or a payload this script cannot read, is allowed
    through in silence. The feedback is returned as PostToolUse additionalContext in both tool shapes
    (HookPayload.psm1): nested in hookSpecificOutput for Claude Code, and at the top level for GitHub
    Copilot CLI, which drops the nested form for this event. It never blocks the edit, because the fix
    is the model's next action, not a refusal of the last one.

    Wired from .claude/settings.json with matcher Edit|Write. The file filter lives here rather than
    in an `if` condition, for the reason Deny-IncompletePush.ps1 records: GitHub Copilot CLI reads the
    same entry and ignores `if`. HookPayload.psm1 also reads the patch text of apply_patch, which a GPT
    model in Copilot CLI uses, and every file the patch names is checked. Every failure path exits 0
    with no output, so a bug here can never turn every edit into an error. An edit gets its gate result
    at once.

.PARAMETER Payload
    The hook payload as JSON. Read from stdin when not supplied.

.PARAMETER RepoRoot
    The repository root. Defaults to the folder that holds aisdlc.json, found from this script.

.PARAMETER SkillsRoot
    Where the packages are installed, read for their postEdit entries. Defaults to <RepoRoot>/.claude/skills.

.PARAMETER ReadingLevelScript
    The reading-level gate to run on a markdown file. Defaults to Check-DocReadingLevel.ps1 in the ai-sdlc-gates skill.

.PARAMETER EmDashScript
    The em-dash gate to run after a markdown edit. Defaults to Check-DocEmDashes.ps1 in the ai-sdlc-gates skill.

.EXAMPLE
    '{"tool_name":"Edit","tool_input":{"file_path":"docs/README.md"}}' | pwsh .claude/skills/ai-sdlc-hooks/scripts/Invoke-PostEditCheck.ps1
#>
[CmdletBinding()]
param(
    [string]$Payload,
    [string]$RepoRoot,
    [string]$SkillsRoot,
    [string]$ReadingLevelScript = (Join-Path -Path $PSScriptRoot -ChildPath '..' '..' 'ai-sdlc-gates' 'scripts' 'Check-DocReadingLevel.ps1'),
    [string]$EmDashScript = (Join-Path -Path $PSScriptRoot -ChildPath '..' '..' 'ai-sdlc-gates' 'scripts' 'Check-DocEmDashes.ps1')
)

$ErrorActionPreference = 'Stop'

trap { exit 0 }

Import-Module (Join-Path $PSScriptRoot 'HookPayload.psm1') -Force

function Resolve-InsideRepo {
    param([string]$File, [string]$Root)

    $full = if ([IO.Path]::IsPathRooted($File)) { $File } else { Join-Path $Root $File }
    $full = [IO.Path]::GetFullPath($full)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    if (-not (Test-Path -LiteralPath $full)) { return $null }
    return $full
}

function Get-MarkdownFeedback {
    param([string]$File, [string]$Relative)

    $ErrorActionPreference = 'Continue'
    $parts = [System.Collections.Generic.List[string]]::new()

    if (Test-Path -LiteralPath $ReadingLevelScript) {
        $report = & pwsh -NoProfile -File $ReadingLevelScript -RepoRoot $RepoRoot -Path $Relative 2>&1 | Out-String
        if ($LASTEXITCODE -eq 1) { $parts.Add("Reading level (C11) on ${Relative}:`n$($report.Trim())") }
    }

    if (Test-Path -LiteralPath $EmDashScript) {
        $report = & pwsh -NoProfile -File $EmDashScript -RepoRoot $RepoRoot -Path $Relative 2>&1 | Out-String
        if ($LASTEXITCODE -eq 1) { $parts.Add("Em-dash (C06) on ${Relative}:`n$($report.Trim())") }
    }

    if ($parts.Count -eq 0) { return }
    return (@("The file you just edited breaks a house-style rule that the doc gates check. Fix it now, in this file:") + $parts -join "`n`n")
}

function Get-PackFeedback {
    param([object[]]$Files)

    $ErrorActionPreference = 'Continue'
    $handlers = @(Get-AiSdlcPackage -RepoRoot $RepoRoot -SkillsRoot $SkillsRoot |
        Where-Object { $_.PostEdit -and (Test-Path -LiteralPath $_.PostEdit.Script) })

    # One call per handler with all its files, so a patch over many files of one project builds it once.
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($handler in $handlers) {
        $claimed = @($Files | Where-Object { $handler.PostEdit.Extensions -contains $_.Extension })
        if ($claimed.Count -eq 0) { continue }
        $text = & $handler.PostEdit.Script -File @($claimed.Full) -Relative @($claimed.Relative) -RepoRoot $RepoRoot 6>$null | Out-String
        if ($text.Trim()) { $parts.Add($text.Trim()) }
    }

    if ($parts.Count -eq 0) { return }
    return ($parts -join "`n`n")
}

if (-not $PSBoundParameters.ContainsKey('Payload')) {
    $Payload = if ([Console]::IsInputRedirected) { [Console]::In.ReadToEnd() } else { '' }
}

$editedFiles = @(Get-HookEditedFile -Json $Payload)
if ($editedFiles.Count -eq 0) { exit 0 }

Import-Module (Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts' 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }
if (-not $SkillsRoot) { $SkillsRoot = Join-Path $RepoRoot '.claude' 'skills' }

$feedback = [System.Collections.Generic.List[string]]::new()
$packFiles = [System.Collections.Generic.List[object]]::new()
foreach ($edited in $editedFiles) {
    $full = Resolve-InsideRepo -File $edited -Root $RepoRoot
    if (-not $full) { continue }

    $relative = [IO.Path]::GetRelativePath($RepoRoot, $full).Replace('\', '/')
    $extension = [IO.Path]::GetExtension($full).ToLowerInvariant()
    if ($extension -eq '.md') {
        $text = Get-MarkdownFeedback -File $full -Relative $relative
        if ($text) { $feedback.Add($text) }
    }
    elseif ($extension) { $packFiles.Add([pscustomobject]@{ Full = $full; Relative = $relative; Extension = $extension }) }
}
if ($packFiles.Count -gt 0) {
    $text = Get-PackFeedback -Files $packFiles
    if ($text) { $feedback.Add($text) }
}

if ($feedback.Count -gt 0) { New-HookContextOutput -EventName 'PostToolUse' -Text ($feedback -join "`n`n") | Write-Output }

exit 0
