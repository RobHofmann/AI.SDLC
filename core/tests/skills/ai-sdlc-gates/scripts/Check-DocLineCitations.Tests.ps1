#requires -Version 7.4

Describe 'Check-DocLineCitations' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'DocToolTestHarness.psm1') -Force
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Check-DocLineCitations.ps1'

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
        Set-Content -LiteralPath (Join-Path $script:Root 'AGENTS.md') -Value "# Agents`nReference code by file path and symbol.`n" -NoNewline
    }

    It 'passes when no line-number citation is present (exit 0)' {
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nSee the EmailService class in Program.cs for details.`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'C02 OK'
    }

    It 'fails on a file.ext:NN citation (exit 1)' {
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nSee Program.cs:42 for the bug.`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'C02 violation'
    }

    It 'fails on a .py, .psm1, .toml and .yaml file-extension citation (exit 1)' {
        foreach ($cite in 'app.py:12', 'Tool.psm1:7', 'pyproject.toml:3', 'ci.yaml:9') {
            Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nSee $cite for the bug.`n" -NoNewline
            $r = Invoke-Gate -RepoRoot $script:Root
            $r.ExitCode | Should -Be 1 -Because $cite
        }
    }

    It 'fails on a "line NN" citation (exit 1)' {
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nThe handler is on line 88 of the file.`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 1
    }

    It 'allow-lists docs/constitution.md (exit 0 despite a citation)' {
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/constitution.md') -Value "# Constitution`nC02 forbids citing line 42 or Program.cs:42 style references.`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 0
    }

    It 'allow-lists docs/adrs/README.md (exit 0 despite a citation)' {
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'docs/adrs') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/adrs/README.md') -Value "# ADR index`nExample: do not cite line 42 or Program.cs:42 in docs.`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'C02 OK'
    }

    It 'fails on a "lines NN-MM" range citation (exit 1)' {
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nThe loop spans lines 88-92 of the handler.`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'C02 violation'
    }

    It 'fails on a .ts file-extension citation (exit 1)' {
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nSee app.component.ts:17 for the binding.`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'C02 violation'
    }

    It 'fails on a .ps1 file-extension citation (exit 1)' {
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nThe gate lives at Invoke-LocalGates.ps1:23.`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'C02 violation'
    }

    It 'fails on a .bicep file-extension citation (exit 1)' {
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nThe module is declared in main.bicep:5.`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'C02 violation'
    }

    It 'scans AGENTS.md and fails on a citation there (exit 1)' {
        Set-Content -LiteralPath (Join-Path $script:Root 'AGENTS.md') -Value "# Agents`nThe entry point is in Program.cs:10 of the API.`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nReference code by file path and symbol.`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'C02 violation'
        $r.Output | Should -Match 'AGENTS\.md'
    }

    It 'does not flag a path-like string without the file.ext:NN shape (exit 0)' {
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nSee https://dev.azure.com/contoso for the build and a 16:9 layout.`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'C02 OK'
    }

    Context '-Path' {
        BeforeEach {
            New-Item -ItemType Directory -Path (Join-Path $script:Root 'core' 'skill') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nSee Program.cs:42 for the bug.`n" -NoNewline
        }

        It 'reads only the given folders and files, not docs/ (exit 0)' {
            Set-Content -LiteralPath (Join-Path $script:Root 'core' 'skill' 'SKILL.md') -Value "# Skill`nReference code by file path and symbol.`n" -NoNewline
            Set-Content -LiteralPath (Join-Path $script:Root 'README.md') -Value "# Readme`nClean.`n" -NoNewline
            $out = & $script:ScriptUnderTest -RepoRoot $script:Root -Path 'core,README.md' *>&1 | Out-String
            $LASTEXITCODE | Should -Be 0
            $out | Should -Match 'C02 OK: no source line-number citations in core, README\.md'
        }

        It 'fails on a citation in a file under a given folder (exit 1)' {
            Set-Content -LiteralPath (Join-Path $script:Root 'core' 'skill' 'SKILL.md') -Value "# Skill`nThe gate lives at Invoke-LocalGates.ps1:23.`n" -NoNewline
            $out = & $script:ScriptUnderTest -RepoRoot $script:Root -Path 'core' *>&1 | Out-String
            $LASTEXITCODE | Should -Be 1
            $out | Should -Match 'core/skill/SKILL\.md:2'
        }

        It 'could not check when a given path does not exist (exit 2)' {
            $out = & $script:ScriptUnderTest -RepoRoot $script:Root -Path 'core,missing' *>&1 | Out-String
            $LASTEXITCODE | Should -Be 2
            $out | Should -Match 'Could not check: the path\(s\) missing do not exist'
        }
    }
}
