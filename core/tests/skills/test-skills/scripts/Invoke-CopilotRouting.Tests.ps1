#requires -Version 7.4

Describe 'Invoke-CopilotRouting' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-CopilotRouting.ps1'
        $script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ("copilot-routing-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        $script:PromptFile = Join-Path $script:Root 'prompts.md'
        $script:ExpectedFile = Join-Path $script:Root 'expected.md'
        Set-Content -LiteralPath $script:PromptFile -Value @(
            '# heading that is not a prompt'
            'P01: Fix the page I wrote'
            'P02: Explain this simply'
            'P03: Adopt the docs'
        ) -Encoding utf8
        Set-Content -LiteralPath $script:ExpectedFile -Value @(
            'P01: write-docs'
            'P02: wait-what or none'
            'P03: adopt-docs'
        ) -Encoding utf8

        $answers = @{
            'Fix the page I wrote' = "write-docs`n"
            'Explain this simply'  = 'none'
            'Adopt the docs'       = 'docs-wiki-conventions'
        }
        $script:FakeAsk = {
            param([string]$Question)
            foreach ($key in $answers.Keys) { if ($Question -like "*`"$key`"*") { return $answers[$key] } }
            return 'unknown'
        }.GetNewClosure()

        $script:AllLoaded = { param([string]$Root) "Project skills:`n  write-docs - Write the docs.`n  adopt-docs - Adopt the docs.`n" }
        $script:WriteDocsFails = {
            param([string]$Root)
            @(
                'Project skills:'
                '✖ The following skills failed to load:'
                "  • $Root\.claude\skills\write-docs\SKILL.md: Skill description must be at most 1024 characters"
                '  adopt-docs - Adopt the docs.'
            ) -join "`n"
        }
    }

    AfterAll { Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'compares each answer with the expected skill and accepts any of the names joined by or' {
        $lines = @(& $script:ScriptUnderTest -Prompts $script:PromptFile -Expected $script:ExpectedFile -RepoRoot $script:Root -Ask $script:FakeAsk -ListSkills $script:AllLoaded)

        $lines | Should -Contain 'P01: write-docs -> write-docs OK'
        $lines | Should -Contain 'P02: wait-what or none -> none OK'
        $lines | Should -Contain 'P03: adopt-docs -> docs-wiki-conventions MISS'
        $lines[-1] | Should -Be 'Copilot routing: 2 of 3 as expected, 1 miss(es).'
    }

    It 'asks Copilot not to run the skill and to answer with the name only' {
        $seen = [System.Collections.Generic.List[string]]::new()
        $capture = { param([string]$Question) $seen.Add($Question); 'none' }.GetNewClosure()

        & $script:ScriptUnderTest -Prompts $script:PromptFile -RepoRoot $script:Root -Ask $capture -ListSkills $script:AllLoaded | Out-Null

        $seen.Count | Should -Be 3
        $seen[0] | Should -Match 'Do not run it and do not read files'
        $seen[0] | Should -Match 'Reply with only the skill name, or none'
    }

    It 'prints the answers without a verdict when no expected file is given' {
        $lines = @(& $script:ScriptUnderTest -Prompts $script:PromptFile -RepoRoot $script:Root -Ask $script:FakeAsk -ListSkills $script:AllLoaded)

        $lines | Should -Be @('P01: write-docs', 'P02: none', 'P03: docs-wiki-conventions')
    }

    It 'runs Copilot in the repository root, where the trusted folder and the skills are' {
        $where = [System.Collections.Generic.List[string]]::new()
        $capture = { param([string]$Question) $where.Add((Get-Location).Path); 'none' }.GetNewClosure()

        & $script:ScriptUnderTest -Prompts $script:PromptFile -RepoRoot $script:Root -Ask $capture -ListSkills $script:AllLoaded | Out-Null

        $where | ForEach-Object { $_ | Should -Be (Resolve-Path $script:Root).Path }
    }

    It 'refuses a prompt file with no prompt line' {
        $empty = Join-Path $script:Root 'empty.md'
        Set-Content -LiteralPath $empty -Value '# nothing' -Encoding utf8

        { & $script:ScriptUnderTest -Prompts $empty -RepoRoot $script:Root -Ask $script:FakeAsk -ListSkills $script:AllLoaded } | Should -Throw '*No prompt of the form*'
    }

    It 'counts a right name as a miss when Copilot did not load that skill, and exits 1' {
        $lines = @(& $script:ScriptUnderTest -Prompts $script:PromptFile -Expected $script:ExpectedFile -RepoRoot $script:Root -Ask $script:FakeAsk -ListSkills $script:WriteDocsFails)

        $LASTEXITCODE | Should -Be 1
        $lines | Should -Contain 'NOT LOADED in Copilot: write-docs (Skill description must be at most 1024 characters)'
        $lines | Should -Contain 'P01: write-docs -> write-docs MISS (not loaded)'
        $lines | Should -Contain 'Copilot routing: 1 of 3 as expected, 2 miss(es).'
        $lines[-1] | Should -Match '1 skill\(s\) do not load in Copilot'
    }

    It 'reads an answer written as <Answer> as the bare skill name' -ForEach @(
        @{ Answer = '`write-docs`' }
        @{ Answer = '/write-docs' }
        @{ Answer = "write-docs.`n" }
        @{ Answer = '`/write-docs`.' }
    ) {
        $ask = { param([string]$Question) $Answer }.GetNewClosure()
        $one = Join-Path $script:Root 'one.md'
        $oneExpected = Join-Path $script:Root 'one-expected.md'
        Set-Content -LiteralPath $one -Value 'P01: Fix the page I wrote' -Encoding utf8
        Set-Content -LiteralPath $oneExpected -Value 'P01: write-docs' -Encoding utf8

        $lines = @(& $script:ScriptUnderTest -Prompts $one -Expected $oneExpected -RepoRoot $script:Root -Ask $ask -ListSkills $script:AllLoaded)

        $lines | Should -Contain 'P01: write-docs -> write-docs OK'
    }
}
