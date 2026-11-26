#requires -Version 7.4
BeforeAll { $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm' }

Describe 'Check-ChangeCompleteness' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $script:ScriptFolder -ChildPath 'Check-ChangeCompleteness.ps1'
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

    It 'is not applicable when no behaviour changed' -Tag '#46' {
        $r = Invoke-Gate -Changed @('docs/portal/architecture.md', 'README.md')
        $r.ExitCode | Should -Be 3
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

Describe 'Check-ChangeCompleteness waivers' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $script:ScriptFolder -ChildPath 'Check-ChangeCompleteness.ps1'
        $script:SourceFile = 'Demo/src/Portal.Demo/Services/Thing.cs'
        $script:TestFile = 'Demo/tests/Portal.Demo.Tests/Services/ThingTests.cs'
        $script:DocFile = 'docs/portal/thing.md'
        $script:SavedChangedFiles = $env:CHANGED_FILES
        $env:CHANGED_FILES = $null

        function New-WaiverRepo {
            $repo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $repo -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $repo 'aisdlc.json') -Encoding utf8 -Value (@{
                    paths = @{
                        docsRoots        = @('docs', 'docs-functional')
                        adrFolder        = 'docs/adrs'
                        sourceRoot       = 'Demo/src'
                        testRoot         = 'Demo/tests'
                        sourceExtensions = @('.cs')
                        sourceDocMap     = @(@{ source = 'Demo/src/Portal.Demo/'; docs = @('docs/portal/') })
                    }
                } | ConvertTo-Json -Depth 6)
            & git -C $repo init --quiet -b main
            & git -C $repo add .
            & git -C $repo -c user.name=Test -c user.email=test@example.com commit --quiet -m 'base'
            & git -C $repo tag base
            return $repo
        }

        function Add-WaiverCommit {
            param([string]$Repo, [hashtable]$File, [string]$Trailer, [string[]]$Remove = @())
            foreach ($name in $File.Keys) {
                $path = Join-Path $Repo $name
                New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
                [IO.File]::WriteAllText($path, [string]$File[$name], [Text.UTF8Encoding]::new($false))
            }
            foreach ($name in $Remove) { Remove-Item -LiteralPath (Join-Path $Repo $name) }
            $message = "change`n`nBody paragraph.`n"
            if ($Trailer) { $message += "`n$Trailer`n" }
            $messageFile = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.txt')
            [IO.File]::WriteAllText($messageFile, $message, [Text.UTF8Encoding]::new($false))
            & git -C $Repo add -A
            & git -C $Repo -c user.name=Test -c user.email=test@example.com commit --quiet --cleanup=verbatim -F $messageFile
        }

        function Get-ShortSha([string]$Repo) { return (& git -C $Repo rev-parse HEAD).Substring(0, 12) }

        function Invoke-WaiverGate {
            param([string]$Repo, [string[]]$Changed)
            $p = @{ RepoRoot = $Repo; BaseRef = 'base'; Strict = $true }
            if ($Changed) { $p['ChangedFiles'] = $Changed }
            $out = & $script:ScriptUnderTest @p *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }
    }

    AfterAll { $env:CHANGED_FILES = $script:SavedChangedFiles }

    It 'clears the TESTS finding for the files of a commit with a valid No-Test trailer, and prints the waiver' -Tag '#60' {
        $repo = New-WaiverRepo
        Add-WaiverCommit -Repo $repo -File @{ $script:DocFile = '# Thing' }
        Add-WaiverCommit -Repo $repo -File @{ $script:SourceFile = 'class Thing {}' } -Trailer 'No-Test: no-behaviour-change: a pure rename'
        $r = Invoke-WaiverGate -Repo $repo
        $r.ExitCode | Should -Be 0
        $sha = Get-ShortSha $repo
        $r.Output | Should -Match ([regex]::Escape("Waiver used: No-Test: no-behaviour-change: a pure rename (commit $sha) cleared: $script:SourceFile"))
    }

    It 'clears the DOCS finding with a valid No-Docs trailer' -Tag '#60' {
        $repo = New-WaiverRepo
        Add-WaiverCommit -Repo $repo -File @{ $script:SourceFile = 'class Thing {}'; $script:TestFile = 'class ThingTests {}' } -Trailer 'No-Docs: no-doc-reader-affected: internal helper'
        $r = Invoke-WaiverGate -Repo $repo
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Waiver used: No-Docs: no-doc-reader-affected: internal helper'
    }

    It 'reads the trailer key in any case' -Tag '#60' {
        $repo = New-WaiverRepo
        Add-WaiverCommit -Repo $repo -File @{ $script:DocFile = '# Thing' }
        Add-WaiverCommit -Repo $repo -File @{ $script:SourceFile = 'class Thing {}' } -Trailer 'no-test: existing-tests-cover-it: the old tests already assert it'
        (Invoke-WaiverGate -Repo $repo).ExitCode | Should -Be 0
    }

    It 'makes a file a finding again when a later commit changes it without a trailer' -Tag '#60' {
        $repo = New-WaiverRepo
        Add-WaiverCommit -Repo $repo -File @{ $script:DocFile = '# Thing' }
        Add-WaiverCommit -Repo $repo -File @{ $script:SourceFile = 'class Thing {}' } -Trailer 'No-Test: no-behaviour-change: rename'
        Add-WaiverCommit -Repo $repo -File @{ $script:SourceFile = 'class Thing { int x; }' }
        $r = Invoke-WaiverGate -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'TESTS:'
    }

    It 'does not waive a file that has only uncommitted changes, or an edit after the waived commit' -Tag '#60' {
        $repo = New-WaiverRepo
        Add-WaiverCommit -Repo $repo -File @{ $script:DocFile = '# Thing' }
        Add-WaiverCommit -Repo $repo -File @{ $script:SourceFile = 'class Thing {}' } -Trailer 'No-Test: no-behaviour-change: rename'
        Set-Content -LiteralPath (Join-Path $repo $script:SourceFile) -Value 'class Thing { int y; }'
        $r = Invoke-WaiverGate -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'TESTS:'
    }

    It 'does not let a pure rename with a trailer waive a file whose earlier commit has none' -Tag '#60' {
        $repo = New-WaiverRepo
        Add-WaiverCommit -Repo $repo -File @{ $script:DocFile = '# Thing' }
        Add-WaiverCommit -Repo $repo -File @{ $script:SourceFile = "class Thing {`n    int a;`n    int b;`n}`n" }
        Add-WaiverCommit -Repo $repo -File @{ 'Demo/src/Portal.Demo/Services/Other.cs' = "class Thing {`n    int a;`n    int b;`n}`n" } -Remove @($script:SourceFile) -Trailer 'No-Test: no-behaviour-change: rename'
        $r = Invoke-WaiverGate -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'TESTS:'
    }

    It 'clears nothing for a trailer that is not valid, and says why' -Tag '#60' -ForEach @(
        @{ Name = 'unknown reason'; Trailer = 'No-Test: because-i-say-so: whatever'; Cause = 'the reason is not one of' }
        @{ Name = 'reason in capitals'; Trailer = 'No-Test: No-Behaviour-Change: whatever'; Cause = 'the reason is not one of' }
        @{ Name = 'reason of the other trailer'; Trailer = 'No-Test: no-doc-reader-affected: whatever'; Cause = 'for No-Docs only' }
        @{ Name = 'existing-tests-cover-it on No-Docs'; Trailer = 'No-Docs: existing-tests-cover-it: whatever'; Cause = 'for No-Test only' }
        @{ Name = 'empty why'; Trailer = 'No-Test: no-behaviour-change:'; Cause = 'gives no why' }
        @{ Name = 'no why at all'; Trailer = 'No-Test: no-behaviour-change'; Cause = 'gives no why' }
        @{ Name = 'control character'; Trailer = "No-Test: no-behaviour-change: bad$([char]1)text"; Cause = 'control character' }
        @{ Name = 'unicode line separator'; Trailer = "No-Test: no-behaviour-change: bad$([char]0x2028)text"; Cause = 'control character' }
    ) {
        $repo = New-WaiverRepo
        Add-WaiverCommit -Repo $repo -File @{ $script:DocFile = '# Thing' }
        Add-WaiverCommit -Repo $repo -File @{ $script:SourceFile = 'class Thing {}' } -Trailer $Trailer
        $r = Invoke-WaiverGate -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'TESTS:'
        $r.Output | Should -Match 'Waiver not used: '
        $r.Output | Should -Match ([regex]::Escape($Cause))
    }

    It 'says a valid waiver was not needed when it clears nothing' -Tag '#60' {
        $repo = New-WaiverRepo
        Add-WaiverCommit -Repo $repo -File @{ $script:DocFile = '# Thing'; $script:TestFile = 'class ThingTests {}' }
        Add-WaiverCommit -Repo $repo -File @{ $script:SourceFile = 'class Thing {}' } -Trailer 'No-Test: no-behaviour-change: rename'
        $r = Invoke-WaiverGate -Repo $repo
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Waiver not needed: No-Test: no-behaviour-change: rename'
    }

    It 'applies no waiver when the caller passes the changed files, because there is no base to read commits from' -Tag '#60' {
        $repo = New-WaiverRepo
        Add-WaiverCommit -Repo $repo -File @{ $script:DocFile = '# Thing' }
        Add-WaiverCommit -Repo $repo -File @{ $script:SourceFile = 'class Thing {}' } -Trailer 'No-Test: no-behaviour-change: rename'
        $r = Invoke-WaiverGate -Repo $repo -Changed @($script:SourceFile, $script:DocFile)
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'TESTS:'
        $r.Output | Should -Not -Match 'Waiver used'
    }

    It 'still exits 3 when nothing carries behaviour' -Tag '#60' {
        $repo = New-WaiverRepo
        Add-WaiverCommit -Repo $repo -File @{ $script:DocFile = '# Thing' } -Trailer 'No-Test: no-behaviour-change: docs only'
        (Invoke-WaiverGate -Repo $repo).ExitCode | Should -Be 3
    }
}
