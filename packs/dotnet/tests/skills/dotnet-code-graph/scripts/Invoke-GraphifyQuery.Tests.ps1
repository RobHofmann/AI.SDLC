#requires -Version 7.4
Describe 'Invoke-GraphifyQuery' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-GraphifyQuery.ps1'

        $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
        if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
        Import-Module (Join-Path $aiSdlcGates 'DocToolTestHarness.psm1') -Force

        $script:FakeGraphify = Join-Path $TestDrive 'fake-graphify.ps1'
        Set-Content -LiteralPath $script:FakeGraphify -Encoding utf8 -Value @'
param([Parameter(ValueFromRemainingArguments)][string[]]$Args)
Write-Output ("QUERIED: " + ($Args -join ' '))
exit 0
'@

        function New-GraphRepo {
            param([switch]$Stale)

            $root = New-DocToolRepo -Prefix 'igq' -InitialiseGit -Files @{
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

        function Invoke-Query {
            param([hashtable]$ScriptArgs)
            if (-not $ScriptArgs.ContainsKey('GraphifyCommand')) { $ScriptArgs['GraphifyCommand'] = $script:FakeGraphify }
            $out = & $script:ScriptUnderTest @ScriptArgs *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }
    }

    AfterAll {
        Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'igq-*' -Directory -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Module DocToolTestHarness -Force -ErrorAction SilentlyContinue
    }

    Context 'what it will and will not ask' {
        It 'passes <Subcommand> through, since it only reads the graph' -ForEach @(
            @{ Subcommand = 'affected' }
            @{ Subcommand = 'explain' }
            @{ Subcommand = 'path' }
        ) {
            # Arrange
            $root = New-GraphRepo

            # Act
            $r = Invoke-Query -ScriptArgs @{ Subcommand = $Subcommand; Argument = @('A'); RepoRoot = $root }

            # Assert
            $r.Output | Should -Match "QUERIED: $Subcommand A"
        }

        It 'refuses <Subcommand>, which is not a read-only query' -ForEach @(
            @{ Subcommand = 'extract' }
            @{ Subcommand = 'cluster-only' }
            @{ Subcommand = 'update' }
            @{ Subcommand = 'add' }
        ) {
            # Arrange
            $root = New-GraphRepo

            # Act
            $r = Invoke-Query -ScriptArgs @{ Subcommand = $Subcommand; Argument = @('.'); RepoRoot = $root }

            # Assert
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'Refused'
            $r.Output | Should -Not -Match 'QUERIED'
        }

        It 'refuses a flag it does not recognise rather than forwarding it' {
            # Arrange
            $root = New-GraphRepo

            # Act
            $r = Invoke-Query -ScriptArgs @{ Subcommand = 'explain'; Argument = @('A', '--backend=openai'); RepoRoot = $root }

            # Assert
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'Refused'
            $r.Output | Should -Not -Match 'QUERIED'
        }

        It 'allows the query flags graphify documents' {
            # Arrange
            $root = New-GraphRepo

            # Act
            $r = Invoke-Query -ScriptArgs @{ Subcommand = 'affected'; Argument = @('A', '--depth', '2', '--relation', 'calls'); RepoRoot = $root }

            # Assert
            $r.Output | Should -Match 'QUERIED: affected A --depth 2 --relation calls'
        }
    }

    Context 'the freshness it exists to report' {
        It 'warns before it answers when the graph is behind the working tree' {
            # Arrange
            $root = New-GraphRepo -Stale

            # Act
            $r = Invoke-Query -ScriptArgs @{ Subcommand = 'explain'; Argument = @('A'); RepoRoot = $root }

            # Assert
            $r.Output | Should -Match 'STALE GRAPH'
            $r.Output | Should -Match 'QUERIED: explain A'
        }

        It 'says nothing about freshness when the graph is current' {
            # Arrange
            $root = New-GraphRepo

            # Act
            $r = Invoke-Query -ScriptArgs @{ Subcommand = 'explain'; Argument = @('A'); RepoRoot = $root }

            # Assert
            $r.Output | Should -Not -Match 'STALE GRAPH'
        }

        It 'refuses outright when asked to, for a caller that wants the answer or nothing' {
            # Arrange
            $root = New-GraphRepo -Stale

            # Act
            $r = Invoke-Query -ScriptArgs @{ Subcommand = 'explain'; Argument = @('A'); RepoRoot = $root; FailOnStaleGraph = $true }

            # Assert
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Not -Match 'QUERIED'
        }

        It 'checks the graph the caller named, not the default one' {
            # Arrange
            $root = New-GraphRepo -Stale
            $elsewhere = Join-Path $root 'graphify-out/other.json'
            [ordered]@{
                nodes = @([pscustomobject]@{ id = 'a'; label = 'A'; source_file = 'Demo/src/Shared.Thing/A.cs' })
                links = @()
            } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $elsewhere -Encoding utf8

            # Act
            $r = Invoke-Query -ScriptArgs @{ Subcommand = 'explain'; Argument = @('A', '--graph', $elsewhere); RepoRoot = $root }

            # Assert
            $r.Output | Should -Not -Match 'STALE GRAPH'
            $r.Output | Should -Match 'QUERIED: explain A --graph'
        }

        It 'says so when there is no graph, rather than letting graphify report an empty codebase' {
            # Arrange
            $root = New-DocToolRepo -Prefix 'igq' -InitialiseGit -Files @{ 'Demo/src/Shared.Thing/A.cs' = 'public class A { }' }

            # Act
            $r = Invoke-Query -ScriptArgs @{ Subcommand = 'explain'; Argument = @('A'); RepoRoot = $root }

            # Assert
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'No graph at'
        }
    }
}
