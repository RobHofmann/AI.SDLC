#Requires -Version 7
<#
.SYNOPSIS
    Layer 0 of the skill eval harness: static hygiene gate for the AI-SDLC skills.

.DESCRIPTION
    Validates every skill under .claude/skills/ against the structural and house-style rules the
    skill ecosystem relies on, so a skill cannot silently drift. Every skill declares its kind in
    frontmatter, and Claude Code and GitHub Copilot read the same files:

      - kind: workflow        a step the model runs: a procedure, its gates, and the hand-offs to
                              agents and knowledge skills. It is a command people type, or an internal
                              step other skills call (user-invocable: false). All rules below apply.
      - kind: knowledge       how we do one thing here, loaded when needed and never typed. It carries
                              `user-invocable: false`, a `## Sources` section whose links resolve into
                              the docs that hold the full rule, and at most 120 lines. It has no phase,
                              no persona and no Next steps, because it is not a step in the flow. The
                              phase, persona, persona-line, Next-steps and pattern.md section rules do not
                              apply to it.

    For each skill folder containing a SKILL.md it checks:

      - name=folder           the frontmatter `name:` matches the folder name (how skills are invoked).
      - name spec             the name has 1 to 64 characters: lowercase letters, digits and single
                              hyphens, with no hyphen at either end (the Agent Skills specification).
      - description length    the description has 1 to 1024 characters once its YAML block is folded.
                              GitHub Copilot and the Agent Skills specification refuse a longer one, and
                              Copilot then does not load the skill at all. Claude Code accepts it, so
                              without this rule the skill works in one tool and is missing in the other.
      - phase + persona       the frontmatter carries `phase:` (discovery|elaboration|create|mature|
                              cross-cutting) and a non-empty `persona:`. Skill names are bare and no longer
                              encode the phase, so the lifecycle position and owner live in frontmatter.
      - trigger-rich desc     the description carries triggering language ("Use when/whenever/after/...").
      - persona line          a persona / "Usable by" / "Invoked as" line is present.
      - Next-steps section     a `## Next steps` section is present.
      - standing rules        a `## Standing rules` section that links BOTH the language conventions
                              (a link to a file named language.md) and the autolearn loop (a link
                              to a file named autolearn.md); both live in the ai-sdlc-handbook skill
                              under references/. Only that section is read, not the whole
                              file, so an empty block cannot pass on a link that sits under References.
                              Every skill run follows those two rules, so every skill points at the one
                              page that defines each. The pointer lives in the skill because the hooks
                              that fire the loop do not run everywhere a skill runs, for example in a
                              session that starts in a subfolder.
      - no em-dash            no U+2014 (house style, same rule as Check-DocEmDashes.ps1).
      - no line-citations     no `file.ext:NN` or "line NN" source citations (clause C02 patterns,
                              same as Check-DocLineCitations.ps1).
      - cross-refs resolve    every `/skill-name` reference resolves to a real skill folder, a skill
                              that skill-catalog.json lists for any AI-SDLC package (a pack this
                              repository did not install), or an allowlisted external tool skill. Names are bare (not phase-prefixed), so refs
                              are matched as kebab `/tokens` with a path-aware boundary, not by prefix.
      - no plugin refs        no plugin-style `namespace:skill` reference in backticks, such as a
                              personal plugin skill. Nobody else has it, so the step it names cannot run
                              for the next person.

    It also checks two further sections from the handbook page pattern.md: a `## Failure modes` section
    and a `## Observable signal` section. These are reported by the default run and FAIL under -Strict.
    The -Strict registration is Blocking, so a new skill without both sections fails the build. Keep this
    in lockstep with pattern.md. The check confirms the sections exist, not that they say anything
    useful; pattern.md carries the bar their content has to clear.

    This is the deterministic, CI-gateable layer; the routing (Layer 1) and value (Layer 2) layers
    are subagent-driven and documented in the test-skills skill, which calls this
    script for Layer 0. Exits non-zero (fails the build) when any skill violates a blocking rule.

    The pattern.md section findings do not fail the default run. gates.json registers this script once,
    with -Strict and Blocking, the way it registers Check-DocsWiki.ps1 and Check-StoryTraits.ps1: a
    -Strict run fails on every violation the default run fails on, and on the missing sections too, so a
    second registration without -Strict would only repeat it. Invoke-LocalGates.ps1 (through
    GateAnnotation.psm1) derives the CI signal from the exit code alone, so a finding that never changes the exit code produces a green step with no
    annotation and nobody sees it. That is what -Strict exists to prevent.

