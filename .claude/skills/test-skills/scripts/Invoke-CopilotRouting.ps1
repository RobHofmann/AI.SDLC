#Requires -Version 7
<#
.SYNOPSIS
    Layer 4 of test-skills: asks GitHub Copilot CLI which installed skill it would use for each
    routing prompt, one fresh headless session per prompt, and compares the answers with the expected ones.

.DESCRIPTION
    The skills are shared by Claude Code and GitHub Copilot, but Layers 1 and 2 only measure Claude
    routing. This script runs the same prompt set through `copilot -p` in the repository, so the
    description of a skill is judged by the second tool too. Copilot reads the skills of a repository
    only in a folder it trusts (trustedFolders in its config), so run it from the repository root.

    The prompt file holds one prompt per line in the form `P01: <prompt>`. The expected file holds one
    line per prompt in the form `P01: <skill>`, where the skill is a name, `none`, or names separated by
    ` or ` when more than one answer is right. Copilot is told not to run the skill and not to read files,
    and to answer with the skill name only.

    The output is one line per prompt: `P01: <expected> -> <answer> OK` or `MISS`, then a summary line.
    A miss is a finding to record in the pull request that changes the skill, not a failure of the build.

    Before it routes, it asks Copilot which skills failed to load (`copilot skill list`). Copilot refuses
    a skill whose description is over 1024 characters, but the model can still answer with its name,
    because AGENTS.md and other skills name it. So a name-only answer cannot prove that a skill works.
    The script lists each skill that did not load, and marks an answer that names one of them as
    `MISS (not loaded)`. Then it exits 1, because a skill that does not load is a defect, not a
    routing finding. The answer is normalised first: backticks, a leading slash and a full stop at the
    end are removed.

.PARAMETER Prompts
    The prompt file.

.PARAMETER Expected
    The expected file. Without it the answers are printed and nothing is compared.

.PARAMETER RepoRoot
    The repository Copilot reads the skills from. Default: the current directory.

.PARAMETER Ask
    A script block that takes the question text and returns Copilot's answer. The default runs
    `copilot --trust-folder -p <question> -s`, so the skills of the repository load without a saved trust
    entry. A test passes its own block instead.

.PARAMETER ListSkills
    A script block that takes the repository root and returns the output of `copilot skill list`. A
    test passes its own block instead.

.EXAMPLE
    pwsh .claude/skills/test-skills/scripts/Invoke-CopilotRouting.ps1 -Prompts routing-prompts.md -Expected routing-expected.md
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Prompts,
    [string]$Expected,
    [string]$RepoRoot = (Get-Location).Path,
    [scriptblock]$Ask = { param([string]$Question) (& copilot --trust-folder -p $Question -s 2>&1 | Out-String) },
    [scriptblock]$ListSkills = { param([string]$Root) (& copilot -C $Root skill list 2>&1 | Out-String) }
)

$ErrorActionPreference = 'Stop'

function Read-PromptLines {
    param([Parameter(Mandatory)][string]$Path)
    $entries = [ordered]@{}
    foreach ($line in Get-Content -LiteralPath $Path -Encoding utf8) {
        if ($line -match '^(P\d+):\s*(.+?)\s*$') { $entries[$Matches[1]] = $Matches[2] }
    }
    return $entries
}

function Get-UnloadedSkill {
    param([string]$Listing)
    $unloaded = [ordered]@{}
    foreach ($match in [regex]::Matches([string]$Listing, '(?m)^\s*\S\s+(?<path>\S.*?[\\/](?<name>[a-z0-9-]+)[\\/]SKILL\.md):\s*(?<reason>.+?)\s*$')) {
        $unloaded[$match.Groups['name'].Value] = $match.Groups['reason'].Value
    }
    return $unloaded
}

function ConvertTo-SkillAnswer {
    param([string]$Text)
    $answer = (([string]$Text) -replace '\s+', ' ').Trim()
    $answer = $answer.Trim('`', '"', "'", ' ')
    $answer = $answer.TrimEnd('.')
    return $answer.TrimStart('/').Trim('`')
}

$promptSet = Read-PromptLines -Path $Prompts
if ($promptSet.Count -eq 0) { throw "No prompt of the form 'P01: <prompt>' in $Prompts" }
$expectedSet = if ($Expected) { Read-PromptLines -Path $Expected } else { [ordered]@{} }

$unloaded = Get-UnloadedSkill -Listing (& $ListSkills $RepoRoot)
foreach ($name in $unloaded.Keys) { Write-Output "NOT LOADED in Copilot: $name ($($unloaded[$name]))" }

$hits = 0
$misses = 0
Push-Location $RepoRoot
try {
    foreach ($id in $promptSet.Keys) {
        $question = "A user asks: `"$($promptSet[$id])`". Which ONE of the skills available to you in this repository would you use for it? Do not run it and do not read files. Reply with only the skill name, or none."
        $answer = ConvertTo-SkillAnswer -Text ((& $Ask $question) -join ' ')
        if (-not $expectedSet.Contains($id)) {
            Write-Output "${id}: $answer"
            continue
        }
        $accepted = @($expectedSet[$id] -split '\s+or\s+' | ForEach-Object { $_.Trim() })
        if ($answer -in $accepted -and $unloaded.Contains($answer)) { $misses++; $verdict = 'MISS (not loaded)' }
        elseif ($answer -in $accepted) { $hits++; $verdict = 'OK' }
        else { $misses++; $verdict = 'MISS' }
        Write-Output "${id}: $($expectedSet[$id]) -> $answer $verdict"
    }
}
finally { Pop-Location }

if ($expectedSet.Count -gt 0) {
    Write-Output "Copilot routing: $hits of $($hits + $misses) as expected, $misses miss(es)."
}
if ($unloaded.Count -gt 0) {
    Write-Output "Copilot routing: $($unloaded.Count) skill(s) do not load in Copilot; fix them before you judge the routing."
    exit 1
}
