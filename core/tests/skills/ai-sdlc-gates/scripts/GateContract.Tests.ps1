#requires -Version 7.4

Describe 'Every gate keeps the exit-code contract' {
    BeforeDiscovery {
        Import-Module (Join-Path $PSScriptRoot 'GateContractTestHarness.psm1') -Force
        $sourceRoot = Find-ContractSourceRoot -From $PSScriptRoot
        $gates = if ($sourceRoot) { @(Get-ContractGate -SourceRoot $sourceRoot | ForEach-Object { @{ Id = $_.Id; Leaf = $_.Leaf; Source = $_.Source } }) } else { @() }
        $skip = -not $sourceRoot
    }

    BeforeAll {
        $script:FixtureModule = Join-Path $PSScriptRoot 'GateContractTestHarness.psm1'
        Import-Module $script:FixtureModule -Force
        $script:SourceRoot = Find-ContractSourceRoot -From $PSScriptRoot
        $script:Gates = if ($script:SourceRoot) { @(Get-ContractGate -SourceRoot $script:SourceRoot) } else { @() }

        $script:CrashPattern = '\.psm?1:(\d+| )|At line:\d+|At .+:\d+ char:\d+|CategoryInfo|FullyQualifiedErrorId|is not recognized as the name|Exception calling'

        # The exit codes each gate may give in an empty repository. 3 means the gate found nothing to
        # check there. 2 means it misses an input it needs, such as a doc layer, a setting or the git
        # history. 1 is allowed only for a gate whose rule is that something must exist.
        $script:Expected = @{
            'Test-GitleaksBaseline.ps1'         = @(0, 2)
            'Check-DocLineCitations.ps1'        = @(2, 3)
            'Check-ArtifactGraph.ps1'           = @(2, 3)
            'Check-DocsWiki.ps1'                = @(2, 3)
            'Build-DocsIndex.ps1'               = @(2, 3)
            'Check-DocEmDashes.ps1'             = @(2, 3)
            'Check-AgentsFileSize.ps1'          = @(2, 3)
            'Check-SyncManifest.ps1'            = @(2, 3)
            'Check-LocalPackages.ps1'           = @(2, 3)
            'Sync-AgentsFile.ps1'               = @(2, 3)
            'Check-DocReadingLevel.ps1'         = @(2, 3)
            'Check-SkillHygiene.ps1'            = @(2, 3)
            'Check-AgentHygiene.ps1'            = @(3)
            'Check-DocPersonNames.ps1'          = @(3)
            'Check-DocRowContent.ps1'           = @(2, 3)
            'Check-ChangeCompleteness.ps1'      = @(2, 3)
            'Check-PrHygiene.ps1'               = @(3)
            'Check-PrivateTerms.ps1'            = @(3)
            'Check-DocSectionRefs.ps1'          = @(2, 3)
            'Check-DocCoverage.ps1'             = @(1)
            'Check-DocLastChecked.ps1'          = @(3)
            'Sync-AllowRules.ps1'               = @(3)
            'Check-RazorConventions.ps1'        = @(2, 3)
            'Check-RazorAttributePlacement.ps1' = @(2, 3)
            'Check-DocGraphClaims.ps1'          = @(3)
            'Check-CommentHygiene.ps1'          = @(2, 3)
            'Check-NativeExitCode.ps1'          = @(2, 3)
            'Check-ScriptAnalyzer.ps1'          = @(2, 3)
            'Check-PrSize.ps1'                  = @(2, 3)
            'Check-BicepConventions.ps1'        = @(2, 3)
            'Check-TestShape.ps1'               = @(2, 3)
            'Check-ProjectReferenceUse.ps1'     = @(2, 3)
            'Check-ProjectLayerOrder.ps1'       = @(2, 3)
            'Check-SharedParts.ps1'             = @(2, 3)
            'Check-XmlDocs.ps1'                 = @(2, 3)
            'Check-StoryTraits.ps1'             = @(2, 3)
            'Check-ApiPascalCase.ps1'           = @(2, 3)
            'Check-SpecDrift.ps1'               = @(2, 3)
            'Check-DocDrift.ps1'                = @(2, 3)
            'Check-Coverage.ps1'                = @(2, 3)
            'Check-PrStoryContract.ps1'         = @(3)
            'Check-StoryBackEdges.ps1'          = @(2, 3)
            'Check-McpToken.ps1'                = @(3)
            'Check-RetiredSkillNames.ps1'       = @(2, 3)
            'Update-SkillCatalog.ps1'           = @(2, 3)
            'Update-SyncManifest.ps1'           = @(2, 3)
            'Check-SharedAgentsPartSize.ps1'    = @(2, 3)
            'Check-PackageVersion.ps1'          = @(2, 3)
            'Build-GateCatalog.ps1'             = @(2, 3)
        }

        $script:Work = Join-Path ([IO.Path]::GetTempPath()) ('gate-contract-' + [guid]::NewGuid().ToString('n'))
        $script:EmptyRoot = New-EmptyContractFixture -Path (Join-Path $script:Work 'empty')
        $script:EmptyResults = @{}
        if ($script:SourceRoot) {
            $module = $script:FixtureModule
            $fixture = $script:EmptyRoot
            $rows = $script:Gates | ForEach-Object -ThrottleLimit 8 -Parallel {
                Import-Module $using:module
                $result = Invoke-ContractGate -Gate $_ -Fixture $using:fixture
                [pscustomobject]@{ Id = $_.Id; Code = $result.Code; Output = $result.Output; Error = $result.Error }
            }
            foreach ($row in $rows) { $script:EmptyResults[$row.Id] = $row }
        }
    }

    AfterAll {
        if ($script:Work) { Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'sees a crash: a gate script that throws gives an error the crash pattern matches' -Tag '#46' {
        $thrower = Join-Path $script:Work 'Throw-Gate.ps1'
        Set-Content -LiteralPath $thrower -Value "param([string]`$RepoRoot)`nthrow 'boom'" -Encoding utf8
        $gate = [pscustomobject]@{ Script = $thrower; Args = @{}; Requires = '' }

        $result = Invoke-ContractGate -Gate $gate -Fixture $script:EmptyRoot

        $result.Code | Should -Be 1
        $result.Error | Should -Match $script:CrashPattern
    }

    It 'finds the gates of the core, the packs and the repository' -Tag '#46' -Skip:$skip {
        $script:Gates.Count | Should -BeGreaterThan 30
        @($script:Gates | ForEach-Object Source | Sort-Object -Unique) | Should -Contain 'repoGates'
    }

    It 'lists <Leaf> in the expected table, so a new gate cannot skip the contract' -Tag '#46' -ForEach $gates {
        $script:Expected.ContainsKey($Leaf) | Should -BeTrue -Because "add $Leaf to the Expected table of GateContract.Tests.ps1 with the exit codes it gives in an empty repository"
    }

    Context 'in an empty repository, which holds only a minimal aisdlc.json' {
        It '<Id> never crashes and exits with a code from its expected set' -Tag '#46' -ForEach $gates {
            $expected = $script:Expected[$Leaf]
            $expected | Should -Not -BeNullOrEmpty
            $result = $script:EmptyResults[$Id]

            $result.Error | Should -Not -Match $script:CrashPattern -Because 'an unhandled error is a crash'
            $result.Code | Should -BeIn $expected -Because $result.Output
            $result.Output.Trim() | Should -Not -BeNullOrEmpty -Because 'a gate that exits 2 or 3 says why in one plain line'
        }

        It '<Id> prints a FIX line when it exits 2, and no ::error:: or ::warning:: prefix' -Tag '#46' -ForEach $gates {
            $result = $script:EmptyResults[$Id]
            if ($result.Code -eq 2) { $result.Output | Should -Match '(?m)^\s*FIX: \S' -Because 'a gate that could not check says how to fix it' }
            $result.Output | Should -Not -Match '::(error|warning)::' -Because 'a gate prints plain output; the runner writes the annotations'
        }
    }
}