.PARAMETER RepoRoot
    Repository root that contains .claude/skills/. Defaults to the folder that holds aisdlc.json, found from this script.

.PARAMETER SkillsRoot
    The skills directory to scan. Defaults to <RepoRoot>/.claude/skills. Override for testing.

.PARAMETER CatalogPath
    The skill catalog of every AI-SDLC package. Defaults to skill-catalog.json in the ai-sdlc-gates
    skill, beside this script's folder.

.PARAMETER Strict
    Also fail when a skill is missing a recommended pattern.md section, so the advisory findings reach
    CI as a warning instead of passing unseen.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$SkillsRoot,
    [string]$CatalogPath,
    [switch]$Strict
)

Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

$ErrorActionPreference = 'Stop'

if (-not $SkillsRoot) { $SkillsRoot = Join-Path $RepoRoot '.claude' 'skills' }
$linkRoot = Split-Path (Split-Path $SkillsRoot -Parent) -Parent
if (-not $CatalogPath) { $CatalogPath = Join-Path $PSScriptRoot '..' 'skill-catalog.json' }

$catalogSkills = @()
if (Test-Path -LiteralPath $CatalogPath -PathType Leaf) {
    $catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json -AsHashtable
    if ($catalog.skills) { $catalogSkills = @($catalog.skills.Values | ForEach-Object { $_ } | Where-Object { $_ }) }
}

$emDash = [char]0x2014
$validPhases = @('discovery', 'elaboration', 'create', 'mature', 'cross-cutting')
$validKinds = @('workflow', 'knowledge')
$knowledgeMaxLines = 120
$descriptionMaxChars = 1024
# Skill names are bare verb-noun, with the phase/persona in frontmatter. A name that starts with
# one of the old phase/area prefixes is a regression to the superseded scheme. The list is explicit and
# adjustable: if a legitimate verb-noun ever collides (e.g. a real 'create-*' action), drop that token here.
$forbiddenNamePrefixes = @('discovery', 'elaboration', 'create', 'mature', 'cross-cutting', 'governance', 'core', 'agent')
# External tool commands our skills may reference by /slash; not flagged as broken refs. Keep it to what
# every developer has: a personal plugin skill is a reference nobody else can run.
$externalSkillRefs = @()
$lineCitationPatterns = @(
    '\.(?:cs|ts|tsx|razor|bicep|yml|yaml|json|ps1|js|css|sln|csproj):\d+',
    '\b[Ll]ines?\s+\d+'
)

if (-not (Test-Path $SkillsRoot)) {
    Write-Host "Skill hygiene: skills directory not found at $SkillsRoot." -ForegroundColor Red
    exit 1
}

$skillDirs = Get-ChildItem -Path $SkillsRoot -Directory | Sort-Object Name
$skillNames = $skillDirs.Name

$workflowCount = 0
$knowledgeCount = 0

$violations = [System.Collections.Generic.List[object]]::new()
function Add-Violation { param($Skill, $Rule, $Detail) $violations.Add([pscustomobject]@{ Skill = $Skill; Rule = $Rule; Detail = $Detail }) }

$advisories = [System.Collections.Generic.List[object]]::new()
function Add-Advisory { param($Skill, $Rule, $Detail) $advisories.Add([pscustomobject]@{ Skill = $Skill; Rule = $Rule; Detail = $Detail }) }

# A plain or quoted value can go on over more indented lines, which YAML folds with a space.
function Get-PlainDescription {
    param([string[]]$Lines, [int]$Start, [string]$Value)

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add($Value)
    for ($j = $Start + 1; $j -lt $Lines.Count -and $Lines[$j] -match '^\s+\S'; $j++) { $parts.Add($Lines[$j].Trim()) }
    return ($parts -join ' ').Trim().Trim('"', "'")
}

