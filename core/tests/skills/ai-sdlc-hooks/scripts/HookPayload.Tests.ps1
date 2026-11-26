#requires -Version 7.4

Describe 'HookPayload' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'HookPayload.psm1') -Force

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
