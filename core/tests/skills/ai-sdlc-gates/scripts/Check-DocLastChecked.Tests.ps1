#requires -Version 7.4

Describe 'Check-DocLastChecked' {
    BeforeAll {
        $script:Gate = Join-Path $PSScriptRoot 'Check-DocLastChecked.ps1'

        # A repository with aisdlc.json, AGENTS.md and a docs/ folder with the given pages.
        function New-Repo {
            param([string]$Json = '{}', [hashtable]$Pages = @{}, [string]$Agents = '# Agents')
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path (Join-Path $root 'docs') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value $Json
            Set-Content -LiteralPath (Join-Path $root 'AGENTS.md') -Value $Agents
            foreach ($name in $Pages.Keys) { Set-Content -LiteralPath (Join-Path $root 'docs' $name) -Value $Pages[$name] }
            $root
        }

        function Invoke-Gate {
            param([string]$Root, [switch]$Quiet)
            $extra = @()
            if ($Quiet) { $extra += '-Quiet' }
            $output = & pwsh -NoProfile -File $script:Gate -RepoRoot $Root -Today '2026-11-09' @extra *>&1 | Out-String
            [pscustomobject]@{ Code = $LASTEXITCODE; Output = $output }
        }

        $script:On = '{ "docs": { "lastCheckedMaxAgeDays": 30 } }'
        $script:OldPage = @{ 'old.md' = @('# Old', '', 'The list. Last checked: 2026-09-01.') }
    }

    It 'is off by default, also with an old date' {
        $r = Invoke-Gate (New-Repo -Pages $script:OldPage)
        $r.Code | Should -Be 0
        $r.Output | Should -Match 'off'
    }

    It 'counts <Name> as off' -ForEach @(
        @{ Name = 'the string "30"'; Json = '{ "docs": { "lastCheckedMaxAgeDays": "30" } }' }
        @{ Name = 'zero'; Json = '{ "docs": { "lastCheckedMaxAgeDays": 0 } }' }
        @{ Name = 'a negative number'; Json = '{ "docs": { "lastCheckedMaxAgeDays": -5 } }' }
        @{ Name = 'true'; Json = '{ "docs": { "lastCheckedMaxAgeDays": true } }' }
    ) {
        $r = Invoke-Gate (New-Repo -Json $Json -Pages $script:OldPage)
        $r.Code | Should -Be 0
        $r.Output | Should -Match 'off'
    }

    It 'lists a date older than the setting, with the file, the line and the age' {
        $r = Invoke-Gate (New-Repo -Json $script:On -Pages $script:OldPage)
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'docs/old\.md:3 last checked 2026-09-01, 69 days ago'
    }

    It 'passes a date that is exactly the setting old, and a newer one' {
        $r = Invoke-Gate (New-Repo -Json $script:On -Pages @{ 'edge.md' = 'Last checked: 2026-10-10'; 'new.md' = 'last checked 2026-11-08' })
        $r.Code | Should -Be 0 -Because $r.Output
    }

    It 'reads AGENTS.md too' {
        $r = Invoke-Gate (New-Repo -Json $script:On -Agents "# Agents`nLast checked: 2025-01-01")
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'AGENTS\.md:2'
    }

    It 'leaves a page without a date alone' {
        $r = Invoke-Gate (New-Repo -Json $script:On -Pages @{ 'plain.md' = '# Plain page' })
        $r.Code | Should -Be 0
    }

    It 'prints nothing with -Quiet when nothing is too old, and the list when something is' {
        (Invoke-Gate (New-Repo -Json $script:On -Pages @{ 'new.md' = 'Last checked: 2026-11-08' }) -Quiet).Output.Trim() | Should -BeNullOrEmpty
        (Invoke-Gate (New-Repo -Pages $script:OldPage) -Quiet).Output.Trim() | Should -BeNullOrEmpty -Because 'off stays quiet as well'
        (Invoke-Gate (New-Repo -Json $script:On -Pages $script:OldPage) -Quiet).Output | Should -Match 'docs/old\.md:3'
    }

    It 'is registered as an Advisory core gate' {
        $gates = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'gates.json') -Raw | ConvertFrom-Json
        $entry = @($gates.gates | Where-Object { $_.script -eq 'scripts/Check-DocLastChecked.ps1' })
        $entry.Count | Should -Be 1
        $entry[0].mode | Should -Be 'Advisory'
    }
}
