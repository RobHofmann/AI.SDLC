#requires -Version 7.4

Describe 'Check-ClosingKeywordExamples' {
    BeforeAll {
        $script:Gate = Join-Path $PSScriptRoot 'Check-ClosingKeywordExamples.ps1'
        Import-Module (Join-Path $PSScriptRoot '..' 'core' 'tests' 'skills' 'ai-sdlc-gates' 'scripts' 'DocToolTestHarness.psm1') -Force

        # The bad form is built from parts, so this file never holds it whole.
        $script:Hash = '#'

        function New-SharedRepo {
            param([hashtable]$Files)
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            foreach ($rel in $Files.Keys) {
                $full = Join-Path $root $rel
                New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
                [IO.File]::WriteAllText($full, $Files[$rel], [Text.UTF8Encoding]::new($false))
            }
            return $root
        }

        function Invoke-Gate {
            param([string]$Root)
            $run = Invoke-ScriptInProcess -Path $script:Gate -Arguments @('-RepoRoot', $Root)
            return [pscustomobject]@{ Code = $run.ExitCode; Output = $run.Output }
        }
    }

    It 'fails on a closing keyword with a number, and names the file, the line and the fix' {
        $root = New-SharedRepo -Files @{ 'core/.apm/skills/x/SKILL.md' = "# X`nThe body says ``Fixes $($script:Hash)42``.`n" }
        $r = Invoke-Gate -Root $root
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'core/\.apm/skills/x/SKILL\.md:2'
        $r.Output | Should -Match 'FIX: .*#n'
    }

    It 'fails on <Keyword>, in any case and with a colon' -ForEach @(
        @{ Keyword = 'close' }, @{ Keyword = 'Closes' }, @{ Keyword = 'closed' },
        @{ Keyword = 'fix' }, @{ Keyword = 'FIXES' }, @{ Keyword = 'fixed:' },
        @{ Keyword = 'resolve' }, @{ Keyword = 'Resolves' }, @{ Keyword = 'resolved' }
    ) {
        $root = New-SharedRepo -Files @{ 'docs/page.md' = "Then write $Keyword $($script:Hash)7 in the body.`n" }
        (Invoke-Gate -Root $root).Code | Should -Be 1
    }

    It 'fails in a script, in a shared tools file and in the root pages' {
        $root = New-SharedRepo -Files @{
            'packs/github/.apm/skills/y/scripts/Run.ps1' = "Write-Output 'Put (Fixes $($script:Hash)1234) in the body.'`n"
            'tools/templates/body.md'                     = "Resolves $($script:Hash)3`n"
            '.github/pull_request_template.md'            = "Closes $($script:Hash)8`n"
            'README.md'                                   = "Its pull request says Closes $($script:Hash)12.`n"
            'AGENTS.md'                                   = "fix $($script:Hash)5`n"
        }
        $r = Invoke-Gate -Root $root
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'packs/github/\.apm/skills/y/scripts/Run\.ps1:1'
        $r.Output | Should -Match 'tools/templates/body\.md:1'
        $r.Output | Should -Match '\.github/pull_request_template\.md:1'
        $r.Output | Should -Match 'README\.md:1'
        $r.Output | Should -Match 'AGENTS\.md:1'
    }

    It 'passes on the placeholder, a bare mention, another keyword, a branch name and a word that holds a keyword' {
        $text = @(
            'The body says `Fixes #n`, then `Closes #n`.'
            "See $($script:Hash)42 for the epic, and Refs $($script:Hash)42 in an update."
            'The branch is 42-short-name.'
            "A prefix $($script:Hash)42 and suffixes $($script:Hash)42 stay."
            "The bugfixes $($script:Hash)42 list."
        ) -join "`n"
        $root = New-SharedRepo -Files @{ 'core/x.md' = $text }
        $r = Invoke-Gate -Root $root
        $r.Code | Should -Be 0 -Because ($r.Output -join "`n")
    }

    It 'skips the CHANGELOG, the sync manifest and every test file' {
        $bad = "Fixes $($script:Hash)42`n"
        $root = New-SharedRepo -Files @{
            'CHANGELOG.md'                                                   = $bad
            'core/.apm/skills/ai-sdlc-gates/sync-manifest.json'              = $bad
            'core/tests/skills/ai-sdlc-gates/scripts/X.Tests.ps1'            = $bad
            'packs/github/tests/skills/y/scripts/Helper.psm1'                = $bad
            'tools/Y.Tests.ps1'                                              = $bad
            'core/.apm/skills/x/SKILL.md'                                    = "Fine.`n"
        }
        $r = Invoke-Gate -Root $root
        $r.Code | Should -Be 0 -Because ($r.Output -join "`n")
    }

    It 'exits 3 when no file is left to read' {
        $root = New-SharedRepo -Files @{ 'CHANGELOG.md' = "Fixes $($script:Hash)42`n" }
        (Invoke-Gate -Root $root).Code | Should -Be 3
    }

    It 'passes on the shared files of this repository' {
        $repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $r = Invoke-Gate -Root $repo
        $r.Code | Should -Be 0 -Because ($r.Output -join "`n")
    }
}
