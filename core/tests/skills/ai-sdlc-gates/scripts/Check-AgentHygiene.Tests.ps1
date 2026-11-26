#requires -Version 7.4

Describe 'Check-AgentHygiene' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Check-AgentHygiene.ps1'

        function New-Workspace {
            $root = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString('N'))
            $agents = Join-Path $root 'agents'
            $skills = Join-Path $root 'skills'
            New-Item -ItemType Directory -Path $agents, $skills -Force | Out-Null
            $personas = Join-Path $root 'personas.md'
            Set-Content -LiteralPath $personas -Value "# Personas`n`n### Architect`n`n### QA`n`n### Designer / UX`n`n### Lead`n"
            foreach ($s in @(@{ Name = 'know-x'; Kind = 'knowledge' }, @{ Name = 'do-x'; Kind = 'workflow' })) {
                New-Item -ItemType Directory -Path (Join-Path $skills $s.Name) -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $skills $s.Name 'SKILL.md') -Value "---`nname: $($s.Name)`nkind: $($s.Kind)`n---`n"
            }
            [pscustomobject]@{ Agents = $agents; Skills = $skills; Personas = $personas }
        }

        function New-Agent {
            param(
                [Parameter(Mandatory)][object]$Ws,
                [string]$File = 'reviewer',
                [string]$Name = $File,
                [string]$Description = 'Reviews a change. Use when a diff needs a second reader.',
                [string]$Tools = 'tools: Read, Grep, Glob',
                [string]$Extra = '',
                [string]$Persona = 'Persona: QA. See [personas](../skills/ai-sdlc-handbook/references/personas.md).',
                [string]$ReadFirst = '',
                [string]$Task = 'Review.',
                [switch]$NoStandingRules
            )
            $fm = "name: $Name"
            if ($Description) { $fm += "`ndescription: >`n  $Description" }
            if ($Tools) { $fm += "`n$Tools" }
            if ($Extra) { $fm += "`n$Extra" }
            $body = "# Reviewer`n`n$Persona`n`n$ReadFirst`n`n## Task`n`n$Task`n"
            if (-not $NoStandingRules) { $body += "`n## Standing rules`n`n- [language](../skills/ai-sdlc-handbook/references/language.md)`n- [autolearn](../skills/ai-sdlc-handbook/references/autolearn.md)`n" }
            Set-Content -LiteralPath (Join-Path $Ws.Agents "$File.md") -Value "---`n$fm`n---`n`n$body" -NoNewline
        }

        function Invoke-AgentHygiene {
            param([Parameter(Mandatory)][object]$Ws, [string]$AgentsRoot = $Ws.Agents, [string]$Catalog)
            $extra = @{}
            if ($Catalog) { $extra.CatalogPath = $Catalog }
            $out = & $script:ScriptUnderTest -AgentsRoot $AgentsRoot -SkillsRoot $Ws.Skills -PersonasFile $Ws.Personas @extra *>&1 | Out-String
            [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }
    }

    BeforeEach { $script:Ws = New-Workspace }

    It 'passes a well-formed read-only agent' {
        New-Agent -Ws $script:Ws
        $r = Invoke-AgentHygiene -Ws $script:Ws
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Agent hygiene OK: 1 agent'
    }

    It 'passes when there is no agents folder at all' {
        $r = Invoke-AgentHygiene -Ws $script:Ws -AgentsRoot (Join-Path $script:Ws.Agents 'missing')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match '0 agents'
    }

    It 'fails when the name does not match the file' {
        New-Agent -Ws $script:Ws -Name 'other'
        $r = Invoke-AgentHygiene -Ws $script:Ws
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'name=file'
    }

    It 'fails when the description is missing or only a block marker' {
        New-Agent -Ws $script:Ws -Description ''
        $r = Invoke-AgentHygiene -Ws $script:Ws
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match '\[description\]'
    }

    It 'fails when the tools list is left out' {
        New-Agent -Ws $script:Ws -Tools ''
        $r = Invoke-AgentHygiene -Ws $script:Ws
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'no explicit tools list'
    }

    It 'fails an agent that can edit files' {
        New-Agent -Ws $script:Ws -Tools 'tools: Read, Edit, Write'
        $r = Invoke-AgentHygiene -Ws $script:Ws
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match "tool 'Edit'"
        $r.Output | Should -Match "tool 'Write'"
    }

    It 'fails an agent with a wildcard or an MCP write tool, in list form' {
        New-Agent -Ws $script:Ws -Tools "tools:`n  - Read`n  - mcp__github__create_issue`n  - mcp__other__*"
        $r = Invoke-AgentHygiene -Ws $script:Ws
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'create_issue'
        $r.Output | Should -Match 'mcp__other__\*'
    }

    It 'fails a tools line written as a folded block or a list over several lines, which hides a write tool' {
        New-Agent -Ws $script:Ws -Tools "tools: >-`n  Read, Write"
        New-Agent -Ws $script:Ws -File 'walker' -Tools "tools: [Read,`n  Write]"
        $r = Invoke-AgentHygiene -Ws $script:Ws
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'reviewer.md  \[tools\]'
        $r.Output | Should -Match 'walker.md  \[tools\]'
    }

    It 'fails a GitHub or a verb-only MCP write tool, and a tool that starts another agent' {
        New-Agent -Ws $script:Ws -Tools 'tools: Read, mcp__github__create_pull_request, mcp__claude_ai_Claude_Docs__update, mcp__github__run_workflow, Agent'
        $r = Invoke-AgentHygiene -Ws $script:Ws
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'create_pull_request'
        $r.Output | Should -Match 'Claude_Docs__update'
        $r.Output | Should -Match 'run_workflow'
        $r.Output | Should -Match "tool 'Agent'"
    }

    It 'passes a GitHub read tool' {
        New-Agent -Ws $script:Ws -Tools 'tools: Read, mcp__github__get_pull_request, mcp__github__get_issue'
        $r = Invoke-AgentHygiene -Ws $script:Ws
        $r.ExitCode | Should -Be 0
    }

    It 'fails an agent with a shell and no Shell use section, and passes it with one' {
        New-Agent -Ws $script:Ws -Tools 'tools: Read, Bash'
        $r = Invoke-AgentHygiene -Ws $script:Ws
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match '\[shell\]'

        New-Agent -Ws $script:Ws -Tools 'tools: Read, Bash' -ReadFirst "## Shell use`n`n- ``git log```n"
        $r = Invoke-AgentHygiene -Ws $script:Ws
        $r.ExitCode | Should -Be 0
    }

    It 'passes an MCP read tool' {
        New-Agent -Ws $script:Ws -Tools 'tools: [Read, mcp__github__get_issue, mcp__github__search_issues]'
        $r = Invoke-AgentHygiene -Ws $script:Ws
        $r.ExitCode | Should -Be 0
    }

    It 'passes an MCP read tool in the GitHub Copilot form server/action' {
        New-Agent -Ws $script:Ws -Tools 'tools: Read, mcp__github__get_issue, github/get_issue, github/search_code'
        $r = Invoke-AgentHygiene -Ws $script:Ws
        $r.ExitCode | Should -Be 0 -Because $r.Output
    }

    It 'fails an MCP write tool or a server wildcard in the GitHub Copilot form: <Tool>' -ForEach @(
        @{ Tool = 'github/create_issue' }
        @{ Tool = 'github/merge_pull_request' }
        @{ Tool = 'github/*' }
    ) {
        New-Agent -Ws $script:Ws -Tools "tools: Read, $Tool"
        $r = Invoke-AgentHygiene -Ws $script:Ws
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match ([regex]::Escape($Tool))
    }

    It 'does not take a tool with a path in brackets for an MCP tool' {
        New-Agent -Ws $script:Ws -Tools 'tools: Read, Bash(tools/run.ps1)' -Task "Review.`n`n## Shell use`n`n- tools/run.ps1"
        $r = Invoke-AgentHygiene -Ws $script:Ws
        $r.Output | Should -Not -Match '\[read-only\]'
    }

    It 'passes an agent whose model is <Model>, a value both tools survive' -ForEach @(
        @{ Model = 'opus' }
        @{ Model = 'sonnet' }
        @{ Model = 'inherit' }
    ) {
        New-Agent -Ws $script:Ws -Extra "model: $Model" -Task "Review.`n`n## Output`n`nAGENT: reviewer`nModel: <the model you run on>"
        $r = Invoke-AgentHygiene -Ws $script:Ws
        $r.ExitCode | Should -Be 0
    }

    It 'fails an opus agent whose output does not name the model it runs on' {
        New-Agent -Ws $script:Ws -Extra 'model: opus'
        $r = Invoke-AgentHygiene -Ws $script:Ws
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match '\[model-report\]'
    }

    It 'passes an opus agent that names its model in its own words' {
        New-Agent -Ws $script:Ws -Extra 'model: opus' -Task "Review.`n`n## Output`n`nModel: Opus 5.5"
        $r = Invoke-AgentHygiene -Ws $script:Ws
        $r.ExitCode | Should -Be 0 -Because $r.Output
    }

    It 'does not ask an inherit agent to name its model' {
        New-Agent -Ws $script:Ws -Extra 'model: inherit'
        $r = Invoke-AgentHygiene -Ws $script:Ws
        $r.ExitCode | Should -Be 0 -Because $r.Output
    }

    It 'does not ask a sonnet agent to name its model, because Copilot falls back to Sonnet anyway' {
        New-Agent -Ws $script:Ws -Extra 'model: sonnet'
        $r = Invoke-AgentHygiene -Ws $script:Ws
        $r.ExitCode | Should -Be 0
    }

    Context 'the writer exception' {
        BeforeAll {
            $script:WriterTask = 'Build the plan test-first. You never commit, push or open a pull request.'
        }

        It 'passes the builder with Edit and Write, a model and the never-commit sentence' {
            New-Agent -Ws $script:Ws -File 'builder' -Tools 'tools: Read, Grep, Glob, Edit, Write' -Extra 'model: sonnet' -Task $script:WriterTask
            $r = Invoke-AgentHygiene -Ws $script:Ws
            $r.ExitCode | Should -Be 0
        }

        It 'fails any other agent that holds <Tool>, because a reviewer that can write is not independent' -ForEach @(
            @{ Tool = 'Edit' }
            @{ Tool = 'Write' }
        ) {
            New-Agent -Ws $script:Ws -File 'reviewer' -Tools "tools: Read, $Tool" -Extra 'model: sonnet' -Task $script:WriterTask
            $r = Invoke-AgentHygiene -Ws $script:Ws
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match ([regex]::Escape("tool '$Tool' can change a file"))
        }

        It 'fails the builder without a model line' {
            New-Agent -Ws $script:Ws -File 'builder' -Tools 'tools: Read, Edit, Write' -Task $script:WriterTask
            $r = Invoke-AgentHygiene -Ws $script:Ws
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match '\[writer\].*sets model'
        }

        It 'fails the builder when its Task section does not say it never commits or pushes' {
            New-Agent -Ws $script:Ws -File 'builder' -Tools 'tools: Read, Edit, Write' -Extra 'model: sonnet' -Task 'Build the plan test-first.'
            $r = Invoke-AgentHygiene -Ws $script:Ws
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match '\[writer\].*never commits or pushes'
        }

        It 'fails the builder when it holds Agent, which is never a writer tool' {
            New-Agent -Ws $script:Ws -File 'builder' -Tools 'tools: Read, Edit, Agent' -Extra 'model: sonnet' -Task $script:WriterTask
            $r = Invoke-AgentHygiene -Ws $script:Ws
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match "tool 'Agent'"
        }
    }

    It 'fails an agent whose model is <Model>, because Claude Code fails on it or runs another model' -ForEach @(
        @{ Model = 'Claude Opus 5.5' }
        @{ Model = 'claude-opus-5.5' }
        @{ Model = 'gpt-unknown' }
    ) {
        New-Agent -Ws $script:Ws -Extra "model: $Model"
        $r = Invoke-AgentHygiene -Ws $script:Ws
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match '\[model\]'
        $r.Output | Should -Match ([regex]::Escape("model '$Model' is not opus, sonnet or inherit"))
    }

    It 'passes an agent without a model line, which the gate leaves to the tool' {
        New-Agent -Ws $script:Ws
        $r = Invoke-AgentHygiene -Ws $script:Ws
        $r.ExitCode | Should -Be 0
    }

    It 'passes a preloaded knowledge skill that the Read first section links' {
        New-Agent -Ws $script:Ws -Extra "skills:`n  - know-x" -ReadFirst "## Read first`n`n- [know-x](../skills/know-x/SKILL.md)"
        $r = Invoke-AgentHygiene -Ws $script:Ws
        $r.ExitCode | Should -Be 0
    }

    It 'fails a preloaded skill that the Read first section does not link' {
        New-Agent -Ws $script:Ws -Extra 'skills: [know-x]'
        $r = Invoke-AgentHygiene -Ws $script:Ws
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'read-first'
    }

    It 'fails a preloaded skill that is a workflow skill or does not exist' {
        New-Agent -Ws $script:Ws -Extra "skills:`n  - do-x`n  - gone-x" -ReadFirst "## Read first`n`n- [do-x](../skills/do-x/SKILL.md)"
        $r = Invoke-AgentHygiene -Ws $script:Ws
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match "'do-x' is not a knowledge skill"
        $r.Output | Should -Match "'gone-x' does not exist"
    }

    It 'passes a preload of a skill from a pack that is not installed, when the catalog lists it and Read first links it' {
        $catalog = Join-Path $TestDrive 'catalog.json'
        Set-Content -LiteralPath $catalog -Value '{ "skills": { "core": ["know-x"], "blazor": ["pack-x"] } }'
        New-Agent -Ws $script:Ws -Extra "skills:`n  - know-x`n  - pack-x" -ReadFirst "## Read first`n`n- [know-x](../skills/know-x/SKILL.md)`n- [pack-x](../skills/pack-x/SKILL.md), when the blazor pack is installed."
        $r = Invoke-AgentHygiene -Ws $script:Ws -Catalog $catalog
        $r.ExitCode | Should -Be 0 -Because $r.Output
    }

    It 'still fails a preload of a pack skill that Read first does not link' {
        $catalog = Join-Path $TestDrive 'catalog.json'
        Set-Content -LiteralPath $catalog -Value '{ "skills": { "blazor": ["pack-x"] } }'
        New-Agent -Ws $script:Ws -Extra "skills:`n  - pack-x" -ReadFirst "## Read first`n`n- nothing"
        $r = Invoke-AgentHygiene -Ws $script:Ws -Catalog $catalog
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'read-first'
    }

    It 'passes several personas, also a split registry name and any' {
        New-Agent -Ws $script:Ws -Persona 'Persona: **Architect** + UX, and QA. The lens is design.'
        New-Agent -Ws $script:Ws -File 'walker' -Persona 'Persona: any'
        $r = Invoke-AgentHygiene -Ws $script:Ws
        $r.ExitCode | Should -Be 0
    }

    It 'fails an unknown persona and a missing persona line' {
        New-Agent -Ws $script:Ws -Persona 'Persona: Security Champion'
        New-Agent -Ws $script:Ws -File 'walker' -Persona 'No persona here.'
        $r = Invoke-AgentHygiene -Ws $script:Ws
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match "persona 'Security Champion'"
        $r.Output | Should -Match 'no "Persona:" line'
    }

    It 'fails without a Standing rules section' {
        New-Agent -Ws $script:Ws -NoStandingRules
        $r = Invoke-AgentHygiene -Ws $script:Ws
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'standing-rules'
    }

    It 'fails on an em-dash' {
        New-Agent -Ws $script:Ws -Description "Reviews $([char]0x2014) carefully. Use when asked."
        $r = Invoke-AgentHygiene -Ws $script:Ws
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'em-dash'
    }

    It 'reports that it could not check when the persona registry is missing' {
        New-Agent -Ws $script:Ws
        $out = & $script:ScriptUnderTest -AgentsRoot $script:Ws.Agents -SkillsRoot $script:Ws.Skills -PersonasFile (Join-Path $TestDrive 'none.md') *>&1 | Out-String
        $LASTEXITCODE | Should -Be 2
        $out | Should -Match 'NOTHING WAS CHECKED'
    }

    It 'is registered as a blocking gate in gates.json' {
        (Get-Content (Join-Path $PSScriptRoot '..' 'gates.json') -Raw) | Should -Match '"script": "scripts/Check-AgentHygiene.ps1"[^\r\n]*"mode": "Blocking"'
    }

    It 'passes a Standing rules section that links the two pages by any relative path' {
        New-Agent -Ws $script:Ws -NoStandingRules
        $file = Join-Path $script:Ws.Agents 'reviewer.md'
        Add-Content -LiteralPath $file -Value "`n## Standing rules`n`n- [language](../../somewhere/language.md)`n- [autolearn](../other/autolearn.md)`n"
        $r = Invoke-AgentHygiene -Ws $script:Ws
        $r.ExitCode | Should -Be 0
    }

    It 'reads the persona registry from the handbook in the skills folder by default' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $agents = Join-Path $root '.claude' 'agents'
        $handbook = Join-Path $root '.claude' 'skills' 'ai-sdlc-handbook' 'references'
        New-Item -ItemType Directory -Path $agents, $handbook -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $handbook 'personas.md') -Value "# Personas`n`n### QA`n"
        New-Agent -Ws ([pscustomobject]@{ Agents = $agents; Skills = (Join-Path $root '.claude' 'skills'); Personas = '' })
        $out = & $script:ScriptUnderTest -RepoRoot $root *>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
    }
}
