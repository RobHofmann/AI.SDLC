#requires -Version 7.4

Describe 'Get-FolderFacts' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Get-FolderFacts.ps1'

        function New-FolderRepo {
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('gff-' + [guid]::NewGuid().ToString('n'))
            $files = @{
                'aisdlc.json'                                  = '{}'
                'packs/demo/.apm/skills/demo-rules/SKILL.md'   = "---`nname: demo-rules`ndescription: >`n  How demo things are written.`n  Use when writing one.`n---`n# Demo rules`n"
                'packs/demo/.apm/agents/checker.agent.md'      = "---`nname: checker`ndescription: Checks a demo change.`n---`n"
                'packs/demo/.apm/skills/demo-rules/gates.json' = '{ "package": "demo", "gates": [ { "name": "Demo gate", "script": "scripts/Check-Demo.ps1", "mode": "Blocking" } ] }'
                'packs/demo/.apm/skills/demo-rules/scripts/Check-Demo.ps1'       = "<#`n.SYNOPSIS`n    Gate: every demo has a name.`n#>`n"
                'packs/demo/.apm/skills/demo-rules/scripts/Check-Demo.Tests.ps1' = "Describe 'x' { }"
                'packs/demo/.apm/skills/demo-rules/references/rules.md'          = "# The demo rules`n"
                'packs/demo/apm.yml'                           = 'name: demo'
            }
            foreach ($rel in $files.Keys) {
                $full = Join-Path $root $rel
                New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
                Set-Content -LiteralPath $full -Value $files[$rel] -Encoding utf8
            }
            return $root
        }
    }

    AfterAll {
        Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'gff-*' -Directory -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'reads each skill and agent with the description from its front matter, a folded one included' {
        $text = (& $script:ScriptUnderTest -Unit 'packs/demo' -RepoRoot (New-FolderRepo)) -join "`n"

        $text | Should -Match 'skill demo-rules: How demo things are written\. Use when writing one\.'
        $text | Should -Match 'agent checker: Checks a demo change\.'
    }

    It 'reads the synopsis of a script, the gates of a package and the H1 of a page' {
        $text = (& $script:ScriptUnderTest -Unit 'packs/demo' -RepoRoot (New-FolderRepo)) -join "`n"

        $text | Should -Match 'Check-Demo.ps1 - Gate: every demo has a name\.'
        $text | Should -Match 'Blocking gate: Demo gate'
        $text | Should -Match 'rules.md - The demo rules'
        $text | Should -Match 'file: packs/demo/apm.yml'
    }

    It 'lists a test file as a test and reads nothing from it' {
        $text = (& $script:ScriptUnderTest -Unit 'packs/demo' -RepoRoot (New-FolderRepo)) -join "`n"

        $text | Should -Match 'test: packs/demo/.apm/skills/demo-rules/scripts/Check-Demo.Tests.ps1'
    }

    It 'caps the number of files it reads' {
        $text = (& $script:ScriptUnderTest -Unit 'packs/demo' -RepoRoot (New-FolderRepo) -MaximumFiles 2) -join "`n"

        $text | Should -Match 'and 5 more files, capped'
    }

    It 'refuses a unit that is not a folder in the repository' {
        { & $script:ScriptUnderTest -Unit 'packs/gone' -RepoRoot (New-FolderRepo) } | Should -Throw '*is not a folder*'
    }
}