# A block value runs to the first line that is not indented. A literal block (|) keeps its lines; a
# folded block (>) joins them with one space and keeps a blank line as a line break.
function Get-BlockDescription {
    param([string[]]$Lines, [int]$Start, [bool]$Folded)

    $block = [System.Collections.Generic.List[string]]::new()
    for ($j = $Start + 1; $j -lt $Lines.Count -and $Lines[$j] -notmatch '^\S'; $j++) { $block.Add($Lines[$j].Trim()) }
    if (-not $Folded) { return ($block -join "`n").Trim() }
    $text = [System.Text.StringBuilder]::new()
    foreach ($line in $block) {
        if ($line -eq '') { [void]$text.Append("`n"); continue }
        if ($text.Length -gt 0 -and -not $text.ToString().EndsWith("`n")) { [void]$text.Append(' ') }
        [void]$text.Append($line)
    }
    return $text.ToString().Trim()
}

# The description as a YAML reader sees it: a folded block (>) joins its lines with one space, a
# literal block (|) keeps them, and an inline value loses its quotes. Copilot counts this value.
function Get-FrontmatterDescription {
    param([string]$Frontmatter)

    $lines = [string[]]($Frontmatter -split '\r?\n')
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^description:[ \t]*(.*)$') { continue }
        $value = $Matches[1].Trim()
        if ($value -notmatch '^([>|])[-+]?$') { return Get-PlainDescription -Lines $lines -Start $i -Value $value }
        return Get-BlockDescription -Lines $lines -Start $i -Folded ($Matches[1] -eq '>')
    }
    return ''
}

