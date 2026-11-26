#requires -Version 7.4

Describe 'Invoke-AutolearnHook' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-AutolearnHook.ps1'
        Import-Module (Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts' 'DocToolTestHarness.psm1') -Force

        function Invoke-Hook {
            param(
                [hashtable]$Payload,
                [string]$FlagRoot
            )

            $json = $Payload | ConvertTo-Json -Depth 5 -Compress
            $run = Invoke-ScriptInProcess -Path $script:ScriptUnderTest -Arguments @('-Payload', $json, '-FlagRoot', $FlagRoot)
            return $run.Output.Trim()
        }
    }

    BeforeEach {
        $script:FlagRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
    }

    Context 'UserPromptSubmit' {
        It 'flags a correction and asks for the capture-learning skill' {
            $output = Invoke-Hook -FlagRoot $script:FlagRoot -Payload @{
                hook_event_name = 'UserPromptSubmit'
                session_id      = 'abc-123'
                user_input      = 'no, that is wrong, we never log that way'
            }

            $output | Should -Match 'capture-learning'
            $output | Should -Match 'additionalContext'
            (Get-ChildItem -Path $script:FlagRoot -Filter '*.flag').Count | Should -Be 1
        }

        It 'names the page that holds the filter and the route table' {
            $output = Invoke-Hook -FlagRoot $script:FlagRoot -Payload @{
                hook_event_name = 'UserPromptSubmit'
                session_id      = 'abc-123'
                user_input      = 'dat klopt niet, gebruik altijd de bestaande service'
            }

            $output | Should -Match 'ai-sdlc-handbook/references/autolearn.md'
        }

        It 'reads the Copilot CLI prompt field and returns the context at the top level too, the shape Copilot reads' {
            $output = Invoke-Hook -FlagRoot $script:FlagRoot -Payload @{
                hook_event_name = 'UserPromptSubmit'
                session_id      = 'copilot-1'
                prompt          = 'No, that is wrong. Use the existing client.'
            }

            $json = $output | ConvertFrom-Json
            $json.additionalContext | Should -Match 'capture-learning'
            $json.hookSpecificOutput.hookEventName | Should -Be 'UserPromptSubmit'
            $json.hookSpecificOutput.additionalContext | Should -Be $json.additionalContext
        }

        It 'stays silent on an ordinary request' {
            $output = Invoke-Hook -FlagRoot $script:FlagRoot -Payload @{
                hook_event_name = 'UserPromptSubmit'
                session_id      = 'abc-123'
                user_input      = 'add a version footer to the portal and run the tests'
            }

            $output | Should -BeNullOrEmpty
            Test-Path -Path $script:FlagRoot | Should -BeFalse
        }

        It 'does not read "no problem" or "note" as a correction' {
            foreach ($text in 'no problem, carry on', 'note that the gate is advisory', 'there is no story yet') {
                $output = Invoke-Hook -FlagRoot $script:FlagRoot -Payload @{
                    hook_event_name = 'UserPromptSubmit'
                    session_id      = 'abc-123'
                    user_input      = $text
                }

                $output | Should -BeNullOrEmpty -Because "'$text' is not a correction"
            }
        }

        It 'writes only a timestamp to the flag, never the prompt' {
            $null = Invoke-Hook -FlagRoot $script:FlagRoot -Payload @{
                hook_event_name = 'UserPromptSubmit'
                session_id      = 'abc-123'
                user_input      = 'no, that is wrong: the secret lives in Key Vault'
            }

            $flag = Get-ChildItem -Path $script:FlagRoot -Filter '*.flag' | Select-Object -First 1
            $content = Get-Content -LiteralPath $flag.FullName -Raw
            $content | Should -Not -Match 'Key Vault'
            { [datetime]::Parse($content.Trim()) } | Should -Not -Throw
        }

        It 'keeps a session id that is not a safe file name out of the path' {
            $null = Invoke-Hook -FlagRoot $script:FlagRoot -Payload @{
                hook_event_name = 'UserPromptSubmit'
                session_id      = '../../escape me'
                user_input      = 'no, that is wrong'
            }

            $flags = @(Get-ChildItem -Path $script:FlagRoot -Filter '*.flag' -Force)
            $flags.Count | Should -Be 1
            $flags[0].Name | Should -Not -BeLike '.*' -Because 'a name that starts with a dot is a hidden file on Linux'
        }
    }

    Context 'Stop' {
        It 'blocks once when a correction is still uncaptured' {
            $null = Invoke-Hook -FlagRoot $script:FlagRoot -Payload @{
                hook_event_name = 'UserPromptSubmit'
                session_id      = 'abc-123'
                user_input      = 'no, that is wrong'
            }

            $first = Invoke-Hook -FlagRoot $script:FlagRoot -Payload @{
                hook_event_name = 'Stop'
                session_id      = 'abc-123'
            }
            $second = Invoke-Hook -FlagRoot $script:FlagRoot -Payload @{
                hook_event_name = 'Stop'
                session_id      = 'abc-123'
            }

            $first | Should -Match 'block'
            $first | Should -Match 'capture-learning'
            $second | Should -BeNullOrEmpty
        }

        It 'carries both output shapes so either agent reads it' {
            $null = Invoke-Hook -FlagRoot $script:FlagRoot -Payload @{
                hook_event_name = 'UserPromptSubmit'
                session_id      = 'abc-123'
                user_input      = 'no, that is wrong'
            }

            $output = Invoke-Hook -FlagRoot $script:FlagRoot -Payload @{
                hook_event_name = 'Stop'
                session_id      = 'abc-123'
            }
            $parsed = $output | ConvertFrom-Json

            $parsed.decision | Should -Be 'block'
            $parsed.hookSpecificOutput.permissionDecision | Should -Be 'block'
            $parsed.hookSpecificOutput.hookEventName | Should -Be 'Stop'
        }

        It 'stays silent when no correction was flagged' {
            $output = Invoke-Hook -FlagRoot $script:FlagRoot -Payload @{
                hook_event_name = 'Stop'
                session_id      = 'clean-session'
            }

            $output | Should -BeNullOrEmpty
        }

        It 'stays silent when a stop hook is already running' {
            $null = Invoke-Hook -FlagRoot $script:FlagRoot -Payload @{
                hook_event_name = 'UserPromptSubmit'
                session_id      = 'abc-123'
                user_input      = 'no, that is wrong'
            }

            $output = Invoke-Hook -FlagRoot $script:FlagRoot -Payload @{
                hook_event_name  = 'Stop'
                session_id       = 'abc-123'
                stop_hook_active = $true
            }

            $output | Should -BeNullOrEmpty
        }

        It 'keeps the sessions apart' {
            $null = Invoke-Hook -FlagRoot $script:FlagRoot -Payload @{
                hook_event_name = 'UserPromptSubmit'
                session_id      = 'session-one'
                user_input      = 'no, that is wrong'
            }

            $output = Invoke-Hook -FlagRoot $script:FlagRoot -Payload @{
                hook_event_name = 'Stop'
                session_id      = 'session-two'
            }

            $output | Should -BeNullOrEmpty
        }
    }

    Context 'Registration' {
        It 'is wired in the hook entries of the package on both events' {
            Import-Module (Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts' 'DocToolTestHarness.psm1') -Force
            $settings = Get-AiSdlcHookSettings -From $PSScriptRoot
            $settings | Should -Not -BeNullOrEmpty

            foreach ($eventName in 'UserPromptSubmit', 'Stop') {
                $commands = @($settings.hooks.$eventName.hooks.command)
                $commands | Should -Contain 'pwsh -NoProfile -File .claude/skills/ai-sdlc-hooks/scripts/Invoke-AutolearnHook.ps1' -Because "the $eventName event runs the hook"
            }
        }
    }

    Context 'Payloads it cannot use' {
        It 'allows an unreadable payload in silence' {
            $output = (Invoke-ScriptInProcess -Path $script:ScriptUnderTest -Arguments @('-Payload', 'not json at all', '-FlagRoot', $script:FlagRoot)).Output
            $LASTEXITCODE | Should -Be 0
            $output.Trim() | Should -BeNullOrEmpty
        }

        It 'allows an event it does not handle in silence' {
            $output = Invoke-Hook -FlagRoot $script:FlagRoot -Payload @{
                hook_event_name = 'PreToolUse'
                session_id      = 'abc-123'
                user_input      = 'no, that is wrong'
            }

            $output | Should -BeNullOrEmpty
        }
    }
}
