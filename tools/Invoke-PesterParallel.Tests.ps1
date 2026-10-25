#requires -Version 7.4

Describe 'Invoke-PesterParallel' {
    BeforeAll {
        $script:Tool = Join-Path $PSScriptRoot 'Invoke-PesterParallel.ps1'
        Import-Module (Join-Path $PSScriptRoot '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' 'DocToolTestHarness.psm1') -Force

        function New-TestTree {
            param([hashtable]$Files)
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('pester-parallel-' + [guid]::NewGuid().ToString('n'))
            foreach ($rel in $Files.Keys) {
                $full = Join-Path $root $rel
                New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
                Set-Content -LiteralPath $full -Value $Files[$rel] -Encoding utf8NoBOM
            }
            return $root
        }

        function Invoke-Tool {
            param([string]$Root, [string[]]$Path, [switch]$Ci)
            $paths = ($Path | ForEach-Object { "'$_'" }) -join ', '
            $command = "& '$($script:Tool)' -RepoRoot '$Root' -Path $paths -ThrottleLimit 4 $(if ($Ci) { '-Ci' }); exit `$LASTEXITCODE"
            $out = & pwsh -NoProfile -Command $command 2>&1 | Out-String
            [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out }
        }

        $script:Pass = "Describe 'p' { It 'passes' { 1 | Should -Be 1 } }"
        $script:Fail = "Describe 'f' { It 'fails on purpose' { 1 | Should -Be 2 } }"
    }

    AfterAll {
        Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'pester-parallel-*' -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'passes and counts every test, also the ones under a hidden .apm folder' {
        $root = New-TestTree @{ 'a/one.Tests.ps1' = $script:Pass; 'a/.apm/skills/x/two.Tests.ps1' = $script:Pass }

        $r = Invoke-Tool -Root $root -Path 'a'

        $r.Code | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'Pester: 2 passed, 0 failed, 0 skipped, in 2 file\(s\)'
    }

    It 'fails and names the test that failed' {
        $root = New-TestTree @{ 'a/one.Tests.ps1' = $script:Pass; 'a/bad.Tests.ps1' = $script:Fail }

        $r = Invoke-Tool -Root $root -Path 'a'

        $r.Code | Should -Be 1
        $r.Output | Should -Match 'FAILED a/bad\.Tests\.ps1: f\.fails on purpose'
    }

    It 'runs each file in its own process, so a file that leans on another one fails' {
        $root = New-TestTree @{
            'a/1-loads.Tests.ps1' = "BeforeAll { function global:Get-Leaked { 'from another file' } }`nDescribe 'loads' { It 'loads' { Get-Leaked | Should -Be 'from another file' } }"
            'a/2-leans.Tests.ps1' = "Describe 'leans' { It 'uses what the other file loaded' { Get-Leaked | Should -Be 'from another file' } }"
        }

        $r = Invoke-Tool -Root $root -Path 'a'

        $r.Code | Should -Be 1
        $r.Output | Should -Match 'FAILED a/2-leans\.Tests\.ps1'
        $r.Output | Should -Not -Match 'FAILED a/1-loads\.Tests\.ps1'
    }

    It 'fails on a file that does not load, which Pester does not count as a failed test' {
        $root = New-TestTree @{ 'a/one.Tests.ps1' = $script:Pass; 'a/broken.Tests.ps1' = "Describe 'b' { It 'x' { " }

        $r = Invoke-Tool -Root $root -Path 'a'

        $r.Code | Should -Be 1
        $r.Output | Should -Match 'FAILED a/broken\.Tests\.ps1'
        $r.Output | Should -Match '1 of them could not run'
    }

    It 'fails when a setup block throws' {
        $root = New-TestTree @{ 'a/setup.Tests.ps1' = "Describe 's' { BeforeAll { throw 'setup broke' }; It 'x' { 1 | Should -Be 1 } }" }

        $r = Invoke-Tool -Root $root -Path 'a'

        $r.Code | Should -Be 1
        $r.Output | Should -Match 'setup broke'
    }

    It 'fails when a folder holds no test file, so a wrong path cannot pass in silence' {
        $root = New-TestTree @{ 'a/readme.md' = 'no tests here' }

        $r = Invoke-Tool -Root $root -Path 'a'

        $r.Code | Should -Be 1
        $r.Output | Should -Match 'No test file found under a'
    }

    It 'splits the files into shares that together run each file once' {
        $tree = @{}
        foreach ($n in 1..5) { $tree["a/t$n.Tests.ps1"] = "Describe 't$n' { It 'passes' { 1 | Should -Be 1 } }" }
        $root = New-TestTree $tree

        $counts = foreach ($share in 1..3) {
            $command = "& '$($script:Tool)' -RepoRoot '$root' -Path 'a' -ThrottleLimit 4 -Shards 3 -Shard $share; exit `$LASTEXITCODE"
            $out = & pwsh -NoProfile -Command $command 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0 -Because $out
            [int][regex]::Match($out, 'Pester: (\d+) passed').Groups[1].Value
        }

        $counts | Should -Be @(2, 2, 1)
        ($counts | Measure-Object -Sum).Sum | Should -Be 5
    }

    Context 'the order of the files' {
        BeforeAll {
            function New-OrderTree {
                $log = Join-Path ([System.IO.Path]::GetTempPath()) ('pester-parallel-order-' + [guid]::NewGuid().ToString('n') + '.txt')
                $tree = @{}
                foreach ($n in 'a', 'b', 'c') {
                    $tree["t/$n.Tests.ps1"] = "Describe '$n' { It 'logs' { Add-Content -LiteralPath '$log' -Value '$n' } }"
                }
                return [pscustomobject]@{ Root = (New-TestTree $tree); Log = $log }
            }

            function Invoke-Ordered {
                param($Tree)
                $command = "& '$($script:Tool)' -RepoRoot '$($Tree.Root)' -Path 't' -ThrottleLimit 1; exit `$LASTEXITCODE"
                $out = & pwsh -NoProfile -Command $command 2>&1 | Out-String
                $code = $LASTEXITCODE
                $order = if (Test-Path -LiteralPath $Tree.Log) { @(Get-Content -LiteralPath $Tree.Log) } else { @() }
                Remove-Item -LiteralPath $Tree.Log -ErrorAction SilentlyContinue
                [pscustomobject]@{ Code = $code; Output = $out; Order = $order }
            }

            function Get-Plan {
                param($Tree, [string[]]$Extra = @())
                $run = Invoke-ScriptInProcess -Path $script:Tool -Arguments (@('-RepoRoot', $Tree.Root, '-Path', 't', '-ListOnly') + $Extra)
                $order = @([regex]::Matches($run.Output, '(?m)^Would run: t/(\w)\.Tests\.ps1') | ForEach-Object { $_.Groups[1].Value })
                [pscustomobject]@{ Code = $run.ExitCode; Output = $run.Output; Order = $order }
            }

            function Set-Times {
                param($Tree, [hashtable]$Times)
                $file = Join-Path $Tree.Root 'temp' 'pester-times.json'
                New-Item -ItemType Directory -Path (Split-Path $file -Parent) -Force | Out-Null
                $Times | ConvertTo-Json | Set-Content -LiteralPath $file
                return $file
            }
        }

        It 'starts the files in the order it plans, writes the time of each file, and keeps the times of files it did not run' {
            $tree = New-OrderTree
            $file = Set-Times -Tree $tree -Times @{ 't/c.Tests.ps1' = 9; 'other/x.Tests.ps1' = 4 }

            $r = Invoke-Ordered -Tree $tree

            $r.Code | Should -Be 0 -Because $r.Output
            $r.Order | Should -Be @('a', 'b', 'c')
            $times = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
            @($times.Keys | Sort-Object) | Should -Be @('other/x.Tests.ps1', 't/a.Tests.ps1', 't/b.Tests.ps1', 't/c.Tests.ps1')
            $times['other/x.Tests.ps1'] | Should -Be 4
            $times['t/a.Tests.ps1'] | Should -BeGreaterThan 0
        }

        It 'plans the files in alphabetical order without a timing file' {
            (Get-Plan -Tree (New-OrderTree)).Order | Should -Be @('a', 'b', 'c')
        }

        It 'starts the slowest file of the last run first, a file the timing file does not list before the known ones, and keeps the times of files it did not run' {
            $tree = New-OrderTree
            Set-Times -Tree $tree -Times @{ 't/a.Tests.ps1' = 1.5; 't/c.Tests.ps1' = 9 } | Out-Null

            $r = Get-Plan -Tree $tree

            $r.Code | Should -Be 0 -Because $r.Output
            $r.Order | Should -Be @('b', 'c', 'a')
        }

        It 'runs in alphabetical order and does not fail when the timing file cannot be read' {
            $tree = New-OrderTree
            $file = Join-Path $tree.Root 'temp' 'pester-times.json'
            New-Item -ItemType Directory -Path (Split-Path $file -Parent) -Force | Out-Null
            Set-Content -LiteralPath $file -Value 'not json {'

            $r = Get-Plan -Tree $tree

            $r.Code | Should -Be 0 -Because $r.Output
            $r.Order | Should -Be @('a', 'b', 'c')
            $r.Output | Should -Match 'pester-times\.json'
        }

        It 'cuts the shares from the alphabetical list when a timing file is present, so the shares still run each file once' {
            $tree = New-OrderTree
            Set-Times -Tree $tree -Times @{ 't/a.Tests.ps1' = 1; 't/b.Tests.ps1' = 2; 't/c.Tests.ps1' = 3 } | Out-Null

            $first = Get-Plan -Tree $tree -Extra @('-Shards', '2', '-Shard', '1')
            $second = Get-Plan -Tree $tree -Extra @('-Shards', '2', '-Shard', '2')

            $first.Order | Should -Be @('c', 'a') -Because 'share 1 holds the first and third file of the alphabetical list, slowest first'
            $second.Order | Should -Be @('b')
        }
    }

    It 'gives the test processes of one run their own temp folder, and removes it after the run' {
        $log = Join-Path ([System.IO.Path]::GetTempPath()) ('pester-parallel-temp-' + [guid]::NewGuid().ToString('n') + '.txt')
        $root = New-TestTree @{ 'a/temp.Tests.ps1' = "Describe 't' { It 'logs' { Set-Content -LiteralPath '$log' -Value ([IO.Path]::GetTempPath()) } }" }

        $r = Invoke-Tool -Root $root -Path 'a'

        $r.Code | Should -Be 0 -Because $r.Output
        $runTemp = (Get-Content -LiteralPath $log).Trim()
        Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue
        $runTemp | Should -Not -Be ([System.IO.Path]::GetTempPath())
        $runTemp | Should -Match 'pester-run-'
        Test-Path -LiteralPath $runTemp | Should -BeFalse
    }

    Context 'only the tests of the changed files, with -Changed' {
        BeforeAll {
            function New-ChangedTree {
                $root = New-TestTree @{
                    'a/Get-One.ps1'       = "'one'"
                    'a/Get-One.Tests.ps1' = "Describe 'one' { It 'one' { 1 | Should -Be 1 } }"
                    'a/Get-Two.ps1'       = "'two'"
                    'a/Get-Two.Tests.ps1' = "Describe 'two' { It 'two' { 1 | Should -Be 1 } }"
                    'a/No-Test.ps1'       = "'none'"
                    'a/notes.md'          = '# notes'
                }
                git -C $root init --quiet
                git -C $root config --local user.email probe@example.invalid
                git -C $root config --local user.name probe
                git -C $root add -A
                git -C $root commit --quiet -m base --no-verify
                return $root
            }

            function Invoke-Changed {
                param([string]$Root)
                $run = Invoke-ScriptInProcess -Path $script:Tool -Arguments @('-RepoRoot', $Root, '-Path', 'a', '-Changed', '-Base', 'HEAD', '-ListOnly')
                [pscustomobject]@{ Code = $run.ExitCode; Output = $run.Output; Files = @([regex]::Matches($run.Output, '(?m)^Would run: (\S+)') | ForEach-Object { $_.Groups[1].Value }) }
            }
        }

        It 'runs only the test file next to a changed script' {
            $root = New-ChangedTree
            Add-Content -LiteralPath (Join-Path $root 'a' 'Get-One.ps1') -Value "'more'"

            $r = Invoke-Changed -Root $root

            $r.Code | Should -Be 0 -Because $r.Output
            $r.Files | Should -Be @('a/Get-One.Tests.ps1')
        }

        It 'runs every test file when a changed script has no test file next to it' {
            $root = New-ChangedTree
            Add-Content -LiteralPath (Join-Path $root 'a' 'No-Test.ps1') -Value "'more'"

            $r = Invoke-Changed -Root $root

            $r.Code | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match 'a/No-Test\.ps1 has no test file next to it'
            $r.Files | Should -HaveCount 2
        }

        It 'runs no test and passes when only files that are not scripts changed' {
            $root = New-ChangedTree
            Add-Content -LiteralPath (Join-Path $root 'a' 'notes.md') -Value 'more'

            $r = Invoke-Changed -Root $root

            $r.Code | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match 'No changed script'
        }
    }

    It 'writes each failure as a GitHub Actions error annotation with -Ci' {
        $root = New-TestTree @{ 'a/bad.Tests.ps1' = $script:Fail }

        $r = Invoke-Tool -Root $root -Path 'a' -Ci

        $r.Code | Should -Be 1
        $r.Output | Should -Match '::error file=a/bad\.Tests\.ps1,title=Pester::a/bad\.Tests\.ps1: f\.fails on purpose'
    }

    It 'writes the coverage of the scripts next to each test file with -CoverageFile, merged over the test files' {
        $root = New-TestTree @{
            'a/Get-Answer.ps1'          = "param([switch]`$Other)`nif (`$Other) {`n    'other'`n}`nelse {`n    'answer'`n}"
            'a/Answer.Tests.ps1'        = "Describe 'a' { It 'answers' { & (Join-Path `$PSScriptRoot 'Get-Answer.ps1') | Should -Be 'answer' } }"
            'a/Other.Tests.ps1'         = "Describe 'o' { It 'answers other' { & (Join-Path `$PSScriptRoot 'Get-Answer.ps1') -Other | Should -Be 'other' } }"
            'b/Untested.ps1'            = "'never run'"
            'b/Nothing.Tests.ps1'       = $script:Pass
        }
        $file = Join-Path $root 'out' 'coverage.xml'

        # In this process, so the coverage of this repository measures the runner too.
        $out = & $script:Tool -RepoRoot $root -Path 'a', 'b' -ThrottleLimit 4 -CoverageFile $file *>&1 | Out-String

        $LASTEXITCODE | Should -Be 0 -Because $out
        $out | Should -Match 'Coverage: \d+ of \d+ line\(s\) covered'
        [xml]$xml = Get-Content -LiteralPath $file -Raw
        @($xml.coverage.file.path) | Should -Be @('a/Get-Answer.ps1', 'b/Untested.ps1')
        $answer = $xml.coverage.file | Where-Object path -eq 'a/Get-Answer.ps1'
        @($answer.lineToCover | Where-Object covered -eq 'false').Count | Should -Be 0 -Because 'one test file ran the if branch and the other the else branch'
        ($xml.coverage.file | Where-Object path -eq 'b/Untested.ps1').lineToCover.covered | Should -Be 'false'
        @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter 'coverage*.xml' | Where-Object FullName -ne $file).Count | Should -Be 0 -Because 'the Pester report of each process is removed'
    }

    It 'writes no coverage file without -CoverageFile' {
        $root = New-TestTree @{ 'a/Get-Answer.ps1' = "'answer'"; 'a/one.Tests.ps1' = $script:Pass }

        $r = Invoke-Tool -Root $root -Path 'a'

        $r.Code | Should -Be 0 -Because $r.Output
        $r.Output | Should -Not -Match 'Coverage:'
        @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.xml').Count | Should -Be 0
    }
}
