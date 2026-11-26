#requires -Version 7.4

BeforeAll { $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm' }

Describe 'Invoke-AutolearnHook' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $script:ScriptFolder -ChildPath 'Invoke-AutolearnHook.ps1'
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

    Context 'Advice update' {
        It 'asks for the capture-learning skill when the user asks to update the advice' -Tag '54' {
            foreach ($text in 'update your advice', 'revise your advice', 'revise your recommendation', 'reconsider your advice', 'update je advies', 'pas je advies aan', 'herzie je advies', 'kun je je advies herzien', 'wil je je advies updaten', 'pas je aanbeveling aan', 'not sure but update your advice', 'not sure, but update your advice', 'no idea if it helps, but revise your recommendation', 'je advies is niet goed, update je advies', 'je aanbeveling werkt niet, pas je aanbeveling aan') {
                $output = Invoke-Hook -FlagRoot $script:FlagRoot -Payload @{
                    hook_event_name = 'UserPromptSubmit'
                    session_id      = 'advice-1'
                    user_input      = $text
                }

                $output | Should -Match 'additionalContext' -Because "'$text' asks for an updated advice"
                $output | Should -Match 'capture-learning' -Because "'$text' asks for an updated advice"
            }
        }

        It 'stays silent on text that only looks like an advice update' -Tag '54' {
            foreach ($text in 'het advies van de architect is helder', 'update the advice page in the docs', 'update je branch', 'nieuwe info: de deadline is vrijdag', 'wat is je advies?', 'what is your advice?', 'no problem, carry on', 'do not update your advice', "don't revise your recommendation", 'never update your advice', 'pas je advies niet aan', 'je hoeft je advies niet aan te passen', 'je advies niet herzien', 'je advies hoef je niet te updaten', 'update je advies niet', 'herzie je advies maar niet', 'pas je advies maar niet aan', 'werk je advies niet bij', "I don't think you should update your advice", 'you do not need to update your advice', 'no need to revise your recommendation') {
                $output = Invoke-Hook -FlagRoot $script:FlagRoot -Payload @{
                    hook_event_name = 'UserPromptSubmit'
                    session_id      = 'advice-2'
                    user_input      = $text
                }

                $output | Should -BeNullOrEmpty -Because "'$text' is not an advice update"
            }
        }

        It 'writes no flag, so the Stop event does nothing' -Tag '54' {
            $null = Invoke-Hook -FlagRoot $script:FlagRoot -Payload @{
                hook_event_name = 'UserPromptSubmit'
                session_id      = 'advice-3'
                user_input      = 'please update your advice with this new input'
            }

            @(Get-ChildItem -Path $script:FlagRoot -Filter '*.flag' -ErrorAction SilentlyContinue).Count | Should -Be 0

            $stop = Invoke-Hook -FlagRoot $script:FlagRoot -Payload @{
                hook_event_name = 'Stop'
                session_id      = 'advice-3'
            }
            $stop | Should -BeNullOrEmpty
        }

        It 'does not say a correction happened' -Tag '54' {
            $output = Invoke-Hook -FlagRoot $script:FlagRoot -Payload @{
                hook_event_name = 'UserPromptSubmit'
                session_id      = 'advice-4'
                user_input      = 'revise your recommendation'
            }

            $output | Should -Match 'capture-learning'
            $output | Should -Not -Match 'A correction just happened'
        }

        It 'lets a correction win over an advice update' -Tag '54' {
            $output = Invoke-Hook -FlagRoot $script:FlagRoot -Payload @{
                hook_event_name = 'UserPromptSubmit'
                session_id      = 'advice-5'
                user_input      = 'nee, update je advies'
            }

            $output | Should -Match 'A correction just happened'
            @(Get-ChildItem -Path $script:FlagRoot -Filter '*.flag').Count | Should -Be 1
        }

        It 'asks both questions: could the input have been found before, and does it hold beyond this work item' -Tag '54' {
            $output = Invoke-Hook -FlagRoot $script:FlagRoot -Payload @{
                hook_event_name = 'UserPromptSubmit'
                session_id      = 'advice-6'
                user_input      = 'update your advice'
            }

            $output | Should -Match 'before you advised'
            $output | Should -Match 'beyond this work item'
            $output | Should -Match 'ai-sdlc-handbook/references/autolearn.md'
        }

        It 'says nothing about a lesson when both answers are no' -Tag '54' {
            $output = Invoke-Hook -FlagRoot $script:FlagRoot -Payload @{
                hook_event_name = 'UserPromptSubmit'
                session_id      = 'advice-7'
                user_input      = 'update your advice'
            }

            $output | Should -Match 'both answers are no, say nothing about a lesson'
        }

        It 'proposes a capture and never writes it without asking' -Tag '54' {
            $output = Invoke-Hook -FlagRoot $script:FlagRoot -Payload @{
                hook_event_name = 'UserPromptSubmit'
                session_id      = 'advice-8'
                user_input      = 'update your advice'
            }

            $output | Should -Match 'propose a capture through the capture-learning skill'
            $output | Should -Match 'never write it without asking'
        }
    }

    Context 'Open lesson proposals' {
        BeforeAll {
            function Invoke-Prompt {
                param([string]$Cwd, [string]$SessionId = 'start-1', [string]$Text = 'carry on with the build')

                $payload = @{
                    hook_event_name = 'UserPromptSubmit'
                    session_id      = $SessionId
                    user_input      = $Text
                }
                if ($Cwd) { $payload.cwd = $Cwd }
                return (Invoke-Hook -FlagRoot $script:FlagRoot -Payload $payload)
            }

            function Set-PendingLines {
                param([string[]]$Lines)

                $null = New-Item -ItemType Directory -Path $script:PendingFolder -Force
                [IO.File]::WriteAllText($script:PendingFile, (($Lines -join "`n") + "`n"))
            }
        }

        BeforeEach {
            $script:Repo = Join-Path -Path $TestDrive -ChildPath ('repo-' + [guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $script:Repo
            $null = git -C $script:Repo init --quiet
            $script:PendingFolder = Join-Path -Path $script:Repo -ChildPath 'temp' 'autolearn'
            $script:PendingFile = Join-Path -Path $script:PendingFolder -ChildPath 'pending.md'
        }

        It 'names the file and the number of open proposals on the first prompt of a session' -Tag '54' {
            Set-PendingLines -Lines @('2026-11-14 | always read the config first | AGENTS.md', '2026-11-15 | name the story key in the branch | a skill')

            $parsed = (Invoke-Prompt -Cwd $script:Repo) | ConvertFrom-Json

            $parsed.additionalContext | Should -Match 'temp/autolearn/pending\.md'
            $parsed.additionalContext | Should -Match '\b2\b'
            $parsed.additionalContext | Should -Match 'capture-learning'
        }

        It 'returns the context for the UserPromptSubmit event in both shapes' -Tag '54' {
            Set-PendingLines -Lines @('2026-11-14 | a lesson | a home')

            $parsed = (Invoke-Prompt -Cwd $script:Repo) | ConvertFrom-Json

            $parsed.hookSpecificOutput.hookEventName | Should -Be 'UserPromptSubmit'
            $parsed.hookSpecificOutput.additionalContext | Should -Be $parsed.additionalContext
        }

        It 'stays silent on the second prompt of the same session' -Tag '54' {
            Set-PendingLines -Lines @('2026-11-14 | a lesson | a home')

            $null = Invoke-Prompt -Cwd $script:Repo
            $second = Invoke-Prompt -Cwd $script:Repo

            $second | Should -BeNullOrEmpty
        }

        It 'stays silent and leaves the target alone when the marker path already exists as a link' -Tag '54' {
            Set-PendingLines -Lines @('2026-11-14 | a lesson | a home')
            $target = Join-Path -Path $TestDrive -ChildPath ('target-' + [guid]::NewGuid().ToString('N') + '.txt')
            [IO.File]::WriteAllText($target, 'keep me')
            $null = New-Item -ItemType Directory -Path $script:FlagRoot -Force
            $link = Join-Path -Path $script:FlagRoot -ChildPath 'start-1.seen'
            try { $null = New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction Stop }
            catch { Set-ItResult -Skipped -Because 'this machine does not allow symbolic links'; return }

            Invoke-Prompt -Cwd $script:Repo | Should -BeNullOrEmpty
            [IO.File]::ReadAllText($target) | Should -Be 'keep me'
        }

        It 'sweeps session markers older than the retention, and keeps the recent ones and the flags' -Tag '54' {
            $null = New-Item -ItemType Directory -Path $script:FlagRoot -Force
            $old = Join-Path -Path $script:FlagRoot -ChildPath 'old-session.seen'
            $recent = Join-Path -Path $script:FlagRoot -ChildPath 'recent-session.seen'
            $oldFlag = Join-Path -Path $script:FlagRoot -ChildPath 'old-session.flag'
            foreach ($path in $old, $recent, $oldFlag) { [IO.File]::WriteAllText($path, '') }
            (Get-Item -LiteralPath $old).LastWriteTime = (Get-Date).AddDays(-30)
            (Get-Item -LiteralPath $oldFlag).LastWriteTime = (Get-Date).AddDays(-30)

            $null = Invoke-Prompt -Cwd $script:Repo

            Test-Path -LiteralPath $old | Should -BeFalse
            Test-Path -LiteralPath $recent | Should -BeTrue
            Test-Path -LiteralPath $oldFlag | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $script:FlagRoot 'start-1.seen') | Should -BeTrue
        }

        It 'reminds again in a new session' -Tag '54' {
            Set-PendingLines -Lines @('2026-11-14 | a lesson | a home')

            $null = Invoke-Prompt -Cwd $script:Repo -SessionId 'session-one'
            $parsed = (Invoke-Prompt -Cwd $script:Repo -SessionId 'session-two') | ConvertFrom-Json

            $parsed.additionalContext | Should -Match 'temp/autolearn/pending\.md'
        }

        It 'adds the reminder to the correction note, and the correction is still flagged' -Tag '54' {
            Set-PendingLines -Lines @('2026-11-14 | a lesson | a home')

            $parsed = (Invoke-Prompt -Cwd $script:Repo -Text 'no, that is wrong') | ConvertFrom-Json

            $parsed.additionalContext | Should -Match 'A correction just happened'
            $parsed.additionalContext | Should -Match 'temp/autolearn/pending\.md'
            (Get-ChildItem -Path $script:FlagRoot -Filter '*.flag').Count | Should -Be 1
        }

        It 'adds the reminder to the advice-update note' -Tag '54' {
            Set-PendingLines -Lines @('2026-11-14 | a lesson | a home')

            $parsed = (Invoke-Prompt -Cwd $script:Repo -Text 'update je advies') | ConvertFrom-Json

            $parsed.additionalContext | Should -Match 'update your advice'
            $parsed.additionalContext | Should -Match 'holds 1 open lesson proposal'
        }

        It 'does not make the stop block' -Tag '54' {
            Set-PendingLines -Lines @('2026-11-14 | a lesson | a home')

            $null = Invoke-Prompt -Cwd $script:Repo
            $stop = Invoke-Hook -FlagRoot $script:FlagRoot -Payload @{ hook_event_name = 'Stop'; session_id = 'start-1' }

            $stop | Should -BeNullOrEmpty
        }

        It 'counts only the non-empty lines' -Tag '54' {
            Set-PendingLines -Lines @('2026-11-14 | a lesson | a home', '', '   ', '2026-11-15 | another | a home', '')

            $parsed = (Invoke-Prompt -Cwd $script:Repo) | ConvertFrom-Json

            $parsed.additionalContext | Should -Match '\b2\b'
        }

        It 'stays silent when the file is missing' -Tag '54' {
            Invoke-Prompt -Cwd $script:Repo | Should -BeNullOrEmpty
        }

        It 'stays silent when the file is empty' -Tag '54' {
            $null = New-Item -ItemType Directory -Path $script:PendingFolder -Force
            [IO.File]::WriteAllText($script:PendingFile, '')

            Invoke-Prompt -Cwd $script:Repo | Should -BeNullOrEmpty
        }

        It 'stays silent when the file has only blank lines' -Tag '54' {
            Set-PendingLines -Lines @('', '  ', '')

            Invoke-Prompt -Cwd $script:Repo | Should -BeNullOrEmpty
        }

        It 'stays silent when the file cannot be read' -Tag '54' {
            $null = New-Item -ItemType Directory -Path $script:PendingFile -Force

            Invoke-Prompt -Cwd $script:Repo | Should -BeNullOrEmpty
        }

        It 'stays silent outside a git repository' -Tag '54' {
            $plain = Join-Path -Path $TestDrive -ChildPath ('plain-' + [guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path (Join-Path $plain 'temp' 'autolearn') -Force
            [IO.File]::WriteAllText((Join-Path $plain 'temp' 'autolearn' 'pending.md'), "a lesson`n")

            Invoke-Prompt -Cwd $plain | Should -BeNullOrEmpty
        }

        It 'stays silent when the payload has no cwd, even inside a checkout with open proposals' -Tag '54' {
            Set-PendingLines -Lines @('2026-11-14 | a lesson | a home')

            Push-Location -LiteralPath $script:Repo
            try {
                $output = Invoke-Prompt
            }
            finally { Pop-Location }

            $output | Should -BeNullOrEmpty
        }

        It 'does not change the file' -Tag '54' {
            Set-PendingLines -Lines @('2026-11-14 | a lesson | a home', '2026-11-15 | another | a home')
            $before = [IO.File]::ReadAllBytes($script:PendingFile)

            $null = Invoke-Prompt -Cwd $script:Repo

            [IO.File]::ReadAllBytes($script:PendingFile) | Should -Be $before
        }

        It 'prints no line of the file' -Tag '54' {
            Set-PendingLines -Lines @('zebra-quartz-lesson | one', 'walrus-basalt-lesson | two')

            $output = Invoke-Prompt -Cwd $script:Repo

            $output | Should -Not -BeNullOrEmpty
            $output | Should -Not -Match 'zebra-quartz'
            $output | Should -Not -Match 'walrus-basalt'
        }

        It 'finds the file from a subfolder of the checkout' -Tag '54' {
            Set-PendingLines -Lines @('2026-11-14 | a lesson | a home')
            $sub = Join-Path -Path $script:Repo -ChildPath 'src' 'deep'
            $null = New-Item -ItemType Directory -Path $sub -Force

            $parsed = (Invoke-Prompt -Cwd $sub) | ConvertFrom-Json

            $parsed.additionalContext | Should -Match 'temp/autolearn/pending\.md'
            $parsed.additionalContext | Should -Match '\b1\b'
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
            $settings = Get-AiSdlcHookSettings -From $script:ScriptFolder
            $settings | Should -Not -BeNullOrEmpty

            foreach ($eventName in 'UserPromptSubmit', 'Stop') {
                $commands = @($settings.hooks.$eventName.hooks.command)
                $commands | Should -Contain 'pwsh -NoProfile -Command "& (Join-Path ([Environment]::GetEnvironmentVariable(''CLAUDE_PROJECT_DIR'') ?? ''.'') ''.claude/skills/ai-sdlc-hooks/scripts/Invoke-AutolearnHook.ps1'')"' -Because "the $eventName event runs the hook"
            }
            @($settings.hooks.SessionStart.hooks.command | Where-Object { $_ -like '*Invoke-AutolearnHook.ps1*' }) | Should -BeNullOrEmpty -Because 'two packages on SessionStart make apm audit report drift'
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
