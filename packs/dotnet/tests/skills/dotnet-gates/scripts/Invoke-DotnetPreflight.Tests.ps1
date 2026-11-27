#requires -Version 7.4

BeforeAll { $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm' }

Describe 'Invoke-DotnetPreflight' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $script:ScriptFolder -ChildPath 'Invoke-DotnetPreflight.ps1'

        function dotnet { }
        function dotnet-coverage { }
        function dotnet-sonarscanner { }

        function New-DotnetRepo {
            param([hashtable]$Paths = @{ solution = 'App.sln'; runSettings = 'App.runsettings'; coverageBaseline = 'coverage-baseline.json' }, [hashtable]$SonarCloud = @{})
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value (@{ paths = $Paths; sonarcloud = $SonarCloud } | ConvertTo-Json -Depth 4)
            Set-Content -LiteralPath (Join-Path $root 'coverage-baseline.json') -Value '{ "lineCoveragePercent": 90 }'
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
            Filters     = [System.Collections.Generic.List[object]]::new()
        }
        Mock dotnet {
            $global:DotnetTest.Calls.Add(($args -join ' '))
            if ("$($args[1])" -like '*.slnf') { $global:DotnetTest.Filters.Add(@($args[0]) + @((Get-Content -LiteralPath $args[1] -Raw | ConvertFrom-Json).solution.projects | ForEach-Object { $_.Replace([string][char]92, '/') })) }
            $global:LASTEXITCODE = 0
            if ($args[0] -eq 'build') {
                $global:LASTEXITCODE = $global:DotnetTest.BuildExit
                return $global:DotnetTest.BuildOutput
            }
            if ($args[0] -eq 'test') {
                $index = [array]::IndexOf($args, '--results-directory')
                if ($global:DotnetTest.WriteCov -and $index -ge 0) {
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
            $script:SavedTokens = @{ SONAR_TOKEN = $env:SONAR_TOKEN; SONARCLOUD_TOKEN = $env:SONARCLOUD_TOKEN; AISDLC_SONAR_MCP_TOKEN = $env:AISDLC_SONAR_MCP_TOKEN }
            $env:SONAR_TOKEN = $null
            $env:SONARCLOUD_TOKEN = $null
            $env:AISDLC_SONAR_MCP_TOKEN = $null
        }

        AfterEach {
            $env:SONAR_TOKEN = $script:SavedTokens.SONAR_TOKEN
            $env:AISDLC_SONAR_MCP_TOKEN = $script:SavedTokens.AISDLC_SONAR_MCP_TOKEN
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

        Context 'which token the scanner gets' {
            BeforeEach {
                $global:DotnetTest.ScannerToken = @()
                Mock dotnet-sonarscanner {
                    $global:DotnetTest.Calls.Add('dotnet-sonarscanner ' + ($args -join ' '))
                    if ($args[0] -eq 'begin') { $global:DotnetTest.ScannerToken += $env:SONAR_TOKEN }
                    $global:LASTEXITCODE = if ($args[0] -eq 'begin') { $global:DotnetTest.BeginExit } else { 0 }
                }
                $global:DotnetTest.BeginExit = 0
                $script:SonarRoot = New-DotnetRepo -SonarCloud @{ projectKey = 'key'; organization = 'org' }
            }

            It 'falls back to AISDLC_SONAR_MCP_TOKEN when SONAR_TOKEN and SONARCLOUD_TOKEN are not set' -Tag '84' {
                $env:AISDLC_SONAR_MCP_TOKEN = 'fake-sonar-token-84'

                $rows = Invoke-Preflight -Root $script:SonarRoot -Extra @{ SkipTests = $true; IncludeSonar = $true }

                (Get-Row $rows 'SonarCloud*').Status | Should -Be 'PASS'
                $global:DotnetTest.ScannerToken | Should -Be @('fake-sonar-token-84')
            }

            It 'treats an empty SONAR_TOKEN and SONARCLOUD_TOKEN as not set' -Tag '84' {
                # On Windows an empty value removes the variable; on Linux and macOS it stays set and empty.
                [Environment]::SetEnvironmentVariable('SONAR_TOKEN', '')
                [Environment]::SetEnvironmentVariable('SONARCLOUD_TOKEN', '')
                $env:AISDLC_SONAR_MCP_TOKEN = 'fake-sonar-token-84'

                $rows = Invoke-Preflight -Root $script:SonarRoot -Extra @{ SkipTests = $true; IncludeSonar = $true }

                (Get-Row $rows 'SonarCloud*').Status | Should -Be 'PASS'
                $global:DotnetTest.ScannerToken | Should -Be @('fake-sonar-token-84')
            }

            It 'prefers SONAR_TOKEN, then SONARCLOUD_TOKEN, over AISDLC_SONAR_MCP_TOKEN' -Tag '84' {
                $env:AISDLC_SONAR_MCP_TOKEN = 'fake-mcp-token-84'
                $env:SONARCLOUD_TOKEN = 'fake-cloud-token-84'

                Invoke-Preflight -Root $script:SonarRoot -Extra @{ SkipTests = $true; IncludeSonar = $true } | Out-Null
                $env:SONAR_TOKEN = 'fake-sonar-token-84'
                Invoke-Preflight -Root $script:SonarRoot -Extra @{ SkipTests = $true; IncludeSonar = $true } | Out-Null

                $global:DotnetTest.ScannerToken | Should -Be @('fake-cloud-token-84', 'fake-sonar-token-84')
            }

            It 'leaves SONAR_TOKEN unset after the scan when only the fallback token was set' -Tag '84' {
                $env:AISDLC_SONAR_MCP_TOKEN = 'fake-sonar-token-84'

                Invoke-Preflight -Root $script:SonarRoot -Extra @{ SkipTests = $true; IncludeSonar = $true } | Out-Null

                Test-Path Env:SONAR_TOKEN | Should -BeFalse
            }

            It 'gives SONAR_TOKEN its old value back after the scan, also when the scanner fails' -Tag '84' {
                $env:SONAR_TOKEN = 'fake-sonar-token-84'
                $global:DotnetTest.BeginExit = 1

                $rows = Invoke-Preflight -Root $script:SonarRoot -Extra @{ SkipTests = $true; IncludeSonar = $true }

                (Get-Row $rows 'SonarCloud*').Status | Should -Be 'FAIL'
                $env:SONAR_TOKEN | Should -Be 'fake-sonar-token-84'
            }

            It 'names Set-SonarMcpToken.ps1 in the NEEDS-TOKEN row when no token is set' -Tag '84' {
                $rows = Invoke-Preflight -Root $script:SonarRoot -Extra @{ SkipTests = $true; IncludeSonar = $true }

                $row = Get-Row $rows 'SonarCloud*'
                $row.Status | Should -Be 'NEEDS-TOKEN'
                $row.Detail | Should -Match 'Set-SonarMcpToken\.ps1'
            }
        }
    }

    Context 'a scoped run, with -ScopeFiles' -Tag '#81' {
        BeforeAll {
            function New-ScopedRepo {
                $root = New-DotnetRepo
                foreach ($project in @(
                        @{ Path = 'src/Lib/Lib.csproj'; Refs = '' }
                        @{ Path = 'src/App/App.csproj'; Refs = '<ProjectReference Include="..\Lib\Lib.csproj" />' }
                        @{ Path = 'tests/Lib.Tests/Lib.Tests.csproj'; Refs = '<ProjectReference Include="..\..\src\Lib\Lib.csproj" />' }
                        @{ Path = 'tests/App.Tests/App.Tests.csproj'; Refs = '<ProjectReference Include="..\..\src\App\App.csproj" />' }
                    )) {
                    $full = Join-Path $root $project.Path
                    New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
                    Set-Content -LiteralPath $full -Value "<Project Sdk=`"Microsoft.NET.Sdk`"><ItemGroup>$($project.Refs)</ItemGroup></Project>"
                }
                return $root
            }
        }

        BeforeEach {
            # A pull request build runs everything, so the scope is switched off there; these tests need it on.
            $script:SavedPipeline = @{ GITHUB_ACTIONS = $env:GITHUB_ACTIONS; CI = $env:CI }
            $env:GITHUB_ACTIONS = $null
            $env:CI = $null
        }

        AfterEach {
            $env:GITHUB_ACTIONS = $script:SavedPipeline.GITHUB_ACTIONS
            $env:CI = $script:SavedPipeline.CI
        }

        It 'builds and tests nothing for a change that touches no .NET project, and says N/A' {
            $root = New-ScopedRepo

            $rows = Invoke-Preflight -Root $root -Extra @{ ScopeFiles = @('docs/page.md', 'infra/main.bicep') }

            (Get-Row -Rows $rows -Like 'Build*').Status | Should -Be 'N/A'
            (Get-Row -Rows $rows -Like 'Tests*').Status | Should -Be 'N/A'
            (Get-Row -Rows $rows -Like 'Coverage ratchet*').Status | Should -Be 'N/A'
            $global:DotnetTest.Calls | Should -BeNullOrEmpty
        }

        It 'builds the changed project with its test projects, runs only those tests, and leaves the ratchet to -Full' {
            $root = New-ScopedRepo

            $rows = Invoke-Preflight -Root $root -Extra @{ ScopeFiles = @('src/App/Page.cs') }

            $global:DotnetTest.Filters[0] | Should -Be @('build', 'src/App/App.csproj', 'tests/App.Tests/App.Tests.csproj')
            $global:DotnetTest.Filters[1] | Should -Be @('test', 'tests/App.Tests/App.Tests.csproj')
            @($global:DotnetTest.Calls | Where-Object { $_ -match '--collect' -or $_ -match '^dotnet-coverage' }) | Should -BeNullOrEmpty
            (Get-Row -Rows $rows -Like 'Tests (the change only)').Status | Should -Be 'PASS'
            (Get-Row -Rows $rows -Like 'Coverage ratchet (C04)').Status | Should -Be 'N/A'
        }

        It 'removes the temporary solution filters after the run' {
            $root = New-ScopedRepo
            $before = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Filter 'preflight-*.slnf').Count

            $null = Invoke-Preflight -Root $root -Extra @{ ScopeFiles = @('src/App/Page.cs') }

            @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Filter 'preflight-*.slnf').Count | Should -Be $before
        }

        It 'shows a FAIL row when a test that the change reaches fails' {
            $root = New-ScopedRepo
            $global:DotnetTest.TestExit = 1

            $rows = Invoke-Preflight -Root $root -Extra @{ ScopeFiles = @('src/Lib/Service.cs') }

            $global:DotnetTest.Filters[1] | Should -Be @('test', 'tests/App.Tests/App.Tests.csproj', 'tests/Lib.Tests/Lib.Tests.csproj')
            (Get-Row -Rows $rows -Like 'Tests (the change only)').Status | Should -Be 'FAIL'
        }

        It 'builds and tests the whole solution with coverage when the change touches a file every project reads' {
            $root = New-ScopedRepo

            $rows = Invoke-Preflight -Root $root -Extra @{ ScopeFiles = @('src/App/Page.cs', 'Directory.Packages.props') }

            $global:DotnetTest.Filters | Should -BeNullOrEmpty
            @($global:DotnetTest.Calls | Where-Object { $_ -match '^test .*App\.sln .*--collect' }) | Should -HaveCount 1
            (Get-Row -Rows $rows -Like 'Tests + coverage (C04)').Status | Should -Be 'PASS'
        }

        It 'runs everything with -Full, also when -ScopeFiles is given' {
            $root = New-ScopedRepo

            $rows = Invoke-Preflight -Root $root -Extra @{ ScopeFiles = @('src/App/Page.cs'); Full = $true }

            $global:DotnetTest.Filters | Should -BeNullOrEmpty
            (Get-Row -Rows $rows -Like 'Tests + coverage (C04)').Status | Should -Be 'PASS'
        }

        It 'runs everything in a GitHub Actions run, also when -ScopeFiles is given' {
            $root = New-ScopedRepo
            $env:GITHUB_ACTIONS = 'true'

            $rows = Invoke-Preflight -Root $root -Extra @{ ScopeFiles = @('src/App/Page.cs') }

            $global:DotnetTest.Filters | Should -BeNullOrEmpty
            (Get-Row -Rows $rows -Like 'Tests + coverage (C04)').Status | Should -Be 'PASS'
        }

        It 'runs everything when no -ScopeFiles is given' {
            $root = New-ScopedRepo

            $rows = Invoke-Preflight -Root $root

            $global:DotnetTest.Filters | Should -BeNullOrEmpty
            (Get-Row -Rows $rows -Like 'Tests + coverage (C04)').Status | Should -Be 'PASS'
        }
    }
}
