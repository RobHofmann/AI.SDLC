#Requires -Version 7
<#
.SYNOPSIS
    Reports how often each AI-SDLC skill and agent is really invoked, from the Claude Code session
    transcripts and the GitHub Copilot CLI session logs.

.DESCRIPTION
    Answers "which skills do we actually use, and which are dead weight" with counts rather than a
    feeling. It reads the session transcripts Claude Code writes under ~/.claude/projects, and the
    session logs GitHub Copilot CLI writes under ~/.copilot/session-state/<session>/events.jsonl. It
    counts two kinds of invocation, which mean different things:

      typed   the person typed the slash command, so they chose the skill themselves.
      agent   the agent called the skill through its Skill tool (skill in Copilot). This is where one
              skill calling another lands, because a delegated call is a Skill tool call like any other.
              It also covers the agent picking a skill on its own for a plain request.

    Both are counted per skill, and the report also shows how many OTHER skills name this one in their
    own SKILL.md. That third number is the intended call graph rather than a count of runs, and it is
    what separates "nobody calls it" from "nothing even points at it". Each skill row carries its kind,
    workflow or knowledge, because a knowledge skill is never typed and is often preloaded by an agent
    without a Skill tool call, so a low count means less for it.

    The agents in .claude/agents/ are counted too, one row each with the kind 'agent'. A run is an Agent
    tool call (task in Copilot) whose subagent or agent type names the agent; only that name is read.
    ReferencedBy for an agent is the number of skills that name it in backticks, which is how a
    workflow skill hands work to it.

    A Copilot session counts when its first event (session.start) names this repository: its
    repository, git root or folder matches the project filter, in the same form as a Claude project
    folder.

    A young skill has had less time to be used, so the report also gives each skill's age in weeks, from
    the first commit of its SKILL.md, and its total divided by that age. Compare skills on PerWeek, not on
    Total, when their ages differ.

    ONLY skill names and timestamps are read out of a transcript. No prompt, no answer, no argument and
    no file content is read, extracted or printed, so the report can be shared without leaking work.

    What it cannot see, and says so rather than suggesting otherwise:
      - Copilot in VS Code or another IDE, which keeps its sessions elsewhere.
      - A skill whose instructions an agent followed without calling the Skill tool, and a knowledge
        skill an agent preloaded.
      - A review a skill did inline because no agent could run, which is the fallback every hand-off has.
      - Sessions on another machine, or transcripts a person has deleted.

.PARAMETER RepoRoot
    Repository root that holds .claude/skills. Defaults to the folder that holds aisdlc.json, found from this script.

.PARAMETER TranscriptRoot
    Folder that holds the per-project transcript folders. Defaults to ~/.claude/projects.

.PARAMETER CopilotSessionRoot
    Folder that holds the Copilot CLI session folders. Defaults to session-state in COPILOT_HOME when it
    is set, otherwise ~/.copilot/session-state.

.PARAMETER ProjectFilter
    Wildcard for the project folders to read. Defaults to the repository name from aisdlc.json
    ("repository"), or the name of the repository folder, with every character that is not a letter
    or a digit turned into "-" the way Claude Code names its project folders, between two "*". That
    picks up the repository under every path it has been opened from, including git worktrees.

.PARAMETER Detail
    Also list every skill that was never invoked, and every skill no other skill names.

.PARAMETER AsObject
    Return the rows as objects instead of printing a table, for a caller that wants to sort or export.

.PARAMETER SkillAgesForTest
    Test seam only: a hashtable of skill name to the date its SKILL.md was first committed. When set, git
    is not consulted. Never set in normal use.

.EXAMPLE
    pwsh .claude/skills/test-skills/scripts/Get-SkillUsage.ps1

.EXAMPLE
    pwsh .claude/skills/test-skills/scripts/Get-SkillUsage.ps1 -Detail
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$TranscriptRoot = (Join-Path $HOME '.claude/projects'),
    [string]$CopilotSessionRoot = $(if ($env:COPILOT_HOME) { Join-Path $env:COPILOT_HOME 'session-state' } else { Join-Path $HOME '.copilot/session-state' }),
    [string]$ProjectFilter,
    [switch]$Detail,
    [switch]$AsObject,
    [hashtable]$SkillAgesForTest
)

