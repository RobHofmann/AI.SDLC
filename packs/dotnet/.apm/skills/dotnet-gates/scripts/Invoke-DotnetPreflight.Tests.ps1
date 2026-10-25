#requires -Version 7.4

Describe 'Invoke-DotnetPreflight' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-DotnetPreflight.ps1'

        function dotnet { }
        function dotnet-coverage { }
        function dotnet-sonarscanner { }

        function New-DotnetRepo {
            param([hashtable]$Paths = @{ solution = 'App.sln'; runSettings = 'App.runsettings'; coverageBaseline = 'coverage-baseline.json' }, [hashtable]$SonarCloud = @{})
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value (@{ paths = $Paths; sonarcloud = $SonarCloud } | ConvertTo-Json -Depth 4)
            Set-Content -LiteralPath (Join-Path $root 'coverage-baseline.json') -Value '{ "lineCoveragePercent": 50 }'
            return $root
        }

        function Invoke-Preflight {
            param([string]$Root, [hashtable]$Extra = @{})
            $rows = @(& $script:ScriptUnderTest -RepoRoot $Root @Extra 6> $null)
            return @($rows | Where-Object { $_.PSObject.Properties['Check'] })
        }

        function Get-Row {
            param([object[]]$Rows, [string]$Like)
            return @($Rows | Where-Object { $_.Check -like $Like })[0]
        }

        function Write-CoverageReport {
            param([string]$Path, [int]$Visited)
            $xml = "<?xml version=`"1.0`" encoding=`"utf-8`"?><CoverageSession><Summary numSequencePoints=`"100`" visitedSequencePoints=`"$Visited`" /><Modules><Module><ModuleName>App</ModuleName><Summary numSequencePoints=`"100`" visitedSequencePoints=`"$Visited`" /></Module></Modules></CoverageSession>"
            Set-Content -LiteralPath $Path -Value $xml -Encoding utf8
        }
    }

    BeforeEach {
        $global:DotnetTest = @{
            Calls       = [System.Collections.Generic.List[string]]::new()
            BuildExit   = 0
            BuildOutput = @('Build succeeded.')
            TestExit    = 0
            Coverage    = 90
            WriteCov    = $true
        }
        Mock dotnet {
            $global:DotnetTest.Calls.Add(($args -join ' '))
            $global:LASTEXITCODE = 0
            if ($args[0] -eq 'build') {
                $global:LASTEXITCODE = $global:DotnetTest.BuildExit
                return $global:DotnetTest.BuildOutput
            }
            if ($args[0] -eq 'test') {
                $index = [array]::IndexOf($args, '--results-directory')
                if ($global:DotnetTest.WriteCov) {
                    $dir = Join-Path $args[$index + 1] 'run'
                    New-Item -ItemType Directory -Path $dir -Force | Out-Null
                    Set-Content -LiteralPath (Join-Path $dir 'a.coverage') -Value 'binary'
                }
                $global:LASTEXITCODE = $global:DotnetTest.TestExit
            }
        }
        Mock dotnet-coverage {
            $global:DotnetTest.Calls.Add('dotnet-coverage ' + ($args -join ' '))
            $index = [array]::IndexOf($args, '--output')
            Write-CoverageReport -Path $args[$index + 1] -Visited $global:DotnetTest.Coverage
            $global:LASTEXITCODE = 0
        }
        Mock dotnet-sonarscanner {
            $global:DotnetTest.Calls.Add('dotnet-sonarscanner ' + ($args -join ' '))
            $global:LASTEXITCODE = 0
        }
    }

    AfterAll {
        Remove-Variable -Name DotnetTest -Scope Global -ErrorAction SilentlyContinue
    }

    It 'skips with one row when aisdlc.json names no solution, and runs nothing' {
        $root = New-DotnetRepo -Paths @{}

        $rows = Invoke-Preflight -Root $root

        $rows.Count | Should -Be 1
        $rows[0].Status | Should -Be 'SKIP'
        $global:DotnetTest.Calls.Count | Should -Be 0
    }

    It 'builds the solution in Release and tests it with the run settings and code coverage' {
        $root = New-DotnetRepo

        Invoke-Preflight -Root $root | Out-Null

        $build = @($global:DotnetTest.Calls | Where-Object { $_ -like 'build *' })
        $build[0] | Should -Match ([regex]::Escape((Join-Path $root 'App.sln')) + ' -c Release')
        $test = @($global:DotnetTest.Calls | Where-Object { $_ -like 'test *' })
        $test.Count | Should -Be 1
        $test[0] | Should -Match '--collect Code Coverage'
        $test[0] | Should -Match ('--settings ' + [regex]::Escape((Join-Path $root 'App.runsettings')))
    }

    It 'passes every step when the build, the tests and the ratchet pass' {
        $rows = Invoke-Preflight -Root (New-DotnetRepo)

        (Get-Row $rows 'Build*').Status | Should -Be 'PASS'
        (Get-Row $rows 'Tests*').Status | Should -Be 'PASS'
        (Get-Row $rows 'SonarCloud*').Status | Should -Be 'OPT-IN'
        @($global:DotnetTest.Calls | Where-Object { $_ -like 'dotnet-coverage merge *' }).Count | Should -Be 1
    }

    It 'fails the tests row when coverage drops below the recorded baseline' {
        $global:DotnetTest.Coverage = 10

        $rows = Invoke-Preflight -Root (New-DotnetRepo)

        (Get-Row $rows 'Tests*').Status | Should -Be 'FAIL'
    }

    It 'fails the C04 row and names the fix when the test run wrote no coverage file' {
        $global:DotnetTest.WriteCov = $false

        $rows = Invoke-Preflight -Root (New-DotnetRepo)

        (Get-Row $rows 'Tests*').Status | Should -Be 'FAIL'
        (Get-Row $rows 'Tests*').Detail | Should -Match 'no coverage file'
        (Get-Row $rows 'Tests*').Detail | Should -Match 'Code Coverage'
        @($global:DotnetTest.Calls | Where-Object { $_ -like 'dotnet-coverage*' }).Count | Should -Be 0
    }

    It 'fails the C04 row and names the fix when dotnet-coverage is not installed' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'dotnet-coverage' }

        $rows = Invoke-Preflight -Root (New-DotnetRepo)

        (Get-Row $rows 'Tests*').Status | Should -Be 'FAIL'
        (Get-Row $rows 'Tests*').Detail | Should -Match 'dotnet tool install --global dotnet-coverage'
        (Get-Row $rows 'Tests*').Detail | Should -Match 'Initialize-AiSdlc\.ps1'
    }

    It 'fails the build row when the build fails' {
        $global:DotnetTest.BuildExit = 1

        $rows = Invoke-Preflight -Root (New-DotnetRepo)

        (Get-Row $rows 'Build*').Status | Should -Be 'FAIL'
    }

    It 'asks for a review when a build warning names a changed file' {
        $global:DotnetTest.BuildOutput = @('src/Api/Thing.cs(4,2): warning S1481: Remove the unused local variable', 'src/Api/Other.cs(1,1): warning CA1822: Mark as static')

        $rows = Invoke-Preflight -Root (New-DotnetRepo) -Extra @{ ChangedFiles = @('src/Api/Thing.cs') }

        (Get-Row $rows 'Build*').Status | Should -Be 'REVIEW'
    }

    It 'keeps the build row green when the warnings are on files the change did not touch' {
        $global:DotnetTest.BuildOutput = @('src/Api/Other.cs(1,1): warning CA1822: Mark as static')

        $rows = Invoke-Preflight -Root (New-DotnetRepo) -Extra @{ ChangedFiles = @('src/Api/Thing.cs') }

        (Get-Row $rows 'Build*').Status | Should -Be 'PASS'
    }

    It 'fails the tests row when dotnet test fails' {
        $global:DotnetTest.TestExit = 1

        $rows = Invoke-Preflight -Root (New-DotnetRepo)

        (Get-Row $rows 'Tests*').Status | Should -Be 'FAIL'
    }

    It 'runs no tests with -SkipTests' {
        $rows = Invoke-Preflight -Root (New-DotnetRepo) -Extra @{ SkipTests = $true }

        (Get-Row $rows 'Tests*').Status | Should -Be 'SKIP'
        @($global:DotnetTest.Calls | Where-Object { $_ -like 'test *' }).Count | Should -Be 0
    }

    It 'skips the build when dotnet is not installed' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'dotnet' }

        $rows = Invoke-Preflight -Root (New-DotnetRepo) -Extra @{ SkipTests = $true }

        (Get-Row $rows 'Build*').Status | Should -Be 'SKIP'
        @($global:DotnetTest.Calls | Where-Object { $_ -like 'build *' }).Count | Should -Be 0
    }

    It 'skips the tests row, and never reports a pass, when dotnet is not installed' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'dotnet' }
        $global:LASTEXITCODE = 0

        $rows = Invoke-Preflight -Root (New-DotnetRepo)

        (Get-Row $rows 'Tests*').Status | Should -Be 'SKIP'
        @($global:DotnetTest.Calls | Where-Object { $_ -like 'test *' }).Count | Should -Be 0
    }

    Context 'the SonarCloud opt-in' {
        BeforeEach {
            $script:SavedTokens = @{ SONAR_TOKEN = $env:SONAR_TOKEN; SONARCLOUD_TOKEN = $env:SONARCLOUD_TOKEN }
            $env:SONAR_TOKEN = $null
            $env:SONARCLOUD_TOKEN = $null
        }

        AfterEach {
            $env:SONAR_TOKEN = $script:SavedTokens.SONAR_TOKEN
            $env:SONARCLOUD_TOKEN = $script:SavedTokens.SONARCLOUD_TOKEN
        }

        It 'skips when aisdlc.json names no SonarCloud project' {
            $env:SONAR_TOKEN = 'token-value'

            $rows = Invoke-Preflight -Root (New-DotnetRepo) -Extra @{ SkipTests = $true; IncludeSonar = $true }

            (Get-Row $rows 'SonarCloud*').Status | Should -Be 'SKIP'
            @($global:DotnetTest.Calls | Where-Object { $_ -like 'dotnet-sonarscanner*' }).Count | Should -Be 0
        }

        It 'asks for a token and uploads nothing without one' {
            $root = New-DotnetRepo -SonarCloud @{ projectKey = 'key'; organization = 'org' }

            $rows = Invoke-Preflight -Root $root -Extra @{ SkipTests = $true; IncludeSonar = $true }

            (Get-Row $rows 'SonarCloud*').Status | Should -Be 'NEEDS-TOKEN'
            @($global:DotnetTest.Calls | Where-Object { $_ -like 'dotnet-sonarscanner*' }).Count | Should -Be 0
        }

        It 'runs begin, build and end, and never passes the token on the command line' {
            $env:SONAR_TOKEN = 'secret-token-value'
            $root = New-DotnetRepo -SonarCloud @{ projectKey = 'key'; organization = 'org' }

            $rows = Invoke-Preflight -Root $root -Extra @{ SkipTests = $true; IncludeSonar = $true }

            (Get-Row $rows 'SonarCloud*').Status | Should -Be 'PASS'
            $scanner = @($global:DotnetTest.Calls | Where-Object { $_ -like 'dotnet-sonarscanner*' })
            $scanner[0] | Should -Match '^dotnet-sonarscanner begin'
            $scanner[-1] | Should -Match '^dotnet-sonarscanner end'
            @($global:DotnetTest.Calls | Where-Object { $_ -like 'build *' }).Count | Should -Be 2
            @($global:DotnetTest.Calls | Where-Object { $_ -match 'secret-token-value' }).Count | Should -Be 0
        }
    }
}
