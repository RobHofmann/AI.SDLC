#requires -Version 7.4

BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
    $repo = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot
    $script:NotInstalled = -not ($repo -and (Test-Path -LiteralPath (Join-Path $repo 'aisdlc.json')))
}


Describe 'Check-AgentsFileSize' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
        Import-Module (Join-Path $PSScriptRoot 'DocToolTestHarness.psm1') -Force
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Check-AgentsFileSize.ps1'

        function Invoke-Gate {
            param([Parameter(Mandatory)][string]$RepoRoot, [hashtable]$Extra = @{})
            $out = & $script:ScriptUnderTest -RepoRoot $RepoRoot @Extra *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }

        function Set-Agents {
            param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines)
            Set-Content -LiteralPath (Join-Path $RepoRoot 'AGENTS.md') -Value ($Lines -join "`n") -NoNewline -Encoding utf8
        }
    }

    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        Set-AiSdlcTestConfig -Root $script:Root
    }

    It 'passes a file within both limits and reports the counts' {
        Set-Agents -RepoRoot $script:Root -Lines @('# Agents', '', 'One short rule.', 'Another short rule.')

        $r = Invoke-Gate -RepoRoot $script:Root

        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'AGENTS.md size OK: 4 lines, 8 words'
    }

    It 'fails a file with more lines than the limit, blank lines included' {
        Set-Agents -RepoRoot $script:Root -Lines @(1..6 | ForEach-Object { if ($_ % 2 -eq 0) { '' } else { 'rule' } })

        $r = Invoke-Gate -RepoRoot $script:Root -Extra @{ MaxLines = 4; MaxWords = 1000 }

        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match '5 lines, the limit is 4'
    }

    It 'fails a file that keeps under the line limit by writing long lines' {
        Set-Agents -RepoRoot $script:Root -Lines @(('word ' * 30).Trim(), ('word ' * 30).Trim())

        $r = Invoke-Gate -RepoRoot $script:Root -Extra @{ MaxLines = 150; MaxWords = 50 }

        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match '60 words, the limit is 50'
        $r.Output | Should -Match 'FIX: Move the detail'
    }

    It 'checks the file that paths.agentsFile names, not a fixed AGENTS.md' {
        Set-AiSdlcTestConfig -Root $script:Root -Paths @{ agentsFile = 'docs/AGENTS.md' }
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'docs') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Root 'docs' 'AGENTS.md') -Value "# Agents`nOne line." -NoNewline -Encoding utf8

        $r = Invoke-Gate -RepoRoot $script:Root

        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'size OK: 2 lines'
    }

    It 'reports that it could not check when AGENTS.md is missing (exit 2)' {
        $r = Invoke-Gate -RepoRoot $script:Root

        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'could not be checked'
    }

    It 'holds the real AGENTS.md within the default limits' -Skip:$script:NotInstalled {
        $repo = (Find-AiSdlcRepoRoot -StartPath $PSScriptRoot)

        $r = Invoke-Gate -RepoRoot $repo

        $r.ExitCode | Should -Be 0
    }
}
