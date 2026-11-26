#requires -Version 7.4

Describe 'Sync-AgentsFile' {
    BeforeAll {
        $script:Script = Join-Path $PSScriptRoot 'Sync-AgentsFile.ps1'
        Import-Module (Join-Path $PSScriptRoot 'DocToolTestHarness.psm1') -Force

        function New-AgentsRepo {
            param(
                [string]$Agents,
                [string]$Packs = '[]',
                [hashtable]$Parts = @{ 'ai-sdlc-gates/assets/agents-core.md' = "## Core rules`n`n- **C01** Core clause." }
            )
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('saf-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value '{}' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $root 'apm.yml') -Value ((@('dependencies:', '  apm:') + @($Packs | ConvertFrom-Json | ForEach-Object { "    - ../AI.SDLC/packs/$_" })) -join "`n")
            [IO.File]::WriteAllText((Join-Path $root 'AGENTS.md'), $Agents)
            foreach ($rel in $Parts.Keys) {
                $full = Join-Path $root '.claude' 'skills' $rel
                New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
                [IO.File]::WriteAllText($full, $Parts[$rel])
            }
            return $root
        }

        function Invoke-Sync {
            param([string]$Root, [switch]$Check)
            $extra = @()
            if ($Check) { $extra += '-Check' }
            $run = Invoke-ScriptInProcess -Path $script:Script -Arguments (@('-RepoRoot', $Root) + $extra)
            return [pscustomobject]@{ Code = $run.ExitCode; Output = $run.Output; Text = [IO.File]::ReadAllText((Join-Path $Root 'AGENTS.md')) }
        }
    }

    It 'places the core part before the first section heading and leaves the rest unchanged' {
        $root = New-AgentsRepo -Agents "# AGENTS.md - Demo`n`nIntro line.`n`n## Build`n`nRepo text.`n"

        $result = Invoke-Sync -Root $root

        $result.Code | Should -Be 0
        $result.Text | Should -Be ("# AGENTS.md - Demo`n`nIntro line.`n`n" +
            "<!-- ai-sdlc:core:start - installed from AI.SDLC; change it there, not here -->`n## Core rules`n`n- **C01** Core clause.`n<!-- ai-sdlc:core:end -->`n`n" +
            "## Build`n`nRepo text.`n")
    }

    It 'replaces only the text between the markers and keeps every line outside them' {
        $agents = "# A`n`nTop.`n<!-- ai-sdlc:core:start - installed from AI.SDLC; change it there, not here -->`nold hand edit`n<!-- ai-sdlc:core:end -->`nBottom.`n"
        $root = New-AgentsRepo -Agents $agents

        $result = Invoke-Sync -Root $root

        $result.Text | Should -Be "# A`n`nTop.`n<!-- ai-sdlc:core:start - installed from AI.SDLC; change it there, not here -->`n## Core rules`n`n- **C01** Core clause.`n<!-- ai-sdlc:core:end -->`nBottom.`n"
    }

    It 'gives the same file when it runs twice' {
        $root = New-AgentsRepo -Agents "# A`n`n## B`n`ntext`n" -Packs '["dotnet"]' -Parts @{
            'ai-sdlc-gates/assets/agents-core.md' = 'core text'
            'test-first-dotnet/assets/agents-dotnet.md' = 'dotnet text'
        }

        $first = Invoke-Sync -Root $root
        $second = Invoke-Sync -Root $root

        $second.Text | Should -Be $first.Text
        $second.Output | Should -Match 'in sync'
    }

    It 'adds the part of every listed pack after the core part, and skips a pack that is not listed' {
        $root = New-AgentsRepo -Agents "# A`n`n## B`n" -Packs '["dotnet"]' -Parts @{
            'ai-sdlc-gates/assets/agents-core.md' = 'core text'
            'test-first-dotnet/assets/agents-dotnet.md' = 'dotnet text'
            'bicep-conventions/assets/agents-bicep.md' = 'bicep text'
        }

        $result = Invoke-Sync -Root $root

        $result.Text.IndexOf('core text') | Should -BeLessThan $result.Text.IndexOf('dotnet text')
        $result.Text | Should -Not -Match 'bicep text'
    }

    It 'removes the part of a pack that is no longer installed' {
        $agents = "# A`n`n<!-- ai-sdlc:core:start - installed from AI.SDLC; change it there, not here -->`ncore text`n<!-- ai-sdlc:core:end -->`n`n<!-- ai-sdlc:bicep:start - installed from AI.SDLC; change it there, not here -->`nbicep text`n<!-- ai-sdlc:bicep:end -->`n`n## B`n"
        $root = New-AgentsRepo -Agents $agents -Parts @{ 'ai-sdlc-gates/assets/agents-core.md' = 'core text' }

        $result = Invoke-Sync -Root $root

        $result.Text | Should -Not -Match 'bicep'
        $result.Text | Should -Match 'core text'
    }

    It 'fails the check on a hand edit between the markers, names the fix, and writes nothing' {
        $agents = "# A`n<!-- ai-sdlc:core:start - installed from AI.SDLC; change it there, not here -->`nedited by hand`n<!-- ai-sdlc:core:end -->`n"
        $root = New-AgentsRepo -Agents $agents

        $result = Invoke-Sync -Root $root -Check

        $result.Code | Should -Be 1
        $result.Output | Should -Match 'FIX: Run pwsh \.claude/skills/ai-sdlc-gates/scripts/Sync-AgentsFile\.ps1'
        $result.Text | Should -Be $agents
    }

    It 'passes the check when the file is in sync' {
        $root = New-AgentsRepo -Agents "# A`n`n## B`n"
        Invoke-Sync -Root $root | Out-Null

        $result = Invoke-Sync -Root $root -Check

        $result.Code | Should -Be 0
    }

    It 'fails the check when the core part is missing' {
        $root = New-AgentsRepo -Agents "# A`n`n## B`n"

        $result = Invoke-Sync -Root $root -Check

        $result.Code | Should -Be 1
    }

    It 'exits 2 when no installed skill ships the core part' {
        $root = New-AgentsRepo -Agents "# A`n" -Parts @{}

        $result = Invoke-Sync -Root $root -Check

        $result.Code | Should -Be 2
        $result.Output | Should -Match 'apm install'
    }

    It 'exits 2 when a start marker has no end marker' {
        $root = New-AgentsRepo -Agents "# A`n<!-- ai-sdlc:core:start - installed from AI.SDLC; change it there, not here -->`ntext`n"

        $result = Invoke-Sync -Root $root -Check

        $result.Code | Should -Be 2
    }

    It 'reads a file with Windows line endings as the same file' {
        $root = New-AgentsRepo -Agents "# A`n`n## B`n"
        Invoke-Sync -Root $root | Out-Null
        $path = Join-Path $root 'AGENTS.md'
        [IO.File]::WriteAllText($path, ([IO.File]::ReadAllText($path) -replace "`n", "`r`n"))

        $result = Invoke-Sync -Root $root -Check

        $result.Code | Should -Be 0
    }

    Context 'the CLAUDE.md import' {
        BeforeAll {
            function New-GitAgentsRepo {
                param([string]$RootClaude, [string]$DotClaude, [switch]$Untracked, [string]$GitIgnore)
                $root = New-AgentsRepo -Agents "# A`n`n## B`n"
                git -C $root init --quiet
                git -C $root config user.email probe@example.invalid
                git -C $root config user.name probe
                if ($GitIgnore) { [IO.File]::WriteAllText((Join-Path $root '.gitignore'), $GitIgnore) }
                if ($null -ne $DotClaude -and $PSBoundParameters.ContainsKey('DotClaude')) {
                    [IO.File]::WriteAllText((Join-Path $root '.claude' 'CLAUDE.md'), $DotClaude)
                }
                git -C $root add -A
                git -C $root commit --quiet -m init --no-verify
                if ($PSBoundParameters.ContainsKey('RootClaude')) {
                    [IO.File]::WriteAllText((Join-Path $root 'CLAUDE.md'), $RootClaude)
                    if (-not $Untracked) {
                        git -C $root add -- CLAUDE.md
                        git -C $root commit --quiet -m claude --no-verify
                    }
                }
                return $root
            }
            function Get-Staged { param([string]$Root) @(git -C $Root diff --cached --no-renames --name-status) }
        }

        It 'moves a root CLAUDE.md that only imports AGENTS.md to .claude/CLAUDE.md, and stages the move' {
            $root = New-GitAgentsRepo -RootClaude "@AGENTS.md`n"

            $result = Invoke-Sync -Root $root

            $result.Code | Should -Be 0 -Because $result.Output
            Test-Path -LiteralPath (Join-Path $root 'CLAUDE.md') | Should -BeFalse
            [IO.File]::ReadAllText((Join-Path $root '.claude' 'CLAUDE.md')) | Should -Be "@../AGENTS.md`n"
            $staged = Get-Staged -Root $root
            $staged | Should -Contain "D`tCLAUDE.md"
            $staged | Should -Contain "A`t.claude/CLAUDE.md"
            $result.Output | Should -Match 'GitHub Copilot reads AGENTS\.md once'
        }

        It 'moves an import with a byte order mark, Windows line endings or blank lines' {
            $root = New-GitAgentsRepo -RootClaude ([char]0xFEFF + "@AGENTS.md`r`n`r`n")

            Invoke-Sync -Root $root | Out-Null

            Test-Path -LiteralPath (Join-Path $root 'CLAUDE.md') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $root '.claude' 'CLAUDE.md') | Should -BeTrue
        }

        It 'moves an untracked root CLAUDE.md and stages the new file' {
            $root = New-GitAgentsRepo -RootClaude "@AGENTS.md`n" -Untracked

            Invoke-Sync -Root $root | Out-Null

            Test-Path -LiteralPath (Join-Path $root 'CLAUDE.md') | Should -BeFalse
            Get-Staged -Root $root | Should -Contain "A`t.claude/CLAUDE.md"
        }

        It 'moves a root CLAUDE.md with unstaged changes, because its text is only the import' {
            $root = New-GitAgentsRepo -RootClaude "@AGENTS.md`n"
            [IO.File]::WriteAllText((Join-Path $root 'CLAUDE.md'), "@AGENTS.md`n`n")

            Invoke-Sync -Root $root | Out-Null

            Test-Path -LiteralPath (Join-Path $root 'CLAUDE.md') | Should -BeFalse
            Get-Staged -Root $root | Should -Contain "D`tCLAUDE.md"
        }

        It 'leaves a root CLAUDE.md that holds more than the import' {
            $root = New-GitAgentsRepo -RootClaude "@AGENTS.md`n`nClaude-only note.`n"

            Invoke-Sync -Root $root | Out-Null

            [IO.File]::ReadAllText((Join-Path $root 'CLAUDE.md')) | Should -Match 'Claude-only note'
            Test-Path -LiteralPath (Join-Path $root '.claude' 'CLAUDE.md') | Should -BeFalse
        }

        It 'leaves an empty root CLAUDE.md alone and does not fail' {
            $root = New-GitAgentsRepo -RootClaude ''

            $result = Invoke-Sync -Root $root

            $result.Code | Should -Be 0 -Because $result.Output
            Test-Path -LiteralPath (Join-Path $root 'CLAUDE.md') | Should -BeTrue
        }

        It 'removes the root file when .claude/CLAUDE.md already holds the same import' {
            $root = New-GitAgentsRepo -RootClaude "@AGENTS.md`n" -DotClaude "@../AGENTS.md`n"

            Invoke-Sync -Root $root | Out-Null

            Test-Path -LiteralPath (Join-Path $root 'CLAUDE.md') | Should -BeFalse
            Get-Staged -Root $root | Should -Contain "D`tCLAUDE.md"
        }

        It 'keeps both files and warns when .claude/CLAUDE.md holds something else' {
            $root = New-GitAgentsRepo -RootClaude "@AGENTS.md`n" -DotClaude "Claude-only note.`n"

            $result = Invoke-Sync -Root $root

            $result.Output | Should -Match 'reads AGENTS\.md twice'
            Test-Path -LiteralPath (Join-Path $root 'CLAUDE.md') | Should -BeTrue
            [IO.File]::ReadAllText((Join-Path $root '.claude' 'CLAUDE.md')) | Should -Be "Claude-only note.`n"
        }

        It 'changes nothing and warns when git ignores .claude/CLAUDE.md' {
            $root = New-GitAgentsRepo -RootClaude "@AGENTS.md`n" -GitIgnore ".claude/CLAUDE.md`n"

            $result = Invoke-Sync -Root $root

            $result.Output | Should -Match 'ignores \.claude/CLAUDE\.md'
            Test-Path -LiteralPath (Join-Path $root 'CLAUDE.md') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $root '.claude' 'CLAUDE.md') | Should -BeFalse
        }

        It 'changes nothing and warns when the root file has staged changes' {
            $root = New-GitAgentsRepo -RootClaude "@AGENTS.md`n" -Untracked
            git -C $root add -- CLAUDE.md

            $result = Invoke-Sync -Root $root

            $result.Output | Should -Match 'staged changes'
            Test-Path -LiteralPath (Join-Path $root 'CLAUDE.md') | Should -BeTrue
        }

        It 'moves nothing with -Check' {
            $root = New-GitAgentsRepo -RootClaude "@AGENTS.md`n"
            Invoke-Sync -Root $root -Check | Out-Null

            Test-Path -LiteralPath (Join-Path $root 'CLAUDE.md') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $root '.claude' 'CLAUDE.md') | Should -BeFalse
        }
    }
}
