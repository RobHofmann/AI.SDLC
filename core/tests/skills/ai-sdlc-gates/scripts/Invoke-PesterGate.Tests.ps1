#requires -Version 7.4

Describe 'Invoke-PesterGate' {
    BeforeAll {
        $script:Gate = Join-Path $PSScriptRoot 'Invoke-PesterGate.ps1'
        Import-Module (Join-Path $PSScriptRoot 'DocToolTestHarness.psm1') -Force

        function New-TestRepo {
            param([hashtable]$Files = @{})
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value '{ }'
            foreach ($rel in $Files.Keys) {
                $full = Join-Path $root $rel
                New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
                Set-Content -LiteralPath $full -Value $Files[$rel]
            }
            return $root
        }

        function Invoke-Gate {
            param([string]$Root, [string[]]$Path)
            $tests = @($Path | ForEach-Object { Join-Path $Root $_ } | Where-Object { Test-Path -LiteralPath $_ } |
                ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -File -Force } | Where-Object { $_.Name.EndsWith('.tests.ps1', [StringComparison]::OrdinalIgnoreCase) })
            if ($tests.Count -gt 0) {
                # A child pwsh, because the gate imports Pester again and runs Invoke-Pester, which breaks the running test.
                $out = & pwsh -NoProfile -File $script:Gate -RepoRoot $Root -Path $Path 2>&1 | Out-String
                return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out }
            }
            $run = Invoke-ScriptInProcess -Path $script:Gate -Parameters @{ RepoRoot = $Root; Path = $Path }
            return [pscustomobject]@{ Code = $run.ExitCode; Output = $run.Output }
        }

        $script:Passing = "Describe 'ok' { It 'passes' { 1 | Should -Be 1 } }"
        $script:Failing = "Describe 'broken' {`n    It 'fails' {`n        1 | Should -Be 2`n    }`n}"
    }

    It 'exits 0 when every test under the path passes' {
        $root = New-TestRepo -Files @{ 'tools/A.Tests.ps1' = $script:Passing }

        $r = Invoke-Gate -Root $root -Path 'tools'

        $r.Code | Should -Be 0 -Because $r.Output
    }

    It 'exits 1 and names the failing test with its file and line' {
        $root = New-TestRepo -Files @{ 'tools/A.Tests.ps1' = $script:Passing; 'tools/B.Tests.ps1' = $script:Failing }

        $r = Invoke-Gate -Root $root -Path 'tools'

        $r.Code | Should -Be 1
        $r.Output | Should -Match '  tools/B\.Tests\.ps1:2  broken\.fails'
    }

    It 'runs every path it is given' {
        $root = New-TestRepo -Files @{ 'one/A.Tests.ps1' = $script:Passing; 'two/B.Tests.ps1' = $script:Failing }

        $r = Invoke-Gate -Root $root -Path 'one', 'two'

        $r.Code | Should -Be 1
    }

    It 'runs a test file whose name ends in .tests.ps1 in lowercase, also under a hidden folder' {
        $root = New-TestRepo -Files @{ 'tools/.claude/x.tests.ps1' = $script:Failing }
        if ($IsWindows) { (Get-Item -LiteralPath (Join-Path $root 'tools' '.claude')).Attributes += 'Hidden' }

        $r = Invoke-Gate -Root $root -Path 'tools'

        $r.Code | Should -Be 1 -Because $r.Output
        $r.Output | Should -Match '  tools/\.claude/x\.tests\.ps1:2  broken\.fails'
    }

    It 'runs a test file named in the path as it is' {
        $root = New-TestRepo -Files @{ 'tools/A.Tests.ps1' = $script:Passing; 'tools/B.Tests.ps1' = $script:Failing }

        $r = Invoke-Gate -Root $root -Path 'tools/A.Tests.ps1'

        $r.Code | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match '1 test\(s\) passed'
    }

    It 'exits 2, could not check, when a path does not exist' {
        $root = New-TestRepo

        $r = Invoke-Gate -Root $root -Path 'missing'

        $r.Code | Should -Be 2
    }

    It 'exits 2, could not check, when the path holds no test' {
        $root = New-TestRepo -Files @{ 'tools/readme.txt' = 'no tests here' }

        $r = Invoke-Gate -Root $root -Path 'tools'

        $r.Code | Should -Be 2
    }
}
