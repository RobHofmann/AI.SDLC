#Requires -Version 7
<#
.SYNOPSIS
    Gate: every agent under .claude/agents/ has an explicit read-only tool list and a known persona. The
    one exception is a writer agent on the list in this script, which may edit files under strict rules.
.DESCRIPTION
    Claude Code, GitHub Copilot CLI and Copilot in VS Code all read the agents in .claude/agents/, and
    the workflow skills hand review and context work to them. An agent runs in its own context with the
    tools its file grants, so the file is the contract and this gate keeps it honest.

    For each .md file it checks:

      - name=file         the frontmatter `name:` matches the file name, which is how both tools find it.
      - description       a non-empty `description:`, because both tools choose an agent on it.
      - tools             an explicit `tools:` list. Left out, an agent gets every tool, edit tools
                          included, so it is never left out.
      - read-only         no tool that can change a file, an outside system or start another agent:
                          Edit, Write, MultiEdit, NotebookEdit, Agent, Task, a wildcard, or an MCP tool
                          whose action is not a read verb (get, search, list, query, read, fetch,
                          lookup) or carries a write verb (create, update, run and the like). An MCP
                          tool has the Claude Code form mcp__<server>__<action> or the GitHub Copilot
                          form <server>/<action>; each tool ignores the form of the other, so an agent
                          that needs an MCP server lists both. The
                          tools line is one line or a YAML list, never a folded block. The agents
                          review and read; the workflow skill that called them does the writing.
      - writer            the exception to read-only. Only an agent on the writer list of this
                          script (today only `builder`) may hold Edit and Write, and never Agent,
                          Task, a wildcard or an MCP write tool. It must set `model:`, and its
                          `## Task` section must say that it never commits or pushes. A reviewer
                          that can write is no longer independent, so the list stays short.
      - shell use         a shell tool (Bash, PowerShell) can write files, so an agent that holds one
                          carries a "## Shell use" section listing the read-only commands it may run.
                          The limit then rests on that text and the stop list in
                          the handbook page orchestration.md, not on the tool list, so few agents
                          keep a shell.
      - model             a `model:` line, when there is one, is `opus`, `sonnet` or `inherit`.
                          Claude Code fails a subagent on a name it does not know, and runs another
                          model without a warning on a near miss such as `claude-opus-5.5`. Copilot
                          CLI warns on these aliases and runs its default model. The tests behind
                          this are in the handbook page pattern.md.
      - model report      an `opus` agent has a `Model:` line in its output template, with any text. Copilot CLI
                          runs an agent started with --agent on its default model, and its task tool
                          refuses the alias when the hand-off passes no model. So the agent says which
                          model it ran on, and the evidence record shows a run below its model.
      - skills            every `skills:` entry is a knowledge skill that exists, or a skill of a pack
                          that is not installed, which the skill catalog lists.
      - read first        a `## Read first` section links the SKILL.md of every `skills:` entry,
                          because Copilot may not preload what `skills:` names.
      - persona           a `Persona:` line that names roles from the handbook personas.md, the short
                          forms PM and UX, or `any`.
      - standing rules    a `## Standing rules` section that links the handbook pages language.md and
                          autolearn.md, the same pointer every skill carries.
      - no em-dash        no U+2014 (house style).

    A repository with no .claude/agents/ folder passes with zero agents.
.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script.
.PARAMETER AgentsRoot
    The agents directory to scan. Defaults to <RepoRoot>/.claude/agents. Override for testing.
.PARAMETER SkillsRoot
    The skills directory the `skills:` entries resolve against. Defaults to <RepoRoot>/.claude/skills.
.PARAMETER PersonasFile
    The persona registry. Defaults to <SkillsRoot>/ai-sdlc-handbook/references/personas.md.
.PARAMETER CatalogPath
    The skill catalog of every AI-SDLC package. Defaults to skill-catalog.json in the ai-sdlc-gates
    skill. A preloaded skill that is not installed passes when the catalog lists it: it belongs to a
    pack this repository does not use, and Claude Code skips a preload it cannot find.
