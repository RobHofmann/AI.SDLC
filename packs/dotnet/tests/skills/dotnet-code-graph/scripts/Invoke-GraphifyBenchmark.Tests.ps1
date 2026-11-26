#requires -Version 7.4

Describe 'Invoke-GraphifyBenchmark' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-GraphifyBenchmark.ps1'

        function Invoke-Benchmark {
            param([hashtable]$ScriptArgs)
            $out = & $script:ScriptUnderTest @ScriptArgs *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }

        function New-FakeGraphify {
            param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Emits)
            Set-Content -LiteralPath $Path -Encoding utf8 -Value "Write-Output @'
$Emits
'@"
        }

        function New-CaseFile {
            param(
                [Parameter(Mandatory)][string]$Path,
                [AllowEmptyCollection()][object[]]$Cases = @()
            )
            [ordered]@{
                description     = 'test set'
                graphifyVersion = '0.0.0'
                cases           = $Cases
            } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding utf8
        }

        function New-GraphFile {
            param(
                [Parameter(Mandatory)][string]$Path,
                [string[]]$SourceFiles = @('Demo/src/Thing.cs')
            )
            $nodes = @()
            foreach ($f in $SourceFiles) {
                $nodes += [pscustomobject]@{ id = $f; label = 'N'; source_file = $f }
            }
            [ordered]@{ nodes = $nodes; links = @() } | ConvertTo-Json -Depth 8 |
                Set-Content -LiteralPath $Path -Encoding utf8
        }
    }

    BeforeEach {
        $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ("gbench-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Dir | Out-Null
        $script:CaseFile = Join-Path $script:Dir 'cases.json'
        $script:GraphFile = Join-Path $script:Dir 'graph.json'
        $script:Fake = Join-Path $script:Dir 'fake-graphify.ps1'
    }

    AfterEach {
        if ($script:Dir -and (Test-Path -LiteralPath $script:Dir)) {
            Remove-Item -LiteralPath $script:Dir -Recurse -Force
        }
    }

    Context 'cli cases' {
        It 'passes when every expected symbol appears' {
            New-FakeGraphify -Path $script:Fake -Emits 'PaymentClient implements IPaymentClient'
            New-CaseFile -Path $script:CaseFile -Cases @(
                @{ id = 'c1'; type = 'cli'; question = 'q'; arguments = @('explain', 'X'); expectSymbols = @('PaymentClient'); forbidSymbols = @() }
            )

            $r = Invoke-Benchmark -ScriptArgs @{ CaseFile = $script:CaseFile; GraphifyCommand = $script:Fake }

            $r.Output | Should -Match '\[PASS\] c1'
            $r.Output | Should -Match 'Accuracy: 1 of 1'
            $r.ExitCode | Should -Be 0
        }

        It 'refuses a case that asks anything but a read-only query, before invoking the tool' {
            New-FakeGraphify -Path $script:Fake -Emits 'should never run'
            New-CaseFile -Path $script:CaseFile -Cases @(
                @{ id = 'bad'; type = 'cli'; question = 'q'; arguments = @('extract', '.', '--force'); expectSymbols = @(); forbidSymbols = @() }
            )

            $r = Invoke-Benchmark -ScriptArgs @{ CaseFile = $script:CaseFile; GraphifyCommand = $script:Fake }

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match "Refused case 'bad'"
            $r.Output | Should -Match 'affected, explain, path'
            $r.Output | Should -Not -Match 'should never run'
        }

        It 'fails and names the symbol that did not appear' {
            New-FakeGraphify -Path $script:Fake -Emits 'nothing useful here'
            New-CaseFile -Path $script:CaseFile -Cases @(
                @{ id = 'c1'; type = 'cli'; question = 'q'; arguments = @('explain', 'X'); expectSymbols = @('MissingType', 'AlsoMissing'); forbidSymbols = @() }
            )

            $r = Invoke-Benchmark -ScriptArgs @{ CaseFile = $script:CaseFile; GraphifyCommand = $script:Fake }

            $r.Output | Should -Match '\[FAIL\] c1'
            $r.Output | Should -Match '0/2 symbols'
            $r.Output | Should -Match 'missing: MissingType, AlsoMissing'
        }

        It 'reports a partial score when only some symbols appear' {
            New-FakeGraphify -Path $script:Fake -Emits 'FoundType is here'
            New-CaseFile -Path $script:CaseFile -Cases @(
                @{ id = 'c1'; type = 'cli'; question = 'q'; arguments = @('explain', 'X'); expectSymbols = @('FoundType', 'AbsentType'); forbidSymbols = @() }
            )

            $r = Invoke-Benchmark -ScriptArgs @{ CaseFile = $script:CaseFile; GraphifyCommand = $script:Fake }

            $r.Output | Should -Match '1/2 symbols'
            $r.Output | Should -Match 'missing: AbsentType'
        }

        It 'fails when a forbidden string appears' {
            New-FakeGraphify -Path $script:Fake -Emits 'GoodType found. No directed path found between A and B.'
            New-CaseFile -Path $script:CaseFile -Cases @(
                @{ id = 'c1'; type = 'cli'; question = 'q'; arguments = @('path', 'A', 'B'); expectSymbols = @('GoodType'); forbidSymbols = @('No directed path found') }
            )

            $r = Invoke-Benchmark -ScriptArgs @{ CaseFile = $script:CaseFile; GraphifyCommand = $script:Fake }

            $r.Output | Should -Match '\[FAIL\] c1'
            $r.Output | Should -Match 'must not appear, but did: No directed path found'
        }
    }

    Context 'absence cases' {
        It 'passes when the extension is absent from the graph' {
            New-GraphFile -Path $script:GraphFile -SourceFiles @('Demo/src/Thing.cs')
            New-CaseFile -Path $script:CaseFile -Cases @(
                @{ id = 'no-bicep'; type = 'absence'; question = 'q'; absentExtensions = @('.bicep') }
            )

            $r = Invoke-Benchmark -ScriptArgs @{ CaseFile = $script:CaseFile; GraphPath = $script:GraphFile }

            $r.Output | Should -Match '\[PASS\] no-bicep'
            $r.ExitCode | Should -Be 0
        }

        It 'fails when the graph gained coverage the docs call a blind spot' {
            New-GraphFile -Path $script:GraphFile -SourceFiles @('Demo/src/Thing.cs', 'Demo/platform-provisioning/main.bicep')
            New-CaseFile -Path $script:CaseFile -Cases @(
                @{ id = 'no-bicep'; type = 'absence'; question = 'q'; absentExtensions = @('.bicep') }
            )

            $r = Invoke-Benchmark -ScriptArgs @{ CaseFile = $script:CaseFile; GraphPath = $script:GraphFile }

            $r.Output | Should -Match '\[FAIL\] no-bicep'
            $r.Output | Should -Match '\.bicep \(1 node'
        }

        It 'refuses to score an absence case with no graph to read' {
            New-CaseFile -Path $script:CaseFile -Cases @(
                @{ id = 'no-bicep'; type = 'absence'; question = 'q'; absentExtensions = @('.bicep') }
            )

            $r = Invoke-Benchmark -ScriptArgs @{ CaseFile = $script:CaseFile; GraphPath = (Join-Path $script:Dir 'absent.json') }

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'No graph at'
        }
    }

    Context 'exit behaviour' {
        It 'stays advisory by default so a failure does not block' {
            New-FakeGraphify -Path $script:Fake -Emits 'nothing'
            New-CaseFile -Path $script:CaseFile -Cases @(
                @{ id = 'c1'; type = 'cli'; question = 'q'; arguments = @('explain', 'X'); expectSymbols = @('Absent'); forbidSymbols = @() }
            )

            $r = Invoke-Benchmark -ScriptArgs @{ CaseFile = $script:CaseFile; GraphifyCommand = $script:Fake }

            $r.Output | Should -Match 'Accuracy: 0 of 1'
            $r.ExitCode | Should -Be 0
        }

        It 'exits non-zero on a regression when asked to' {
            New-FakeGraphify -Path $script:Fake -Emits 'nothing'
            New-CaseFile -Path $script:CaseFile -Cases @(
                @{ id = 'c1'; type = 'cli'; question = 'q'; arguments = @('explain', 'X'); expectSymbols = @('Absent'); forbidSymbols = @() }
            )

            $r = Invoke-Benchmark -ScriptArgs @{ CaseFile = $script:CaseFile; GraphifyCommand = $script:Fake; FailOnRegression = $true }

            $r.ExitCode | Should -Be 1
        }

        It 'passes with FailOnRegression when every case passes' {
            New-FakeGraphify -Path $script:Fake -Emits 'PresentType'
            New-CaseFile -Path $script:CaseFile -Cases @(
                @{ id = 'c1'; type = 'cli'; question = 'q'; arguments = @('explain', 'X'); expectSymbols = @('PresentType'); forbidSymbols = @() }
            )

            $r = Invoke-Benchmark -ScriptArgs @{ CaseFile = $script:CaseFile; GraphifyCommand = $script:Fake; FailOnRegression = $true }

            $r.ExitCode | Should -Be 0
        }
    }

    Context 'bad input' {
        It 'fails when the question set is missing' {
            $r = Invoke-Benchmark -ScriptArgs @{ CaseFile = (Join-Path $script:Dir 'nope.json') }

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'No question set at'
        }

        It 'fails when the question set has no cases' {
            New-CaseFile -Path $script:CaseFile -Cases @()

            $r = Invoke-Benchmark -ScriptArgs @{ CaseFile = $script:CaseFile }

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'no cases'
        }
    }
}
