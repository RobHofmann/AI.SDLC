#requires -Version 7.4

Describe 'Check-PrHygiene' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Check-PrHygiene.ps1'

        $script:GoodBody = 'This change adds the billing cost centre field to the order form and its validation.'

        $script:Root = Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Root 'aisdlc.json') -Value '{}' -Encoding utf8

        function Invoke-Gate {
            param([hashtable]$Extra = @{})
            $out = & $script:ScriptUnderTest -RepoRoot $script:Root @Extra *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }
    }

    Context 'when there is no pull request' {
        It 'passes and says so, so a local gate run does not trip on it' {
            $r = Invoke-Gate

            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'no pull request context'
        }
    }

    Context 'the story key, which may be in any of three places' {
        It 'accepts a key in the source branch alone' {
            $r = Invoke-Gate -Extra @{ SourceBranch = 'refs/heads/2891-add-field'; PrTitle = 'Add a field'; PrDescription = $script:GoodBody }

            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'the story key is in the source branch'
        }

        It 'accepts a key in the title alone' {
            $r = Invoke-Gate -Extra @{ SourceBranch = 'refs/heads/feature/x'; PrTitle = 'Add a field (#2891)'; PrDescription = $script:GoodBody }

            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'the story key is in the title'
        }

        It 'accepts a key in the description alone' {
            $r = Invoke-Gate -Extra @{ SourceBranch = 'refs/heads/feature/x'; PrTitle = 'Add a field'; PrDescription = "Fixes #2891. $script:GoodBody" }

            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'the story key is in the description'
        }

        It 'fails when no place carries a key' {
            $r = Invoke-Gate -Extra @{ SourceBranch = 'refs/heads/feature/x'; PrTitle = 'Add a field'; PrDescription = $script:GoodBody }

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'STORY: no story key \(#42\)'
        }

        It 'names the key of this repository, and no page of another repository, in its messages' {
            $other = Join-Path $TestDrive 'other'
            New-Item -ItemType Directory -Path $other -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $other 'aisdlc.json') -Value '{ "tracker": { "keyPattern": "PROJ-[0-9]+" } }' -Encoding utf8

            $out = & $script:ScriptUnderTest -RepoRoot $other -SourceBranch 'refs/heads/feature/x' -PrTitle 'Add a field' -PrDescription '' *>&1 | Out-String

            $out | Should -Match 'STORY: no story key \(tracker.keyPattern\)'
            $out | Should -Not -Match '#42\)'
            $out | Should -Not -Match 'docs/work-instructions'
        }

        It 'does not read a key out of a larger token' {
            $r = Invoke-Gate -Extra @{ SourceBranch = 'refs/heads/feature/x2891-y'; PrTitle = 'Add a field'; PrDescription = $script:GoodBody }

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'STORY: no story key \(#42\)'
        }
    }

    Context 'the description, which is free text but must be there' {
        It 'fails on an empty description' {
            $r = Invoke-Gate -Extra @{ SourceBranch = '2891-add-field'; PrTitle = 'Add a field'; PrDescription = '' }

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'DESCRIPTION: empty'
        }

        It 'fails when the description is only the title again' {
            $r = Invoke-Gate -Extra @{ SourceBranch = '2891-add-field'; PrTitle = 'Add the billing cost centre field (#2891)'; PrDescription = 'Add the billing cost centre field (#2891)' }

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'the same text as the title'
        }

        It 'fails on the shape a cut-off description has' {
            $r = Invoke-Gate -Extra @{ SourceBranch = '2891-add-field'; PrTitle = 'Add a field'; PrDescription = '## Summary' }

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'under the 40 this gate accepts'
        }

        It 'accepts free text with no heading and no sections' {
            $r = Invoke-Gate -Extra @{ SourceBranch = '2891-add-field'; PrTitle = 'Add a field'; PrDescription = $script:GoodBody }

            $r.ExitCode | Should -Be 0
            $r.Output | Should -Not -Match 'Summary'
        }

        It 'takes the shortest accepted length from a parameter' {
            $r = Invoke-Gate -Extra @{ SourceBranch = '2891-add-field'; PrTitle = 'Add a field'; PrDescription = 'Short but allowed here.'; MinDescription = 10 }

            $r.ExitCode | Should -Be 0
        }
    }

    Context 'when the pull request could not be read' {
        It 'reports could-not-check rather than a violation (exit 2)' {
            $r = Invoke-Gate -Extra @{ PrId = '17' }

            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match 'could not be checked'
            $r.Output | Should -Match 'request 17 '
        }
    }

    Context 'reporting' {
        It 'names both findings when both fail, so one fix does not hide the other' {
            $r = Invoke-Gate -Extra @{ SourceBranch = 'refs/heads/feature/x'; PrTitle = 'Add a field'; PrDescription = '' }

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'STORY'
            $r.Output | Should -Match 'DESCRIPTION'
            $r.Output | Should -Match 'failed on 2 point\(s\)'
        }

        It 'reads its inputs from the environment when no parameter is passed' {
            try {
                $env:PR_SOURCE_BRANCH = 'refs/heads/feature/2891-add-field'
                $env:PR_TITLE = 'Add a field'
                $env:PR_DESCRIPTION = $script:GoodBody

                $out = & $script:ScriptUnderTest *>&1 | Out-String

                $LASTEXITCODE | Should -Be 0
                $out | Should -Match 'PR hygiene OK'
            }
            finally {
                $env:PR_SOURCE_BRANCH = $null
                $env:PR_TITLE = $null
                $env:PR_DESCRIPTION = $null
            }
        }
    }
}
