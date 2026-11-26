#requires -Version 7.4

BeforeAll { $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm' }

Describe 'SonarMcpToken' -Tag '84' {
    BeforeAll {
        Import-Module (Join-Path $script:ScriptFolder 'SonarMcpToken.psm1') -Force
        $script:Fake = 'fake-sonar-token-84'
        $script:SetCommand = 'pwsh .claude/skills/sonarcloud-mcp/scripts/Set-SonarMcpToken.ps1'
    }

    BeforeEach {
        $script:SavedToken = $env:AISDLC_SONAR_MCP_TOKEN
        $script:SavedXdg = $env:XDG_CONFIG_HOME
    }

    AfterEach {
        $env:AISDLC_SONAR_MCP_TOKEN = $script:SavedToken
        $env:XDG_CONFIG_HOME = $script:SavedXdg
    }

    AfterAll { Remove-Module SonarMcpToken -Force -ErrorAction SilentlyContinue }

    Context 'Test-TokenInProcess' {
        It 'is true when AISDLC_SONAR_MCP_TOKEN is set in the process' {
            $env:AISDLC_SONAR_MCP_TOKEN = $script:Fake
            Test-TokenInProcess | Should -BeTrue
        }

        It 'is false when AISDLC_SONAR_MCP_TOKEN is not set in the process' {
            Remove-Item Env:AISDLC_SONAR_MCP_TOKEN -ErrorAction SilentlyContinue
            Test-TokenInProcess | Should -BeFalse
        }

        It 'is false when AISDLC_SONAR_MCP_TOKEN is inherited with an empty value' {
            $startInfo = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
            foreach ($argument in @('-NoProfile', '-NonInteractive', '-Command', "Import-Module '$(Join-Path $script:ScriptFolder 'SonarMcpToken.psm1')' -Force; Test-TokenInProcess")) { $startInfo.ArgumentList.Add($argument) }
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardOutput = $true
            $startInfo.Environment['AISDLC_SONAR_MCP_TOKEN'] = ''

            $process = [System.Diagnostics.Process]::Start($startInfo)
            $answer = $process.StandardOutput.ReadToEnd().Trim()
            $process.WaitForExit()

            $answer | Should -BeExactly 'False'
        }
    }

    Context 'Test-IsWindows' {
        It 'returns the platform answer as a boolean' {
            Test-IsWindows | Should -BeOfType [bool]
            Test-IsWindows | Should -Be ([bool]$IsWindows)
        }
    }

    Context 'Get-SonarMcpTokenFile' {
        It 'puts the file under XDG_CONFIG_HOME when it is set' {
            $env:XDG_CONFIG_HOME = Join-Path $TestDrive 'xdg'

            Get-SonarMcpTokenFile | Should -BeExactly (Join-Path $TestDrive 'xdg' 'ai-sdlc' 'sonar-mcp-token')
        }

        It 'puts the file under the .config folder of the home folder when XDG_CONFIG_HOME is empty' {
            $env:XDG_CONFIG_HOME = ''

            Get-SonarMcpTokenFile | Should -BeExactly (Join-Path $HOME '.config' 'ai-sdlc' 'sonar-mcp-token')
        }
    }

    Context 'Get-SonarMcpProfileLine' {
        It 'reads the token file into AISDLC_SONAR_MCP_TOKEN and holds no token' {
            $env:AISDLC_SONAR_MCP_TOKEN = $script:Fake

            $line = Get-SonarMcpProfileLine

            $line | Should -Match '^export AISDLC_SONAR_MCP_TOKEN='
            $line | Should -Match 'ai-sdlc/sonar-mcp-token'
            $line | Should -Not -Match $script:Fake
            $line | Should -Not -Match "`n"
        }
    }

    Context 'Test-TokenStored off Windows, where a file holds the token' {
        BeforeEach {
            Mock -ModuleName SonarMcpToken Test-IsWindows { $false }
            $env:XDG_CONFIG_HOME = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        }

        It 'is false when there is no token file' {
            Test-TokenStored | Should -BeFalse
        }

        It 'is false when the token file is empty' {
            New-Item -ItemType File -Path (Get-SonarMcpTokenFile) -Force | Out-Null

            Test-TokenStored | Should -BeFalse
        }

        It 'is true when the token file has content, and returns a boolean, never the value' {
            New-Item -ItemType File -Path (Get-SonarMcpTokenFile) -Force | Out-Null
            Set-Content -LiteralPath (Get-SonarMcpTokenFile) -Value $script:Fake -NoNewline

            $result = Test-TokenStored

            $result | Should -BeOfType [bool]
            $result | Should -BeTrue
        }

        It 'is false when the path is a folder and not a file' {
            New-Item -ItemType Directory -Path (Get-SonarMcpTokenFile) -Force | Out-Null

            Test-TokenStored | Should -BeFalse
        }
    }

    Context 'Test-TokenStored on Windows' {
        It 'returns a boolean on this machine and never the value' {
            Mock -ModuleName SonarMcpToken Test-IsWindows { $true }

            $result = Test-TokenStored

            $result | Should -BeOfType [bool]
            "$result" | Should -Not -Match 'fake-sonar'
        }
    }

    Context 'Get-SonarMcpTokenState' {
        It 'is Process when the process holds the token, even when the store holds it too' {
            Mock -ModuleName SonarMcpToken Test-TokenInProcess { $true }
            Mock -ModuleName SonarMcpToken Test-TokenStored { $true }
            Get-SonarMcpTokenState | Should -BeExactly 'Process'
        }

        It 'is Stored when only the store holds the token' {
            Mock -ModuleName SonarMcpToken Test-TokenInProcess { $false }
            Mock -ModuleName SonarMcpToken Test-TokenStored { $true }
            Get-SonarMcpTokenState | Should -BeExactly 'Stored'
        }

        It 'is Missing when neither holds the token' {
            Mock -ModuleName SonarMcpToken Test-TokenInProcess { $false }
            Mock -ModuleName SonarMcpToken Test-TokenStored { $false }
            Get-SonarMcpTokenState | Should -BeExactly 'Missing'
        }
    }

    Context 'Get-SonarMcpTokenAdvice' {
        It 'gives no advice when the process holds the token' {
            Get-SonarMcpTokenAdvice -State Process | Should -BeNullOrEmpty
        }

        It 'tells a Stored person on Windows to restart the terminal and the tool, with no profile step' {
            Mock -ModuleName SonarMcpToken Test-IsWindows { $true }

            $advice = Get-SonarMcpTokenAdvice -State Stored

            $advice | Should -Match 'restart your terminal and Claude Code or VS Code'
            $advice | Should -Not -Match 'shell profile'
            $advice | Should -Not -Match "`n"
        }

        It 'tells a Stored person off Windows to add the shell profile line, then restart' {
            Mock -ModuleName SonarMcpToken Test-IsWindows { $false }

            $advice = Get-SonarMcpTokenAdvice -State Stored

            $advice | Should -Match 'shell profile'
            $advice | Should -Match 'restart your terminal and Claude Code or VS Code'
            $advice | Should -Not -Match "`n"
        }

        It 'names the command and the restart for a Missing token when Windows is <_>' -ForEach @($true, $false) {
            $onWindows = $_
            Mock -ModuleName SonarMcpToken Test-IsWindows { $onWindows }.GetNewClosure()

            $advice = Get-SonarMcpTokenAdvice -State Missing

            $advice | Should -Match ([regex]::Escape($script:SetCommand))
            $advice | Should -Match 'restart your terminal and Claude Code or VS Code'
            $advice | Should -Not -Match "`n"
        }

        It 'rejects a state outside the closed set' {
            { Get-SonarMcpTokenAdvice -State 'Other' } | Should -Throw
        }
    }
}
