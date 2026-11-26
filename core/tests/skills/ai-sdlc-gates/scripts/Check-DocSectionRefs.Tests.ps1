#requires -Version 7.4

Describe 'Check-DocSectionRefs' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
        Import-Module (Join-Path $PSScriptRoot 'DocToolTestHarness.psm1') -Force
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Check-DocSectionRefs.ps1'

        function Invoke-Gate {
            param([string]$RepoRoot = $script:Root, [hashtable]$Extra = @{})
            $out = & $script:ScriptUnderTest -RepoRoot $RepoRoot @Extra *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }

        function Set-Page {
            param([Parameter(Mandatory)][string]$Relative, [Parameter(Mandatory)][string]$Text)
            $full = Join-Path $script:Root $Relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
            Set-Content -LiteralPath $full -Value $Text -Encoding utf8
        }
    }

    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'docs') -Force | Out-Null
        Set-AiSdlcTestConfig -Root $script:Root
        Set-Page -Relative 'docs/target.md' -Text "# Target`n`n## Test Style`n`nHow tests are written.`n`n## The updater's credentials`n`nHow it signs in.`n"
    }

    It 'reads .claude/CLAUDE.md, where a repository keeps its Claude-only notes' {
        Set-Page -Relative '.claude/CLAUDE.md' -Text 'See the `## Testing Style` section of `docs/target.md`.'

        $r = Invoke-Gate

        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match "names the section 'Testing Style'"
    }

    Context 'the backticked shape' {
        It 'passes when the heading is there' {
            Set-Page -Relative 'docs/source.md' -Text 'See the `## Test Style` section of `target.md`.'

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'Section references OK'
        }

        It 'fails when the heading was renamed' {
            Set-Page -Relative 'docs/source.md' -Text 'See the `## Testing Style` section of `target.md`.'

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match "names the section 'Testing Style' of docs/target.md"
        }

        It 'lists the headings the target does have with -Detail' {
            Set-Page -Relative 'docs/source.md' -Text 'See the `## Testing Style` section of `target.md`.'

            $r = Invoke-Gate -Extra @{ Detail = $true }

            $r.Output | Should -Match 'headings it does have.*Test Style'
        }
    }

    Context 'the bare shape' {
        It 'passes when the heading is there' {
            Set-Page -Relative 'docs/source.md' -Text 'Keep the exact facts. See the Test Style section in `target.md`.'

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 0
        }

        It 'does not take the prose in front of it as the section name' {
            Set-Page -Relative 'docs/source.md' -Text 'Keep the exact facts, names, and numbers. See the Test Style section in `target.md`.'

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 0
            $r.Output | Should -Not -Match 'exact facts'
        }

        It 'fails when the heading is gone' {
            Set-Page -Relative 'docs/source.md' -Text 'See the Validation status section of `target.md`.'

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match "names the section 'Validation status'"
        }
    }

    Context 'the quoted shape, which is weaker on purpose' {
        It 'passes when the quoted text appears anywhere in the target' {
            Set-Page -Relative 'docs/source.md' -Text 'Follow `target.md`, "How tests are written".'

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 0
        }

        It 'fails on a single character of drift, which is what a rename looks like' {
            Set-Page -Relative 'docs/source.md' -Text 'See `target.md`, "The updater credentials".'

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'quotes "The updater credentials"'
        }

        It 'reads the bracketed form too' {
            Set-Page -Relative 'docs/source.md' -Text 'See `target.md` ("No Such Section").'

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 1
        }
    }

    Context 'a link anchor' {
        It 'passes when a heading makes that anchor' {
            Set-Page -Relative 'docs/source.md' -Text '[how](target.md#test-style) explains it.'

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 0
        }

        It 'fails when no heading makes that anchor' {
            Set-Page -Relative 'docs/source.md' -Text '[how](target.md#testing-style) explains it.'

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'links to docs/target.md#testing-style'
        }

        It 'drops punctuation from a heading the way an anchor does' {
            Set-Page -Relative 'docs/source.md' -Text '[how](target.md#the-updaters-credentials) explains it.'

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 0
        }
    }

    Context 'what it leaves alone' {
        It 'says nothing about a file it cannot resolve to exactly one page' {
            Set-Page -Relative 'docs/source.md' -Text 'See the Test Style section of `nowhere.md`.'

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 0
        }

        It 'ignores a heading inside a fenced code block, which is a comment and not a heading' {
            Set-Page -Relative 'docs/fenced.md' -Text "# Fenced`n`n``````text`n## Test Style`n``````;`n"
            Set-Page -Relative 'docs/source.md' -Text 'See the `## Test Style` section of `fenced.md`.'

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 1
        }

        It 'reads a PowerShell help block as well as a page, since that is where the real bug was' {
            Set-Page -Relative 'Demo/tools/Thing.ps1' -Text "<#`n.SYNOPSIS`nSee docs/target.md, `"The updater credentials`".`n#>`n"

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'Demo/tools/Thing.ps1'
        }

        It 'reads a doubled apostrophe in PowerShell source as the one the heading has' {
            Set-Page -Relative 'Demo/tools/Thing.ps1' -Text "Write-Host 'See docs/target.md, `"The updater''s credentials`".'"

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 0
        }

        It 'does not undo the doubling in a markdown page, where it is two apostrophes' {
            $apostrophes = [string][char]39 + [char]39
            Set-Page -Relative 'docs/source.md' -Text ('See `target.md`, "The updater{0}s credentials".' -f $apostrophes)

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 1
        }

        It 'throws when -Path names something that is not there, rather than passing on an empty scan' {
            { & $script:ScriptUnderTest -RepoRoot $script:Root -Path 'docs/gone' } |
                Should -Throw -ExpectedMessage '*does not exist*'
        }
    }

    Context 'a decision record a script names' {
        It 'fails when a script help block names a decision record that is not there' {
            Set-Page -Relative 'Demo/tools/Thing.ps1' -Text "<#`n.SYNOPSIS`nWhy: docs/adrs/0007-gone.md.`n#>`n"

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'Demo/tools/Thing.ps1:3'
            $r.Output | Should -Match 'names the decision record docs/adrs/0007-gone.md, which does not exist'
        }

        It 'passes when the decision record is there' {
            Set-Page -Relative 'docs/adrs/0007-kept.md' -Text "# 0007 Kept`n"
            Set-Page -Relative 'Demo/pipelines/deploy.yml' -Text "# Why: docs/adrs/0007-kept.md`n"

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 0
        }

        It 'leaves a decision record a page names to the wiki gate' {
            Set-Page -Relative 'docs/source.md' -Text "See docs/adrs/0007-gone.md.`n"

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 0
        }

        It 'skips a decision record in a test file, also when -Path names the folder' {
            Set-Page -Relative 'Demo/tools/Thing.Tests.ps1' -Text "It 'x' { 'docs/adrs/0007-gone.md' }`n"

            $r = Invoke-Gate -Extra @{ Path = 'Demo/tools' }

            $r.Output | Should -Not -Match '0007-gone'
        }

        It 'reads the decision record folder from aisdlc.json' {
            Set-AiSdlcTestConfig -Root $script:Root -Paths @{ adrFolder = 'decisions' }
            Set-Page -Relative 'Demo/tools/Thing.ps1' -Text "# docs/adrs/0007-gone.md is not the folder here; decisions/0008-gone.md is.`n"

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'decisions/0008-gone.md'
            $r.Output | Should -Not -Match 'docs/adrs/0007-gone.md, which'
        }
    }

    Context 'the repository it guards' {
        It 'is green on the real repository, so it carries no old debt' {
            $repo = (Find-AiSdlcRepoRoot -StartPath $PSScriptRoot)

            $r = Invoke-Gate -RepoRoot $repo

            $r.ExitCode | Should -Be 0
        }
    }

    Context 'Pester test files' {
        It 'skips a test file, whose fixtures hold pointers that break on purpose' {
            Set-Page -Relative 'docs/Check-Thing.Tests.ps1' -Text "It 'fails' { 'See the ``## Testing Style`` section of ``target.md``.' }"

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 0
        }

        It 'still reads a script that is not a test file' {
            Set-Page -Relative 'docs/Check-Thing.ps1' -Text "# See the ``## Testing Style`` section of ``target.md``."

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 1
        }
    }
}
