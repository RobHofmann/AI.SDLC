#requires -Version 7.4

Describe 'Invoke-GraphifyIndex' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-GraphifyIndex.ps1'

        function Invoke-Script {
            param([hashtable]$ScriptArgs)
            $out = & $script:ScriptUnderTest @ScriptArgs *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }

        function New-GraphFixture {
            param(
                [Parameter(Mandatory)][string]$Path,
                [string]$BuiltAtCommit = 'abc123',
                [int]$CsFiles = 2,
                [int]$DispatchesTo = 1,
                [switch]$OmitCommit
            )

            $nodes = @()
            for ($i = 1; $i -le $CsFiles; $i++) {
                $nodes += [pscustomobject]@{
                    id          = "cs$i"
                    label       = "Type$i"
                    source_file = "Demo/src/Thing$i.cs"
                }
            }
            $nodes += [pscustomobject]@{ id = 'razor1'; label = 'Page'; source_file = 'Demo/src/Page.razor' }
            $nodes += [pscustomobject]@{ id = 'blank'; label = 'Community'; source_file = '' }

            $links = @(
                [pscustomobject]@{ source = 'cs1'; target = 'cs2'; relation = 'implements'; confidence = 'EXTRACTED' }
                [pscustomobject]@{ source = 'cs1'; target = 'razor1'; relation = 'references'; confidence = 'INFERRED' }
            )
            for ($i = 1; $i -le $DispatchesTo; $i++) {
                $links += [pscustomobject]@{ source = 'cs1'; target = 'cs2'; relation = 'dispatches_to'; confidence = 'INFERRED' }
            }

            $graph = [ordered]@{
                directed = $true
                nodes    = $nodes
                links    = $links
            }
            if (-not $OmitCommit) { $graph['built_at_commit'] = $BuiltAtCommit }

            $graph | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding utf8
        }
    }

    BeforeEach {
        $script:Fixture = Join-Path ([System.IO.Path]::GetTempPath()) ("graphify-{0}.json" -f [guid]::NewGuid())
    }

    AfterEach {
        if ($script:Fixture -and (Test-Path -LiteralPath $script:Fixture)) {
            Remove-Item -LiteralPath $script:Fixture -Force
        }
    }

    Context 'refusing arguments that would reach a model backend' {
        It 'refuses <Argument> and does not build' -ForEach @(
            @{ Argument = '--backend' }
            @{ Argument = '--model' }
            @{ Argument = '--mode' }
            @{ Argument = '--dedup-llm' }
            @{ Argument = '--postgres' }
            @{ Argument = '--google-workspace' }
        ) {
            $scriptArgs = @{ ExtraArguments = @($Argument); GraphifyCommand = 'graphify-should-not-run' }

            $result = Invoke-Script -ScriptArgs $scriptArgs

            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'Refused'
            $result.Output | Should -Match 'code-only'
        }

        It 'says how to install graphify when the command is not on PATH, instead of a raw PowerShell error' {
            $scriptArgs = @{ GraphifyCommand = 'graphify-not-installed-anywhere'; GraphPath = $script:Fixture }

            $result = Invoke-Script -ScriptArgs $scriptArgs

            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'is not on PATH'
            $result.Output | Should -Match 'uv tool install graphifyy=='
        }

        It 'leaves an existing graph alone when the command is missing, rather than purging then failing' {
            $outDir = Join-Path ([System.IO.Path]::GetTempPath()) ("graphify-out-{0}" -f [guid]::NewGuid())
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null
            $graphPath = Join-Path $outDir 'graph.json'
            New-GraphFixture -Path $graphPath
            $realOut = Join-Path (Split-Path $outDir -Parent) 'graphify-out'

            try {
                Move-Item -LiteralPath $outDir -Destination $realOut -Force
                $result = Invoke-Script -ScriptArgs @{
                    GraphifyCommand = 'graphify-not-installed-anywhere'
                    GraphPath       = (Join-Path $realOut 'graph.json')
                }

                $result.ExitCode | Should -Be 1
                Test-Path -LiteralPath (Join-Path $realOut 'graph.json') | Should -BeTrue
                $result.Output | Should -Match 'left alone'
            }
            finally {
                if (Test-Path -LiteralPath $realOut) { Remove-Item -LiteralPath $realOut -Recurse -Force }
            }
        }

        It 'allows an argument on the pass-through list' {
            New-GraphFixture -Path $script:Fixture
            $scriptArgs = @{ ReportOnly = $true; GraphPath = $script:Fixture; HeadCommit = 'abc123'; ExtraArguments = @('--no-viz') }

            $result = Invoke-Script -ScriptArgs $scriptArgs

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Not -Match 'Refused'
        }

        It 'refuses <Argument>, which a denylist of backend flag names would have let through' -ForEach @(
            @{ Argument = '--config' }
            @{ Argument = '--backend=openai' }
            @{ Argument = '-m' }
            @{ Argument = '--some-flag-a-later-release-adds' }
        ) {
            $scriptArgs = @{ ExtraArguments = @($Argument); GraphifyCommand = 'graphify-should-not-run' }

            $result = Invoke-Script -ScriptArgs $scriptArgs

            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'Refused'
        }
    }

    Context 'reporting coverage' {
        It 'counts nodes, edges and extracted edges' {
            New-GraphFixture -Path $script:Fixture -CsFiles 3 -DispatchesTo 2

            $result = Invoke-Script -ScriptArgs @{ ReportOnly = $true; GraphPath = $script:Fixture; HeadCommit = 'abc123' }

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '5 nodes'
            $result.Output | Should -Match '4 edges'
            $result.Output | Should -Match '1 of them EXTRACTED'
        }

        It 'counts distinct files per extension, not nodes' {
            New-GraphFixture -Path $script:Fixture -CsFiles 3

            $result = Invoke-Script -ScriptArgs @{ ReportOnly = $true; GraphPath = $script:Fixture; HeadCommit = 'abc123' }

            $result.Output | Should -Match '\.cs\s+3'
            $result.Output | Should -Match '\.razor\s+1'
        }

        It 'reports the resolved interface dispatch count' {
            New-GraphFixture -Path $script:Fixture -DispatchesTo 7

            $result = Invoke-Script -ScriptArgs @{ ReportOnly = $true; GraphPath = $script:Fixture; HeadCommit = 'abc123' }

            $result.Output | Should -Match 'Interface dispatch: 7 resolved call edges'
        }

        It 'ignores nodes that carry no source file' {
            New-GraphFixture -Path $script:Fixture -CsFiles 1

            $result = Invoke-Script -ScriptArgs @{ ReportOnly = $true; GraphPath = $script:Fixture; HeadCommit = 'abc123' }

            $result.Output | Should -Not -Match '\(none\)'
        }
    }

    Context 'staleness against HEAD' {
        It 'reports fresh when the graph was built at HEAD' {
            New-GraphFixture -Path $script:Fixture -BuiltAtCommit 'deadbeef'

            $result = Invoke-Script -ScriptArgs @{ ReportOnly = $true; GraphPath = $script:Fixture; HeadCommit = 'deadbeef' }

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'Fresh: the graph was built at HEAD'
            $result.Output | Should -Not -Match 'STALE'
        }

        It 'reports stale when HEAD has moved on' {
            New-GraphFixture -Path $script:Fixture -BuiltAtCommit 'oldcommit'

            $result = Invoke-Script -ScriptArgs @{ ReportOnly = $true; GraphPath = $script:Fixture; HeadCommit = 'newcommit' }

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'STALE'
            $result.Output | Should -Match 'oldcommit'
            $result.Output | Should -Match 'newcommit'
        }

        It 'says so when the graph records no build commit' {
            New-GraphFixture -Path $script:Fixture -OmitCommit

            $result = Invoke-Script -ScriptArgs @{ ReportOnly = $true; GraphPath = $script:Fixture; HeadCommit = 'abc123' }

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'records no build commit'
        }
    }

    Context 'build mode' {
        BeforeEach {
            $script:ArgLog = Join-Path ([System.IO.Path]::GetTempPath()) ("gargs-{0}.txt" -f [guid]::NewGuid())
            $script:FakeGraphify = Join-Path ([System.IO.Path]::GetTempPath()) ("fakegraphify-{0}.ps1" -f [guid]::NewGuid())
            Set-Content -LiteralPath $script:FakeGraphify -Encoding utf8 -Value @"
`$args -join ' ' | Set-Content -LiteralPath '$($script:ArgLog)' -Encoding utf8
exit 0
"@
        }

        AfterEach {
            foreach ($p in @($script:ArgLog, $script:FakeGraphify)) {
                if ($p -and (Test-Path -LiteralPath $p)) { Remove-Item -LiteralPath $p -Force }
            }
        }

        It 'always builds code-only, even when a graph already exists' {
            New-GraphFixture -Path $script:Fixture

            $null = Invoke-Script -ScriptArgs @{ GraphPath = $script:Fixture; GraphifyCommand = $script:FakeGraphify }

            $logged = Get-Content -LiteralPath $script:ArgLog -Raw
            $logged | Should -Match '^extract '
            $logged | Should -Match '--code-only'
        }

        It 'never calls the incremental update command, which cannot be held to code-only' {
            New-GraphFixture -Path $script:Fixture

            $null = Invoke-Script -ScriptArgs @{ GraphPath = $script:Fixture; GraphifyCommand = $script:FakeGraphify }

            (Get-Content -LiteralPath $script:ArgLog -Raw) | Should -Not -Match '^update '
        }

        It 'purges a graphify-out directory first, so cached out-of-corpus nodes cannot survive' {
            $outDir = Join-Path ([System.IO.Path]::GetTempPath()) ("gout-{0}" -f [guid]::NewGuid()) |
                ForEach-Object { Join-Path $_ 'graphify-out' }
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null
            $stale = Join-Path $outDir 'cache'
            New-Item -ItemType Directory -Path $stale -Force | Out-Null
            New-GraphFixture -Path (Join-Path $outDir 'graph.json')

            $null = Invoke-Script -ScriptArgs @{ GraphPath = (Join-Path $outDir 'graph.json'); GraphifyCommand = $script:FakeGraphify }

            Test-Path -LiteralPath $stale | Should -BeFalse

            Remove-Item -LiteralPath (Split-Path -Parent $outDir) -Recurse -Force -ErrorAction SilentlyContinue
        }

        It 'never deletes a directory that is not named graphify-out' {
            New-GraphFixture -Path $script:Fixture
            $sibling = Join-Path (Split-Path -Parent $script:Fixture) ("keep-{0}.txt" -f [guid]::NewGuid())
            Set-Content -LiteralPath $sibling -Value 'keep me' -Encoding utf8

            $null = Invoke-Script -ScriptArgs @{ GraphPath = $script:Fixture; GraphifyCommand = $script:FakeGraphify }

            Test-Path -LiteralPath $sibling | Should -BeTrue

            Remove-Item -LiteralPath $sibling -Force -ErrorAction SilentlyContinue
        }

        It 'prints nothing when quiet, so a commit hook stays silent' {
            New-GraphFixture -Path $script:Fixture

            $result = Invoke-Script -ScriptArgs @{ Quiet = $true; GraphPath = $script:Fixture; GraphifyCommand = $script:FakeGraphify }

            $result.ExitCode | Should -Be 0
            $result.Output.Trim() | Should -BeNullOrEmpty
        }
    }

    Context 'confidence reporting' {
        It 'names the inferred edges rather than inviting the reader to discard them' {
            New-GraphFixture -Path $script:Fixture -DispatchesTo 3

            $result = Invoke-Script -ScriptArgs @{ ReportOnly = $true; GraphPath = $script:Fixture; HeadCommit = 'abc123' }

            $result.Output | Should -Match 'NOT model output'
            $result.Output | Should -Match 'dispatches_to'
        }
    }

    Context 'when there is no graph' {
        It 'fails ReportOnly with a build instruction' {
            $missing = Join-Path ([System.IO.Path]::GetTempPath()) ("absent-{0}.json" -f [guid]::NewGuid())

            $result = Invoke-Script -ScriptArgs @{ ReportOnly = $true; GraphPath = $missing; HeadCommit = 'abc123' }

            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'No graph at'
        }
    }
}
