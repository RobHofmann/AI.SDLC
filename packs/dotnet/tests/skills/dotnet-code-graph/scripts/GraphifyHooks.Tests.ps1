#requires -Version 7.4

Describe 'Graphify git hooks' {
    BeforeAll {
        $script:HookDir = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-hooks' 'githooks'
        if (-not (Test-Path -LiteralPath $script:HookDir)) { $script:HookDir = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-hooks' 'githooks' }
        $script:HookDir = (Resolve-Path -LiteralPath $script:HookDir).Path

        function Get-Sh {
            $onPath = Get-Command sh -ErrorAction SilentlyContinue
            if ($onPath) { return $onPath.Source }

            $git = Get-Command git -ErrorAction SilentlyContinue
            if (-not $git) { return $null }

            $root = Split-Path (Split-Path $git.Source -Parent) -Parent
            foreach ($candidate in @((Join-Path $root 'bin' 'sh.exe'), (Join-Path $root 'usr' 'bin' 'sh.exe'))) {
                if (Test-Path -LiteralPath $candidate) { return $candidate }
            }
            return $null
        }

        $script:Sh = Get-Sh

        function Invoke-Hook {
            param(
                [Parameter(Mandatory)][string]$Name,
                [string[]]$HookArgs = @(),
                [string]$OverridePath
            )

            $hook = Join-Path $script:HookDir $Name
            $previous = $env:PATH
            try {
                if ($OverridePath) { $env:PATH = $OverridePath }
                $out = & $script:Sh $hook @HookArgs 2>&1 | Out-String
                return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
            }
            finally {
                $env:PATH = $previous
            }
        }
    }

    Context 'the files themselves' {
        It '<Name> exists and starts with a POSIX shebang' -ForEach @(
            @{ Name = 'graphify-refresh' }
            @{ Name = 'post-commit' }
            @{ Name = 'post-merge' }
            @{ Name = 'post-checkout' }
            @{ Name = 'post-rewrite' }
        ) {
            $path = Join-Path $script:HookDir $Name

            $first = (Get-Content -LiteralPath $path -TotalCount 1)

            Test-Path -LiteralPath $path | Should -BeTrue
            $first | Should -Be '#!/bin/sh'
        }

        It '<Name> is recorded executable in git, or every hook that execs it dies with 126' -ForEach @(
            @{ Name = 'graphify-refresh' }
            @{ Name = 'post-commit' }
            @{ Name = 'post-merge' }
            @{ Name = 'post-checkout' }
            @{ Name = 'post-rewrite' }
        ) {
            $entry = & git -C $script:HookDir ls-files -s -- $Name
            if (-not $entry) {
                Set-ItResult -Skipped -Because "$Name is not committed yet, so git records no file mode to check"
                return
            }

            ($entry -split ' ')[0] | Should -Be '100755'
        }

        It '<Name> delegates to the shared helper rather than duplicating it' -ForEach @(
            @{ Name = 'post-commit' }
            @{ Name = 'post-merge' }
            @{ Name = 'post-checkout' }
            @{ Name = 'post-rewrite' }
        ) {
            $content = Get-Content -LiteralPath (Join-Path $script:HookDir $Name) -Raw

            $content | Should -Match 'graphify-refresh'
            $content | Should -Not -Match 'Invoke-GraphifyIndex'
        }

        It 'the shared helper never reaches a model backend' {
            $content = Get-Content -LiteralPath (Join-Path $script:HookDir 'graphify-refresh') -Raw

            $content | Should -Not -Match '--backend'
            $content | Should -Not -Match '--mode'
        }

        It 'the shared helper does not call the incremental update path' {
            $content = Get-Content -LiteralPath (Join-Path $script:HookDir 'graphify-refresh') -Raw

            $content | Should -Not -Match '\-Update\b'
        }

        It 'relinks the documentation after rebuilding, or the doc edges are lost every commit' {
            $content = Get-Content -LiteralPath (Join-Path $script:HookDir 'graphify-refresh') -Raw

            $content | Should -Match 'Invoke-DocGraphLink\.ps1'
            $content.IndexOf('Invoke-GraphifyIndex') | Should -BeGreaterThan -1
            $content.IndexOf('Invoke-DocGraphLink') | Should -BeGreaterThan -1
            $content.IndexOf('Invoke-GraphifyIndex') | Should -BeLessThan $content.IndexOf('Invoke-DocGraphLink')
        }
    }

    Context 'behaviour when graphify is not installed' {
        It 'graphify-refresh is a silent no-op' {
            if (-not $script:Sh) { Set-ItResult -Skipped -Because 'no POSIX sh available'; return }

            $r = Invoke-Hook -Name 'graphify-refresh' -OverridePath '/usr/bin:/bin'

            $r.ExitCode | Should -Be 0
            $r.Output.Trim() | Should -BeNullOrEmpty
        }

        It 'post-commit is a silent no-op and never fails the commit' {
            if (-not $script:Sh) { Set-ItResult -Skipped -Because 'no POSIX sh available'; return }

            $r = Invoke-Hook -Name 'post-commit' -OverridePath '/usr/bin:/bin'

            $r.ExitCode | Should -Be 0
            $r.Output.Trim() | Should -BeNullOrEmpty
        }

        It 'post-merge is a silent no-op and never fails the merge' {
            if (-not $script:Sh) { Set-ItResult -Skipped -Because 'no POSIX sh available'; return }

            $r = Invoke-Hook -Name 'post-merge' -OverridePath '/usr/bin:/bin'

            $r.ExitCode | Should -Be 0
            $r.Output.Trim() | Should -BeNullOrEmpty
        }

        It 'post-rewrite is a silent no-op and never fails the rebase' {
            if (-not $script:Sh) { Set-ItResult -Skipped -Because 'no POSIX sh available'; return }

            $r = Invoke-Hook -Name 'post-rewrite' -HookArgs @('rebase') -OverridePath '/usr/bin:/bin'

            $r.ExitCode | Should -Be 0
            $r.Output.Trim() | Should -BeNullOrEmpty
        }
    }

    Context 'post-checkout only reacts to a branch switch' {
        It 'exits without refreshing on a file checkout (flag 0)' {
            if (-not $script:Sh) { Set-ItResult -Skipped -Because 'no POSIX sh available'; return }

            $r = Invoke-Hook -Name 'post-checkout' -HookArgs @('oldsha', 'newsha', '0')

            $r.ExitCode | Should -Be 0
            $r.Output.Trim() | Should -BeNullOrEmpty
        }

        It 'exits 0 on a branch checkout (flag 1)' {
            if (-not $script:Sh) { Set-ItResult -Skipped -Because 'no POSIX sh available'; return }

            $r = Invoke-Hook -Name 'post-checkout' -HookArgs @('oldsha', 'newsha', '1') -OverridePath '/usr/bin:/bin'

            $r.ExitCode | Should -Be 0
        }
    }
}