foreach ($dir in $skillDirs) {
    $name = $dir.Name
    $path = Join-Path $dir.FullName 'SKILL.md'
    if (-not (Test-Path $path)) { Add-Violation $name 'skill-md' 'no SKILL.md in folder'; continue }
    $text = Get-Content -LiteralPath $path -Raw

    # Scope name/phase/persona to the YAML frontmatter block, so a `phase:`-like line in the body prose
    # is not mistaken for the frontmatter field.
    $fmMatch = [regex]::Match($text, '\A\s*---\r?\n(.*?)\r?\n---\r?\n', 'Singleline')
    $fm = if ($fmMatch.Success) { $fmMatch.Groups[1].Value } else { '' }

    $fmName = if ($fm -match '(?m)^name:\s*(\S+)') { $matches[1] } else { '' }
    if ($fmName -ne $name) { Add-Violation $name 'name=folder' "frontmatter name '$fmName' does not match folder" }
    if ($fmName -cnotmatch '^[a-z0-9]+(-[a-z0-9]+)*$' -or $fmName.Length -gt 64) {
        Add-Violation $name 'name-spec' "name '$fmName' must have 1 to 64 lowercase letters, digits and single hyphens, with no hyphen at either end"
    }

    $description = Get-FrontmatterDescription -Frontmatter $fm
    if (-not $description) { Add-Violation $name 'description' 'missing or empty frontmatter description:' }
    elseif ($description.Length -gt $descriptionMaxChars) {
        Add-Violation $name 'description-length' "the description has $($description.Length) characters; GitHub Copilot does not load a skill whose description is over $descriptionMaxChars (the Agent Skills specification), so move the detail into the body"
    }

    foreach ($pfx in $forbiddenNamePrefixes) {
        if ($name -like "$pfx-*") {
            Add-Violation $name 'bare-name' "skill name is phase/area-prefixed ('$pfx-...'); use a bare verb-noun name and carry the phase/persona in frontmatter"
            break
        }
    }

    $kind = if ($fm -match '(?m)^kind:\s*(\S+)') { $matches[1] } else { '' }
    if (-not $kind) { Add-Violation $name 'kind' 'missing frontmatter kind: (workflow or knowledge)' }
    elseif ($kind -notin $validKinds) { Add-Violation $name 'kind' "kind '$kind' is not one of: $($validKinds -join ', ')" }
    $isKnowledge = $kind -eq 'knowledge'
    if ($isKnowledge) { $knowledgeCount++ } else { $workflowCount++ }

    $phase = if ($fm -match '(?m)^phase:\s*(\S+)') { $matches[1] } else { '' }
    $hasPersona = $fm -match '(?m)^persona:\s*\S'
    if ($isKnowledge) {
        if ($phase) { Add-Violation $name 'knowledge-shape' 'a knowledge skill has no phase: it is not a step in the flow' }
        if ($hasPersona) { Add-Violation $name 'knowledge-shape' 'a knowledge skill has no persona: every role loads it' }
        if ($fm -notmatch '(?m)^user-invocable:\s*false\s*$') { Add-Violation $name 'knowledge-shape' 'a knowledge skill sets user-invocable: false, so it stays out of the slash-command list' }
        if ($text -match '(?m)^##\s*Next steps') { Add-Violation $name 'knowledge-shape' 'a knowledge skill has no "## Next steps": the workflow skill that loaded it decides what comes next' }
        $lineCount = ($text.TrimEnd() -split '\r?\n').Count
        if ($lineCount -gt $knowledgeMaxLines) { Add-Violation $name 'knowledge-size' "a knowledge skill is at most $knowledgeMaxLines lines and this one has $lineCount; move the detail into the docs page it links" }
        $sourcesMatch = [regex]::Match($text, '(?ms)^##[ \t]*Sources[ \t]*\r?$.*?(?=^##[ \t]|\z)')
        if (-not $sourcesMatch.Success) { Add-Violation $name 'sources' 'a knowledge skill needs a "## Sources" section that links the docs holding the full rule' }
        else {
            $links = @([regex]::Matches($sourcesMatch.Value, '\]\(([^)\s#]+)(?:#[^)]*)?\)') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notmatch '^[a-z]+:' })
            if ($links.Count -eq 0) { Add-Violation $name 'sources' 'the Sources section links no repository page; link the docs page that holds the full rule' }
            foreach ($link in $links) {
                $target = if ($link.StartsWith('/')) { Join-Path $linkRoot $link.TrimStart('/') } else { Join-Path $dir.FullName $link }
                if (-not (Test-Path -LiteralPath $target)) { Add-Violation $name 'sources' "the Sources link '$link' does not resolve" }
            }
        }
    }
    else {
        if (-not $phase) { Add-Violation $name 'phase' 'missing frontmatter phase:' }
        elseif ($phase -notin $validPhases) { Add-Violation $name 'phase' "phase '$phase' is not one of: $($validPhases -join ', ')" }
        if (-not $hasPersona) { Add-Violation $name 'persona' 'missing or empty frontmatter persona:' }
        if ($text -notmatch 'Usable by|Invoked as|Owned by') { Add-Violation $name 'persona-line' 'no "Owned by" / "Usable by" / "Invoked as" role-framing line in the body' }
        if ($text -notmatch '(?m)^##\s*Next steps') { Add-Violation $name 'next-steps' 'no "## Next steps" section' }
    }

    if ($text -notmatch 'Use (when|whenever|after|once|during|this)') { Add-Violation $name 'trigger-rich-desc' 'description lacks triggering language (Use when/whenever/after/...)' }

    # The pointers must sit INSIDE the Standing rules section, so read that section only: from its
    # heading to the next heading of the same level or the end of the file. A file-wide search would
    # pass an empty block whenever the paths appear anywhere else, for example under References.
    $standingMatch = [regex]::Match($text, '(?ms)^##[ \t]*Standing rules[ \t]*\r?$.*?(?=^##[ \t]|\z)')
    if (-not $standingMatch.Success) { Add-Violation $name 'standing-rules' 'no "## Standing rules" section' }
    else {
        $standingBody = $standingMatch.Value
        $missingPointers = @()
        if ($standingBody -notmatch '\]\((?:[^)\s]*/)?language\.md(?:#[^)]*)?\)') { $missingPointers += 'language.md' }
        if ($standingBody -notmatch '\]\((?:[^)\s]*/)?autolearn\.md(?:#[^)]*)?\)') { $missingPointers += 'autolearn.md' }
        if ($missingPointers.Count -gt 0) { Add-Violation $name 'standing-rules' ("the Standing rules section itself does not link: " + ($missingPointers -join ', ')) }
    }

    if ($text.Contains($emDash)) { Add-Violation $name 'em-dash' 'contains an em-dash (U+2014)' }

    foreach ($p in $lineCitationPatterns) {
        if ($text -match $p) { Add-Violation $name 'line-citation' "matches source line-citation pattern ($p)"; break }
    }

    # Cross-refs: a `/token` (kebab) must resolve to a real skill folder or an allowlisted external tool skill.
    # The boundary is path-aware so a doc path or markdown link is not mistaken for a skill ref: the lookbehind
    # rejects a slash preceded by a word char, another slash, a dot, or an open paren (so docs/area/x,
    # ./azure-x, ../work-instructions/azure-x, and (/azure-x) are skipped), and a token followed by a '.' is a
    # file path (e.g. a link to /azure-x.md), not a skill.
    $badRefs = [System.Collections.Generic.List[string]]::new()
    foreach ($m in [regex]::Matches($text, '(?<![\w/.(])/([a-z][a-z0-9]*(?:-[a-z0-9]+)+)')) {
        $tok = $m.Groups[1].Value
        # A token immediately followed by a file extension (a dot then an alphanumeric, e.g. /azure-x.md) is a
        # path, not a skill ref. A trailing sentence period (dot then space/newline/end) is not an extension.
        $rest = $text.Substring($m.Index + $m.Length)
        if ($rest -match '^\.[a-z0-9]') { continue }
        if ($skillNames -notcontains $tok -and $catalogSkills -notcontains $tok -and $externalSkillRefs -notcontains $tok -and -not $badRefs.Contains($tok)) { $badRefs.Add($tok) }
    }
    if ($badRefs.Count -gt 0) { Add-Violation $name 'cross-ref' ("unresolved skill reference(s): " + ($badRefs -join ', ')) }

    $pluginRefs = @([regex]::Matches($text, '`([a-z][a-z0-9-]*:[a-z][a-z0-9-]+)`') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    if ($pluginRefs.Count -gt 0) { Add-Violation $name 'plugin-ref' ("plugin-style skill reference(s) nobody else has: " + ($pluginRefs -join ', ') + '; name a repository skill or agent, or describe the step') }

    if ($isKnowledge) { continue }

    # Advisory (non-failing) per the handbook page pattern.md: recommended for all skills, required for
    # executor / orchestrator skills once the ramp closes. Warnings now so pre-convention skills do not
    # fail the build.
    if ($text -notmatch '(?m)^##\s*Failure modes') { Add-Advisory $name 'failure-modes' 'no "## Failure modes" section (recommended; required for executor skills once the ramp closes)' }
    if ($text -notmatch '(?m)^##\s*Observable signal') { Add-Advisory $name 'observable-signal' 'no "## Observable signal" section (recommended)' }
}

