#requires -Version 7.4

Describe 'the pull request workflow of AI.SDLC' -Skip:(-not (Get-Module -ListAvailable powershell-yaml)) {
    BeforeAll {
        Import-Module powershell-yaml
        $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:Folder = Join-Path $script:Root '.github' 'workflows'
        $script:PrFile = Join-Path $script:Folder 'pr.yml'
        $script:PrText = Get-Content -LiteralPath $script:PrFile -Raw
        $script:Pr = ConvertFrom-Yaml $script:PrText
        $script:Config = Get-Content -LiteralPath (Join-Path $script:Root 'aisdlc.json') -Raw | ConvertFrom-Json

        function Get-MatrixRow {
            param([string]$Job)
            return @($script:Pr.jobs[$Job].strategy.matrix.include)
        }

        function Get-Step {
            param([string]$Job)
            return @($script:Pr.jobs[$Job].steps)
        }
    }

    It 'keeps the workflow under .github/workflows, where GitHub reads it, and nothing in a pipelines folder' {
        Test-Path -LiteralPath $script:PrFile | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Root 'pipelines') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:Root -File -Filter '*.yml' | ForEach-Object Name | Where-Object { $_ -ne 'apm.yml' }) | Should -BeNullOrEmpty
    }

    It 'runs on a pull request to main and on a push to main, and cancels a run that a newer push replaces' {
        $script:Pr.on.pull_request.branches | Should -Be @('main')
        $script:Pr.on.push.branches | Should -Be @('main')
        $script:Pr.concurrency.group | Should -Not -BeNullOrEmpty
        $script:Pr.concurrency['cancel-in-progress'] | Should -BeTrue
    }

    It 'asks for read rights only' {
        $script:Pr.permissions.contents | Should -Be 'read'
        @($script:Pr.permissions.Values | Where-Object { $_ -ne 'read' }) | Should -BeNullOrEmpty
        foreach ($name in $script:Pr.jobs.Keys) { $script:Pr.jobs[$name].Contains('permissions') | Should -BeFalse -Because "job $name takes the read rights of the workflow" }
    }

    It 'runs every job on a GitHub-hosted runner, because a fork could run code on a self-hosted one' {
        foreach ($name in $script:Pr.jobs.Keys) { $script:Pr.jobs[$name]['runs-on'] | Should -Match '^ubuntu-\d' -Because "job $name" }
    }

    It 'pins every third-party action to a full commit SHA with its version in a comment' {
        $uses = @([regex]::Matches($script:PrText, '(?m)^\s*(?:-\s*)?uses:\s*(\S+)(.*)$'))
        $uses | Should -Not -BeNullOrEmpty
        foreach ($u in $uses) {
            $ref = $u.Groups[1].Value
            if ($ref.StartsWith('./')) { continue }
            $ref | Should -Match '^[\w.-]+/[\w./-]+@[0-9a-f]{40}$' -Because "$ref is pinned by SHA"
            $u.Groups[2].Value | Should -Match '#\s*v\d+\.\d+\.\d+' -Because "$ref names its version"
        }
    }

    It 'names only scripts and local actions that exist' {
        $missing = foreach ($m in [regex]::Matches($script:PrText, '\./((?:tools|core|packs)/[^\s"'']+\.ps1)')) {
            if (-not (Test-Path -LiteralPath (Join-Path $script:Root $m.Groups[1].Value))) { $m.Groups[1].Value }
        }
        @($missing) | Should -BeNullOrEmpty
        foreach ($m in [regex]::Matches($script:PrText, '(?m)uses:\s*\./(\S+)')) {
            Test-Path -LiteralPath (Join-Path $script:Root $m.Groups[1].Value 'action.yml') | Should -BeTrue -Because "the workflow uses ./$($m.Groups[1].Value)"
        }
    }

    It 'has the three jobs of AI.SDLC and no SonarCloud job, because AI.SDLC does not install the sonarcloud pack' {
        @($script:Pr.jobs.Keys | Sort-Object) | Should -Be @('ai-sdlc', 'pester', 'test-consumer')
        $script:PrText | Should -Not -Match '(?i)sonar'
    }

    It 'names in needs only jobs that exist' {
        foreach ($name in $script:Pr.jobs.Keys) {
            foreach ($need in @($script:Pr.jobs[$name].needs | Where-Object { $_ })) { $script:Pr.jobs.Keys | Should -Contain $need -Because "job $name needs $need" }
        }
    }

    It 'runs the shared AI-SDLC step through the composite action of the core, with the private term list from a secret' {
        $steps = Get-Step 'ai-sdlc'
        $steps[0].uses | Should -Match '^actions/checkout@'
        $steps[0].with['fetch-depth'] | Should -Be 0
        $action = @($steps | Where-Object { $_.uses -eq './.claude/skills/ai-sdlc-gates/assets/actions/ai-sdlc-pr' })
        $action | Should -HaveCount 1
        $action[0].with['private-terms'] | Should -Be '${{ secrets.AISDLC_PRIVATE_TERMS }}'
    }

    It 'runs no gate by hand, because the composite action runs every core, pack and repoGate gate once' {
        $script:PrText | Should -Not -Match 'Invoke-Gate\.ps1'
        $packageGates = foreach ($file in Get-ChildItem -LiteralPath (Join-Path $script:Root 'core'), (Join-Path $script:Root 'packs') -Recurse -Force -File -Filter 'gates.json') {
            (Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json).gates | ForEach-Object { Split-Path $_.script -Leaf }
        }
        $scripts = @(@($packageGates) + @($script:Config.repoGates | ForEach-Object { Split-Path $_.script -Leaf }) | Sort-Object -Unique)
        $scripts | Should -Not -BeNullOrEmpty
        $code = ($script:PrText -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        foreach ($leaf in $scripts) { $code | Should -Not -Match ([regex]::Escape($leaf)) -Because "the composite action already runs $leaf" }
    }

    It 'checks the em-dash and the line citations as blocking repoGates over a wide path' {
        $emDash = @($script:Config.repoGates | Where-Object { $_.script -eq 'core/.apm/skills/ai-sdlc-gates/scripts/Check-DocEmDashes.ps1' })
        $emDash | Should -HaveCount 1
        $emDash[0].mode | Should -Be 'Blocking'
        $emDash[0].clause | Should -Be 'C06'
        @($emDash[0].args.Path | Sort-Object) | Should -Be @('AGENTS.md', 'CHANGELOG.md', 'core', 'docs', 'docs-functional', 'packs', 'README.md', 'test-consumers', 'tools' | Sort-Object)
        $lines = @($script:Config.repoGates | Where-Object { $_.script -eq 'core/.apm/skills/ai-sdlc-gates/scripts/Check-DocLineCitations.ps1' })
        $lines | Should -HaveCount 1
        $lines[0].mode | Should -Be 'Blocking'
        $lines[0].clause | Should -Be 'C02'
        @($lines[0].args.Path | Sort-Object) | Should -Be @('AGENTS.md', 'core', 'docs', 'docs-functional', 'packs', 'README.md' | Sort-Object)
    }

    It 'runs the hygiene checks of AI.SDLC as blocking repoGates' {
        foreach ($script in 'tools/Check-RetiredSkillNames.ps1', 'tools/Update-SkillCatalog.ps1', 'tools/Update-SyncManifest.ps1', 'tools/Check-SharedAgentsPartSize.ps1', 'tools/Check-PackageVersion.ps1') {
            $entry = @($script:Config.repoGates | Where-Object { $_.script -eq $script })
            $entry | Should -HaveCount 1 -Because "$script is one repoGate"
            $entry[0].mode | Should -Be 'Blocking'
        }
    }

    It 'checks the reading level of the shared docs from one repoGate only, so the arguments cannot drift' {
        $entry = @($script:Config.repoGates | Where-Object { $_.script -eq 'core/.apm/skills/ai-sdlc-gates/scripts/Check-DocReadingLevel.ps1' })
        $entry | Should -HaveCount 1
        $entry[0].mode | Should -Be 'Blocking'
        $entry[0].args.SentenceScope | Should -Be 'Paragraph'
        $entry[0].args.MaxSentenceWords | Should -Be 25
        @($entry[0].args.Path) | Should -Be @('core', 'packs', 'README.md', 'AGENTS.md', 'docs', 'docs-functional')
        $script:PrText | Should -Not -Match 'Check-DocReadingLevel\.ps1'
    }

    It 'runs the private term gate as a blocking repoGate that fails when the list is missing' {
        $entry = @($script:Config.repoGates | Where-Object { $_.script -eq 'core/.apm/skills/ai-sdlc-gates/scripts/Check-PrivateTerms.ps1' })
        $entry | Should -HaveCount 1
        $entry[0].mode | Should -Be 'Blocking'
        $entry[0].args.Required | Should -BeTrue
        $script:Config.visibility | Should -Be 'public'
        @($script:Config.repoGates | Where-Object { $_.script -match 'Check-NoRepoSpecificText' }) | Should -BeNullOrEmpty
    }

    It 'runs the shares of each Pester folder as 1 to n, so each test file runs once' {
        $rows = Get-MatrixRow -Job 'pester'
        foreach ($group in ($rows | Group-Object { $_.folder })) {
            $shards = @($group.Group | ForEach-Object { [int]$_.shards } | Select-Object -Unique)
            $shards | Should -HaveCount 1 -Because "every share of $($group.Name) names the same number of shares"
            @($group.Group | ForEach-Object { [int]$_.shard } | Sort-Object) | Should -Be @(1..$shards[0]) -Because "the shares of $($group.Name) are 1 to $($shards[0])"
        }
    }

    It 'runs the tests of every top folder with tests in the Pester job, and not again as a repoGate' {
        $tested = @(Get-MatrixRow -Job 'pester' | ForEach-Object { $_.folder } | Sort-Object -Unique)
        $withTests = @('core', 'packs', 'tools' | Where-Object { Get-ChildItem -LiteralPath (Join-Path $script:Root $_) -Recurse -Force -File -Filter '*.Tests.ps1' -ErrorAction SilentlyContinue | Select-Object -First 1 })
        $tested | Should -Be $withTests
        @($script:Config.repoGates | Where-Object { $_.script -eq 'tools/Invoke-PesterParallel.ps1' }) | Should -BeNullOrEmpty -Because 'the shared job runs the repoGates, so a Pester repoGate would run the tests twice'
    }

    It 'uploads the coverage of every Pester share, under a name per share and attempt' {
        $steps = Get-Step 'pester'
        $run = @($steps | Where-Object { $_.run -match 'Invoke-PesterParallel\.ps1' })
        $run | Should -HaveCount 1
        $run[0].run | Should -Match '-CoverageFile "\$env:RUNNER_TEMP/coverage/coverage\.xml"'
        $run[0].run | Should -Match '-Ci'
        $upload = @($steps | Where-Object { $_.uses -match '^actions/upload-artifact@' })
        $upload | Should -HaveCount 1
        $upload[0].with.path | Should -Be '${{ runner.temp }}/coverage'
        $upload[0].with.name | Should -Be 'coverage-${{ matrix.folder }}-${{ matrix.shard }}-${{ github.run_attempt }}'
        $upload[0].if | Should -Be '${{ !cancelled() }}'
    }

    It 'installs and upgrades each test consumer, with the history and the tags for the upgrade' {
        $steps = Get-Step 'test-consumer'
        $steps[0].with['fetch-depth'] | Should -Be 0 -Because 'the upgrade starts from the previous release tag'
        $runs = @($steps | Where-Object { $_.run -match 'tools/Test-Consumers\.ps1' })
        $runs | Should -HaveCount 2
        $runs[0].run | Should -Not -Match '-Upgrade'
        $runs[0].run | Should -Match '-Name \$\{\{ matrix\.consumer \}\} ' -Because 'an unquoted list such as bicep-only,setup-script reaches the script as an array'
        $runs[0].if | Should -Be "`${{ matrix.pass == 'fresh' }}"
        $runs[1].run | Should -Match '-Upgrade -Ci'
        $runs[1].if | Should -Be "`${{ matrix.pass == 'upgrade' }}"
        @($steps | Where-Object { $_.run -match 'Install-Apm\.ps1' }) | Should -HaveCount 1
    }

    It 'installs gitleaks in each test consumer job before the test consumers run, because their gates include the C03 secret scan' {
        $steps = Get-Step 'test-consumer'
        $install = @(for ($i = 0; $i -lt $steps.Count; $i++) { if ($steps[$i].run -match 'Install-Gitleaks\.ps1') { $i } })
        $install | Should -HaveCount 1
        $steps[$install[0]].Contains('if') | Should -BeFalse -Because 'both passes need gitleaks'
        $first = @(for ($i = 0; $i -lt $steps.Count; $i++) { if ($steps[$i].run -match 'tools/Test-Consumers\.ps1') { $i } })[0]
        $install[0] | Should -BeLessThan $first
    }

    It 'runs a fresh job for every test consumer under test-consumers/ and the setup script, and an upgrade job beside it for each test consumer' {
        $rows = Get-MatrixRow -Job 'test-consumer'
        $consumers = @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'test-consumers') -Directory | ForEach-Object Name | Sort-Object)
        @($rows | Where-Object { $_.pass -eq 'fresh' } | ForEach-Object { $_.consumer -split ',' } | Sort-Object) | Should -Be @(@($consumers) + 'setup-script' | Sort-Object)
        @($rows | Where-Object { $_.pass -eq 'upgrade' } | ForEach-Object { $_.consumer } | Sort-Object) | Should -Be $consumers -Because 'the setup-script consumer has no old version to upgrade from'
        @($rows | Where-Object { $_.pass -notin 'fresh', 'upgrade' }) | Should -BeNullOrEmpty
    }
}
