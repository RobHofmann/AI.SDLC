#requires -Version 7.4

Describe 'PesterCoverage' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'PesterCoverage.psm1') -Force

        function New-Folder {
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            return $root
        }
    }

    Context 'Get-CoverageTarget' {
        It 'returns the scripts and modules next to a test file, and no test file or test harness' {
            $root = New-Folder
            foreach ($name in 'Do-Thing.ps1', 'Do-Thing.Tests.ps1', 'Helper.psm1', 'DocToolTestHarness.psm1', 'notes.md', 'data.json') { Set-Content -LiteralPath (Join-Path $root $name) -Value '' }

            $targets = Get-CoverageTarget -TestFile (Join-Path $root 'Do-Thing.Tests.ps1')

            @($targets | ForEach-Object { Split-Path -Leaf $_ }) | Should -Be @('Do-Thing.ps1', 'Helper.psm1')
        }

        It 'finds a script under a hidden .apm folder' {
            $root = New-Folder
            $folder = Join-Path $root '.apm' 'skills' 'x' 'scripts'
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $folder 'Run-It.ps1') -Value ''

            @(Get-CoverageTarget -TestFile (Join-Path $folder 'Run-It.Tests.ps1')).Count | Should -Be 1
        }
    }

    Context 'ConvertTo-CoverageLine' {
        It 'makes paths relative with forward slashes, and covers a line when one command on it ran' {
            $root = New-Folder
            $file = Join-Path $root 'core' 'scripts' 'A.ps1'
            $coverage = [pscustomobject]@{
                CommandsExecuted = @([pscustomobject]@{ File = $file; Line = 3 })
                CommandsMissed   = @([pscustomobject]@{ File = $file; Line = 3 }, [pscustomobject]@{ File = $file; Line = 7 })
            }

            $lines = ConvertTo-CoverageLine -CodeCoverage $coverage -RepoRoot $root

            $lines.Count | Should -Be 2
            $lines[0].File | Should -Be 'core/scripts/A.ps1'
            ($lines | Where-Object Line -eq 3).Covered | Should -BeTrue
            ($lines | Where-Object Line -eq 7).Covered | Should -BeFalse
        }

        It 'returns nothing when Pester measured nothing' {
            @(ConvertTo-CoverageLine -CodeCoverage $null -RepoRoot (New-Folder)).Count | Should -Be 0
        }
    }

    Context 'Merge-CoverageLine' {
        It 'covers a line that one test file ran and another missed' {
            $lines = @(
                [pscustomobject]@{ File = 'a.ps1'; Line = 1; Covered = $false }
                [pscustomobject]@{ File = 'a.ps1'; Line = 1; Covered = $true }
                [pscustomobject]@{ File = 'a.ps1'; Line = 2; Covered = $false }
                [pscustomobject]@{ File = 'b.ps1'; Line = 1; Covered = $false }
            )

            $merged = Merge-CoverageLine -Line $lines

            $merged.Count | Should -Be 3
            ($merged | Where-Object { $_.File -eq 'a.ps1' -and $_.Line -eq 1 }).Covered | Should -BeTrue
            ($merged | Where-Object { $_.File -eq 'a.ps1' -and $_.Line -eq 2 }).Covered | Should -BeFalse
        }
    }

    Context 'ConvertTo-SonarCoverageXml' {
        It 'writes the generic coverage format of SonarCloud, one file element per path' {
            $lines = @(
                [pscustomobject]@{ File = 'core/b.ps1'; Line = 2; Covered = $false }
                [pscustomobject]@{ File = 'core/a.ps1'; Line = 5; Covered = $true }
                [pscustomobject]@{ File = 'core/a.ps1'; Line = 1; Covered = $false }
            )

            [xml]$xml = ConvertTo-SonarCoverageXml -Line $lines

            $xml.coverage.version | Should -Be '1'
            @($xml.coverage.file.path) | Should -Be @('core/a.ps1', 'core/b.ps1')
            @($xml.coverage.file[0].lineToCover.lineNumber) | Should -Be @('1', '5')
            @($xml.coverage.file[0].lineToCover.covered) | Should -Be @('false', 'true')
        }

        It 'writes an empty coverage element when there is no line' {
            [xml]$xml = ConvertTo-SonarCoverageXml -Line @()

            $xml.coverage.version | Should -Be '1'
            $xml.coverage.file | Should -BeNullOrEmpty
        }
    }

    Context 'with a real Pester run' {
        It 'turns the coverage of a test that runs a script with & into covered and missed lines' {
            $root = New-Folder
            $folder = Join-Path $root 'tools'
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $folder 'Get-Answer.ps1') -Value "param([switch]`$Other)`nif (`$Other) {`n    'other'`n}`n'answer'"
            Set-Content -LiteralPath (Join-Path $folder 'Get-Answer.Tests.ps1') -Value "Describe 'a' { It 'answers' { & (Join-Path `$PSScriptRoot 'Get-Answer.ps1') | Should -Be 'answer' } }"
            $testFile = Join-Path $folder 'Get-Answer.Tests.ps1'
            # Its own pwsh, as the runner does: a Pester run inside a Pester test shares TestDrive.
            $command = @"
Import-Module Pester -MinimumVersion 5.0
Import-Module '$(Join-Path $PSScriptRoot 'PesterCoverage.psm1')'
`$c = New-PesterConfiguration
`$c.Run.Path = '$testFile'
`$c.Run.PassThru = `$true
`$c.Output.Verbosity = 'None'
`$c.CodeCoverage.Enabled = `$true
`$c.CodeCoverage.UseBreakpoints = `$false
`$c.CodeCoverage.Path = Get-CoverageTarget -TestFile '$testFile'
`$c.CodeCoverage.OutputPath = '$(Join-Path $root 'pester-coverage.xml')'
`$r = Invoke-Pester -Configuration `$c
ConvertTo-Json -Compress -InputObject @(ConvertTo-CoverageLine -CodeCoverage `$r.CodeCoverage -RepoRoot '$root')
"@
            $json = & pwsh -NoProfile -NonInteractive -Command $command | Select-Object -Last 1
            $lines = @($json | ConvertFrom-Json)

            ($lines | Where-Object Line -eq 5).Covered | Should -BeTrue
            ($lines | Where-Object Line -eq 3).Covered | Should -BeFalse
            @($lines.File | Sort-Object -Unique) | Should -Be @('tools/Get-Answer.ps1')
        }
    }
}
