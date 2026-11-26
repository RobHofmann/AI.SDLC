#requires -Version 7.4

BeforeDiscovery {
    function Find-Sh {
        $found = (Get-Command sh -ErrorAction SilentlyContinue).Source
        if (-not $found -and $IsWindows) {
            $gitSh = Join-Path (Split-Path (Split-Path (Get-Command git).Source)) 'bin' 'sh.exe'
            if (Test-Path -LiteralPath $gitSh) { $found = $gitSh }
        }
        return $found
    }
    $script:NoSh = -not (Find-Sh)
    $null = git lfs version 2>&1
    $script:NoLfs = $LASTEXITCODE -ne 0
    $script:NoPwsh = -not (Get-Command pwsh -ErrorAction SilentlyContinue)
}

# The install points core.hooksPath at the githooks folder, so git no longer runs the hooks that
# `git lfs install` put in .git/hooks. These tests prove the AI-SDLC hooks hand on to Git LFS.
Describe 'The git hooks hand on to Git LFS' {
    BeforeAll {
        $script:HookDir = (Resolve-Path (Join-Path $PSScriptRoot '..' 'githooks')).Path -replace '\\', '/'
        $script:Sh = (Get-Command sh -ErrorAction SilentlyContinue).Source
        if (-not $script:Sh -and $IsWindows) {
            $gitSh = Join-Path (Split-Path (Split-Path (Get-Command git).Source)) 'bin' 'sh.exe'
            if (Test-Path -LiteralPath $gitSh) { $script:Sh = $gitSh }
        }
        $script:Sha = 'a' * 40
        $script:Zero = '0' * 40
        $script:Roots = [System.Collections.Generic.List[string]]::new()

        function New-TempRoot {
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('git-lfs-hook-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $root | Out-Null
            $script:Roots.Add($root)
            return $root
        }

        # A clone with a bare remote next to it, core.hooksPath at the hooks under test, and one
        # LFS-tracked file committed. No stock LFS hook is installed anywhere, so only the hooks
        # under test can upload the LFS object.
        function New-LfsClone {
            param([string]$HooksPath = $script:HookDir)
            $root = New-TempRoot
            $remote = Join-Path $root 'remote.git'
            $work = Join-Path $root 'work'
            git init --quiet --bare $remote
            git init --quiet $work
            git -C $work config user.name 'Test'
            git -C $work config user.email 'test@example.invalid'
            git -C $work config core.hooksPath $HooksPath
            git -C $work remote add origin $remote
            Push-Location $work
            try {
                # The filter and .gitattributes by hand: `git lfs install` (even with --skip-repo) and
                # `git lfs track` write the stock hooks into core.hooksPath, which would hide the bug.
                git config filter.lfs.clean 'git-lfs clean -- %f'
                git config filter.lfs.smudge 'git-lfs smudge -- %f'
                git config filter.lfs.process 'git-lfs filter-process'
                git config filter.lfs.required true
                [System.IO.File]::WriteAllText((Join-Path $work '.gitattributes'), "*.bin filter=lfs diff=lfs merge=lfs -text`n")
                [System.IO.File]::WriteAllBytes((Join-Path $work 'film.bin'), [byte[]](1..200))
                git add .gitattributes film.bin
                git commit --quiet -m 'add an LFS file'
            }
            finally { Pop-Location }
            [pscustomobject]@{ Root = $root; Work = $work; Remote = $remote }
        }

        function Get-RemoteLfsObject {
            param([string]$Remote)
            $folder = Join-Path $Remote 'lfs' 'objects'
            if (-not (Test-Path -LiteralPath $folder)) { return @() }
            @(Get-ChildItem -LiteralPath $folder -Recurse -File)
        }

        function Invoke-Push {
            param([string]$Work, [string]$Target)
            $output = git -C $Work push origin "HEAD:$Target" 2>&1 | Out-String
            [pscustomobject]@{ Code = $LASTEXITCODE; Output = $output }
        }

        # Runs one hook through sh in a scratch repository. -Path sets PATH inside sh, after the Git for
        # Windows sh launcher has added its own folders, so a test can hide or replace git-lfs.
        function Invoke-Hook {
            param(
                [string]$Name,
                [string[]]$Arguments = @(),
                [string]$StdIn = '',
                [switch]$UsesLfs,
                [ValidateSet('Real', 'Fake', 'None')][string]$GitLfs = 'Real',
                [switch]$SpyGit
            )
            $root = New-TempRoot
            $repo = Join-Path $root 'repo'
            git init --quiet $repo
            if ($UsesLfs) { Set-Content -LiteralPath (Join-Path $repo '.gitattributes') -Value '*.bin filter=lfs diff=lfs merge=lfs -text' }
            $log = (Join-Path $root 'git-lfs.log') -replace '\\', '/'
            $bin = (Join-Path $root 'bin') -replace '\\', '/'
            # PATH in sh splits on a colon, so a Windows path such as C:/x is written as /c/x there.
            $shBin = $bin -replace '^([A-Za-z]):/', { "/$($_.Groups[1].Value.ToLower())/" }
            New-Item -ItemType Directory -Path $bin | Out-Null

            # Fake: a git-lfs that logs its arguments and stdin. None: a PATH that holds only git,
            # cat and dirname, so git-lfs (which sits next to git in Git for Windows) is not found.
            function Write-Script([string]$Path, [string[]]$Lines) {
                [System.IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"))
            }
            $setup = switch ($GitLfs) {
                'Real' { '' }
                'Fake' {
                    Write-Script "$bin/git-lfs" '#!/bin/sh', "echo `"args: `$*`" >> '$log'", "sed 's/^/stdin: /' >> '$log'"
                    "PATH='$shBin':`$PATH;"
                }
                'None' {
                    foreach ($tool in 'git', 'cat', 'dirname') {
                        $target = (& $script:Sh -c "command -v $tool").Trim()
                        Write-Script "$bin/$tool" '#!/bin/sh', "exec '$target' `"`$@`""
                    }
                    "PATH='$shBin';"
                }
            }
            # Spy: a git that logs each call and then runs the real git, so a test sees every git command a hook runs.
            if ($SpyGit) {
                $realGit = (& $script:Sh -c 'command -v git').Trim()
                Write-Script "$bin/git" '#!/bin/sh', "echo `"git: `$*`" >> '$log'", "exec '$realGit' `"`$@`""
                if ($GitLfs -ne 'None') { $setup = "PATH='$shBin':`$PATH;" }
            }
            Push-Location $repo
            try {
                $command = "chmod +x '$shBin'/* 2>/dev/null; $setup exec `"`$@`""
                $output = $StdIn | & $script:Sh -c $command hook "$script:HookDir/$Name" @Arguments 2>&1 | Out-String
                $code = $LASTEXITCODE
            }
            finally { Pop-Location }
            $logText = if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Raw } else { '' }
            [pscustomobject]@{ Code = $code; Output = $output; Log = $logText }
        }
    }

    AfterAll {
        foreach ($root in $script:Roots) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Context 'a real push to a local remote' {
        It 'leaves the LFS object behind without the hand-on, which is the bug' -Skip:($script:NoSh -or $script:NoLfs) {
            # Hooks that exist but do not hand on, like the hooks before this fix. An empty folder does
            # not show the bug: git-lfs writes its stock hooks into core.hooksPath when a name is free.
            $oldHooks = (New-TempRoot) -replace '\\', '/'
            foreach ($name in 'pre-push', 'post-checkout', 'post-commit', 'post-merge') {
                [System.IO.File]::WriteAllText("$oldHooks/$name", "#!/bin/sh`nexit 0`n")
            }
            $clone = New-LfsClone -HooksPath $oldHooks

            $r = Invoke-Push -Work $clone.Work -Target 'refs/heads/1-story'

            $r.Code | Should -Be 0 -Because $r.Output
            Get-RemoteLfsObject -Remote $clone.Remote | Should -HaveCount 0
        }

        It 'uploads the LFS object of a story branch (AC-1)' -Skip:($script:NoSh -or $script:NoLfs) {
            $clone = New-LfsClone

            $r = Invoke-Push -Work $clone.Work -Target 'refs/heads/1-story'

            $r.Code | Should -Be 0 -Because $r.Output
            $objects = Get-RemoteLfsObject -Remote $clone.Remote
            $objects | Should -HaveCount 1
            $oid = (Get-FileHash -LiteralPath (Join-Path $clone.Work 'film.bin') -Algorithm SHA256).Hash.ToLower()
            $objects[0].Name | Should -Be $oid
        }

        It 'refuses a push to main and uploads nothing (AC-2)' -Skip:($script:NoSh -or $script:NoLfs) {
            $clone = New-LfsClone

            $r = Invoke-Push -Work $clone.Work -Target 'refs/heads/main'

            $r.Code | Should -Not -Be 0
            $r.Output | Should -Match 'a push to main is refused'
            Get-RemoteLfsObject -Remote $clone.Remote | Should -HaveCount 0
        }

        It 'stops the push on a failing blocking gate before the LFS upload (AC-3)' -Skip:($script:NoSh -or $script:NoLfs -or $script:NoPwsh) {
            $clone = New-LfsClone
            $gates = Join-Path $clone.Work '.claude' 'skills' 'ai-sdlc-gates' 'scripts'
            New-Item -ItemType Directory -Path $gates -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $gates 'Invoke-LocalGates.ps1') -Value 'param([switch]$BlockingOnly) Write-Host "gate failed"; exit 1'

            $r = Invoke-Push -Work $clone.Work -Target 'refs/heads/1-story'

            $r.Code | Should -Not -Be 0
            $r.Output | Should -Match 'blocking gate\(s\) failed'
            Get-RemoteLfsObject -Remote $clone.Remote | Should -HaveCount 0
        }
    }

    Context 'the hand-on to git-lfs' {
        It 'gives git lfs pre-push the arguments and the ref lines git gave the hook (AC-4)' -Skip:$script:NoSh {
            $refLine = "refs/heads/1-story $script:Sha refs/heads/1-story $script:Zero"

            $r = Invoke-Hook -Name 'pre-push' -Arguments 'origin', 'https://example.invalid/repo' -StdIn $refLine -UsesLfs -GitLfs Fake

            $r.Code | Should -Be 0 -Because $r.Output
            $r.Log | Should -Match ([regex]::Escape('args: pre-push origin https://example.invalid/repo'))
            $r.Log | Should -Match ([regex]::Escape("stdin: $refLine"))
        }

        It 'hands <Name> on to git lfs with its arguments (AC-4)' -Skip:$script:NoSh -ForEach @(
            @{ Name = 'post-checkout'; Arguments = @(('a' * 40), ('0' * 40), '1') }
            @{ Name = 'post-checkout'; Arguments = @(('a' * 40), ('0' * 40), '0') }
            @{ Name = 'post-commit'; Arguments = @() }
            @{ Name = 'post-merge'; Arguments = @('0') }
        ) {
            $r = Invoke-Hook -Name $Name -Arguments $Arguments -UsesLfs -GitLfs Fake

            $r.Code | Should -Be 0 -Because $r.Output
            ($r.Log -split "`n")[0].Trim() | Should -Be ("args: $Name $($Arguments -join ' ')".Trim())
        }

        It 'fails the push with a clear message when the repository uses LFS but git-lfs is missing (AC-5)' -Skip:$script:NoSh {
            $r = Invoke-Hook -Name 'pre-push' -Arguments 'origin', 'https://example.invalid/repo' -StdIn "refs/heads/1-story $script:Sha refs/heads/1-story $script:Zero" -UsesLfs -GitLfs None

            $r.Code | Should -Be 2
            $r.Output | Should -Match "uses Git LFS.*'git-lfs' was not found"
        }

        It 'leaves a repository without LFS alone when git-lfs is missing (AC-6)' -Skip:$script:NoSh -ForEach @(
            @{ Name = 'pre-push'; Arguments = @('origin', 'https://example.invalid/repo') }
            @{ Name = 'post-checkout'; Arguments = @(('a' * 40), ('0' * 40), '0') }
            @{ Name = 'post-commit'; Arguments = @() }
            @{ Name = 'post-merge'; Arguments = @('0') }
        ) {
            $r = Invoke-Hook -Name $Name -Arguments $Arguments -StdIn "refs/heads/1-story $script:Sha refs/heads/1-story $script:Zero" -GitLfs None

            $r.Code | Should -Be 0 -Because $r.Output
            $r.Output | Should -Not -Match 'git-lfs'
        }

        It 'does not call git-lfs in a repository without LFS, so it sees no change (AC-6)' -Skip:$script:NoSh {
            $r = Invoke-Hook -Name 'post-commit' -GitLfs Fake

            $r.Code | Should -Be 0 -Because $r.Output
            $r.Log | Should -BeNullOrEmpty
        }

        # A comment line that lost its # once ran `git push` inside pre-push. Once the branch had an
        # upstream, that push ran the hook again, without end. A real second push would hang the test,
        # so a spy git shows that push instead.
        It '<Name> runs no command from its comments and never starts a git push' -Skip:$script:NoSh -ForEach @(
            @{ Name = 'pre-push'; Arguments = @('origin', 'https://example.invalid/repo') }
            @{ Name = 'post-checkout'; Arguments = @(('a' * 40), ('0' * 40), '1') }
            @{ Name = 'post-commit'; Arguments = @() }
            @{ Name = 'post-merge'; Arguments = @('0') }
        ) {
            $r = Invoke-Hook -Name $Name -Arguments $Arguments -StdIn "refs/heads/1-story $script:Sha refs/heads/1-story $script:Zero" -UsesLfs -SpyGit

            $r.Output | Should -Not -Match 'not found'
            $r.Log | Should -Match '(?m)^git: ' -Because 'the spy must see the git calls of the hook'
            @($r.Log -split "`n" | Where-Object { $_ -match '^git: push\b' }) | Should -HaveCount 0
        }
    }
}
