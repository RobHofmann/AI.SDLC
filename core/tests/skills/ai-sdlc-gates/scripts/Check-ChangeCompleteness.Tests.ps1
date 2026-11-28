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

    It 'accepts an ADR as the documentation only for the area it names' -Tag '#104' {
        $adrFolder = Join-Path $script:Root 'docs/adrs'
        New-Item -ItemType Directory -Path $adrFolder -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $adrFolder '0031-a-decision.md') -Value "---`nrelates:`n  code: Demo/src/Shared.StockLevel/`n---`n# A decision`n"
        $r = Invoke-Gate -Changed @(
            'Demo/src/Shared.StockLevel/Services/Thing.cs',
            'Demo/tests/Shared.StockLevel.Tests/Services/ThingTests.cs',
            'Demo/src/Portal.Demo/Services/Thing.cs',
            'Demo/tests/Portal.Demo.Tests/Services/ThingTests.cs',
            'docs/adrs/0031-a-decision.md')
        $r.Output | Should -Not -Match 'DOCS: \d+ changed file\(s\) under Demo/src/Shared\.'
        $r.Output | Should -Match 'DOCS: \d+ changed file\(s\) under Demo/src/Portal\.Demo/'
    }

    It 'lets an ADR clear an area when it names a parent folder or a doc path of the area' -Tag '#104' {
        $adrFolder = Join-Path $script:Root 'docs/adrs'
        New-Item -ItemType Directory -Path $adrFolder -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $adrFolder '0032-portal.md') -Value "# Portal`n`nThe rule lives in docs/portal/ and touches Demo/src."
        $r = Invoke-Gate -Changed @(
            'Demo/src/Portal.Demo/Services/Thing.cs',
            'Demo/tests/Portal.Demo.Tests/Services/ThingTests.cs',
            'docs/adrs/0032-portal.md')
        $r.Output | Should -Not -Match 'DOCS:'
    }

    It 'does not count an ADR that the change lists but that is not on disk' -Tag '#104' {
        $r = Invoke-Gate -Changed @(
            'Demo/src/Portal.Demo/Services/Thing.cs',
            'Demo/tests/Portal.Demo.Tests/Services/ThingTests.cs',
            'docs/adrs/0099-gone.md')
        $r.Output | Should -Match 'DOCS:'
    }

    It 'counts a test only in the test project that mirrors the changed project' -Tag '#104' {
        $r = Invoke-Gate -Changed @(
            'Demo/src/Portal.Demo/Services/Thing.cs',
            'Demo/tests/Api.Demo.Tests/Services/ThingTests.cs',
            'docs/portal/architecture.md')
        $r.Output | Should -Match ([regex]::Escape('TESTS: 1 source file(s) carry behaviour and no test file changed under Demo/tests/Portal.Demo.Tests/'))
    }

    It 'accepts a test project with one word before Tests' -Tag '#104' {
        $r = Invoke-Gate -Changed @(
            'Demo/src/Portal.Demo/Services/Thing.cs',
            'Demo/tests/Portal.Demo.IntegrationTests/Services/ThingTests.cs',
            'docs/portal/architecture.md')
        $r.Output | Should -Not -Match 'TESTS:'
    }

    It 'asks for a test in each changed project, not in one of them' -Tag '#104' {
        $r = Invoke-Gate -Changed @(
            'Demo/src/Portal.Demo/Services/Thing.cs',
            'Demo/src/Api.Demo/Services/Thing.cs',
            'Demo/tests/Portal.Demo.Tests/Services/ThingTests.cs',
            'docs/portal/architecture.md',
            'docs/api/thing.md')
        $r.Output | Should -Match 'under Demo/tests/Api\.Demo\.Tests/'
        $r.Output | Should -Not -Match 'under Demo/tests/Portal\.Demo\.Tests/'
    }

    It 'does not count a project file in the test folder as a test' -Tag '#104' {
        $r = Invoke-Gate -Changed @(
            'Demo/src/Portal.Demo/Services/Thing.cs',
            'Demo/tests/Portal.Demo.Tests/Portal.Demo.Tests.csproj',
            'docs/portal/architecture.md')
        $r.Output | Should -Match 'TESTS:'
    }

    It 'needs no test for a deleted file, but still needs its docs' -Tag '#104' {
        . $script:ScriptUnderTest -RepoRoot $script:Root -ChangedFiles @('x')
        $gone = 'Demo/src/Portal.Demo/Services/Gone.cs'
        $result = Invoke-ChangeCompletenessCheck -Changed @($gone) -Deleted @($gone)
        $result.NoOp | Should -BeFalse
        @($result.Findings | Where-Object Kind -EQ 'TESTS').Count | Should -Be 0
        @($result.Findings | Where-Object Kind -EQ 'DOCS').Count | Should -Be 1
    }

    It 'does not count a deleted test file as a test change' -Tag '#104' {
        . $script:ScriptUnderTest -RepoRoot $script:Root -ChangedFiles @('x')
        $oldTest = 'Demo/tests/Portal.Demo.Tests/Services/OldTests.cs'
        $result = Invoke-ChangeCompletenessCheck -Changed @('Demo/src/Portal.Demo/Services/Thing.cs', $oldTest, 'docs/portal/architecture.md') -Deleted @($oldTest)
        @($result.Findings | Where-Object Kind -EQ 'TESTS').Count | Should -Be 1
    }

    It 'does not take a folder named Tests in the source for a test folder' -Tag '#104' {
        $repo = Join-Path $TestDrive 'case-repo'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'aisdlc.json') -Encoding utf8 -Value (@{
                paths = @{ sourceRoots = @('core'); sourceExtensions = @('.ps1') }
            } | ConvertTo-Json -Depth 6)
        & $script:ScriptUnderTest -RepoRoot $repo -Strict -ChangedFiles @('core/Tests/Helper.ps1') *>&1 | Out-Null
        $LASTEXITCODE | Should -Be 1
    }

    It 'reads paths.sourceRoots as well as paths.sourceRoot' -Tag '#104' {
        $repo = Join-Path $TestDrive 'roots-repo'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'aisdlc.json') -Encoding utf8 -Value (@{
                paths = @{ sourceRoots = @('core', 'packs'); sourceExtensions = @('.ps1') }
            } | ConvertTo-Json -Depth 6)
        $out = & $script:ScriptUnderTest -RepoRoot $repo -ChangedFiles @('packs/demo/.apm/skills/x/scripts/Do-It.ps1') -Strict *>&1 | Out-String
        $LASTEXITCODE | Should -Be 1
        $out | Should -Match ([regex]::Escape('under packs/demo/tests/skills/x/scripts/'))
    }

    It 'maps a package script to its test under the package tests folder (ADR 0015)' -Tag '#104' {
        $repo = Join-Path $TestDrive 'package-repo'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'aisdlc.json') -Encoding utf8 -Value (@{
                paths = @{ sourceRoots = @('core', 'packs'); sourceExtensions = @('.ps1') }
            } | ConvertTo-Json -Depth 6)
        $out = & $script:ScriptUnderTest -RepoRoot $repo -Strict -ChangedFiles @(
            'core/.apm/skills/x/scripts/Do-It.ps1',
            'core/tests/skills/x/scripts/Do-It.Tests.ps1') *>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $out | Should -Not -Match 'TESTS:'
    }

    It 'never counts a file under a tests folder as behaviour' -Tag '#104' {
        $repo = Join-Path $TestDrive 'tests-only-repo'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'aisdlc.json') -Encoding utf8 -Value (@{
                paths = @{ sourceRoots = @('core'); sourceExtensions = @('.ps1') }
            } | ConvertTo-Json -Depth 6)
        & $script:ScriptUnderTest -RepoRoot $repo -Strict -ChangedFiles @('core/tests/skills/x/scripts/Do-It.Tests.ps1') *>&1 | Out-Null
        $LASTEXITCODE | Should -Be 3
    }

    It 'cannot check when CHANGED_FILES is set and HEAD cannot be read' -Tag '#104' {
        $saved = $env:CHANGED_FILES
        try {
            $repo = Join-Path $TestDrive 'no-head-repo'
            New-Item -ItemType Directory -Path $repo -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $script:Root 'aisdlc.json') -Destination $repo
            & git -C $repo init --quiet
            $env:CHANGED_FILES = 'Demo/src/Portal.Demo/Services/Thing.cs'
            $out = & $script:ScriptUnderTest -RepoRoot $repo -Strict *>&1 | Out-String
            $LASTEXITCODE | Should -Be 2
            $out | Should -Match 'Could not check'
        }
        finally { $env:CHANGED_FILES = $saved }
    }

    It 'cannot check when there is no merge base with the base ref' -Tag '#104' {
        $saved = $env:CHANGED_FILES
        try {
            $env:CHANGED_FILES = $null
            $repo = Join-Path $TestDrive 'no-base-repo'
            New-Item -ItemType Directory -Path $repo -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $script:Root 'aisdlc.json') -Destination $repo
            & git -C $repo init --quiet
            & git -C $repo add .
            & git -C $repo -c user.name=Test -c user.email=test@example.com commit --quiet -m 'base'
            & $script:ScriptUnderTest -RepoRoot $repo -BaseRef 'origin/does-not-exist' -Strict *>&1 | Out-Null
            $LASTEXITCODE | Should -Be 2
        }
        finally { $env:CHANGED_FILES = $saved }
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

    It 'keeps the TESTS finding of one project open when a waiver clears only the other project' -Tag '#104' {
        $repo = New-WaiverRepo
        $apiSource = 'Demo/src/Api.Demo/Services/Thing.cs'
        Add-WaiverCommit -Repo $repo -File @{ $script:DocFile = '# Thing' }
        Add-WaiverCommit -Repo $repo -File @{ $script:SourceFile = 'class Thing {}' } -Trailer 'No-Test: no-behaviour-change: a pure rename'
        Add-WaiverCommit -Repo $repo -File @{ $apiSource = 'class Thing { int x; }' }
        $r = Invoke-WaiverGate -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Waiver used: No-Test'
        $r.Output | Should -Match 'TESTS: 1 source file\(s\) carry behaviour and no test file changed under Demo/tests/Api\.Demo\.Tests/'
        $r.Output | Should -Not -Match 'Change completeness: TESTS: [^\r\n]*Portal\.Demo\.Tests'
    }

    It 'lets a No-Docs waiver clear the DOCS finding of a deleted file' -Tag '#104' {
        $repo = New-WaiverRepo
        Add-WaiverCommit -Repo $repo -File @{ $script:SourceFile = 'class Thing {}'; $script:TestFile = 'class ThingTests {}'; $script:DocFile = '# Thing' }
        & git -C $repo tag -f base 2>&1 | Out-Null
        Add-WaiverCommit -Repo $repo -File @{} -Remove @($script:SourceFile) -Trailer 'No-Docs: no-doc-reader-affected: the page never named this helper'
        $r = Invoke-WaiverGate -Repo $repo
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Waiver used: No-Docs'
    }

    It 'still exits 3 when nothing carries behaviour' -Tag '#60' {
        $repo = New-WaiverRepo
        Add-WaiverCommit -Repo $repo -File @{ $script:DocFile = '# Thing' } -Trailer 'No-Test: no-behaviour-change: docs only'
        (Invoke-WaiverGate -Repo $repo).ExitCode | Should -Be 3
    }
}
