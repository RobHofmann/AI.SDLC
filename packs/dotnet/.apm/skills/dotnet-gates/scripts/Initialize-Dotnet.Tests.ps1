#requires -Version 7.4
Describe 'Initialize-Dotnet' {
    BeforeAll {
        $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
        if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
        Import-Module (Join-Path $aiSdlcGates 'DocToolTestHarness.psm1') -Force
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Initialize-Dotnet.ps1'

        function New-TempRepo {
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            Set-AiSdlcTestConfig -Root $root
            return $root
        }
    }

    It 'plans the restore by default, and nothing with -Minimal or -SkipRestore' {
        Mock Get-Command { [pscustomobject]@{ Name = 'dotnet-coverage' } } -ParameterFilter { $Name -eq 'dotnet-coverage' }
        $root = New-TempRepo
        @(& $script:ScriptUnderTest -RepoRoot $root -Plan) | Should -Be @('dotnet restore')
        @(& $script:ScriptUnderTest -RepoRoot $root -Plan -Minimal).Count | Should -Be 0
        @(& $script:ScriptUnderTest -RepoRoot $root -Plan -SkipRestore).Count | Should -Be 0
    }

    It 'reports the SDK row and would restore the solution from aisdlc.json under -WhatIf' {
        $root = New-TempRepo
        $rows = @(& $script:ScriptUnderTest -RepoRoot $root -WhatIf 6>$null)
        $rows.Step | Should -Contain '.NET SDK'
        $rows.Step | Should -Contain 'Azure Functions Core Tools'
        $restore = $rows | Where-Object Step -eq 'dotnet restore'
        if (Get-Command dotnet -ErrorAction SilentlyContinue) {
            $restore.Status | Should -Be 'WHATIF'
            $restore.Detail | Should -Match 'Demo/Demo\.sln'
        }
    }

    Context 'with a stub for dotnet' {
        BeforeEach {
            function dotnet { if ($args[0] -eq '--list-sdks') { '8.0.404 [C:\sdk]'; '9.0.100 [C:\sdk]' } }
        }

        It 'passes the SDK row when an installed SDK matches the version in global.json' {
            $root = New-TempRepo
            Set-Content -LiteralPath (Join-Path $root 'global.json') -Value '{ "sdk": { "version": "9.0.100" } }'
            $row = @(& $script:ScriptUnderTest -RepoRoot $root -Minimal 6>$null) | Where-Object Step -eq '.NET SDK'
            $row.Status | Should -Be 'PASS'
            $row.Detail | Should -Match '9\.0'
        }

        It 'warns on the SDK row when no installed SDK matches the version in global.json' {
            $root = New-TempRepo
            Set-Content -LiteralPath (Join-Path $root 'global.json') -Value '{ "sdk": { "version": "10.0.100" } }'
            $row = @(& $script:ScriptUnderTest -RepoRoot $root -Minimal 6>$null) | Where-Object Step -eq '.NET SDK'
            $row.Status | Should -Be 'WARN'
            $row.Detail | Should -Match 'global\.json asks for 10\.0\.100'
        }

        # The stub lists 8.0.404 and 9.0.100. Each case below follows the global.json page of the .NET docs.
        It 'warns when global.json asks for <Version>: <Why>' -ForEach @(
            @{ Version = '9.0.300'; RollForward = $null; Why = 'no rollForward keeps the feature band 9.0.3xx' }
            @{ Version = '8.0.100'; RollForward = $null; Why = '8.0.404 is in another feature band' }
            @{ Version = '9.0.300'; RollForward = 'latestFeature'; Why = '9.0.100 is below the asked version' }
            @{ Version = '8.0.400'; RollForward = 'disable'; Why = 'disable needs the exact version' }
            @{ Version = '8.0.400'; RollForward = 'DISABLE'; Why = 'dotnet reads the name without regard to capitals, so DISABLE still needs the exact version' }
        ) {
            $root = New-TempRepo
            $sdk = @{ version = $Version }
            if ($RollForward) { $sdk.rollForward = $RollForward }
            Set-Content -LiteralPath (Join-Path $root 'global.json') -Value (@{ sdk = $sdk } | ConvertTo-Json)
            $row = @(& $script:ScriptUnderTest -RepoRoot $root -Minimal 6>$null) | Where-Object Step -eq '.NET SDK'
            $row.Status | Should -Be 'WARN' -Because $Why
        }

        It 'passes when <Version> with rollForward <RollForward> can roll forward to an installed SDK' -ForEach @(
            @{ Version = '7.0.100'; RollForward = 'latestMajor' }
            @{ Version = '7.0.100'; RollForward = 'major' }
            @{ Version = '7.0.100'; RollForward = 'LatestMajor' }
            @{ Version = '7.0.100'; RollForward = 'LATESTMAJOR' }
        ) {
            $root = New-TempRepo
            Set-Content -LiteralPath (Join-Path $root 'global.json') -Value (@{ sdk = @{ version = $Version; rollForward = $RollForward } } | ConvertTo-Json)
            $row = @(& $script:ScriptUnderTest -RepoRoot $root -Minimal 6>$null) | Where-Object Step -eq '.NET SDK'
            $row.Status | Should -Be 'PASS'
        }

        # dotnet ignores a global.json with a short version or an unknown rollForward, and uses the newest SDK.
        It 'passes with the newest SDK when dotnet ignores global.json: <Why>' -ForEach @(
            @{ Version = '9.0'; RollForward = $null; Why = 'the version is not a full SDK version' }
            @{ Version = '10.0.100'; RollForward = 'newest'; Why = 'dotnet does not know the rollForward value' }
        ) {
            $root = New-TempRepo
            $sdk = @{ version = $Version }
            if ($RollForward) { $sdk.rollForward = $RollForward }
            Set-Content -LiteralPath (Join-Path $root 'global.json') -Value (@{ sdk = $sdk } | ConvertTo-Json)
            $row = @(& $script:ScriptUnderTest -RepoRoot $root -Minimal 6>$null) | Where-Object Step -eq '.NET SDK'
            $row.Status | Should -Be 'PASS' -Because $Why
            $row.Detail | Should -Match 'ignores'
            $row.Detail | Should -Match '9\.0\.100' -Because 'dotnet then uses the newest installed SDK'
        }

        It 'passes the SDK row on any installed SDK when there is no global.json' {
            $root = New-TempRepo
            $row = @(& $script:ScriptUnderTest -RepoRoot $root -Minimal 6>$null) | Where-Object Step -eq '.NET SDK'
            $row.Status | Should -Be 'PASS'
            $row.Detail | Should -Not -Match 'net10'
        }
    }

    Context 'the dotnet-coverage tool' {
        BeforeEach {
            $global:DotnetCalls = [System.Collections.Generic.List[string]]::new()
            $global:ToolInstallExit = 0
            function dotnet {
                $global:DotnetCalls.Add(($args -join ' '))
                $global:LASTEXITCODE = 0
                if ($args[0] -eq '--list-sdks') { '9.0.100 [C:\sdk]' }
                if ($args[0] -eq 'tool') { $global:LASTEXITCODE = $global:ToolInstallExit }
            }
        }

        AfterAll {
            Remove-Variable -Name DotnetCalls, ToolInstallExit -Scope Global -ErrorAction SilentlyContinue
        }

        It 'installs dotnet-coverage as a global tool when it is missing, and says so' {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'dotnet-coverage' }

            $row = @(& $script:ScriptUnderTest -RepoRoot (New-TempRepo) -SkipRestore 6>$null) | Where-Object Step -eq 'dotnet-coverage'

            $row.Status | Should -Be 'SET'
            $row.Detail | Should -Match 'installed'
            @($global:DotnetCalls | Where-Object { $_ -eq 'tool install --global dotnet-coverage' }) | Should -HaveCount 1
        }

        It 'plans the install of dotnet-coverage when it is missing' {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'dotnet-coverage' }

            @(& $script:ScriptUnderTest -RepoRoot (New-TempRepo) -Plan -SkipRestore) | Should -Be @('dotnet tool install --global dotnet-coverage')
        }

        It 'installs nothing when dotnet-coverage is on PATH' {
            Mock Get-Command { [pscustomobject]@{ Name = 'dotnet-coverage' } } -ParameterFilter { $Name -eq 'dotnet-coverage' }

            $row = @(& $script:ScriptUnderTest -RepoRoot (New-TempRepo) -SkipRestore 6>$null) | Where-Object Step -eq 'dotnet-coverage'

            $row.Status | Should -Be 'PASS'
            @($global:DotnetCalls | Where-Object { $_ -like 'tool *' }) | Should -HaveCount 0
        }

        It 'warns with the command to run by hand when the install fails' {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'dotnet-coverage' }
            $global:ToolInstallExit = 1

            $row = @(& $script:ScriptUnderTest -RepoRoot (New-TempRepo) -SkipRestore 6>$null) | Where-Object Step -eq 'dotnet-coverage'

            $row.Status | Should -Be 'WARN'
            $row.Detail | Should -Match 'dotnet tool install --global dotnet-coverage'
        }

        It 'installs nothing under -WhatIf or -Minimal' {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'dotnet-coverage' }

            $whatIf = @(& $script:ScriptUnderTest -RepoRoot (New-TempRepo) -SkipRestore -WhatIf 6>$null) | Where-Object Step -eq 'dotnet-coverage'
            $minimal = @(& $script:ScriptUnderTest -RepoRoot (New-TempRepo) -Minimal 6>$null) | Where-Object Step -eq 'dotnet-coverage'

            $whatIf.Status | Should -Be 'WHATIF'
            $minimal | Should -BeNullOrEmpty
            @($global:DotnetCalls | Where-Object { $_ -like 'tool *' }) | Should -HaveCount 0
        }
    }

    It 'leaves the restore out with -Minimal' {
        $root = New-TempRepo
        $rows = @(& $script:ScriptUnderTest -RepoRoot $root -Minimal -WhatIf 6>$null)
        $rows.Step | Should -Not -Contain 'dotnet restore'
    }
}
