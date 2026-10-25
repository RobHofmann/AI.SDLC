#requires -Version 7.4

Describe 'Check-DocReadingLevel' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'DocToolTestHarness.psm1') -Force
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Check-DocReadingLevel.ps1'

        function Invoke-Gate {
            param([Parameter(Mandatory)][string]$RepoRoot, [hashtable]$Extra = @{})
            $p = @{ SharedAllowListPath = (Join-Path $RepoRoot 'no-shared-list.txt') }; foreach ($k in $Extra.Keys) { $p[$k] = $Extra[$k] }
            $out = & $script:ScriptUnderTest -RepoRoot $RepoRoot -WordListPath (Join-Path $RepoRoot 'lists') -DenyListPath (Join-Path $RepoRoot 'deny.md') -AllowListPath (Join-Path $RepoRoot 'allow.txt') @p *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }
    }

    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'docs') -Force | Out-Null
        Set-AiSdlcTestConfig -Root $script:Root
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'lists') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Root 'lists/words.csv') -Value @(
            'headword,pos,CEFR'
            'gate,noun,A2'
            'build,verb,A1'
            'fail,verb,A2'
            'page,noun,A1'
            'simple,adjective,A2'
            'sentence,noun,B1'
            'comprehensive,adjective,B2'
            'notwithstanding,preposition,C2'
            'run,verb,A1'
            'run,noun,B2'
        ) -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:Root 'deny.md') -Value "# Deny`n`n| Instead of | Write |`n| --- | --- |`n| load-bearing | key |`n| in order to | to |`n`nAfter the table.`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $script:Root 'allow.txt') -Value "# accepted words`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $script:Root 'AGENTS.md') -Value "# Agents`nThe gate fails the build.`n" -NoNewline
    }

    It 'reads .claude/CLAUDE.md, where a repository keeps its Claude-only notes' {
        New-Item -ItemType Directory -Path (Join-Path $script:Root '.claude') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Root '.claude/CLAUDE.md') -Value "# Notes`nWe do this in order to build.`n" -NoNewline

        $r = Invoke-Gate -RepoRoot $script:Root

        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'CLAUDE\.md'
    }

    Context 'where the word table comes from' {
        It 'reads the table from paths.languagePage when aisdlc.json sets it' {
            Set-AiSdlcTestConfig -Root $script:Root -Paths @{ languagePage = 'deny.md' }
            Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nWe do this in order to build.`n" -NoNewline

            $out = & $script:ScriptUnderTest -RepoRoot $script:Root -WordListPath (Join-Path $script:Root 'lists') -AllowListPath (Join-Path $script:Root 'allow.txt') *>&1 | Out-String

            $LASTEXITCODE | Should -Be 1
            $out | Should -Match 'in order to'
        }

        It 'accepts a word from the shared allow list and one from the repository list in the same run' {
            Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nThis is comprehensive.`nThis is notwithstanding.`n" -NoNewline
            Set-Content -LiteralPath (Join-Path $script:Root 'allow.txt') -Value "notwithstanding`n" -NoNewline
            Set-Content -LiteralPath (Join-Path $script:Root 'shared.txt') -Value "# shared`ncomprehensive`n" -NoNewline

            $r = Invoke-Gate -RepoRoot $script:Root -Extra @{ SharedAllowListPath = (Join-Path $script:Root 'shared.txt') }

            $r.ExitCode | Should -Be 0 -Because $r.Output
        }

        It 'ships a shared allow list beside the script' {
            Test-Path -LiteralPath (Join-Path $PSScriptRoot 'data' 'reading-level-allowlist.txt') | Should -BeTrue
        }

        It 'reads the handbook language page beside the gates skill when aisdlc.json sets none' {
            (Get-Content -LiteralPath $script:ScriptUnderTest -Raw) | Should -Match "'ai-sdlc-handbook' 'references' 'language\.md'"
        }
    }

    Context 'a failing run always names the file and the line' {
        It 'lists each finding as file:line without -Detail, so the build annotation can point at it' {
            Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nThis is comprehensive.`n" -NoNewline

            $r = Invoke-Gate -RepoRoot $script:Root

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'docs/page\.md:2\s+\[hard-word\]\s+comprehensive'
        }

        It 'caps the list and says how many more, so one bad page does not print a wall' {
            $body = (1..8 | ForEach-Object { 'This is comprehensive.' }) -join "`n"
            Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`n$body`n" -NoNewline

            $r = Invoke-Gate -RepoRoot $script:Root -Extra @{ MaxListed = 3 }

            $r.ExitCode | Should -Be 1
            ([regex]::Matches($r.Output, 'docs/page\.md:\d+\s+\[hard-word\]')).Count | Should -Be 3
            $r.Output | Should -Match 'and 5 more finding\(s\)'
        }

        It 'drops the tables when there is a single finding, because they repeat the one line' {
            Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nThis is comprehensive.`n" -NoNewline

            $r = Invoke-Gate -RepoRoot $script:Root

            $r.Output | Should -Not -Match 'Per file \(long sentences'
            $r.Output | Should -Match 'docs/page\.md:2'
        }
    }

    It 'passes a page of short sentences and B1 words (exit 0)' {
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nThe gate fails the build. A simple sentence.`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Reading level OK'
    }

    It 'fails on a sentence longer than the limit (exit 1)' {
        $long = (1..26 | ForEach-Object { 'gate' }) -join ' '
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`n$long.`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root -Extra @{ Detail = $true }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'long-sentence'
    }

    It 'flags a word the lists place above B1 (exit 1)' {
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nA comprehensive page.`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root -Extra @{ Detail = $true }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'hard-word.*comprehensive'
    }

    It 'folds an inflected form onto its headword before the lookup' {
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nThe gates failed the builds.`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 0
    }

    It 'does not flag a word the lists do not know' {
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nCosmos and Demo run the gate.`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 0
    }

    It 'takes the lowest level when a headword appears at several levels' {
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nA run of the gate.`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 0
    }

    It 'ignores inline code, fenced code, link targets and front matter' {
        $body = "---`nnotwithstanding: comprehensive`n---`n# Page`nUse ``comprehensive`` here. See [the page](comprehensive-notwithstanding.md).`n``````text`nnotwithstanding comprehensive`n``````text`n"
        $body = $body -replace '``````text', '```'
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value $body -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 0
    }

    It 'ignores a source citation in square brackets' {
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nThe gate fails the build [Source: notwithstanding comprehensive one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty].`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 0
    }

    It 'ignores text inside double quotes (a citation or an example)' {
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nThe gate fails the build. Write ""use"", not ""notwithstanding"". Microsoft says ""comprehensive one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty twenty-one twenty-two"".`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 0
    }

    It 'flags a phrase from the deny table (exit 1)' {
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nA load-bearing gate, in order to build.`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root -Extra @{ Detail = $true }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'load-bearing'
        $r.Output | Should -Match 'in order to'
    }

    It 'accepts a word from the allow list' {
        Set-Content -LiteralPath (Join-Path $script:Root 'allow.txt') -Value "comprehensive # the team accepts it`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nA comprehensive page.`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 0
    }

    It 'ends a sentence at a closing bold marker or quote after the full stop' {
        $long = (1..14 | ForEach-Object { 'gate' }) -join ' '
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`n**$long.** $long. ""$long."" $long.`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 0
    }

    It 'skips the sentence-length check on headings and table rows' {
        $long = (1..26 | ForEach-Object { 'gate' }) -join ' '
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# $long`n| a | b |`n| --- | --- |`n| $long | gate |`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 0
    }

    Context 'a sentence that wraps over several lines (-SentenceScope)' {
        BeforeEach {
            $script:Half = (1..15 | ForEach-Object { 'gate' }) -join ' '
        }

        It 'counts each line on its own by default, so a page that passes today keeps passing' {
            Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`n$script:Half`n$script:Half.`n" -NoNewline
            $r = Invoke-Gate -RepoRoot $script:Root
            $r.ExitCode | Should -Be 0 -Because $r.Output
        }

        It 'joins the lines of a paragraph under Paragraph and names the line where the sentence starts' {
            Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`n`nThe gate fails the build. $script:Half`n$script:Half.`nThe gate fails the build.`n" -NoNewline
            $r = Invoke-Gate -RepoRoot $script:Root -Extra @{ SentenceScope = 'Paragraph' }
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'docs/page\.md:3\s+\[long-sentence\]\s+30 words'
        }

        It 'joins the continuation lines of a list item into that item' {
            Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`n`n- $script:Half`n  $script:Half.`n" -NoNewline
            $r = Invoke-Gate -RepoRoot $script:Root -Extra @{ SentenceScope = 'Paragraph' }
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'docs/page\.md:3\s+\[long-sentence\]'
        }

        It 'starts a new unit at a blank line, a new list item, a heading, a table row and a fence' {
            $fence = '`' * 3
            $h = $script:Half
            $body = (@('# Page', $h, '', $h, "- $h", "- $h", '## Next', $h, '| a | b |', '| --- | --- |', $h, "${fence}text", 'code', $fence, $h) -join "`n") + "`n"
            Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value $body -NoNewline
            $r = Invoke-Gate -RepoRoot $script:Root -Extra @{ SentenceScope = 'Paragraph' }
            $r.ExitCode | Should -Be 0 -Because $r.Output
        }

        It 'refuses a scope it does not know' {
            { Invoke-Gate -RepoRoot $script:Root -Extra @{ SentenceScope = 'Page' } } | Should -Throw
        }
    }

    It 'skips the sentence-length check on an index row (a link, a dash, a summary)' {
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`n- [The gate page](gate.md) - The gate fails the build one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty.`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 0
    }

    It 'checks words in headings and table rows' {
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Comprehensive`n| a | b |`n| --- | --- |`n| notwithstanding | gate |`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root -Extra @{ Detail = $true }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Comprehensive'
        $r.Output | Should -Match 'notwithstanding'
    }

    It 'checks a page inside a dot-directory, which Linux and macOS treat as hidden' {
        New-Item -ItemType Directory -Path (Join-Path $script:Root '.claude/skills/demo') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Root '.claude/skills/demo/SKILL.md') -Value "# Skill`nThe gate runs notwithstanding the page.`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root -Extra @{ Detail = $true }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'skills/demo/SKILL\.md'
    }

    It 'throws on a -Path that does not exist, so a typo cannot pass silently' {
        { Invoke-Gate -RepoRoot $script:Root -Extra @{ Path = 'docs/not-here' } } |
            Should -Throw -ExpectedMessage '*Path not found*'
    }

    It 'checks only the given -Path when one is passed' {
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nA comprehensive page.`n" -NoNewline
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'docs/clean') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/clean/ok.md') -Value "# Ok`nThe gate fails the build.`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root -Extra @{ Path = 'docs/clean' }
        $r.ExitCode | Should -Be 0
    }

    It 'prints the per-file summary and the top words without -Detail' {
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nA comprehensive page. Another comprehensive page.`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'docs/page.md'
        $r.Output | Should -Match '2\s+comprehensive'
    }
}
