#requires -Version 7.4

Describe 'Initialize-SonarCloud' -Tag '84' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Initialize-SonarCloud.ps1'
        Import-Module (Join-Path $PSScriptRoot 'SonarMcpToken.psm1') -Force
        $script:Fake = 'fake-sonar-token-84'
        $script:SetCommand = 'pwsh .claude/skills/sonarcloud-mcp/scripts/Set-SonarMcpToken.ps1'
    }

    AfterAll { Remove-Module SonarMcpToken -Force -ErrorAction SilentlyContinue }

    It 'is the setup script that gates.json names, next to the gates list' {
        $gates = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'gates.json') -Raw | ConvertFrom-Json
        $gates.setup | Should -BeExactly 'scripts/Initialize-SonarCloud.ps1'
        $gates.gates | Should -Not -BeNullOrEmpty
    }

    It 'returns nothing for -Plan, because it changes no machine setting' {
        $out = @(& $script:ScriptUnderTest -Plan)
        $out.Count | Should -Be 0
    }

    It 'binds -WhatIf and -Plan' {
        $parameters = (Get-Command -Name $script:ScriptUnderTest).Parameters.Keys
        $parameters | Should -Contain 'WhatIf'
        $parameters | Should -Contain 'Plan'
    }

    Context 'the row' {
        BeforeAll { . $script:ScriptUnderTest }

        It 'is OK when the process holds the token' {
            Mock Get-SonarMcpTokenState { 'Process' }
            $row = Get-SonarCloudSetupRow
            $row.Step | Should -BeExactly 'SonarCloud MCP token'
            $row.Status | Should -BeExactly 'OK'
        }

        It 'is WARN with the restart line when only the store holds the token' {
            Mock Get-SonarMcpTokenState { 'Stored' }
            $row = Get-SonarCloudSetupRow
            $row.Status | Should -BeExactly 'WARN'
            $row.Detail | Should -Match 'restart your terminal and Claude Code or VS Code'
        }

        It 'is WARN with the command when the token is missing' {
            Mock Get-SonarMcpTokenState { 'Missing' }
            $row = Get-SonarCloudSetupRow
            $row.Status | Should -BeExactly 'WARN'
            $row.Detail | Should -Match ([regex]::Escape($script:SetCommand))
        }

        It 'is WARN and never throws or fails when the state check breaks' {
            Mock Get-SonarMcpTokenState { throw "boom $script:Fake" }
            $row = Get-SonarCloudSetupRow
            $row.Status | Should -BeExactly 'WARN'
            $row.Detail | Should -Match ([regex]::Escape($script:SetCommand))
        }

        It 'is WARN when the advice breaks' {
            Mock Get-SonarMcpTokenState { 'Missing' }
            Mock Get-SonarMcpTokenAdvice { throw "boom $script:Fake" }
            (Get-SonarCloudSetupRow).Status | Should -BeExactly 'WARN'
        }

        It 'puts no token value in a row, whatever the state' {
            foreach ($state in 'Process', 'Stored', 'Missing') {
                Mock Get-SonarMcpTokenState { $state }.GetNewClosure()
                ((Get-SonarCloudSetupRow) | Out-String) | Should -Not -Match $script:Fake
            }
            Mock Get-SonarMcpTokenState { throw "boom $script:Fake" }
            ((Get-SonarCloudSetupRow) | Out-String) | Should -Not -Match $script:Fake
        }
    }

    Context 'run as a script' {
        BeforeEach {
            $script:HadToken = Test-Path -LiteralPath Env:AISDLC_SONAR_MCP_TOKEN
            $script:PreviousToken = $env:AISDLC_SONAR_MCP_TOKEN
        }

        AfterEach {
            if ($script:HadToken) { $env:AISDLC_SONAR_MCP_TOKEN = $script:PreviousToken }
            else { Remove-Item -LiteralPath Env:AISDLC_SONAR_MCP_TOKEN -ErrorAction SilentlyContinue }
        }

        It 'emits one OK row when the process holds the token, and shows no value' {
            $env:AISDLC_SONAR_MCP_TOKEN = $script:Fake
            $rows = @(& $script:ScriptUnderTest 6>$null)
            $rows.Count | Should -Be 1
            $rows[0].Status | Should -BeExactly 'OK'
            ($rows | Out-String) | Should -Not -Match $script:Fake
        }

        It 'emits one row that is OK or WARN under -WhatIf' {
            $rows = @(& $script:ScriptUnderTest -WhatIf 6>$null)
            $rows.Count | Should -Be 1
            $rows[0].Status | Should -BeIn @('OK', 'WARN')
        }

        It 'gives a WARN row and exit 0 when the module is missing next to the script' {
            $folder = Join-Path $TestDrive 'lonely'
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            Copy-Item -LiteralPath $script:ScriptUnderTest -Destination $folder
            $copy = Join-Path $folder 'Initialize-SonarCloud.ps1'
            $psi = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
            foreach ($argument in '-NoProfile', '-Command', "& '$copy' | ConvertTo-Json -Compress") { $psi.ArgumentList.Add($argument) }
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false

            $process = [System.Diagnostics.Process]::Start($psi)
            try {
                $stdout = $process.StandardOutput.ReadToEndAsync()
                $null = $process.StandardError.ReadToEndAsync()
                $process.WaitForExit(60000) | Should -BeTrue
                $row = $stdout.Result | ConvertFrom-Json
                $row.Status | Should -BeExactly 'WARN'
                $process.ExitCode | Should -Be 0
            }
            finally { $process.Dispose() }
        }
    }
}
