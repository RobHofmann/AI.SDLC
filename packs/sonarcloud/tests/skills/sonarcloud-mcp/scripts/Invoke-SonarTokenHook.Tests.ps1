#requires -Version 7.4

BeforeAll { $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm' }

Describe 'Invoke-SonarTokenHook' -Tag '84' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $script:ScriptFolder -ChildPath 'Invoke-SonarTokenHook.ps1'
        $script:Fake = 'fake-sonar-token-84'
        $script:SetCommand = 'pwsh .claude/skills/sonarcloud-mcp/scripts/Set-SonarMcpToken.ps1'
        . $script:ScriptUnderTest

        function Get-HookText {
            param([string]$Json)
            $parsed = $Json | ConvertFrom-Json
            return [pscustomobject]@{ Top = $parsed.additionalContext; Nested = $parsed.hookSpecificOutput.additionalContext; EventName = $parsed.hookSpecificOutput.hookEventName }
        }
    }

    Context 'Get-SonarTokenHookOutput' {
        It 'is silent when the process holds the token' {
            Mock Get-SonarMcpTokenState { 'Process' }

            Get-SonarTokenHookOutput | Should -BeNullOrEmpty
        }

        It 'gives one SessionStart line that names the restart when only the store holds the token' {
            Mock Get-SonarMcpTokenState { 'Stored' }

            $text = Get-HookText (Get-SonarTokenHookOutput)

            $text.EventName | Should -BeExactly 'SessionStart'
            $text.Top | Should -Match 'restart your terminal and Claude Code or VS Code'
            $text.Nested | Should -BeExactly $text.Top
            $text.Top | Should -Not -Match "`n"
        }

        It 'gives one SessionStart line that names the command and the restart when the token is missing' {
            Mock Get-SonarMcpTokenState { 'Missing' }

            $text = Get-HookText (Get-SonarTokenHookOutput)

            $text.EventName | Should -BeExactly 'SessionStart'
            $text.Top | Should -Match ([regex]::Escape($script:SetCommand))
            $text.Top | Should -Match 'restart your terminal and Claude Code or VS Code'
            $text.Top | Should -Not -Match "`n"
        }

        It 'gives no output when the check fails, and never the error text' {
            Mock Get-SonarMcpTokenState { throw "boom $script:Fake" }

            Get-SonarTokenHookOutput | Should -BeNullOrEmpty
        }
    }

    Context 'run as a script, in a child process' {
        BeforeAll {
            function Invoke-HookProcess {
                param([hashtable]$Environment = @{})

                $psi = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
                foreach ($argument in '-NoProfile', '-File', $script:ScriptUnderTest) { $psi.ArgumentList.Add($argument) }
                $psi.RedirectStandardInput = $true
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $psi.UseShellExecute = $false
                foreach ($name in 'AISDLC_SONAR_MCP_TOKEN', 'SONAR_TOKEN', 'SONARCLOUD_TOKEN') { $null = $psi.Environment.Remove($name) }
                # An empty config folder keeps a token file of the person who runs the tests out of the result.
                $psi.Environment['XDG_CONFIG_HOME'] = Join-Path $TestDrive 'empty-config'
                foreach ($name in $Environment.Keys) { $psi.Environment[$name] = $Environment[$name] }

                $process = [System.Diagnostics.Process]::Start($psi)
                try {
                    $stdout = $process.StandardOutput.ReadToEndAsync()
                    $stderr = $process.StandardError.ReadToEndAsync()
                    $exited = $process.WaitForExit(60000)
                    if (-not $exited) { $process.Kill($true) }
                    return [pscustomobject]@{ Exited = $exited; ExitCode = $process.ExitCode; Output = $stdout.Result; Error = $stderr.Result }
                }
                finally { $process.Dispose() }
            }
        }

        It 'is silent and exits 0 when the process holds the token' {
            $r = Invoke-HookProcess -Environment @{ AISDLC_SONAR_MCP_TOKEN = $script:Fake }

            $r.Exited | Should -BeTrue
            $r.ExitCode | Should -Be 0
            $r.Output | Should -BeNullOrEmpty
            ($r.Output + $r.Error) | Should -Not -Match $script:Fake
        }

        It 'exits 0 and prints exactly one valid JSON SessionStart line when the token is not in the process' {
            $r = Invoke-HookProcess

            $r.Exited | Should -BeTrue
            $r.ExitCode | Should -Be 0
            $lines = @($r.Output -split "`r?`n" | Where-Object { $_ })
            $lines.Count | Should -Be 1
            $text = Get-HookText $lines[0]
            $text.EventName | Should -BeExactly 'SessionStart'
            $text.Top | Should -Match ('restart your terminal and Claude Code or VS Code|' + [regex]::Escape($script:SetCommand))
        }
    }

    Context 'the script text' {
        It 'sets a trap that exits 0, so no failure ever blocks a session' {
            $text = Get-Content -LiteralPath $script:ScriptUnderTest -Raw
            $text | Should -Match 'trap \{ exit 0 \}'
            $text | Should -Not -Match 'exit [1-9]'
        }
    }

    Context 'the wiring in sonarcloud-hooks.json, or in .claude/settings.json of a consumer' {
        BeforeAll {
            $script:Command = 'pwsh -NoProfile -Command "& (Join-Path ([Environment]::GetEnvironmentVariable(''CLAUDE_PROJECT_DIR'') ?? ''.'') ''.claude/skills/sonarcloud-mcp/scripts/Invoke-SonarTokenHook.ps1'')"'
            $sourceFile = Join-Path $script:ScriptFolder '..' '..' '..' 'hooks' 'sonarcloud-hooks.json'
            if (Test-Path -LiteralPath $sourceFile) {
                $script:Registration = (Resolve-Path -LiteralPath $sourceFile).Path
                $script:InstalledRoot = Join-Path $script:ScriptFolder '..' '..'
            }
            else {
                $script:Registration = Join-Path $script:ScriptFolder '..' '..' '..' 'settings.json'
                $script:InstalledRoot = Join-Path $script:ScriptFolder '..' '..'
            }
            $script:Entries = @()
            if (Test-Path -LiteralPath $script:Registration) {
                $script:Entries = @((Get-Content -LiteralPath $script:Registration -Raw -Encoding utf8 | ConvertFrom-Json).hooks.SessionStart |
                        Where-Object { @($_.hooks | Where-Object { $_.command -eq $script:Command }).Count -gt 0 })
            }
        }

        BeforeEach {
            if (-not (Test-Path -LiteralPath $script:Registration)) { Set-ItResult -Skipped -Because "this layout has no $([IO.Path]::GetFileName($script:Registration)) to read" }
        }

        It 'has one SessionStart entry for the hook, which fires on every start source' {
            $script:Entries.Count | Should -Be 1
            $matcher = $script:Entries[0].PSObject.Properties['matcher']
            if ($matcher) { $matcher.Value | Should -BeIn @('', '*') }
        }

        It 'runs the hook as a command with a timeout' {
            $hook = @($script:Entries[0].hooks | Where-Object { $_.command -eq $script:Command })[0]
            $hook.type | Should -BeExactly 'command'
            $hook.timeout | Should -BeGreaterThan 0
        }

        It 'points at a script that exists in the skill folder' {
            Test-Path -LiteralPath (Join-Path $script:InstalledRoot 'sonarcloud-mcp' 'scripts' 'Invoke-SonarTokenHook.ps1') | Should -BeTrue
        }

        It 'uses a path relative to the repository root, never one inside the hooks folder' {
            $script:Command | Should -Not -Match 'apm_modules|\.apm/hooks|[A-Za-z]:[\\/]'
        }
    }
}
