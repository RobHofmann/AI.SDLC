#requires -Version 7.4

BeforeAll { $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm' }

Describe 'HookPayload' {
    BeforeAll {
        Import-Module (Join-Path $script:ScriptFolder 'HookPayload.psm1') -Force

        function ConvertTo-Payload {
            param([hashtable]$Payload)
            return ($Payload | ConvertTo-Json -Depth 5 -Compress)
        }

        $script:CopilotPatch = "*** Begin Patch`n*** Update File: probe.txt`n@@`n-hello`n+hello world`n*** End Patch`n"
    }

    Context 'Get-HookEditedFile' {
        It 'reads file_path from the Claude Code shape' {
            Get-HookEditedFile -Json (ConvertTo-Payload @{ tool_name = 'Edit'; tool_input = @{ file_path = 'docs/a.md' } }) | Should -Be 'docs/a.md'
        }

        It 'reads path from the Copilot edit and create tools' {
            Get-HookEditedFile -Json (ConvertTo-Payload @{ tool_name = 'Write'; tool_input = @{ path = 'C:\repo\notes.txt'; file_text = 'x' } }) | Should -Be 'C:\repo\notes.txt'
        }

        It 'reads toolArgs that arrive as a JSON string' {
            Get-HookEditedFile -Json (ConvertTo-Payload @{ toolName = 'edit'; toolArgs = '{"path":"docs/b.md"}' }) | Should -Be 'docs/b.md'
        }

        It 'reads the file of an apply_patch call, captured from Copilot CLI with a GPT model' {
            $json = '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":"*** Begin Patch\n*** Update File: probe.txt\n@@\n-hello\n+hello world\n*** End Patch\n"}'
            Get-HookEditedFile -Json $json | Should -Be 'probe.txt'
        }

        It 'returns every file of a patch that adds, updates, moves and deletes, once each' {
            $patch = @(
                '*** Begin Patch'
                '*** Add File: docs/new.md'
                '+# New'
                '*** Update File: .claude/skills/guide-me/SKILL.md'
                '*** Move to: .claude/skills/guide-me/OTHER.md'
                '@@'
                '-a'
                '+b'
                '*** Delete File: docs/old.md'
                '*** Update File: docs/new.md'
                '*** End Patch'
            ) -join "`r`n"
            $files = @(Get-HookEditedFile -Json (ConvertTo-Payload @{ tool_name = 'Edit'; tool_input = $patch }))

            $files | Should -Be @('docs/new.md', '.claude/skills/guide-me/SKILL.md', '.claude/skills/guide-me/OTHER.md', 'docs/old.md')
        }

        It 'reads a patch that sits in an input field of the arguments' {
            Get-HookEditedFile -Json (ConvertTo-Payload @{ toolName = 'apply_patch'; toolArgs = @{ input = $script:CopilotPatch } }) | Should -Be 'probe.txt'
        }

        It 'returns nothing for <Case>' -ForEach @(
            @{ Case = 'an empty payload'; Json = '' }
            @{ Case = 'text that is not JSON'; Json = 'not json' }
            @{ Case = 'a shell command'; Json = '{"tool_name":"Bash","tool_input":{"command":"git status"}}' }
            @{ Case = 'a string that is neither JSON nor a patch'; Json = '{"tool_name":"Edit","tool_input":"just text"}' }
            @{ Case = 'a patch with no file line'; Json = '{"tool_name":"Edit","tool_input":"*** Begin Patch\n*** End Patch\n"}' }
        ) {
            @(Get-HookEditedFile -Json $Json) | Should -HaveCount 0
        }
    }

    Context 'Get-PatchFilePath' {
        It 'ignores text that does not start a patch, so a file that only mentions the markers is not read as one' {
            @(Get-PatchFilePath -Patch "The format has lines such as *** Update File: x.md`n") | Should -HaveCount 0
        }
    }

    Context 'Get-HookCheckoutRoot' {
        BeforeAll {
            $script:Main = Join-Path $TestDrive 'main'
            $script:Worktree = Join-Path $script:Main '.claude' 'worktrees' 'wt'
            New-Item -ItemType Directory -Path (Join-Path $script:Worktree 'docs'), (Join-Path $script:Main 'test' 'full' 'docs') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $script:Main '.git') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $script:Worktree '.git') -Value "gitdir: $script:Main/.git/worktrees/wt"
            New-Item -ItemType Directory -Path (Join-Path $script:Main '.git' 'worktrees' 'wt') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $script:Main '.git' 'worktrees' 'wt' 'gitdir') -Value (Join-Path $script:Worktree '.git')
            Set-Content -LiteralPath (Join-Path $script:Main 'test' 'full' 'aisdlc.json') -Value '{ }'
        }

        It 'returns the worktree for a file in a git worktree that lies inside the repository' -Tag '50' {
            Get-HookCheckoutRoot -File (Join-Path $script:Worktree 'docs' 'page.md') -RepoRoot $script:Main | Should -Be $script:Worktree
        }

        It 'returns the worktree for a file it is about to create in a new folder' -Tag '50' {
            Get-HookCheckoutRoot -File (Join-Path $script:Worktree 'new' 'deep' 'page.md') -RepoRoot $script:Main | Should -Be $script:Worktree
        }

        It 'returns the repository for a file of the repository itself' -Tag '50' {
            Get-HookCheckoutRoot -File (Join-Path $script:Main 'docs' 'page.md') -RepoRoot $script:Main | Should -Be $script:Main
        }

        It 'returns the repository for a folder with its own aisdlc.json but no .git, such as a test consumer' -Tag '50' {
            Get-HookCheckoutRoot -File (Join-Path $script:Main 'test' 'full' 'docs' 'page.md') -RepoRoot $script:Main | Should -Be $script:Main
        }

        It 'returns the repository for a .git file whose gitdir points outside its .git/worktrees folder' -Tag '50' {
            $planted = Join-Path $script:Main 'planted'
            New-Item -ItemType Directory -Path $planted -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $planted '.git') -Value "gitdir: $TestDrive/elsewhere/.git"

            Get-HookCheckoutRoot -File (Join-Path $planted 'page.md') -RepoRoot $script:Main | Should -Be $script:Main
        }

        It 'returns the repository for a .git file that points into .git/worktrees without the back-pointer git writes there' -Tag '50' {
            $forged = Join-Path $script:Main 'forged'
            New-Item -ItemType Directory -Path $forged, (Join-Path $script:Main '.git' 'worktrees' 'forged') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $forged '.git') -Value "gitdir: $script:Main/.git/worktrees/forged"

            Get-HookCheckoutRoot -File (Join-Path $forged 'page.md') -RepoRoot $script:Main | Should -Be $script:Main
        }

        It 'returns the repository for a back-pointer that names another folder' -Tag '50' {
            $other = Join-Path $script:Main 'other'
            New-Item -ItemType Directory -Path $other -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $other '.git') -Value "gitdir: $script:Main/.git/worktrees/wt"

            Get-HookCheckoutRoot -File (Join-Path $other 'page.md') -RepoRoot $script:Main | Should -Be $script:Main
        }

        It 'returns the repository for a .git file whose gitdir is not a valid path, instead of throwing' -Tag '50' {
            $malformed = Join-Path $script:Main 'malformed'
            New-Item -ItemType Directory -Path $malformed -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $malformed '.git') -Value "gitdir: $script:Main/.git/worktrees/bad`0name"

            Get-HookCheckoutRoot -File (Join-Path $malformed 'page.md') -RepoRoot $script:Main | Should -Be $script:Main
        }

        It 'returns the repository for a nested repository with a .git folder' -Tag '50' {
            $nested = Join-Path $script:Main 'nested'
            New-Item -ItemType Directory -Path (Join-Path $nested '.git') -Force | Out-Null

            Get-HookCheckoutRoot -File (Join-Path $nested 'page.md') -RepoRoot $script:Main | Should -Be $script:Main
        }
    }

    Context 'New-HookContextOutput' {
        It 'writes additionalContext at the top level for Copilot CLI and nested for Claude Code' {
            $out = New-HookContextOutput -EventName 'PostToolUse' -Text 'Fix the reading level.' | ConvertFrom-Json

            $out.additionalContext | Should -Be 'Fix the reading level.'
            $out.hookSpecificOutput.hookEventName | Should -Be 'PostToolUse'
            $out.hookSpecificOutput.additionalContext | Should -Be 'Fix the reading level.'
        }

        It 'writes one line, as the Copilot CLI hook guide asks of hook output' {
            New-HookContextOutput -EventName 'UserPromptSubmit' -Text "line one`nline two" | Should -Not -Match "`n"
        }
    }
}
