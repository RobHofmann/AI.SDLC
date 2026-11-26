#requires -Version 7.4

Describe 'Invoke-CompactSuggestionHook' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-CompactSuggestionHook.ps1'
        Import-Module (Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts' 'DocToolTestHarness.psm1') -Force

        function New-Transcript {
            param(
                [Parameter(Mandatory)][string]$Root,
                [Parameter(Mandatory)][object[]]$Records
            )

            if (-not (Test-Path -LiteralPath $Root)) { New-Item -ItemType Directory -Path $Root -Force | Out-Null }
            $path = Join-Path -Path $Root -ChildPath ([guid]::NewGuid().ToString('N') + '.jsonl')
            $lines = foreach ($record in $Records) { $record | ConvertTo-Json -Depth 8 -Compress }
            Set-Content -LiteralPath $path -Value $lines -Encoding utf8
            return $path
        }

        function New-UsageRecord {
            param(
                [int]$InputTokens = 0,
                [int]$CacheRead = 0,
                [int]$CacheCreation = 0,
                [string]$Model = 'claude-opus-5[1m]'
            )

            return @{
                type    = 'assistant'
                message = @{
                    model = $Model
                    usage = @{
                        input_tokens                = $InputTokens
                        cache_read_input_tokens     = $CacheRead
                        cache_creation_input_tokens = $CacheCreation
                    }
                }
            }
        }

        function Invoke-Hook {
            param(
                [hashtable]$Payload,
                [string]$StateRoot,
                [int]$ToolCallThreshold = 0
            )

            $json = $Payload | ConvertTo-Json -Depth 8 -Compress
            $arguments = @('-Payload', $json, '-StateRoot', $StateRoot)
            if ($ToolCallThreshold -gt 0) { $arguments += @('-ToolCallThreshold', $ToolCallThreshold) }
            $run = Invoke-ScriptInProcess -Path $script:ScriptUnderTest -Arguments $arguments
            return $run.Output.Trim()
        }

        function New-Payload {
            param(
                [string]$TranscriptPath = '',
                [string]$SessionId = 'abc-123',
                [string]$EventName = 'PreToolUse'
            )

            return @{
                hook_event_name = $EventName
                session_id      = $SessionId
                transcript_path = $TranscriptPath
                tool_name       = 'Edit'
            }
        }
    }

    BeforeEach {
        $script:StateRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $script:TranscriptRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
    }

    Context 'The context-size signal' {
        It 'suggests a compact once the context crosses the threshold' {
            $transcript = New-Transcript -Root $script:TranscriptRoot -Records @((New-UsageRecord -InputTokens 300000))

            $output = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload -TranscriptPath $transcript)

            $output | Should -Match 'additionalContext'
            $output | Should -Match 'compact'
        }

        It 'names the page that holds the boundary table' {
            $transcript = New-Transcript -Root $script:TranscriptRoot -Records @((New-UsageRecord -InputTokens 300000))

            $output = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload -TranscriptPath $transcript)

            $output | Should -Match 'ai-sdlc-handbook/references/context-management.md'
        }

        It 'names the handoff skill that writes the costly parts down first' {
            $transcript = New-Transcript -Root $script:TranscriptRoot -Records @((New-UsageRecord -InputTokens 300000))

            $output = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload -TranscriptPath $transcript)

            $output | Should -Match '/handoff'
        }

        It 'stays silent while the context is below the threshold' {
            $transcript = New-Transcript -Root $script:TranscriptRoot -Records @((New-UsageRecord -InputTokens 120000))

            $output = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload -TranscriptPath $transcript)

            $output | Should -BeNullOrEmpty
        }

        It 'adds the three usage fields together' {
            $transcript = New-Transcript -Root $script:TranscriptRoot -Records @(
                (New-UsageRecord -InputTokens 100000 -CacheRead 150000 -CacheCreation 60000)
            )

            $output = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload -TranscriptPath $transcript)

            $output | Should -Match '310k'
        }

        It 'reads the last usage record, not the first' {
            $transcript = New-Transcript -Root $script:TranscriptRoot -Records @(
                (New-UsageRecord -InputTokens 10000),
                (New-UsageRecord -InputTokens 300000)
            )

            $output = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload -TranscriptPath $transcript)

            $output | Should -Match '300k'
        }

        It 'skips records that carry no usage block' {
            $transcript = New-Transcript -Root $script:TranscriptRoot -Records @(
                (New-UsageRecord -InputTokens 300000),
                @{ type = 'user'; message = @{ role = 'user'; content = 'hello' } }
            )

            $output = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload -TranscriptPath $transcript)

            $output | Should -Match '300k'
        }
    }

    Context 'The context window' {
        It 'reports a share of the window when the model id marks it' {
            $transcript = New-Transcript -Root $script:TranscriptRoot -Records @(
                (New-UsageRecord -InputTokens 300000 -Model 'claude-opus-5[1m]')
            )

            $output = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload -TranscriptPath $transcript)

            $output | Should -Match '30% of 1M window'
        }

        It 'takes the window size from AISDLC_CONTEXT_WINDOW_TOKENS' {
            $transcript = New-Transcript -Root $script:TranscriptRoot -Records @(
                (New-UsageRecord -InputTokens 300000 -Model 'claude-sonnet-5')
            )
            $saved = $env:AISDLC_CONTEXT_WINDOW_TOKENS
            $env:AISDLC_CONTEXT_WINDOW_TOKENS = '2000000'
            try { $output = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload -TranscriptPath $transcript) }
            finally { $env:AISDLC_CONTEXT_WINDOW_TOKENS = $saved }

            $output | Should -Match '\(15% of 2M window\)' -Because 'a window of 2,000,000 tokens is 2M, not 1M'
        }

        It 'reports no share when nothing proves the window size' {
            $transcript = New-Transcript -Root $script:TranscriptRoot -Records @(
                (New-UsageRecord -InputTokens 170000 -Model 'claude-sonnet-5')
            )

            $output = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload -TranscriptPath $transcript)

            $output | Should -Match '170k'
            $output | Should -Not -Match 'window'
        }

        It 'uses the standard threshold while nothing proves a larger window' {
            $transcript = New-Transcript -Root $script:TranscriptRoot -Records @(
                (New-UsageRecord -InputTokens 170000 -Model 'claude-sonnet-5')
            )

            $output = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload -TranscriptPath $transcript)

            $output | Should -Match '170k'
        }

        It 'treats a context past the standard window as proof of the larger one' {
            $transcript = New-Transcript -Root $script:TranscriptRoot -Records @(
                (New-UsageRecord -InputTokens 300000 -Model 'claude-sonnet-5')
            )

            $output = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload -TranscriptPath $transcript)

            $output | Should -Match '30% of 1M window' -Because 'a 200k window cannot hold 300k tokens'
        }
    }

    Context 'Learning the window from what it has seen' {
        It 'records the largest context it has seen for the model' {
            $transcript = New-Transcript -Root $script:TranscriptRoot -Records @(
                (New-UsageRecord -InputTokens 300000 -Model 'claude-sonnet-5')
            )

            $null = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload -TranscriptPath $transcript)

            $peak = Join-Path -Path $script:StateRoot -ChildPath 'claude-sonnet-5.peak'
            (Get-Content -LiteralPath $peak -Raw).Trim() | Should -Be '300000'
        }

        It 'carries that proof into the next session and holds its peace at 170k' {
            New-Item -ItemType Directory -Path $script:StateRoot -Force | Out-Null
            Set-Content -LiteralPath (Join-Path -Path $script:StateRoot -ChildPath 'claude-sonnet-5.peak') -Value '236524' -Encoding utf8

            $transcript = New-Transcript -Root $script:TranscriptRoot -Records @(
                (New-UsageRecord -InputTokens 169191 -Model 'claude-sonnet-5')
            )

            $output = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload -TranscriptPath $transcript -SessionId 'a-later-session')

            $output | Should -BeNullOrEmpty -Because 'an earlier session held 236524 tokens, so the window is the larger one'
        }

        It 'proves nothing from a peak that fits inside the standard window' {
            New-Item -ItemType Directory -Path $script:StateRoot -Force | Out-Null
            Set-Content -LiteralPath (Join-Path -Path $script:StateRoot -ChildPath 'claude-sonnet-5.peak') -Value '150000' -Encoding utf8

            $transcript = New-Transcript -Root $script:TranscriptRoot -Records @(
                (New-UsageRecord -InputTokens 170000 -Model 'claude-sonnet-5')
            )

            $output = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload -TranscriptPath $transcript -SessionId 'a-later-session')

            $output | Should -Match '170k'
            $output | Should -Not -Match 'window'
        }

        It 'keeps the peak of one model away from another' {
            New-Item -ItemType Directory -Path $script:StateRoot -Force | Out-Null
            Set-Content -LiteralPath (Join-Path -Path $script:StateRoot -ChildPath 'claude-sonnet-5.peak') -Value '236524' -Encoding utf8

            $transcript = New-Transcript -Root $script:TranscriptRoot -Records @(
                (New-UsageRecord -InputTokens 170000 -Model 'some-other-model')
            )

            $output = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload -TranscriptPath $transcript -SessionId 'a-later-session')

            $output | Should -Match '170k' -Because 'nothing has been seen for some-other-model'
        }

        It 'does not lower a peak it has already recorded' {
            New-Item -ItemType Directory -Path $script:StateRoot -Force | Out-Null
            $peak = Join-Path -Path $script:StateRoot -ChildPath 'claude-sonnet-5.peak'
            Set-Content -LiteralPath $peak -Value '400000' -Encoding utf8

            $transcript = New-Transcript -Root $script:TranscriptRoot -Records @(
                (New-UsageRecord -InputTokens 300000 -Model 'claude-sonnet-5')
            )

            $null = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload -TranscriptPath $transcript)

            (Get-Content -LiteralPath $peak -Raw).Trim() | Should -Be '400000'
        }

        It 'holds its peace at 170k on a large window' {
            $transcript = New-Transcript -Root $script:TranscriptRoot -Records @(
                (New-UsageRecord -InputTokens 170000 -Model 'claude-opus-5[1m]')
            )

            $output = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload -TranscriptPath $transcript)

            $output | Should -BeNullOrEmpty
        }
    }

    Context 'Repeating the suggestion' {
        It 'says it once and then keeps quiet until the context grows' {
            $first = New-Transcript -Root $script:TranscriptRoot -Records @((New-UsageRecord -InputTokens 300000))
            $again = New-Transcript -Root $script:TranscriptRoot -Records @((New-UsageRecord -InputTokens 310000))

            $one = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload -TranscriptPath $first)
            $two = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload -TranscriptPath $again)

            $one | Should -Match '300k'
            $two | Should -BeNullOrEmpty
        }

        It 'speaks again after a full interval of growth' {
            $first = New-Transcript -Root $script:TranscriptRoot -Records @((New-UsageRecord -InputTokens 300000))
            $later = New-Transcript -Root $script:TranscriptRoot -Records @((New-UsageRecord -InputTokens 365000))

            $null = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload -TranscriptPath $first)
            $output = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload -TranscriptPath $later)

            $output | Should -Match '365k'
        }

        It 'keeps the sessions apart' {
            $transcript = New-Transcript -Root $script:TranscriptRoot -Records @((New-UsageRecord -InputTokens 300000))

            $null = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload -TranscriptPath $transcript -SessionId 'session-one')
            $output = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload -TranscriptPath $transcript -SessionId 'session-two')

            $output | Should -Match '300k'
        }

        It 'keeps a session id that is not a safe file name out of the path' {
            $transcript = New-Transcript -Root $script:TranscriptRoot -Records @((New-UsageRecord -InputTokens 300000))

            $null = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload -TranscriptPath $transcript -SessionId '../../escape me')

            $files = @(Get-ChildItem -Path $script:StateRoot -File -Force)
            $files.Count | Should -BeGreaterThan 0
            foreach ($file in $files) {
                $file.Name | Should -Not -BeLike '.*' -Because 'a name that starts with a dot is a hidden file on Linux'
            }
        }
    }

    Context 'The tool-call signal' {
        It 'offers a checkpoint once the tool calls reach the threshold' {
            $payload = New-Payload

            $null = Invoke-Hook -StateRoot $script:StateRoot -Payload $payload -ToolCallThreshold 3
            $null = Invoke-Hook -StateRoot $script:StateRoot -Payload $payload -ToolCallThreshold 3
            $third = Invoke-Hook -StateRoot $script:StateRoot -Payload $payload -ToolCallThreshold 3

            $third | Should -Match '3 tool calls'
            $third | Should -Match '/handoff'
        }

        It 'stays silent on the calls before the threshold' {
            $payload = New-Payload

            $first = Invoke-Hook -StateRoot $script:StateRoot -Payload $payload -ToolCallThreshold 3

            $first | Should -BeNullOrEmpty
        }

        It 'offers the checkpoint again every twenty-five calls after the threshold' {
            New-Item -ItemType Directory -Path $script:StateRoot -Force | Out-Null
            Set-Content -LiteralPath (Join-Path -Path $script:StateRoot -ChildPath 'abc-123.count') -Value '27' -Encoding utf8

            $output = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload) -ToolCallThreshold 3

            $output | Should -Match '28 tool calls'
        }

        It 'stays silent between two checkpoints' {
            New-Item -ItemType Directory -Path $script:StateRoot -Force | Out-Null
            Set-Content -LiteralPath (Join-Path -Path $script:StateRoot -ChildPath 'abc-123.count') -Value '20' -Encoding utf8

            $output = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload) -ToolCallThreshold 3

            $output | Should -BeNullOrEmpty
        }
    }

    Context 'State it leaves behind' {
        It 'sweeps state from an old session and keeps this one' {
            if (-not (Test-Path -LiteralPath $script:StateRoot)) { New-Item -ItemType Directory -Path $script:StateRoot -Force | Out-Null }
            $stale = Join-Path -Path $script:StateRoot -ChildPath 'long-gone.count'
            Set-Content -LiteralPath $stale -Value '4' -Encoding utf8
            (Get-Item -LiteralPath $stale).LastWriteTime = (Get-Date).AddDays(-30)

            $transcript = New-Transcript -Root $script:TranscriptRoot -Records @((New-UsageRecord -InputTokens 300000))
            $null = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload -TranscriptPath $transcript)

            Test-Path -LiteralPath $stale | Should -BeFalse
            @(Get-ChildItem -Path $script:StateRoot -File -Force).Count | Should -BeGreaterThan 0
        }

        It 'leaves recent state from another session alone' {
            if (-not (Test-Path -LiteralPath $script:StateRoot)) { New-Item -ItemType Directory -Path $script:StateRoot -Force | Out-Null }
            $recent = Join-Path -Path $script:StateRoot -ChildPath 'still-running.count'
            Set-Content -LiteralPath $recent -Value '4' -Encoding utf8

            $transcript = New-Transcript -Root $script:TranscriptRoot -Records @((New-UsageRecord -InputTokens 300000))
            $null = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload -TranscriptPath $transcript)

            Test-Path -LiteralPath $recent | Should -BeTrue
        }
    }

    Context 'Payloads it cannot use' {
        It 'allows an unreadable payload in silence' {
            $output = (Invoke-ScriptInProcess -Path $script:ScriptUnderTest -Arguments @('-Payload', 'not json at all', '-StateRoot', $script:StateRoot)).Output
            $LASTEXITCODE | Should -Be 0
            $output.Trim() | Should -BeNullOrEmpty
        }

        It 'allows a missing transcript in silence' {
            $missing = Join-Path -Path $script:TranscriptRoot -ChildPath 'no-such-file.jsonl'

            $output = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload -TranscriptPath $missing)

            $output | Should -BeNullOrEmpty
        }

        It 'allows a transcript with no usage record in silence' {
            $transcript = New-Transcript -Root $script:TranscriptRoot -Records @(
                @{ type = 'user'; message = @{ role = 'user'; content = 'hello' } }
            )

            $output = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload -TranscriptPath $transcript)

            $output | Should -BeNullOrEmpty
        }

        It 'allows a line that is not valid JSON in silence' {
            if (-not (Test-Path -LiteralPath $script:TranscriptRoot)) { New-Item -ItemType Directory -Path $script:TranscriptRoot -Force | Out-Null }
            $transcript = Join-Path -Path $script:TranscriptRoot -ChildPath 'broken.jsonl'
            Set-Content -LiteralPath $transcript -Value '{ this is not json' -Encoding utf8

            $output = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload -TranscriptPath $transcript)

            $output | Should -BeNullOrEmpty
        }

        It 'allows an event it does not handle in silence' {
            $transcript = New-Transcript -Root $script:TranscriptRoot -Records @((New-UsageRecord -InputTokens 300000))

            $output = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload -TranscriptPath $transcript -EventName 'Stop')

            $output | Should -BeNullOrEmpty
        }

        It 'emits one JSON object the agent can parse' {
            $transcript = New-Transcript -Root $script:TranscriptRoot -Records @((New-UsageRecord -InputTokens 300000))

            $output = Invoke-Hook -StateRoot $script:StateRoot -Payload (New-Payload -TranscriptPath $transcript)
            $parsed = $output | ConvertFrom-Json

            $parsed.hookSpecificOutput.hookEventName | Should -Be 'PreToolUse'
            $parsed.hookSpecificOutput.additionalContext | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Registration' {
        It 'is wired in the hook entries of the package on the PreToolUse event for Edit and Write' {
            Import-Module (Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts' 'DocToolTestHarness.psm1') -Force
            $settings = Get-AiSdlcHookSettings -From $PSScriptRoot
            $settings | Should -Not -BeNullOrEmpty

            $entry = @($settings.hooks.PreToolUse | Where-Object { $_.matcher -eq 'Edit|Write' })
            $entry.Count | Should -Be 1 -Because 'the hook runs before an Edit or a Write'
            @($entry[0].hooks.command) | Should -Contain 'pwsh -NoProfile -File .claude/skills/ai-sdlc-hooks/scripts/Invoke-CompactSuggestionHook.ps1'
        }
    }
}