.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Check-AgentHygiene.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$AgentsRoot,
    [string]$SkillsRoot,
    [string]$PersonasFile,
    [string]$CatalogPath
)

Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

$ErrorActionPreference = 'Stop'

if (-not $AgentsRoot) { $AgentsRoot = Join-Path $RepoRoot '.claude' 'agents' }
if (-not $SkillsRoot) { $SkillsRoot = Join-Path $RepoRoot '.claude' 'skills' }
if (-not $PersonasFile) { $PersonasFile = Join-Path $SkillsRoot 'ai-sdlc-handbook' 'references' 'personas.md' }

$emDash = [char]0x2014
$editTools = @('Edit', 'Write', 'MultiEdit', 'NotebookEdit', 'edit', 'write', 'Agent', 'Task')
$shellTools = @('Bash', 'PowerShell', 'shell', 'execute')
$allowedModels = @('opus', 'sonnet', 'inherit')
$writerAgents = @('builder')
$writerTools = @('Edit', 'Write', 'MultiEdit', 'edit', 'write')
$mcpReadPattern = '(^|_)(get|search|list|query|read|fetch|lookup)([A-Z_]|$)'
$mcpWritePattern = '(^|_)(create|edit|update|delete|transition|add|run|vote|reply|resolve|batch|push|set|merge|complete|approve|queue)([A-Z_]|$)'

if (-not (Test-Path $AgentsRoot)) {
    Write-Host 'Agent hygiene OK: no .claude/agents/ folder, so there are 0 agents to check.'
    exit 0
}

if (-not (Test-Path $PersonasFile)) {
    Write-Host "Agent hygiene: the persona registry is not at $PersonasFile, so personas could not be checked and NOTHING WAS CHECKED." -ForegroundColor Yellow
    exit 2
}
$personas = @([regex]::Matches((Get-Content -LiteralPath $PersonasFile -Raw), '(?m)^###\s+(.+?)\s*$') | ForEach-Object { $_.Groups[1].Value })
$personaTokens = @($personas | ForEach-Object { $_ -split '\s*/\s*' } | ForEach-Object { $_.Trim() }) + @('PM', 'UX', 'any')

if (-not $CatalogPath) { $CatalogPath = Join-Path $PSScriptRoot '..' 'skill-catalog.json' }
$catalogSkills = @()
if (Test-Path -LiteralPath $CatalogPath -PathType Leaf) {
    $catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json -AsHashtable
    if ($catalog.skills) { $catalogSkills = @($catalog.skills.Values | ForEach-Object { $_ } | Where-Object { $_ }) }
}

$agentFiles = @(Get-ChildItem -Path $AgentsRoot -Filter *.md -File | Sort-Object Name)

$violations = [System.Collections.Generic.List[object]]::new()
function Add-Violation { param($Agent, $Rule, $Detail) $violations.Add([pscustomobject]@{ Agent = $Agent; Rule = $Rule; Detail = $Detail }) }

function Get-FrontmatterList {
    param([string]$Frontmatter, [string]$Key)
    $inline = [regex]::Match($Frontmatter, "(?m)^${Key}:[ \t]*(\S.*)$")
    if ($inline.Success) {
        return @($inline.Groups[1].Value.Trim().Trim('[', ']') -split ',' | ForEach-Object { $_.Trim().Trim('"', "'") } | Where-Object { $_ })
    }
    $block = [regex]::Match($Frontmatter, "(?ms)^${Key}:[ \t]*\r?\n((?:[ \t]+-[^\r\n]*\r?\n?)+)")
    if ($block.Success) {
        return @([regex]::Matches($block.Groups[1].Value, '-[ \t]*([^\r\n]+)') | ForEach-Object { $_.Groups[1].Value.Trim().Trim('"', "'") })
    }
    return $null
}

