#requires -Version 7.4
Describe 'Check-ChangeCompleteness' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Check-ChangeCompleteness.ps1'
        $script:Root = Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Root 'aisdlc.json') -Encoding utf8 -Value (@{
                paths = @{
                    docsRoots        = @('docs', 'docs-functional')
                    adrFolder        = 'docs/adrs'
                    sourceRoot       = 'Demo/src'
                    testRoot         = 'Demo/tests'
                    sourceExtensions = @('.cs', '.razor')
                    sourceDocMap     = @(
                        @{ source = 'Demo/src/Portal.Demo/'; docs = @('docs/portal/', 'docs-functional/') }
                        @{ source = 'Demo/src/Api.Demo/'; docs = @('docs/api/', 'docs/architecture.md', 'docs-functional/') }
                        @{ source = 'Demo/src/Workers.'; docs = @('docs/handlers/') }
                        @{ source = 'Demo/src/Shared.'; docs = @('docs/libraries/') }
                    )
                }
            } | ConvertTo-Json -Depth 6)
        function Invoke-Gate {
            param([string[]]$Changed, [switch]$Strict)
            $p = @{ ChangedFiles = $Changed; RepoRoot = $script:Root }
            if ($Strict) { $p['Strict'] = $true }
            $out = & $script:ScriptUnderTest @p *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }
    }

    It 'says nothing when no behaviour changed' {
        $r = Invoke-Gate -Changed @('docs/portal/architecture.md', 'README.md')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'no behaviour change'
    }

    It 'passes when a service change brings a test and a doc' {
        $r = Invoke-Gate -Changed @(
            'Demo/src/Portal.Demo/Services/Thing.cs',
            'Demo/tests/Portal.Demo.Tests/Services/ThingTests.cs',
            'docs/portal/architecture.md')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'moved with the code'
    }

    It 'reports behaviour that moved without any test at all' {
        $r = Invoke-Gate -Changed @('Demo/src/Portal.Demo/Services/Thing.cs', 'docs/portal/architecture.md')
        $r.Output | Should -Match 'TESTS:'
    }

    It 'does not demand a test for every file, only that some test moved' {
        $r = Invoke-Gate -Changed @(
            'Demo/src/Portal.Demo/Services/One.cs',
            'Demo/src/Portal.Demo/Services/Two.cs',
            'Demo/src/Portal.Demo/Services/Three.cs',
            'Demo/tests/Portal.Demo.Tests/Services/OneTests.cs',
            'docs/portal/architecture.md')
        $r.Output | Should -Not -Match 'TESTS:'
    }

    It 'leaves application startup alone' {
        $r = Invoke-Gate -Changed @('Demo/src/Portal.Demo/Program.cs')
        $r.Output | Should -Match 'no behaviour change'
    }

    It 'leaves a model or contract alone' {
        $r = Invoke-Gate -Changed @(
            'Demo/src/Shared.Demo.Domain/Common/Models/Core/Thing.cs',
            'Demo/src/Portal.Demo/Common/Contracts/Services/IThing.cs')
        $r.Output | Should -Match 'no behaviour change'
    }

    It 'reports a portal change with no portal documentation' {
        $r = Invoke-Gate -Changed @(
            'Demo/src/Portal.Demo/Services/Thing.cs',
            'Demo/tests/Portal.Demo.Tests/Services/ThingTests.cs')
        $r.Output | Should -Match 'DOCS:'
        $r.Output | Should -Match 'docs/portal/'
    }

    It 'accepts an ADR as the documentation for any area' {
        $r = Invoke-Gate -Changed @(
            'Demo/src/Shared.StockLevel/Services/Thing.cs',
            'Demo/tests/Shared.StockLevel.Tests/Services/ThingTests.cs',
            'docs/adrs/0031-a-decision.md')
        $r.Output | Should -Not -Match 'DOCS:'
    }

    It 'maps a handler to the handler documentation' {
        $r = Invoke-Gate -Changed @(
            'Demo/src/Workers.OrderHandler/Thing.cs',
            'Demo/tests/Workers.OrderHandler.Tests/ThingTests.cs',
            'docs/portal/architecture.md')
        $r.Output | Should -Match 'docs/handlers/'
    }

    It 'is advisory by default and blocking only when asked' {
        $changed = @('Demo/src/Portal.Demo/Services/Thing.cs')
        (Invoke-Gate -Changed $changed).ExitCode | Should -Be 0
        (Invoke-Gate -Changed $changed -Strict).ExitCode | Should -Be 1
    }

    It 'counts a new file that is not committed yet, because wrap-up checks before it commits' {
        $repo = Join-Path $TestDrive 'git-repo'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:Root 'aisdlc.json') -Destination $repo
        $source = Join-Path $repo 'Demo/src/Portal.Demo/Services/Thing.cs'
        $test = Join-Path $repo 'Demo/tests/Portal.Demo.Tests/Services/ThingTests.cs'
        foreach ($file in @($source, $test)) {
            New-Item -ItemType Directory -Path (Split-Path $file) -Force | Out-Null
            Set-Content -LiteralPath $file -Value 'old'
        }
        & git -C $repo init --quiet
        & git -C $repo add .
        & git -C $repo -c user.name=Test -c user.email=test@example.com commit --quiet -m 'base'

        Set-Content -LiteralPath $source -Value 'new'
        Set-Content -LiteralPath $test -Value 'new'
        New-Item -ItemType Directory -Path (Join-Path $repo 'docs/portal') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'docs/portal/thing.md') -Value '# Thing'

        $out = & $script:ScriptUnderTest -RepoRoot $repo -BaseRef HEAD -Strict *>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'moved with the code'
    }

    It 'points at the skill that closes the gap' {
        $r = Invoke-Gate -Changed @('Demo/src/Portal.Demo/Services/Thing.cs')
        $r.Output | Should -Match 'wrap-up'
    }
}
