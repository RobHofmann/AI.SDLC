#requires -Version 7.4

BeforeAll { $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm' }

Describe 'Check-DocEmDashes' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'DocToolTestHarness.psm1') -Force
        $script:ScriptUnderTest = Join-Path -Path $script:ScriptFolder -ChildPath 'Check-DocEmDashes.ps1'

        function Invoke-Gate {
            param([Parameter(Mandatory)][string]$RepoRoot)
            $out = & $script:ScriptUnderTest -RepoRoot $RepoRoot *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }
    }

    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'docs') -Force | Out-Null
        Set-AiSdlcTestConfig -Root $script:Root
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'docs-functional') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Root 'AGENTS.md') -Value "# Agents`nClean content with a spaced hyphen - like this.`n" -NoNewline
    }

    It 'passes when no em-dash is present (exit 0)' {
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nPlain prose, commas, and parentheses only.`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Em-dash OK'
    }

    It 'fails when a doc contains an em-dash (exit 1)' {
        $emDash = [char]0x2014
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nThis sentence $emDash has an em-dash.`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'em-dash'
    }

    It 'fails when AGENTS.md contains an em-dash (exit 1)' {
        $emDash = [char]0x2014
        Set-Content -LiteralPath (Join-Path $script:Root 'AGENTS.md') -Value "# Agents`nBroken $emDash here.`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 1
    }

    It 'fails when docs-functional/ contains an em-dash (exit 1)' {
        $emDash = [char]0x2014
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nClean prose only.`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $script:Root 'docs-functional/behaviour.md') -Value "# Behaviour`nThis $emDash is functional.`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'em-dash'
    }

    It 'reports the count when more than one em-dash line is found (exit 1)' {
        $emDash = [char]0x2014
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nFirst $emDash offending line.`nSecond $emDash offending line.`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Found 2 line\(s\) containing an em-dash\.'
    }

    It 'scans .markdown files as well as .md (exit 1)' {
        $emDash = [char]0x2014
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nClean prose only.`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/legacy.markdown') -Value "# Legacy`nThis $emDash is in a .markdown file.`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'em-dash'
    }

    It 'does not flag a spaced hyphen or hyphen-minus (exit 0)' {
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nThis uses a spaced hyphen - and a hyphen-minus, not an em-dash.`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Em-dash OK'
    }

    Context 'HTML codes that draw the em-dash' {
        It 'fails on <Code> (exit 1)' -ForEach @(
            @{ Code = '&mdash;' }
            @{ Code = '&#8212;' }
            @{ Code = '&#008212;' }
            @{ Code = '&#x2014;' }
            @{ Code = '&#X2014;' }
            @{ Code = '&#x002014;' }
        ) {
            Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nThis $Code is a code.`n" -NoNewline
            $r = Invoke-Gate -RepoRoot $script:Root
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'docs/page\.md:2'
        }

        It 'does not flag <Code> (exit 0)' -ForEach @(
            @{ Code = '&ndash;' }
            @{ Code = '&#8211;' }
            @{ Code = '&#x2013;' }
            @{ Code = '&#82120;' }
        ) {
            Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nThis $Code is fine.`n" -NoNewline
            $r = Invoke-Gate -RepoRoot $script:Root
            $r.ExitCode | Should -Be 0
        }
    }

    Context 'nothing to read' {
        It 'exits 3 when -Path names a folder with no markdown page' {
            New-Item -ItemType Directory -Path (Join-Path $script:Root 'empty') -Force | Out-Null
            $out = & $script:ScriptUnderTest -RepoRoot $script:Root -Path 'empty' *>&1 | Out-String
            $LASTEXITCODE | Should -Be 3
            $out | Should -Match 'Not applicable: no page to read in empty, so there is no em-dash to look for\.'
        }

        It 'exits 3 when there is no AGENTS.md and the doc layers hold no page' {
            Remove-Item -LiteralPath (Join-Path $script:Root 'AGENTS.md')
            $out = & $script:ScriptUnderTest -RepoRoot $script:Root *>&1 | Out-String
            $LASTEXITCODE | Should -Be 3
            $out | Should -Match 'Not applicable: no page to read'
        }
    }

    Context '-Path' {
        BeforeEach {
            $script:EmDash = [char]0x2014
            New-Item -ItemType Directory -Path (Join-Path $script:Root 'packs' 'skill') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nThis $($script:EmDash) is outside the given paths.`n" -NoNewline
        }

        It 'reads only the given folders and files, not the doc layers (exit 0)' {
            Set-Content -LiteralPath (Join-Path $script:Root 'packs' 'skill' 'SKILL.md') -Value "# Skill`nClean prose only.`n" -NoNewline
            Set-Content -LiteralPath (Join-Path $script:Root 'README.md') -Value "# Readme`nClean.`n" -NoNewline
            $out = & $script:ScriptUnderTest -RepoRoot $script:Root -Path 'packs,README.md' *>&1 | Out-String
            $LASTEXITCODE | Should -Be 0
            $out | Should -Match 'Em-dash OK: no em-dash \(U\+2014\) characters in packs, README\.md'
        }

        It 'fails on an em-dash in a file under a given folder (exit 1)' {
            Set-Content -LiteralPath (Join-Path $script:Root 'packs' 'skill' 'SKILL.md') -Value "# Skill`nBroken $($script:EmDash) here.`n" -NoNewline
            $out = & $script:ScriptUnderTest -RepoRoot $script:Root -Path 'packs' *>&1 | Out-String
            $LASTEXITCODE | Should -Be 1
            $out | Should -Match 'packs/skill/SKILL\.md:2'
        }

        It 'could not check when a given path does not exist (exit 2)' {
            $out = & $script:ScriptUnderTest -RepoRoot $script:Root -Path 'packs,missing' *>&1 | Out-String
            $LASTEXITCODE | Should -Be 2
            $out | Should -Match 'Could not check: the path\(s\) missing do not exist'
        }
    }
}
