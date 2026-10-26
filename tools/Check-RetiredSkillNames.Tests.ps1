#requires -Version 7.4

Describe 'Check-RetiredSkillNames' {
    BeforeAll {
        $script:Gate = Join-Path $PSScriptRoot 'Check-RetiredSkillNames.ps1'
        Import-Module (Join-Path $PSScriptRoot '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' 'DocToolTestHarness.psm1') -Force

        function New-SharedRepo {
            param([hashtable]$Files, [string]$Retired = "# Demo release`nold-skill new-skill`n")
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path (Join-Path $root 'config') -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $root 'config' 'retired-skill-names.txt'), $Retired, [Text.UTF8Encoding]::new($false))
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

    It 'fails on an old name in backticks, and names the file, the line and the new name' {
        $root = New-SharedRepo -Files @{ 'core/.apm/skills/x/SKILL.md' = "# X`nThen run ``old-skill``.`n" }
        $r = Invoke-Gate -Root $root
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'core/\.apm/skills/x/SKILL\.md:2  old-skill -> new-skill'
        $r.Output | Should -Match 'FIX: '
    }

    It 'fails on an old name as a slash command, in a link, and in plain text' {
        $root = New-SharedRepo -Files @{
            'packs/github-issues/.apm/skills/y/SKILL.md' = "Run /old-skill first.`n"
            'docs/page.md'                      = "See [it](/.claude/skills/old-skill/SKILL.md).`n"
            'README.md'                         = "the old-skill step`n"
        }
        $r = Invoke-Gate -Root $root
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'packs/github-issues/\.apm/skills/y/SKILL\.md:1'
        $r.Output | Should -Match 'docs/page\.md:1'
        $r.Output | Should -Match 'README\.md:1'
    }

    It 'fails on an old skill folder in an allow rule of the repository settings' {
        $root = New-SharedRepo -Files @{ '.claude/settings.json' = "{`n  `"allow`": [`"Bash(pwsh .claude/skills/old-skill/scripts/Run.ps1*)`"]`n}`n" }
        $r = Invoke-Gate -Root $root
        $r.Code | Should -Be 1
        $r.Output | Should -Match '\.claude/settings\.json:2  old-skill -> new-skill'
    }

    It 'passes on a longer name that holds an old name, and on the new name' {
        $root = New-SharedRepo -Files @{ 'core/x.md' = "old-skill-extra, pre-old-skill and ``new-skill`` are fine.`n" }
        $r = Invoke-Gate -Root $root
        $r.Code | Should -Be 0 -Because $r.Output
    }

    It 'fails on an old name written with spaces in a Markdown heading, in any case' {
        $root = New-SharedRepo -Files @{ 'core/.apm/skills/x/SKILL.md' = "---`nname: new-skill`n---`n`n# Old Skill (the loop)`n" }
        $r = Invoke-Gate -Root $root
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'core/\.apm/skills/x/SKILL\.md:5  Old Skill -> new-skill'
    }

    It 'passes on an old name written with spaces in a normal sentence' {
        $root = New-SharedRepo -Files @{ 'core/x.md' = "# New skill`n`nThis step can old skill the code.`n" }
        $r = Invoke-Gate -Root $root
        $r.Code | Should -Be 0 -Because $r.Output
    }

    It 'skips the sync manifest and CHANGELOG.md, which hold the old names on purpose' {
        $root = New-SharedRepo -Files @{
            'core/.apm/skills/ai-sdlc-gates/sync-manifest.json' = "{ ""retired"": { ""old-skill"": ""new-skill"" } }`n"
            'CHANGELOG.md'                                      = "- ``old-skill`` is now ``new-skill``.`n"
        }
        $r = Invoke-Gate -Root $root
        $r.Code | Should -Be 0 -Because $r.Output
    }

    It 'says it could not check when the retired list is missing or malformed, and passes when it holds no names' {
        $root = New-SharedRepo -Files @{ 'core/x.md' = "text`n" }
        Remove-Item -LiteralPath (Join-Path $root 'config' 'retired-skill-names.txt')
        (Invoke-Gate -Root $root).Code | Should -Be 2

        $root = New-SharedRepo -Files @{ 'core/x.md' = "text`n" } -Retired "# nothing`n"
        (Invoke-Gate -Root $root).Code | Should -Be 0

        $root = New-SharedRepo -Files @{ 'core/x.md' = "text`n" } -Retired "old-skill`n"
        (Invoke-Gate -Root $root).Code | Should -Be 2
    }
}
