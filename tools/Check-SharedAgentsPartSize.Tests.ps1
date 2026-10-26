#requires -Version 7.4

Describe 'Check-SharedAgentsPartSize' {
    BeforeAll {
        $script:Tool = Join-Path $PSScriptRoot 'Check-SharedAgentsPartSize.ps1'
        Import-Module (Join-Path $PSScriptRoot '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' 'DocToolTestHarness.psm1') -Force

        function New-Parts {
            param([int]$CoreLines, [int]$PackLines = 0)
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('shared-agents-' + [guid]::NewGuid().ToString('n'))
            $core = Join-Path $root 'core' '.apm' 'skills' 'ai-sdlc-gates' 'assets'
            New-Item -ItemType Directory -Path $core -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $core 'agents-core.md') -Value (1..$CoreLines | ForEach-Object { "Line $_ of the core part." })
            if ($PackLines) {
                $pack = Join-Path $root 'packs' 'dotnet' '.apm' 'skills' 'dotnet-gates' 'assets'
                New-Item -ItemType Directory -Path $pack -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $pack 'agents-dotnet.md') -Value (1..$PackLines | ForEach-Object { "Line $_ of the pack part." })
            }
            return $root
        }

        function Invoke-Gate {
            param([string]$Root, [string[]]$Extra = @())
            $run = Invoke-ScriptInProcess -Path $script:Tool -Arguments (@('-RepoRoot', $Root) + $Extra)
            [pscustomobject]@{ Code = $run.ExitCode; Output = $run.Output }
        }
    }

    AfterAll {
        Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'shared-agents-*' -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'passes parts within the budget and counts the marker lines' {
        $r = Invoke-Gate (New-Parts -CoreLines 30 -PackLines 6)
        $r.Code | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match '40 lines'
    }

    It 'fails when all parts together pass the line budget, and names each part' {
        $r = Invoke-Gate (New-Parts -CoreLines 45 -PackLines 6)
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'over budget: 55 lines'
        $r.Output | Should -Match 'agents-dotnet\.md'
    }

    It 'fails on the word budget' {
        $r = Invoke-Gate (New-Parts -CoreLines 20) -Extra @('-MaxWords', '50')
        $r.Code | Should -Be 1
    }

    It 'cannot check without any part (exit 2)' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('shared-agents-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path (Join-Path $root 'core') -Force | Out-Null
        (Invoke-Gate $root).Code | Should -Be 2
    }

    It 'passes on this repository today' {
        (Invoke-Gate (Split-Path -Parent $PSScriptRoot)).Code | Should -Be 0
    }
}