Import-Module (Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts' 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

$ErrorActionPreference = 'Stop'

if (-not $ProjectFilter) {
    $repositoryName = (Get-AiSdlcConfig -RepoRoot $RepoRoot).repository
    if (-not $repositoryName) { $repositoryName = Split-Path $RepoRoot -Leaf }
    $ProjectFilter = '*' + ($repositoryName -replace '[^A-Za-z0-9]', '-') + '*'
}

$skillsRoot = Join-Path $RepoRoot '.claude/skills'
if (-not (Test-Path -LiteralPath $skillsRoot)) {
    throw "No skills folder at '$skillsRoot'. Point -RepoRoot at a checkout that has .claude/skills."
}

$skills = @(Get-ChildItem -LiteralPath $skillsRoot -Directory -Force |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') } |
    Select-Object -ExpandProperty Name | Sort-Object)

if ($skills.Count -eq 0) { throw "No skill found under '$skillsRoot'." }

$agentsRoot = Join-Path $RepoRoot '.claude/agents'
$agents = @(if (Test-Path -LiteralPath $agentsRoot) {
        Get-ChildItem -LiteralPath $agentsRoot -Filter *.md -File | Select-Object -ExpandProperty BaseName | Sort-Object
    })

$kinds = @{}
foreach ($s in $skills) {
    $kinds[$s] = if ((Get-Content -LiteralPath (Join-Path $skillsRoot "$s/SKILL.md") -Raw) -match '(?m)^kind:\s*knowledge\s*$') { 'knowledge' } else { 'workflow' }
}

$known = @{}
foreach ($s in $skills) { $known[$s] = $true }

$typed = @{}
$agent = @{}
$lastUsed = @{}
foreach ($s in $skills) { $typed[$s] = 0; $agent[$s] = 0; $lastUsed[$s] = $null }

$agentKnown = @{}
$agentRuns = @{}
foreach ($a in $agents) { $agentKnown[$a] = $true; $agentRuns[$a] = 0; $lastUsed["agent:$a"] = $null }

function Update-LastUsed([string]$key, [string]$line) {
    $stamp = [regex]::Match($line, '"timestamp":"(?<t>[^"]+)"')
    if (-not $stamp.Success) { return }
    $when = $stamp.Groups['t'].Value -as [datetime]
    if ($when -and ($null -eq $lastUsed[$key] -or $when -gt $lastUsed[$key])) { $lastUsed[$key] = $when }
}

$files = @()
if (Test-Path -LiteralPath $TranscriptRoot) {
    $folders = @(Get-ChildItem -LiteralPath $TranscriptRoot -Directory -Force |
        Where-Object { $_.Name -like $ProjectFilter })
    foreach ($folder in $folders) {
        $files += @(Get-ChildItem -LiteralPath $folder.FullName -Filter *.jsonl -File -Recurse)
    }
}

$pattern = '"name":"Skill","input":\{"skill":"(?<agent>[a-z0-9:_-]+)"|<command-name>/(?<typed>[a-z0-9:_-]+)</command-name>|"subagent_type":"(?<sub>[a-z0-9:_-]+)"'
$copilotPattern = '"toolName":"skill","arguments":\{"skill":"(?<agent>[a-z0-9:_-]+)"|"type":"user\.message","data":\{"content":"/(?<typed>[a-z0-9_-]+)|"toolName":"task","arguments":\{.*?"agent_type":"(?<sub>[a-z0-9:_-]+)"'

function Test-CopilotSession([string]$StartLine) {
    if ($StartLine -notmatch '"type":"session\.start"') { return $false }
    foreach ($field in 'repository', 'gitRoot', 'cwd') {
        $value = [regex]::Match($StartLine, '"' + $field + '":"(?<v>[^"]*)"')
        if ($value.Success -and ($value.Groups['v'].Value -replace '[^A-Za-z0-9]', '-') -like $ProjectFilter) { return $true }
    }
    return $false
}

$copilotFiles = @()
if (Test-Path -LiteralPath $CopilotSessionRoot) {
    foreach ($session in (Get-ChildItem -LiteralPath $CopilotSessionRoot -Directory -Force -ErrorAction SilentlyContinue)) {
        $events = Join-Path $session.FullName 'events.jsonl'
        if (-not (Test-Path -LiteralPath $events -PathType Leaf)) { continue }
        $first = Get-Content -LiteralPath $events -TotalCount 1 -ErrorAction SilentlyContinue
        if (Test-CopilotSession -StartLine $first) { $copilotFiles += $events }
    }
}

$sources = @($files | ForEach-Object { [pscustomobject]@{ Path = $_.FullName; Pattern = $pattern } }) +
    @($copilotFiles | ForEach-Object { [pscustomobject]@{ Path = $_; Pattern = $copilotPattern } })

foreach ($source in $sources) {
    foreach ($hit in (Select-String -LiteralPath $source.Path -Pattern $source.Pattern -AllMatches)) {
        foreach ($match in $hit.Matches) {
            if ($match.Groups['sub'].Success) {
                $sub = ($match.Groups['sub'].Value -split ':')[-1]
                if ($agentKnown.ContainsKey($sub)) { $agentRuns[$sub]++; Update-LastUsed "agent:$sub" $hit.Line }
                continue
            }

            $name = $null
            $bucket = $null
            if ($match.Groups['agent'].Success) { $name = $match.Groups['agent'].Value; $bucket = 'agent' }
            elseif ($match.Groups['typed'].Success) { $name = $match.Groups['typed'].Value; $bucket = 'typed' }
            if (-not $name) { continue }

            $name = ($name -split ':')[-1]
            if (-not $known.ContainsKey($name)) { continue }

            if ($bucket -eq 'agent') { $agent[$name]++ } else { $typed[$name]++ }
            Update-LastUsed $name $hit.Line
        }
    }
}

$referencedBy = @{}
foreach ($s in $skills) { $referencedBy[$s] = [System.Collections.Generic.List[string]]::new() }

$agentReferencedBy = @{}
foreach ($a in $agents) { $agentReferencedBy[$a] = 0 }

foreach ($s in $skills) {
    $text = Get-Content -LiteralPath (Join-Path $skillsRoot "$s/SKILL.md") -Raw
    foreach ($other in $skills) {
        if ($other -eq $s) { continue }
        if ($text -match ("(/|`")" + [regex]::Escape($other) + "\b")) {
            $referencedBy[$other].Add($s)
        }
    }
    foreach ($a in $agents) {
        if ($text -match ("``" + [regex]::Escape($a) + "``")) { $agentReferencedBy[$a]++ }
    }
}

function Get-SkillAge([string]$name, [string]$rel = ".claude/skills/$name/SKILL.md") {
    if ($SkillAgesForTest) {
        if ($SkillAgesForTest.ContainsKey($name)) { return ($SkillAgesForTest[$name] -as [datetime]) }
        return $null
    }
    $first = git -C $RepoRoot log --diff-filter=A --format=%aI -- $rel 2>$null | Select-Object -Last 1
    if ($first) { return ($first -as [datetime]) }
    return $null
}

$today = (Get-Date).Date
function Get-Weeks($born) {
    if ($born) { [math]::Max(1, [math]::Round(($today - $born.Date).TotalDays / 7, 1)) } else { $null }
}

$rows = @(foreach ($s in $skills) {
    $weeks = Get-Weeks (Get-SkillAge $s)
    $total = $typed[$s] + $agent[$s]
    [pscustomobject]@{
        Skill        = $s
        Kind         = $kinds[$s]
        Typed        = $typed[$s]
        Agent        = $agent[$s]
        Total        = $total
        PerWeek      = if ($weeks) { [math]::Round($total / $weeks, 2) } else { $null }
        AgeWeeks     = $weeks
        ReferencedBy = $referencedBy[$s].Count
        LastUsed     = if ($lastUsed[$s]) { $lastUsed[$s].ToString('yyyy-MM-dd') } else { '' }
    }
})

$rows += @(foreach ($a in $agents) {
    $weeks = Get-Weeks (Get-SkillAge $a ".claude/agents/$a.md")
    [pscustomobject]@{
        Skill        = $a
        Kind         = 'agent'
        Typed        = 0
        Agent        = $agentRuns[$a]
        Total        = $agentRuns[$a]
        PerWeek      = if ($weeks) { [math]::Round($agentRuns[$a] / $weeks, 2) } else { $null }
        AgeWeeks     = $weeks
        ReferencedBy = $agentReferencedBy[$a]
        LastUsed     = if ($lastUsed["agent:$a"]) { $lastUsed["agent:$a"].ToString('yyyy-MM-dd') } else { '' }
    }
})

$rows = @($rows | Sort-Object -Property @{ Expression = 'Total'; Descending = $true }, @{ Expression = 'Skill'; Descending = $false })

if ($AsObject) { return $rows }

$used = @($rows | Where-Object { $_.Total -gt 0 })
$unused = @($rows | Where-Object { $_.Total -eq 0 })

Write-Host ("Skill usage across {0} Claude Code transcript(s) in {1} and {2} GitHub Copilot session(s) in {3}, matching '{4}'." -f $files.Count, $TranscriptRoot, $copilotFiles.Count, $CopilotSessionRoot, $ProjectFilter)
Write-Host "  typed = the person ran the slash command; agent = the agent called it, which includes one skill delegating to another."
Write-Host "  Kind 'agent' rows count the runs of an agent from .claude/agents; ReferencedBy counts the skills that hand work to it."
Write-Host ""

$rows | Format-Table -AutoSize | Out-String -Width 140 | Write-Host

Write-Host ("{0} of {1} skill(s) and agent(s) were invoked at least once; {2} never were." -f $used.Count, $rows.Count, $unused.Count)

if ($Detail) {
    if ($unused.Count -gt 0) {
        Write-Host ""
        Write-Host "Never invoked in a transcript read here:"
        foreach ($r in $unused) {
            $note = if ($r.ReferencedBy -gt 0) { "{0} other skill(s) name it, so it is reachable but unused" -f $r.ReferencedBy } else { 'and no other skill names it' }
            Write-Host ("  {0,-28} {1}" -f $r.Skill, $note)
        }
    }

    $orphans = @($rows | Where-Object { $_.ReferencedBy -eq 0 })
    if ($orphans.Count -gt 0) {
        Write-Host ""
        Write-Host "Named by no other skill (entry points, or candidates to retire):"
        foreach ($r in $orphans) { Write-Host ("  {0,-28} total {1}" -f $r.Skill, $r.Total) }
    }
}

Write-Host ""
Write-Host "Not counted: Copilot in an IDE, a skill followed without calling the Skill tool, a knowledge skill an agent preloaded, an inline fallback review, and sessions on another machine."
