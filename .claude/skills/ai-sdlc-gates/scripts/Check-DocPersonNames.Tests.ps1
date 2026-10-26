#requires -Version 7.4

Describe 'Check-DocPersonNames' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'DocToolTestHarness.psm1') -Force
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Check-DocPersonNames.ps1'

        function Invoke-Gate {
            param(
                [Parameter(Mandatory)][string]$RepoRoot,
                [string[]]$Authors = @(),
                [string]$AllowListPath
            )
            $authorsLocal = $Authors
            $prov = { param($r) $authorsLocal }.GetNewClosure()
            $splat = @{ RepoRoot = $RepoRoot; GitAuthorProvider = $prov }
            if ($PSBoundParameters.ContainsKey('AllowListPath')) { $splat.AllowListPath = $AllowListPath }
            $out = & $script:ScriptUnderTest @splat *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }

        function Set-Doc {
            param([string]$RelPath, [string]$Body)
            $full = Join-Path $script:Root $RelPath
            New-Item -ItemType Directory -Path (Split-Path $full) -Force | Out-Null
            Set-Content -LiteralPath $full -Value $Body -NoNewline
        }
    }

    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'docs') -Force | Out-Null
        Set-AiSdlcTestConfig -Root $script:Root
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'docs-functional') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Root 'AGENTS.md') -Value "# Agents`nClean content, no names.`n" -NoNewline
    }

    It 'passes when no roster name appears (exit 0)' {
        Set-Doc 'docs/page.md' "# Page`nThe reviewer caught the bug in pull request 1234 before merge.`n"
        $r = Invoke-Gate -RepoRoot $script:Root -Authors @('Dana Fictus')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Person-name OK'
    }

    It 'fails when a full contributor name appears (exit 1)' {
        Set-Doc 'docs/page.md' "# Page`nReviewer Dana Fictus caught both occurrences.`n"
        $r = Invoke-Gate -RepoRoot $script:Root -Authors @('Dana Fictus')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Dana Fictus'
    }

    It 'does not flag a surname appearing alone (exit 0)' {
        Set-Doc 'docs/page.md' "# Page`nAs Fictus noted in review, the call clobbers the caller name.`n"
        $r = Invoke-Gate -RepoRoot $script:Root -Authors @('Dana Fictus')
        $r.ExitCode | Should -Be 0
    }

    It 'does not flag a surname that collides with an ordinary documentation word (exit 0)' {
        Set-Doc 'docs/api.md' "# API`nSend a POST request to /api/orderlines to create one.`n"
        $r = Invoke-Gate -RepoRoot $script:Root -Authors @('Kim Post')
        $r.ExitCode | Should -Be 0
    }

    It 'still flags that committer when their full name appears (exit 1)' {
        Set-Doc 'docs/api.md' "# API`nKim Post reviewed the endpoint.`n"
        $r = Invoke-Gate -RepoRoot $script:Root -Authors @('Kim Post')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Kim Post'
    }

    It 'parses the "Last, First" author form (exit 1)' {
        Set-Doc 'docs/page.md' "# Page`nDana Fictus reviewed this change.`n"
        $r = Invoke-Gate -RepoRoot $script:Root -Authors @('Fictus, Dana')
        $r.ExitCode | Should -Be 1
    }

    It 'strips an employee-id prefix from the author form (exit 1)' {
        Set-Doc 'docs/page.md' "# Page`nRobin Sample signed off on the approach.`n"
        $r = Invoke-Gate -RepoRoot $script:Root -Authors @('EMP_SAMPL123 - Robin Sample')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Sample'
    }

    It 'scans AGENTS.md (exit 1)' {
        Set-Content -LiteralPath (Join-Path $script:Root 'AGENTS.md') -Value "# Agents`nMaintained by Dana Fictus.`n" -NoNewline
        $r = Invoke-Gate -RepoRoot $script:Root -Authors @('Dana Fictus')
        $r.ExitCode | Should -Be 1
    }

    It 'scans docs-functional/ (exit 1)' {
        Set-Doc 'docs-functional/behaviour.md' "# Behaviour`nWritten up by Dana Fictus.`n"
        $r = Invoke-Gate -RepoRoot $script:Root -Authors @('Dana Fictus')
        $r.ExitCode | Should -Be 1
    }

    It 'does not flag an external cited author who is not a committer (exit 0)' {
        Set-Doc 'docs/page.md' "# Page`nWe follow Clean Code by Robert C. Martin.`n"
        $r = Invoke-Gate -RepoRoot $script:Root -Authors @('Dana Fictus')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Person-name OK'
    }

    It 'does not flag a bare common first name (exit 0)' {
        Set-Doc 'docs/page.md' "# Page`nWe had a frank discussion about a robust design.`n"
        $r = Invoke-Gate -RepoRoot $script:Root -Authors @('Lee Placeholder', 'Robin Sample')
        $r.ExitCode | Should -Be 0
    }

    It 'does not match a full name embedded in a larger word (exit 0)' {
        Set-Doc 'docs/page.md' "# Page`nSee Dana Fictuswood Lane and the Robin Samplestrasse entry.`n"
        $r = Invoke-Gate -RepoRoot $script:Root -Authors @('Dana Fictus', 'Robin Sample')
        $r.ExitCode | Should -Be 0
    }

    It 'suppresses an allow-listed name (exit 0)' {
        $allow = Join-Path $script:Root 'allow.txt'
        Set-Content -LiteralPath $allow -Value "# intentional`nDana Fictus`n" -NoNewline
        Set-Doc 'docs/page.md' "# Page`nAuthored by Dana Fictus with consent.`n"
        $r = Invoke-Gate -RepoRoot $script:Root -Authors @('Dana Fictus') -AllowListPath $allow
        $r.ExitCode | Should -Be 0
    }

    It 'reports the count when more than one name reference is found (exit 1)' {
        Set-Doc 'docs/page.md' "# Page`nDana Fictus reviewed it.`nLater, Dana Fictus followed up.`n"
        $r = Invoke-Gate -RepoRoot $script:Root -Authors @('Dana Fictus')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Found 2'
    }

    It 'passes with an empty roster (exit 0)' {
        Set-Doc 'docs/page.md' "# Page`nDana Fictus is here but there is no roster.`n"
        $r = Invoke-Gate -RepoRoot $script:Root -Authors @()
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Person-name OK'
    }
}