foreach ($file in $agentFiles) {
    $name = $file.BaseName
    $text = Get-Content -LiteralPath $file.FullName -Raw
    $fmMatch = [regex]::Match($text, '\A\s*---\r?\n(.*?)\r?\n---\r?\n', 'Singleline')
    if (-not $fmMatch.Success) { Add-Violation $name 'frontmatter' 'no YAML frontmatter block'; continue }
    $fm = $fmMatch.Groups[1].Value
    $body = $text.Substring($fmMatch.Length)

    $fmName = if ($fm -match '(?m)^name:\s*(\S+)') { $matches[1] } else { '' }
    if ($fmName -ne $name) { Add-Violation $name 'name=file' "frontmatter name '$fmName' does not match the file name" }

    $inlineDescription = $fm -match '(?m)^description:[ \t]*(?![>|][-+]?[ \t]*\r?$)\S'
    $blockDescription = $fm -match '(?m)^description:[ \t]*[>|][-+]?[ \t]*\r?\n[ \t]+\S'
    if (-not $inlineDescription -and -not $blockDescription) {
        Add-Violation $name 'description' 'no description; both tools choose an agent on it'
    }

    $tools = Get-FrontmatterList -Frontmatter $fm -Key 'tools'
    if ($fm -match '(?m)^tools:[ \t]*([>|]|\[[^\]\r\n]*\r?$)') {
        Add-Violation $name 'tools' 'write tools as one line (tools: Read, Grep) or a YAML list; a folded block or a list over several lines hides tools from this gate'
    }
    elseif ($null -eq $tools -or $tools.Count -eq 0) {
        Add-Violation $name 'tools' 'no explicit tools list; without one the agent gets every tool, edit tools included'
    }
    else {
        foreach ($tool in $tools) {
            $isMcp = $tool -like 'mcp__*' -or $tool -match '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.*-]+$'
            $action = if ($tool -like 'mcp__*') { ($tool -split '__')[-1] } else { ($tool -split '/')[-1] }
            $mcpWrite = $isMcp -and ($action -cmatch $mcpWritePattern -or $action -cnotmatch $mcpReadPattern)
            if ($name -in $writerAgents -and $tool -in $writerTools) { continue }
            if ($tool -in $editTools -or $tool -match '\*' -or $mcpWrite) {
                Add-Violation $name 'read-only' "tool '$tool' can change a file, an outside system or start another agent; agents only read and report"
            }
        }
        if (@($tools | Where-Object { $_ -in $shellTools }).Count -gt 0 -and $body -notmatch '(?m)^##[ \t]*Shell use[ \t]*\r?$') {
            Add-Violation $name 'shell' 'a shell can write files, so an agent with one needs a "## Shell use" section that lists the read-only commands it may run'
        }
    }

    $modelLine = [regex]::Match($fm, '(?m)^model:[ \t]*(.*?)[ \t]*\r?$')
    if ($modelLine.Success) {
        $model = $modelLine.Groups[1].Value.Trim('"', "'")
        if ($model -cnotin $allowedModels) {
            Add-Violation $name 'model' "model '$model' is not opus, sonnet or inherit; another value fails the agent in Claude Code or silently runs another model"
        }
        elseif ($model -ceq 'opus' -and $body -notmatch '(?m)^Model:[ \t]*\S') {
            Add-Violation $name 'model-report' "an opus agent names the model it runs on in a 'Model:' line of its output, because GitHub Copilot can run it on another model"
        }
    }

    if ($name -in $writerAgents -and @($tools | Where-Object { $_ -in $writerTools }).Count -gt 0) {
        if (-not $modelLine.Success) {
            Add-Violation $name 'writer' 'a writer agent sets model, so the build runs on a chosen model whatever the session model is'
        }
        $task = [regex]::Match($body, '(?ms)^##[ \t]*Task[ \t]*\r?$.*?(?=^##[ \t]|\z)')
        if (-not $task.Success -or $task.Value -notmatch '(?is)\bnever commit[^.]*\bpush') {
            Add-Violation $name 'writer' 'a writer agent says in its Task section that it never commits or pushes'
        }
    }

    $skills = Get-FrontmatterList -Frontmatter $fm -Key 'skills'
    $readFirst = [regex]::Match($body, '(?ms)^##[ \t]*Read first[ \t]*\r?$.*?(?=^##[ \t]|\z)')
    foreach ($skill in @($skills | Where-Object { $_ })) {
        $skillFile = Join-Path $SkillsRoot $skill 'SKILL.md'
        if (-not (Test-Path -LiteralPath $skillFile)) {
            if ($skill -notin $catalogSkills) { Add-Violation $name 'skills' "skill '$skill' does not exist" }
            elseif (-not $readFirst.Success -or $readFirst.Value -notmatch "skills/$([regex]::Escape($skill))/SKILL\.md") {
                Add-Violation $name 'read-first' "the Read first section does not link skills/$skill/SKILL.md, so Copilot never loads it"
            }
            continue
        }
        if ((Get-Content -LiteralPath $skillFile -Raw) -notmatch '(?m)^kind:\s*knowledge\s*$') { Add-Violation $name 'skills' "skill '$skill' is not a knowledge skill; an agent preloads knowledge, not a workflow" }
        if (-not $readFirst.Success -or $readFirst.Value -notmatch "skills/$([regex]::Escape($skill))/SKILL\.md") {
            Add-Violation $name 'read-first' "the Read first section does not link skills/$skill/SKILL.md, so Copilot never loads it"
        }
    }

    $personaLine = [regex]::Match($body, '(?m)^Persona:\s*(.+)$')
    if (-not $personaLine.Success) { Add-Violation $name 'persona' 'no "Persona:" line naming a role from the handbook personas.md' }
    else {
        $named = [regex]::Replace($personaLine.Groups[1].Value, '\[([^\]]+)\]\([^)]*\)', '$1')
        $named = ($named -split '\.\s')[0]
        $roles = @($named -split '\s*(?:,|\+|\band\b)\s*' | ForEach-Object { $_.Trim().Trim('*', '.') } | Where-Object { $_ })
        foreach ($role in $roles) {
            if ($role -notin $personaTokens) { Add-Violation $name 'persona' "persona '$role' is not in the handbook personas.md" }
        }
    }

    $standing = [regex]::Match($body, '(?ms)^##[ \t]*Standing rules[ \t]*\r?$.*?(?=^##[ \t]|\z)')
    if (-not $standing.Success -or $standing.Value -notmatch '\]\([^)]*language\.md' -or $standing.Value -notmatch '\]\([^)]*autolearn\.md') {
        Add-Violation $name 'standing-rules' 'no "## Standing rules" section that links language.md and autolearn.md in the handbook'
    }

    if ($text.Contains($emDash)) { Add-Violation $name 'em-dash' 'contains an em-dash (U+2014)' }
}

