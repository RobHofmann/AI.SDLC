#requires -Version 7.4
Describe 'Deny-StaleGraphQuery' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Deny-StaleGraphQuery.ps1'

        $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
        if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
        Import-Module (Join-Path $aiSdlcGates 'DocToolTestHarness.psm1') -Force

        function New-GraphRepo {
            param([switch]$Stale)

            $root = New-DocToolRepo -Prefix 'dsq' -InitialiseGit -Files @{
                'Demo/src/Shared.Thing/A.cs' = 'public class A { }'
            }
            $graphFile = Join-Path $root 'graphify-out/graph.json'
            New-Item -ItemType Directory -Path (Split-Path $graphFile -Parent) -Force | Out-Null
            [ordered]@{
                nodes           = @([pscustomobject]@{ id = 'a'; label = 'A'; source_file = 'Demo/src/Shared.Thing/A.cs' })
                links           = @()
                built_at_commit = [string](git -C $root rev-parse HEAD)
            } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $graphFile -Encoding utf8

            if ($Stale) {
                Set-Content -LiteralPath (Join-Path $root 'Demo/src/Shared.Thing/A.cs') -Value 'public class A { void B() { } }' -Encoding utf8
            }
            return $root
        }

        function New-Payload {
            param([string]$Command)
            return (@{
                    hook_event_name = 'PreToolUse'
                    tool_name       = 'Bash'
                    tool_input      = @{ command = $Command; description = 'probe' }
                } | ConvertTo-Json -Compress)
        }

        function Invoke-Hook {
            param([string]$Command, [string]$Root)
            $out = & $script:ScriptUnderTest -Payload (New-Payload -Command $Command) -RepoRoot $Root *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }
    }

    AfterAll {
        Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'dsq-*' -Directory -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Module DocToolTestHarness -Force -ErrorAction SilentlyContinue
    }

    Context 'the command filter, which the configuration cannot be trusted to apply' {
        It 'allows <Command>, which asks the graph nothing' -ForEach @(
            @{ Command = 'echo hello' }
            @{ Command = 'git log --oneline -5' }
            @{ Command = 'graphify --help' }
            @{ Command = 'graphify extract . --code-only' }
        ) {
            # Arrange
            $root = New-GraphRepo -Stale

            # Act
            $r = Invoke-Hook -Command $Command -Root $root

            # Assert
            $r.Output | Should -Not -Match 'permissionDecision'
        }

        It 'allows the wrapper, whose command line carries no bare graphify query' {
            # Arrange
            $root = New-GraphRepo -Stale

            # Act
            $r = Invoke-Hook -Command 'pwsh .claude/skills/dotnet-code-graph/scripts/Invoke-GraphifyQuery.ps1 affected "A"' -Root $root

            # Assert
            $r.Output | Should -Not -Match 'permissionDecision'
        }
    }

    Context 'what it does with a raw query' {
        It 'denies <Command> while the graph is behind the working tree' -ForEach @(
            @{ Command = 'graphify affected "A" --depth 2' }
            @{ Command = 'graphify explain "A"' }
            @{ Command = 'graphify path "A" "B"' }
            @{ Command = 'cd /repo && graphify affected "A"' }
        ) {
            # Arrange
            $root = New-GraphRepo -Stale

            # Act
            $r = Invoke-Hook -Command $Command -Root $root

            # Assert
            $r.Output | Should -Match 'permissionDecision'
            $r.Output | Should -Match 'deny'
            $r.Output | Should -Match 'Invoke-GraphifyQuery'
        }

        It 'denies <Command> from the PowerShell tool while the graph is behind the working tree' -ForEach @(
            @{ Command = 'graphify explain "A"' }
            @{ Command = '& graphify affected "A"' }
            @{ Command = 'Set-Location C:/repo; graphify path "A" "B"' }
        ) {
            # Arrange
            $root = New-GraphRepo -Stale
            $payload = @{ hook_event_name = 'PreToolUse'; tool_name = 'PowerShell'; tool_input = @{ command = $Command } } | ConvertTo-Json -Compress

            # Act
            $out = & $script:ScriptUnderTest -Payload $payload -RepoRoot $root *>&1 | Out-String

            # Assert
            $out | Should -Match '"permissionDecision":"deny"'
        }

        It 'stays out of the way when the graph is current, or it would be switched off' {
            # Arrange
            $root = New-GraphRepo

            # Act
            $r = Invoke-Hook -Command 'graphify affected "A"' -Root $root

            # Assert
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Not -Match 'permissionDecision'
        }

        It 'allows the query when there is no graph at all, since graphify says so itself' {
            # Arrange
            $root = New-DocToolRepo -Prefix 'dsq' -InitialiseGit -Files @{ 'Demo/src/Shared.Thing/A.cs' = 'public class A { }' }

            # Act
            $r = Invoke-Hook -Command 'graphify affected "A"' -Root $root

            # Assert
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Not -Match 'permissionDecision'
        }

        It 'names the changed files, so the deny is evidence and not an assertion' {
            # Arrange
            $root = New-GraphRepo -Stale

            # Act
            $r = Invoke-Hook -Command 'graphify affected "A"' -Root $root

            # Assert
            $r.Output | Should -Match 'A\.cs'
        }
    }

    Context 'it never blocks the shell on its own failure' {
        It 'allows an unreadable payload rather than denying every command' {
            # Act
            $r = & $script:ScriptUnderTest -Payload 'not json at all' *>&1 | Out-String

            # Assert
            $LASTEXITCODE | Should -Be 0
            $r | Should -Not -Match 'permissionDecision'
        }

        It 'allows an empty payload' {
            # Act
            $r = & $script:ScriptUnderTest -Payload '' *>&1 | Out-String

            # Assert
            $LASTEXITCODE | Should -Be 0
            $r | Should -Not -Match 'permissionDecision'
        }

        It 'reads the Copilot toolArgs shape as well as the Claude tool_input shape' {
            # Arrange
            $root = New-GraphRepo -Stale
            $payload = @{ toolArgs = @{ command = 'graphify explain "A"' } } | ConvertTo-Json -Compress

            # Act
            $out = & $script:ScriptUnderTest -Payload $payload -RepoRoot $root *>&1 | Out-String

            # Assert
            $out | Should -Match 'permissionDecision'
        }
    }
}
