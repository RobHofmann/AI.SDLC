#requires -Version 7.4

Describe 'Get-SkillUsage' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts' 'DocToolTestHarness.psm1') -Force
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Get-SkillUsage.ps1'

        function New-Skill {
            param(
                [Parameter(Mandatory)][string]$Root,
                [Parameter(Mandatory)][string]$Name,
                [string]$Body = 'A skill.'
            )
            $dir = Join-Path $Root ".claude/skills/$Name"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'SKILL.md') -Value "# $Name`n`n$Body`n" -NoNewline
        }

        function New-Transcript {
            param(
                [Parameter(Mandatory)][string]$Root,
                [Parameter(Mandatory)][string]$Project,
                [Parameter(Mandatory)][string]$Name,
                [string[]]$Lines = @()
            )
            $dir = Join-Path $Root $Project
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir "$Name.jsonl") -Value ($Lines -join "`n") -NoNewline
        }

        function New-AgentCall {
            param([Parameter(Mandatory)][string]$Skill, [string]$When = '2026-09-17T10:00:00.000Z')
            return '{"timestamp":"' + $When + '","message":{"content":[{"type":"tool_use","id":"t1","name":"Skill","input":{"skill":"' + $Skill + '","args":"secret work detail"}}]}}'
        }

        function New-TypedCall {
            param([Parameter(Mandatory)][string]$Skill, [string]$When = '2026-09-16T10:00:00.000Z')
            return '{"timestamp":"' + $When + '","message":{"content":"<command-name>/' + $Skill + '</command-name>"}}'
        }

        function Invoke-Report {
            param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$TranscriptRoot, [hashtable]$Extra = @{})
            return & $script:ScriptUnderTest -RepoRoot $RepoRoot -TranscriptRoot $TranscriptRoot -CopilotSessionRoot $script:CopilotSessions -ProjectFilter '*Demo*' @Extra
        }
    }

    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString('N'))
        $script:Transcripts = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        Set-AiSdlcTestConfig -Root $script:Root
        New-Item -ItemType Directory -Path $script:Transcripts -Force | Out-Null
        $script:CopilotSessions = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:CopilotSessions -Force | Out-Null
        New-Skill -Root $script:Root -Name 'implement' -Body 'Calls /write-docs and /write-adr.'
        New-Skill -Root $script:Root -Name 'write-docs'
        New-Skill -Root $script:Root -Name 'write-adr'
    }

    It 'counts an agent call, which is how one skill delegating to another shows up' {
        New-Transcript -Root $script:Transcripts -Project 'C--Demo' -Name 's1' -Lines @(
            (New-AgentCall -Skill 'write-docs')
            (New-AgentCall -Skill 'write-docs')
        )

        $rows = Invoke-Report -RepoRoot $script:Root -TranscriptRoot $script:Transcripts -Extra @{ AsObject = $true }
        $row = $rows | Where-Object { $_.Skill -eq 'write-docs' }

        $row.Agent | Should -Be 2
        $row.Typed | Should -Be 0
        $row.Total | Should -Be 2
    }

    It 'counts a typed slash command apart from an agent call' {
        New-Transcript -Root $script:Transcripts -Project 'C--Demo' -Name 's1' -Lines @(
            (New-TypedCall -Skill 'implement')
            (New-AgentCall -Skill 'implement')
        )

        $row = (Invoke-Report -RepoRoot $script:Root -TranscriptRoot $script:Transcripts -Extra @{ AsObject = $true }) |
            Where-Object { $_.Skill -eq 'implement' }

        $row.Typed | Should -Be 1
        $row.Agent | Should -Be 1
        $row.Total | Should -Be 2
    }

    It 'ignores a slash command that is not one of this repository skills' {
        New-Transcript -Root $script:Transcripts -Project 'C--Demo' -Name 's1' -Lines @(
            (New-TypedCall -Skill 'clear')
            (New-TypedCall -Skill 'model')
        )

        $rows = Invoke-Report -RepoRoot $script:Root -TranscriptRoot $script:Transcripts -Extra @{ AsObject = $true }

        ($rows | Measure-Object -Property Total -Sum).Sum | Should -Be 0
        $rows.Skill | Should -Not -Contain 'clear'
    }

    It 'reads every matching project folder, so a worktree session still counts' {
        New-Transcript -Root $script:Transcripts -Project 'C--Demo' -Name 's1' -Lines @((New-AgentCall -Skill 'write-adr'))
        New-Transcript -Root $script:Transcripts -Project 'C--Demo--worktrees-1-story' -Name 's2' -Lines @((New-AgentCall -Skill 'write-adr'))

        $row = (Invoke-Report -RepoRoot $script:Root -TranscriptRoot $script:Transcripts -Extra @{ AsObject = $true }) |
            Where-Object { $_.Skill -eq 'write-adr' }

        $row.Total | Should -Be 2
    }

    It 'derives the project filter from the repository name in aisdlc.json when none is given' {
        Set-Content -LiteralPath (Join-Path $script:Root 'aisdlc.json') -Value '{ "repository": "Contoso.App" }'
        New-Transcript -Root $script:Transcripts -Project 'C--src-Contoso-App' -Name 's1' -Lines @((New-AgentCall -Skill 'write-adr'))
        New-Transcript -Root $script:Transcripts -Project 'C--src-Other' -Name 's2' -Lines @((New-AgentCall -Skill 'write-adr'))

        $row = (& $script:ScriptUnderTest -RepoRoot $script:Root -TranscriptRoot $script:Transcripts -CopilotSessionRoot $script:CopilotSessions -AsObject) |
            Where-Object { $_.Skill -eq 'write-adr' }

        $row.Total | Should -Be 1
    }

    It 'skips a project folder the filter does not match' {
        New-Transcript -Root $script:Transcripts -Project 'C--SomethingElse' -Name 's1' -Lines @((New-AgentCall -Skill 'write-adr'))

        $row = (Invoke-Report -RepoRoot $script:Root -TranscriptRoot $script:Transcripts -Extra @{ AsObject = $true }) |
            Where-Object { $_.Skill -eq 'write-adr' }

        $row.Total | Should -Be 0
    }

    It 'counts how many other skills name this one, which is the call graph rather than the runs' {
        $rows = Invoke-Report -RepoRoot $script:Root -TranscriptRoot $script:Transcripts -Extra @{ AsObject = $true }

        ($rows | Where-Object { $_.Skill -eq 'write-docs' }).ReferencedBy | Should -Be 1
        ($rows | Where-Object { $_.Skill -eq 'write-adr' }).ReferencedBy | Should -Be 1
        ($rows | Where-Object { $_.Skill -eq 'implement' }).ReferencedBy | Should -Be 0
    }

    It 'gives each skill row its kind, workflow or knowledge' {
        New-Skill -Root $script:Root -Name 'how-we-do-x' -Body "kind: knowledge"
        $rows = Invoke-Report -RepoRoot $script:Root -TranscriptRoot $script:Transcripts -Extra @{ AsObject = $true }

        ($rows | Where-Object { $_.Skill -eq 'how-we-do-x' }).Kind | Should -Be 'knowledge'
        ($rows | Where-Object { $_.Skill -eq 'implement' }).Kind | Should -Be 'workflow'
    }

    It 'counts agent runs by subagent type, and the skills that hand work to each agent' {
        $agents = Join-Path $script:Root '.claude/agents'
        New-Item -ItemType Directory -Path $agents -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $agents 'code-reviewer.md') -Value "---`nname: code-reviewer`n---"
        Set-Content -LiteralPath (Join-Path $agents 'blind-judge.md') -Value "---`nname: blind-judge`n---"
        New-Skill -Root $script:Root -Name 'refactor' -Body 'Hand the review to the `code-reviewer` agent.'
        New-Transcript -Root $script:Transcripts -Project 'C--Demo' -Name 's1' -Lines @(
            '{"timestamp":"2026-09-20T10:00:00.000Z","message":{"content":[{"type":"tool_use","name":"Agent","input":{"description":"review","prompt":"secret diff text","subagent_type":"code-reviewer"}}]}}'
            '{"timestamp":"2026-09-21T10:00:00.000Z","message":{"content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"code-reviewer","prompt":"more secret"}}]}}'
            '{"timestamp":"2026-09-21T10:00:00.000Z","message":{"content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"Explore","prompt":"x"}}]}}'
        )

        $rows = Invoke-Report -RepoRoot $script:Root -TranscriptRoot $script:Transcripts -Extra @{ AsObject = $true }
        $reviewer = $rows | Where-Object { $_.Skill -eq 'code-reviewer' }

        $reviewer.Kind | Should -Be 'agent'
        $reviewer.Total | Should -Be 2
        $reviewer.ReferencedBy | Should -Be 1
        $reviewer.LastUsed | Should -Be '2026-09-21'
        ($rows | Where-Object { $_.Skill -eq 'blind-judge' }).Total | Should -Be 0
        $rows.Skill | Should -Not -Contain 'Explore'
    }

    It 'reports the last use as a date' {
        New-Transcript -Root $script:Transcripts -Project 'C--Demo' -Name 's1' -Lines @(
            (New-AgentCall -Skill 'write-adr' -When '2026-01-02T09:00:00.000Z')
            (New-AgentCall -Skill 'write-adr' -When '2026-03-04T09:00:00.000Z')
        )

        $row = (Invoke-Report -RepoRoot $script:Root -TranscriptRoot $script:Transcripts -Extra @{ AsObject = $true }) |
            Where-Object { $_.Skill -eq 'write-adr' }

        $row.LastUsed | Should -Be '2026-03-04'
    }

    It 'gives each skill an age in weeks and a per-week rate, so a young skill is not judged as unused' {
        New-Transcript -Root $script:Transcripts -Project 'C--Demo' -Name 's1' -Lines @(
            (New-AgentCall -Skill 'write-adr'), (New-AgentCall -Skill 'write-adr'), (New-AgentCall -Skill 'write-adr'), (New-AgentCall -Skill 'write-adr')
            (New-AgentCall -Skill 'write-docs'), (New-AgentCall -Skill 'write-docs')
        )
        $old = (Get-Date).AddDays(-70).ToString('yyyy-MM-dd')
        $young = (Get-Date).AddDays(-7).ToString('yyyy-MM-dd')
        $ages = @{ 'write-adr' = $old; 'write-docs' = $young; 'implement' = $old }

        $rows = Invoke-Report -RepoRoot $script:Root -TranscriptRoot $script:Transcripts -Extra @{ AsObject = $true; SkillAgesForTest = $ages }
        $adr = $rows | Where-Object { $_.Skill -eq 'write-adr' }
        $doc = $rows | Where-Object { $_.Skill -eq 'write-docs' }

        $adr.AgeWeeks | Should -Be 10
        $adr.PerWeek | Should -Be 0.4
        $doc.AgeWeeks | Should -Be 1
        $doc.PerWeek | Should -Be 2
        $doc.PerWeek | Should -BeGreaterThan $adr.PerWeek
    }

    It 'leaves the age blank for a skill whose first commit is unknown, rather than guessing' {
        $rows = Invoke-Report -RepoRoot $script:Root -TranscriptRoot $script:Transcripts -Extra @{ AsObject = $true; SkillAgesForTest = @{ 'write-adr' = '2026-01-01' } }
        ($rows | Where-Object { $_.Skill -eq 'implement' }).AgeWeeks | Should -BeNullOrEmpty
        ($rows | Where-Object { $_.Skill -eq 'write-adr' }).AgeWeeks | Should -BeGreaterThan 0
    }

    It 'lists a skill that was never invoked with a total of zero rather than leaving it out' {
        $rows = Invoke-Report -RepoRoot $script:Root -TranscriptRoot $script:Transcripts -Extra @{ AsObject = $true }

        $rows.Count | Should -Be 3
        ($rows | Where-Object { $_.Total -eq 0 }).Count | Should -Be 3
    }

    It 'never prints anything from the transcript except skill names and dates' {
        New-Transcript -Root $script:Transcripts -Project 'C--Demo' -Name 's1' -Lines @((New-AgentCall -Skill 'write-adr'))

        $out = Invoke-Report -RepoRoot $script:Root -TranscriptRoot $script:Transcripts *>&1 | Out-String

        $out | Should -Not -Match 'secret work detail'
    }

    It 'throws when the repository has no skills folder, rather than reporting an empty set' {
        $empty = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $empty -Force | Out-Null

        { & $script:ScriptUnderTest -RepoRoot $empty -TranscriptRoot $script:Transcripts -CopilotSessionRoot $script:CopilotSessions } |
            Should -Throw -ExpectedMessage '*No skills folder*'
    }

    It 'reports zero counts when the transcript root does not exist, instead of failing' {
        $missing = Join-Path $TestDrive 'no-transcripts-here'

        $rows = & $script:ScriptUnderTest -RepoRoot $script:Root -TranscriptRoot $missing -CopilotSessionRoot $missing -AsObject

        $rows.Count | Should -Be 3
        ($rows | Measure-Object -Property Total -Sum).Sum | Should -Be 0
    }

    Context 'GitHub Copilot CLI sessions' {
        BeforeAll {
            function New-CopilotSession {
                param([Parameter(Mandatory)][string]$Root, [string]$Repository = 'contoso/project/Demo', [string]$GitRoot = 'C:\\src\\Demo', [string[]]$Lines = @())
                $dir = Join-Path $Root ([System.Guid]::NewGuid().ToString())
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                $start = '{"type":"session.start","data":{"sessionId":"s","copilotVersion":"1.0.100","context":{"cwd":"' + $GitRoot + '","gitRoot":"' + $GitRoot + '","repository":"' + $Repository + '"}},"id":"1","timestamp":"2026-10-20T10:45:22.436Z"}'
                Set-Content -LiteralPath (Join-Path $dir 'events.jsonl') -Value ((@($start) + $Lines) -join "`n") -NoNewline
            }
        }

        It 'counts a skill call, a typed command and an agent run from the session log of this repository' {
            $agents = Join-Path $script:Root '.claude/agents'
            New-Item -ItemType Directory -Path $agents -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $agents 'code-reviewer.md') -Value "---`nname: code-reviewer`n---"
            New-CopilotSession -Root $script:CopilotSessions -Lines @(
                '{"type":"user.message","data":{"content":"/implement #1 secret plan","transformedContent":"/implement #1"},"id":"2","timestamp":"2026-10-20T11:00:00.000Z"}'
                '{"type":"tool.execution_start","data":{"toolCallId":"c1","toolName":"skill","arguments":{"skill":"write-docs"}},"id":"3","timestamp":"2026-10-21T11:00:00.000Z"}'
                '{"type":"tool.execution_start","data":{"toolCallId":"c2","toolName":"task","arguments":{"name":"review","prompt":"secret diff with \"agent_type\":\"blind-judge\" in it","agent_type":"code-reviewer","description":"x"}},"id":"4","timestamp":"2026-10-22T11:00:00.000Z"}'
            )

            $rows = Invoke-Report -RepoRoot $script:Root -TranscriptRoot $script:Transcripts -Extra @{ AsObject = $true }

            ($rows | Where-Object { $_.Skill -eq 'implement' }).Typed | Should -Be 1
            $docs = $rows | Where-Object { $_.Skill -eq 'write-docs' }
            $docs.Agent | Should -Be 1
            $docs.LastUsed | Should -Be '2026-10-21'
            ($rows | Where-Object { $_.Skill -eq 'code-reviewer' }).Total | Should -Be 1
        }

        It 'skips a Copilot session of another repository' {
            New-CopilotSession -Root $script:CopilotSessions -Repository 'contoso/project/Other' -GitRoot 'C:\\src\\Other' -Lines @(
                '{"type":"tool.execution_start","data":{"toolCallId":"c1","toolName":"skill","arguments":{"skill":"write-adr"}},"id":"3","timestamp":"2026-10-21T11:00:00.000Z"}'
            )

            $row = (Invoke-Report -RepoRoot $script:Root -TranscriptRoot $script:Transcripts -Extra @{ AsObject = $true }) | Where-Object { $_.Skill -eq 'write-adr' }

            $row.Total | Should -Be 0
        }

        It 'prints only names, dates and counts from a Copilot session' {
            New-CopilotSession -Root $script:CopilotSessions -Lines @(
                '{"type":"user.message","data":{"content":"/write-adr record the secret vendor deal"},"id":"2","timestamp":"2026-10-20T11:00:00.000Z"}'
            )

            $out = Invoke-Report -RepoRoot $script:Root -TranscriptRoot $script:Transcripts *>&1 | Out-String

            $out | Should -Match '1 GitHub Copilot session'
            $out | Should -Not -Match 'secret vendor deal'
        }
    }
}