if ($violations.Count -gt 0) {
    Write-Host 'Agent hygiene violation: one or more agents under .claude/agents/ break the agent contract.' -ForegroundColor Red
    Write-Host 'FIX: Give each agent named below an explicit read-only tools list on one line or as a YAML list, a Shell use section if it keeps a shell, a name that matches its file, a description, a Persona line from the handbook personas.md, a Read first section that links every preloaded knowledge skill, and a Standing rules section; set model only to opus, sonnet or inherit, and give an opus agent a Model: line in its output. Only an agent on the writer list (builder) may hold Edit or Write, and it sets model and says in its Task section that it never commits or pushes (the handbook page pattern.md).' -ForegroundColor Red
    foreach ($v in $violations) { Write-Host ("  .claude/agents/{0}.md  [{1}]  {2}" -f $v.Agent, $v.Rule, $v.Detail) }
    $affected = ($violations | Select-Object -ExpandProperty Agent -Unique).Count
    Write-Host ("Found {0} violation(s) across {1} of {2} agent(s)." -f $violations.Count, $affected, $agentFiles.Count) -ForegroundColor Red
    exit 1
}

Write-Host ("Agent hygiene OK: {0} agent(s) pass (name=file, description, explicit read-only tools or a listed writer, shell use listed, model opus, sonnet or inherit, knowledge skills linked under Read first, known persona, Standing rules, no em-dash)." -f $agentFiles.Count)
exit 0
