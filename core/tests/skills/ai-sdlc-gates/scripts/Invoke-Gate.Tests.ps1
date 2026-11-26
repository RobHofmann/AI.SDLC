#requires -Version 7.4

Describe 'Invoke-Gate' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-Gate.ps1'

        function New-FakeGate {
            param(
                [Parameter(Mandatory)][string]$Root,
                [Parameter(Mandatory)][int]$ExitCode,
                [string]$Message = 'gate ran'
            )
            $path = Join-Path $Root 'FakeGate.ps1'
            Set-Content -LiteralPath $path -Value "Write-Host '$Message'; exit $ExitCode" -NoNewline
            return $path
        }

        function Invoke-Wrapper {
            param(
                [Parameter(Mandatory)][string]$Gate,
                [Parameter(Mandatory)][string]$Mode
            )
            $out = & $script:ScriptUnderTest -Script $Gate -Clause 'C99' -What 'a test rule' -Mode $Mode *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }
    }

    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        $script:SavedActions = $env:GITHUB_ACTIONS
        $env:GITHUB_ACTIONS = 'true'
    }

    AfterEach { $env:GITHUB_ACTIONS = $script:SavedActions }

    It 'passes through a clean gate (exit 0, no annotation) in Advisory mode' {
        $gate = New-FakeGate -Root $script:Root -ExitCode 0
        $r = Invoke-Wrapper -Gate $gate -Mode 'Advisory'
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'gate ran'
        $r.Output | Should -Not -Match '::(error|warning)'
    }

    It 'passes through a clean gate (exit 0, no annotation) in Blocking mode' {
        $gate = New-FakeGate -Root $script:Root -ExitCode 0
        $r = Invoke-Wrapper -Gate $gate -Mode 'Blocking'
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Not -Match '::(error|warning)'
    }

    It 'turns a non-zero gate into a warning in Advisory mode (wrapper exits 0)' {
        $gate = New-FakeGate -Root $script:Root -ExitCode 1
        $r = Invoke-Wrapper -Gate $gate -Mode 'Advisory'
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match '(?m)^::warning title=a test rule::'
        $r.Output | Should -Not -Match '::error'
    }

    It 'turns a non-zero gate into an error in Blocking mode (wrapper exits 1)' {
        $gate = New-FakeGate -Root $script:Root -ExitCode 1
        $r = Invoke-Wrapper -Gate $gate -Mode 'Blocking'
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match '(?m)^::error title=a test rule::'
        $r.Output | Should -Not -Match '##vso'
    }

    It 'includes the clause and label in the annotation' {
        $gate = New-FakeGate -Root $script:Root -ExitCode 1
        $r = Invoke-Wrapper -Gate $gate -Mode 'Blocking'
        $r.Output | Should -Match 'C99'
        $r.Output | Should -Match 'a test rule'
    }

    It 'treats exit 2 as could-not-check in Blocking mode: a warning, never a failure' {
        $gate = Join-Path $script:Root 'UnknownGate.ps1'
        Set-Content -LiteralPath $gate -Value "Write-Host 'the credentials do not work (HTTP 401)'; exit 2" -NoNewline
        $r = Invoke-Wrapper -Gate $gate -Mode 'Blocking'
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'COULD NOT BE CHECKED'
        $r.Output | Should -Match 'HTTP 401'
        $r.Output | Should -Match '(?m)^::warning '
        $r.Output | Should -Not -Match '::error'
    }

    It 'treats exit 2 the same way in Advisory mode' {
        $gate = Join-Path $script:Root 'UnknownGate2.ps1'
        Set-Content -LiteralPath $gate -Value "Write-Host 'the tracker was unreachable'; exit 2" -NoNewline
        $r = Invoke-Wrapper -Gate $gate -Mode 'Advisory'
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'COULD NOT BE CHECKED'
        $r.Output | Should -Match '(?m)^::warning '
    }

    It 'quotes the gate first and last line, so the annotation says the rule and the count' {
        $gate = Join-Path $script:Root 'SummaryGate.ps1'
        Set-Content -LiteralPath $gate -Value "Write-Host 'Reading level: prose must read at B2 and B1.'; Write-Host '  docs/page.md:12  [long-sentence]'; Write-Host 'Found 1 long sentence(s) across 1 file(s).'; exit 1" -NoNewline
        $r = Invoke-Wrapper -Gate $gate -Mode 'Blocking'
        $r.Output | Should -Match 'Why: Reading level: prose must read at B2 and B1\.'
        $r.Output | Should -Match 'Found 1 long sentence\(s\) across 1 file\(s\)\.'
    }

    It 'strips the log-marker prefix, so the annotation reads as a sentence' {
        $gate = Join-Path $script:Root 'MarkerGate.ps1'
        Set-Content -LiteralPath $gate -Value "Write-Host '::warning::the credentials do not work (HTTP 401)'; exit 2" -NoNewline
        $r = Invoke-Wrapper -Gate $gate -Mode 'Blocking'
        $r.Output | Should -Match 'Why: the credentials do not work'
        $r.Output | Should -Not -Match 'Why: ::warning::'
    }

    It 'names the command to repeat the check locally, with the path of the script it ran from the repository root' {
        Set-Content -LiteralPath (Join-Path $script:Root 'aisdlc.json') -Value '{}'
        $gateFolder = Join-Path $script:Root 'skills' 'demo' 'scripts'
        New-Item -ItemType Directory -Path $gateFolder -Force | Out-Null
        $gate = New-FakeGate -Root $gateFolder -ExitCode 1
        $r = Invoke-Wrapper -Gate $gate -Mode 'Blocking'
        $r.Output | Should -Match 'pwsh skills/demo/scripts/FakeGate\.ps1'
    }

    It 'reports a crashing gate as a gate fault, not as a finding' {
        $gate = Join-Path $script:Root 'CrashGate.ps1'
        Set-Content -LiteralPath $gate -Value "throw 'Could not find item /x/.github'" -NoNewline
        $r = Invoke-Wrapper -Gate $gate -Mode 'Blocking'
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'NOTHING WAS CHECKED'
        $r.Output | Should -Match 'Could not find item'
        $r.Output | Should -Match 'CrashGate\.ps1'
        $r.Output | Should -Match '(?m)^::error title=CrashGate\.ps1::'
    }

    Context 'every finding names its file, its line and why, without opening the log' {
        BeforeAll {
            function New-FindingGate {
                param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string[]]$Lines, [int]$ExitCode = 1)
                $path = Join-Path $Root ("FindingGate" + [Guid]::NewGuid().ToString('N') + ".ps1")
                $body = ($Lines | ForEach-Object { "Write-Host '$($_ -replace "'", "''")'" }) -join "`n"
                Set-Content -LiteralPath $path -Value "$body`nexit $ExitCode" -NoNewline
                return $path
            }
        }

        It 'raises each located finding as its own issue, with the file and the line' {
            $gate = New-FindingGate -Root $script:Root -Lines @(
                'Doc house-style violation: no em-dash is allowed.'
                '  docs/page.md:12  This sentence has one.'
                '  docs/other.md:3  And another.'
                'Found 2 line(s) containing an em-dash.'
            )

            $r = Invoke-Wrapper -Gate $gate -Mode 'Blocking'

            $r.Output | Should -Match '::error file=docs/page\.md,line=12,title=a test rule::C99: This sentence has one\.'
            $r.Output | Should -Match '::error file=docs/other\.md,line=3,title=a test rule::C99: And another\.'
        }

        It 'reads the file : message shape that carries no line number' {
            $gate = New-FindingGate -Root $script:Root -Lines @(
                'Docs-wiki violations:'
                "  docs/index.md : broken relative link -> 'gone.md'"
                'Checked 139 wiki page(s); 1 violation(s).'
            )

            $r = Invoke-Wrapper -Gate $gate -Mode 'Blocking'

            $r.Output | Should -Match '::error file=docs/index\.md,title=a test rule::C99: broken relative link'
            $r.Output | Should -Not -Match 'line='
        }

        It 'says why, by quoting the rule the gate stated first and the count it stated last' {
            $gate = New-FindingGate -Root $script:Root -Lines @(
                'Doc house-style violation: no em-dash is allowed.'
                '  docs/page.md:12  This sentence has one.'
                'Found 1 line(s) containing an em-dash.'
            )

            $r = Invoke-Wrapper -Gate $gate -Mode 'Blocking'

            $r.Output | Should -Match 'Why: Doc house-style violation: no em-dash is allowed\.'
            $r.Output | Should -Match 'Found 1 line\(s\) containing an em-dash\.'
        }

        It 'shows the first five and says how many more are in the log' {
            $lines = @('Rule broken.') + (1..8 | ForEach-Object { "  docs/page$_.md:$_  finding $_" }) + @('Found 8.')
            $gate = New-FindingGate -Root $script:Root -Lines $lines

            $r = Invoke-Wrapper -Gate $gate -Mode 'Blocking'

            ([regex]::Matches($r.Output, '::error file=')).Count | Should -Be 5
            $r.Output | Should -Match '3 more are in the log above'
        }

        It 'marks a finding as a warning in Advisory mode, not an error' {
            $gate = New-FindingGate -Root $script:Root -Lines @('Rule broken.', '  docs/page.md:12  one.', 'Found 1.')

            $r = Invoke-Wrapper -Gate $gate -Mode 'Advisory'

            $r.Output | Should -Match '::warning file=docs/page\.md'
            $r.Output | Should -Not -Match '::error'
        }

        It 'says plainly that the gate named no single place, rather than inventing one' {
            $gate = New-FindingGate -Root $script:Root -Lines @(
                'PR hygiene: the pull request does not carry what a reader needs.'
                'PR hygiene failed on 1 point(s): DESCRIPTION.'
            )

            $r = Invoke-Wrapper -Gate $gate -Mode 'Blocking'

            $r.Output | Should -Match 'named no single place'
            $r.Output | Should -Not -Match '::error file='
        }

        It 'takes the header above the findings as the rule, not a note the gate printed first' {
            $gate = New-FindingGate -Root $script:Root -Lines @(
                '  graph advisory: docs/adrs/0030-thing.md : no outbound cross-link'
                'Wiki graph: 132 content page(s), 540 cross-link edge(s).'
                'Docs-wiki violations (see the handbook docs-wiki page):'
                "  docs/page.md : broken relative link -> 'gone.md'"
                'Checked 141 wiki page(s); 1 violation(s).'
            )

            $r = Invoke-Wrapper -Gate $gate -Mode 'Blocking'

            $r.Output | Should -Match 'Why: Docs-wiki violations \(see the handbook docs-wiki page\):'
            $r.Output | Should -Not -Match 'Why: graph advisory'
            $r.Output | Should -Not -Match 'Why: Wiki graph'
        }

        It 'does not raise a note that names no file as if it were a finding' {
            $gate = New-FindingGate -Root $script:Root -Lines @(
                '  graph advisory: docs/adrs/0030-thing.md : no outbound cross-link'
                'Docs-wiki violations:'
                "  docs/page.md : broken relative link -> 'gone.md'"
                'Checked 141 wiki page(s); 1 violation(s).'
            )

            $r = Invoke-Wrapper -Gate $gate -Mode 'Blocking'

            ([regex]::Matches($r.Output, '::error file=')).Count | Should -Be 1
            $r.Output | Should -Match '::error file=docs/page\.md'
        }

        It 'does not say the same line twice when the rule and the count are one line' {
            $gate = New-FindingGate -Root $script:Root -Lines @('AGENTS.md is too long: 192 lines, the limit is 150.')

            $r = Invoke-Wrapper -Gate $gate -Mode 'Blocking'

            ([regex]::Matches($r.Output, 'AGENTS\.md is too long')).Count | Should -Be 2
        }

        It 'gives an exit-2 reason the headline, not the tail of a wrapped sentence' {
            $gate = New-FindingGate -ExitCode 2 -Root $script:Root -Lines @(
                'Story back-edges could not be checked: not one of the 27 stories could be read from the tracker.'
                '  Every one failing the same way points at the credentials rather than at the stories.'
                '  stories: #1, #2'
            )

            $r = Invoke-Wrapper -Gate $gate -Mode 'Advisory'

            $r.Output | Should -Match 'Why: Story back-edges could not be checked: not one of the 27 stories'
            $r.Output | Should -Not -Match 'Why: stories: #1'
            $r.Output | Should -Match 'COULD NOT BE CHECKED'
        }

        It 'lifts the gate FIX line into the annotation, so the reader is told what to do' {
            $gate = New-FindingGate -Root $script:Root -Lines @(
                'Doc house-style violation: no em-dash is allowed.'
                '  docs/page.md:12  This sentence has one.'
                'FIX: Replace each em-dash with a spaced hyphen.'
                'Found 1 line(s) containing an em-dash.'
            )

            $r = Invoke-Wrapper -Gate $gate -Mode 'Blocking'

            $r.Output | Should -Match 'Fix: Replace each em-dash with a spaced hyphen\.'
        }

        It 'keeps the FIX line out of the rule, the count and the findings' {
            $gate = New-FindingGate -Root $script:Root -Lines @(
                'Doc house-style violation: no em-dash is allowed.'
                '  docs/page.md:12  This sentence has one.'
                'Found 1 line(s) containing an em-dash.'
                'FIX: Replace each em-dash with a spaced hyphen.'
            )

            $r = Invoke-Wrapper -Gate $gate -Mode 'Blocking'

            $r.Output | Should -Match 'Why: Doc house-style violation: no em-dash is allowed\.'
            $r.Output | Should -Match 'Found 1 line\(s\) containing an em-dash\.'
            $r.Output | Should -Not -Match 'Why: FIX:'
            ([regex]::Matches($r.Output, '::error file=')).Count | Should -Be 1
        }

        It 'says nothing about a fix when the gate offered none, rather than inventing one' {
            $gate = New-FindingGate -Root $script:Root -Lines @(
                'Rule broken.'
                '  docs/page.md:12  one.'
                'Found 1.'
            )

            $r = Invoke-Wrapper -Gate $gate -Mode 'Blocking'

            $r.Output | Should -Not -Match 'Fix:'
        }

        It 'carries the fix into a could-not-check warning too' {
            $gate = New-FindingGate -ExitCode 2 -Root $script:Root -Lines @(
                'Story back-edges could not be checked: GitHub answered 401.'
                'FIX: Give the workflow a GH_TOKEN that can read issues.'
            )

            $r = Invoke-Wrapper -Gate $gate -Mode 'Advisory'

            $r.Output | Should -Match 'COULD NOT BE CHECKED'
            $r.Output | Should -Match 'Fix: Give the workflow a GH_TOKEN that can read issues\.'
            $r.Output | Should -Not -Match 'Nobody on this pull request can fix it'
        }

        It 'keeps a long finding readable instead of printing a wall' {
            $long = '  docs/page.md:12  ' + ('word ' * 200)
            $gate = New-FindingGate -Root $script:Root -Lines @('Rule broken.', $long, 'Found 1.')

            $r = Invoke-Wrapper -Gate $gate -Mode 'Blocking'

            $issue = (@($r.Output -split "`n" | Where-Object { $_ -match '::error file=docs/page\.md' })[0]).Trim()
            $issue.Length | Should -BeLessThan 500
            $issue | Should -Match '\.\.\.$'
        }

        It 'does not take an indented note as a finding when a real one is there' {
            $gate = New-FindingGate -Root $script:Root -Lines @(
                'Reading level: prose must read at B2 and B1.'
                '  docs/page.md:80  [hard-word]  require'
                '  Per file (long sentences / hard words):'
                '  Most frequent hard words (top 40):'
                'Found 1 hard word(s).'
            )

            $r = Invoke-Wrapper -Gate $gate -Mode 'Blocking'

            ([regex]::Matches($r.Output, '::error file=')).Count | Should -Be 1
            $r.Output | Should -Match 'hard-word.*require'
        }
    }

    It 'passes through named args and switches to the gate by name' {
        $gate = Join-Path $script:Root 'ArgGate.ps1'
        Set-Content -LiteralPath $gate -Value @'
param([string]$RepoRoot, [switch]$Check)
Write-Host "ROOT=[$RepoRoot] CHECK=[$Check]"
exit 0
'@ -NoNewline
        $out = & $script:ScriptUnderTest -Script $gate -Clause 'C99' -What 'passthrough' -Mode 'Blocking' -RepoRoot 'C:\some\path' -Check *>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'ROOT=\[C:\\some\\path\]'
        $out | Should -Match 'CHECK=\[True\]'
        $out | Should -Not -Match 'positional parameter cannot be found'
    }
}