if ($advisories.Count -gt 0) {
    $label = if ($Strict) { 'Skill hygiene advisories (recommended sections from pattern.md)' } else { 'Skill hygiene advisories (recommended sections from pattern.md, not blocking)' }
    Write-Host ("{0}: {1}" -f $label, $advisories.Count) -ForegroundColor Yellow
    foreach ($a in $advisories) { Write-Host ("  {0}  [{1}]  {2}" -f $a.Skill, $a.Rule, $a.Detail) -ForegroundColor DarkYellow }
}

if ($violations.Count -gt 0) {
    Write-Host "Skill hygiene violation: one or more skills under .claude/skills/ break a structure or house-style rule." -ForegroundColor Red
    foreach ($v in $violations) { Write-Host ("  {0}  [{1}]  {2}" -f $v.Skill, $v.Rule, $v.Detail) }
    $affected = ($violations | Select-Object -ExpandProperty Skill -Unique).Count
    Write-Host "FIX: Give each skill named above the part its kind needs. Every skill has a lowercase hyphenated name that matches its folder and a description of at most $descriptionMaxChars characters. A workflow skill has a phase and persona, a trigger-rich description, a Standing rules section that links both standing-rule pages, and a Next steps section. A knowledge skill has user-invocable: false, a Sources section with links that resolve, and no phase, persona or Next steps (.claude/skills/ai-sdlc-handbook/references/pattern.md)." -ForegroundColor Red
    Write-Host ("Found {0} violation(s) across {1} of {2} skill(s)." -f $violations.Count, $affected, $skillDirs.Count) -ForegroundColor Red
    exit 1
}

if ($Strict -and $advisories.Count -gt 0) {
    $affected = ($advisories | Select-Object -ExpandProperty Skill -Unique).Count
    Write-Host ("Strict mode: {0} recommended section(s) missing across {1} of {2} skill(s); failing." -f $advisories.Count, $affected, $skillDirs.Count) -ForegroundColor Yellow
    exit 1
}

Write-Host ("Skill hygiene OK: {0} skill(s) pass, {1} workflow and {2} knowledge (kind, name=folder and the name spec, a description within $descriptionMaxChars characters, the shape of each kind, trigger-rich description, Standing rules, no em-dash, no line-citations, cross-refs resolve, no plugin refs)." -f $skillDirs.Count, $workflowCount, $knowledgeCount)
exit 0
