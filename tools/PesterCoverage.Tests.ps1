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

        It 'returns nothing for a test file under tests whose .apm folder does not exist (#45)' {
            $root = New-Folder
            $tests = Join-Path $root 'core' 'tests' 'skills' 'gone' 'scripts'
            New-Item -ItemType Directory -Path $tests -Force | Out-Null

            @(Get-CoverageTarget -TestFile (Join-Path $tests 'Gone.Tests.ps1')) | Should -HaveCount 0
        }

        It 'measures the scripts under .apm for a test file under tests, and leaves out the test harness (#45)' {
            $root = New-Folder
            $scripts = Join-Path $root 'core' '.apm' 'skills' 'x' 'scripts'
            $tests = Join-Path $root 'core' 'tests' 'skills' 'x' 'scripts'
            New-Item -ItemType Directory -Path $scripts, $tests -Force | Out-Null
            foreach ($name in 'Do-Thing.ps1', 'Helper.psm1') { Set-Content -LiteralPath (Join-Path $scripts $name) -Value '' }
            foreach ($name in 'Do-Thing.Tests.ps1', 'DocToolTestHarness.psm1') { Set-Content -LiteralPath (Join-Path $tests $name) -Value '' }

            $targets = @(Get-CoverageTarget -TestFile (Join-Path $tests 'Do-Thing.Tests.ps1'))

            $targets | Should -Be @((Join-Path $scripts 'Do-Thing.ps1'), (Join-Path $scripts 'Helper.psm1'))
        }
    }

    Context 'Get-ScriptFolderOfTest (#45)' {
        It 'maps the tests folder of a skill to the .apm folder of the same skill' {
            $root = New-Folder
            $tests = Join-Path $root 'packs' 'dotnet' 'tests' 'skills' 'dotnet-gates' 'scripts'

            Get-ScriptFolderOfTest -TestFile (Join-Path $tests 'Run-It.Tests.ps1') | Should -Be (Join-Path $root 'packs' 'dotnet' '.apm' 'skills' 'dotnet-gates' 'scripts')
        }

        It 'leaves the folder of a test file outside a tests tree as it is' {
            $root = New-Folder
            $tools = Join-Path $root 'tools'

            Get-ScriptFolderOfTest -TestFile (Join-Path $tools 'Run-It.Tests.ps1') | Should -Be $tools
        }

        It 'changes only the tests folder that sits right above the skills folder' {
            $root = New-Folder
            $tests = Join-Path $root 'tests' 'core' 'tests' 'skills' 'x' 'scripts'

            Get-ScriptFolderOfTest -TestFile (Join-Path $tests 'Run-It.Tests.ps1') | Should -Be (Join-Path $root 'tests' 'core' '.apm' 'skills' 'x' 'scripts')
        }
    }

    Context 'Get-TestFileOfScript (#45)' {
        It 'maps a script under .apm to the test file in the mirrored tests folder' {
            $root = New-Folder
            $script = Join-Path $root 'core' '.apm' 'skills' 'x' 'scripts' 'Run-It.ps1'

            Get-TestFileOfScript -ScriptFile $script | Should -Be (Join-Path $root 'core' 'tests' 'skills' 'x' 'scripts' 'Run-It.Tests.ps1')
        }

        It 'maps a script outside a skill folder to the test file next to it' {
            $root = New-Folder

            Get-TestFileOfScript -ScriptFile (Join-Path $root 'tools' 'Run-It.ps1') | Should -Be (Join-Path $root 'tools' 'Run-It.Tests.ps1')
        }

        It 'is the reverse of Get-ScriptFolderOfTest' {
            $root = New-Folder
            $script = Join-Path $root 'packs' 'dotnet' '.apm' 'skills' 'x' 'scripts' 'Run-It.ps1'

            $test = Get-TestFileOfScript -ScriptFile $script

            Join-Path (Get-ScriptFolderOfTest -TestFile $test) 'Run-It.ps1' | Should -Be $script
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
