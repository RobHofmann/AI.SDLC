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
}

Describe 'The pre-push git hook' {
    BeforeAll {
        $script:Hook = Join-Path $PSScriptRoot '..' 'githooks' 'pre-push'
        $script:Sh = (Get-Command sh -ErrorAction SilentlyContinue).Source
        if (-not $script:Sh -and $IsWindows) {
            $gitSh = Join-Path (Split-Path (Split-Path (Get-Command git).Source)) 'bin' 'sh.exe'
            if (Test-Path -LiteralPath $gitSh) { $script:Sh = $gitSh }
        }

        function Invoke-PrePush {
            param([string[]]$RefLines)
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('pre-push-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $root | Out-Null
            git -C $root init --quiet
            Push-Location $root
            try {
                $output = ($RefLines -join "`n") + "`n" | & $script:Sh $script:Hook origin 'https://example.invalid/repo' 2>&1 | Out-String
                [pscustomobject]@{ Code = $LASTEXITCODE; Output = $output }
            }
            finally { Pop-Location; Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
        $script:Sha = 'a' * 40
        $script:Zero = '0' * 40
    }

    It 'refuses a push to main and says why' -Skip:$script:NoSh {
        $r = Invoke-PrePush -RefLines @("refs/heads/main $script:Sha refs/heads/main $script:Zero")
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'a push to main is refused'
    }

    It 'refuses a push to master' -Skip:$script:NoSh {
        $r = Invoke-PrePush -RefLines @("refs/heads/feature $script:Sha refs/heads/master $script:Sha")
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'a push to master is refused'
    }

    It 'refuses when one of several refs goes to main' -Skip:$script:NoSh {
        $r = Invoke-PrePush -RefLines @(
            "refs/heads/1-story $script:Sha refs/heads/1-story $script:Zero"
            "refs/heads/main $script:Sha refs/heads/main $script:Sha"
        )
        $r.Code | Should -Be 1
    }

    It 'lets a story branch through to the gates, which a tree without the runner skips' -Skip:$script:NoSh {
        $r = Invoke-PrePush -RefLines @("refs/heads/1-story $script:Sha refs/heads/1-story $script:Zero")
        $r.Code | Should -Be 0 -Because $r.Output
        $r.Output | Should -Not -Match 'refused'
    }

    It 'does not treat a branch that only starts with main as main' -Skip:$script:NoSh {
        $r = Invoke-PrePush -RefLines @("refs/heads/main-fix $script:Sha refs/heads/main-fix $script:Zero")
        $r.Code | Should -Be 0 -Because $r.Output
    }

    It 'never falls back to Windows PowerShell, which cannot run a gate that needs PowerShell 7' {
        foreach ($name in 'pre-push', 'graphify-refresh') {
            $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'githooks' $name) -Raw
            $text | Should -Not -Match 'PWSH=powershell' -Because "$name must skip, not run the gates in Windows PowerShell 5.1"
        }
    }

    Context 'in a tree that has the gates' {
        BeforeAll {
            function Invoke-PrePushWithGates {
                param([int]$RunnerExit = 0, [int]$CompletenessExit = 0, [switch]$AsGitDoes, [ValidateSet('None', 'Pass', 'Fail')][string]$Receipt = 'None')
                $root = Join-Path ([System.IO.Path]::GetTempPath()) ('pre-push-' + [guid]::NewGuid().ToString('n'))
                $gates = Join-Path $root '.claude' 'skills' 'ai-sdlc-gates' 'scripts'
                $dotnet = Join-Path $root '.claude' 'skills' 'dotnet-gates' 'scripts'
                New-Item -ItemType Directory -Path $gates, $dotnet -Force | Out-Null
                git -C $root init --quiet
                Set-Content -LiteralPath (Join-Path $gates 'Invoke-LocalGates.ps1') -Value "param([switch]`$BlockingOnly) Write-Host `"runner ran blockingOnly=`$BlockingOnly`"; Write-Host `"GIT_DIR=[`$env:GIT_DIR] GIT_INDEX_FILE=[`$env:GIT_INDEX_FILE]`"; exit $RunnerExit"
                Set-Content -LiteralPath (Join-Path $gates 'Check-ChangeCompleteness.ps1') -Value "Write-Host 'completeness ran'; exit $CompletenessExit"
                Set-Content -LiteralPath (Join-Path $dotnet 'Check-DocDrift.ps1') -Value "Write-Host 'drift ran on its own'; exit 0"
                $sha = $script:Sha
                if ($Receipt -ne 'None') {
                    $source = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
                    foreach ($name in 'Test-PushReceipt.ps1', 'AiSdlcConfig.psm1', 'PreflightReceipt.psm1') { Copy-Item -LiteralPath (Join-Path $source $name) -Destination $gates }
                    git -C $root config user.email probe@example.invalid
                    git -C $root config user.name probe
                    Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value '{}'
                    git -C $root add aisdlc.json
                    git -C $root commit --quiet -m one --no-verify
                    $sha = (git -C $root rev-parse HEAD).Trim()
                    Import-Module (Join-Path $source 'PreflightReceipt.psm1') -Force
                    Write-PreflightReceipt -ReceiptRoot (Join-Path $root 'temp' 'preflight') -Tree (git -C $root rev-parse 'HEAD^{tree}').Trim() -Status ($Receipt.ToUpperInvariant()) -Commit $sha | Out-Null
                }
                $saved = @{ Dir = $env:GIT_DIR; Index = $env:GIT_INDEX_FILE }
                Push-Location $root
                try {
                    if ($AsGitDoes) { $env:GIT_DIR = Join-Path $root '.git'; $env:GIT_INDEX_FILE = Join-Path $root '.git' 'index' }
                    $output = "refs/heads/1-story $sha refs/heads/1-story $script:Zero`n" | & $script:Sh $script:Hook origin 'https://example.invalid/repo' 2>&1 | Out-String
                    [pscustomobject]@{ Code = $LASTEXITCODE; Output = $output }
                }
                finally {
                    $env:GIT_DIR = $saved.Dir
                    $env:GIT_INDEX_FILE = $saved.Index
                    Pop-Location
                    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            $script:NoPwsh = -not (Get-Command pwsh -ErrorAction SilentlyContinue)
        }

        It 'runs the blocking gates once, and shows the advisory completeness report' -Skip:($script:NoSh -or $script:NoPwsh) {
            $r = Invoke-PrePushWithGates

            $r.Code | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match 'runner ran blockingOnly=True'
            $r.Output | Should -Match 'completeness ran'
        }

        It 'does not run Check-DocDrift.ps1 again, because the runner runs it as a blocking gate' -Skip:($script:NoSh -or $script:NoPwsh) {
            $r = Invoke-PrePushWithGates

            $r.Output | Should -Not -Match 'drift ran on its own'
        }

        It 'refuses the push when a blocking gate fails' -Skip:($script:NoSh -or $script:NoPwsh) {
            $r = Invoke-PrePushWithGates -RunnerExit 1

            $r.Code | Should -Be 1
            $r.Output | Should -Match 'blocking gate\(s\) failed'
        }

        It 'runs the gates without the GIT_DIR and GIT_INDEX_FILE that git sets for a hook, so a test that makes its own repository cannot change this one' -Skip:($script:NoSh -or $script:NoPwsh) {
            $r = Invoke-PrePushWithGates -AsGitDoes

            $r.Code | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match 'runner ran blockingOnly=True'
            $r.Output | Should -Match 'GIT_DIR=\[\] GIT_INDEX_FILE=\[\]'
        }

        It 'lets the push through when only the advisory completeness report finds a gap' -Skip:($script:NoSh -or $script:NoPwsh) {
            $r = Invoke-PrePushWithGates -CompletenessExit 1

            $r.Code | Should -Be 0 -Because $r.Output
        }

        It 'skips the blocking gates when a passing pre-flight receipt covers the pushed commit, and still runs the completeness report' -Skip:($script:NoSh -or $script:NoPwsh) {
            $r = Invoke-PrePushWithGates -Receipt Pass -RunnerExit 1

            $r.Code | Should -Be 0 -Because $r.Output
            $r.Output | Should -Not -Match 'runner ran'
            $r.Output | Should -Match 'pre-flight receipt'
            $r.Output | Should -Match 'completeness ran'
        }

        It 'runs the blocking gates when the receipt of the pushed commit did not pass' -Skip:($script:NoSh -or $script:NoPwsh) {
            $r = Invoke-PrePushWithGates -Receipt Fail

            $r.Output | Should -Match 'runner ran blockingOnly=True'
        }

        It 'hands the refs to Git LFS after a skip, as after a gate run' {
            $text = Get-Content -LiteralPath $script:Hook -Raw
            $skip = $text.IndexOf('Test-PushReceipt.ps1')
            $lfs = $text.LastIndexOf('git-lfs-hook')
            $skip | Should -BeGreaterThan 0
            $lfs | Should -BeGreaterThan $skip
            $text.Substring($skip, $lfs - $skip) | Should -Not -Match '(?m)^\s*exit 0'
        }
    }

    Context 'a push that sends nothing new' {
        BeforeAll {
            function New-PushRepo {
                $root = Join-Path ([System.IO.Path]::GetTempPath()) ('pre-push-new-' + [guid]::NewGuid().ToString('n'))
                $gates = Join-Path $root 'work' '.claude' 'skills' 'ai-sdlc-gates' 'scripts'
                New-Item -ItemType Directory -Path $gates -Force | Out-Null
                $work = Join-Path $root 'work'
                git init --quiet -b main $work
                git -C $work config user.email probe@example.invalid
                git -C $work config user.name probe
                git -C $work config core.autocrlf false
                Set-Content -LiteralPath (Join-Path $gates 'Invoke-LocalGates.ps1') -Value 'param([switch]$BlockingOnly) Write-Host "runner ran"; exit 0'
                Set-Content -LiteralPath (Join-Path $gates 'Check-ChangeCompleteness.ps1') -Value 'exit 0'
                $source = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
                foreach ($name in 'Test-PushSendsNothingNew.ps1', 'PreflightReceipt.psm1') { Copy-Item -LiteralPath (Join-Path $source $name) -Destination $gates }
                git -C $work add -A
                git -C $work commit --quiet -m one --no-verify
                foreach ($name in 'origin', 'fork') {
                    git init --quiet --bare (Join-Path $root "$name.git")
                    git -C $work remote add $name (Join-Path $root "$name.git")
                }
                git -C $work push --quiet --no-verify origin HEAD:refs/heads/1-story 2>&1 | Out-Null
                return [pscustomobject]@{ Root = $root; Work = $work; Pushed = (git -C $work rev-parse HEAD).Trim() }
            }

            function Invoke-Hook {
                param($Repo, [string]$RefLine, [string]$Remote = 'origin')
                Push-Location $Repo.Work
                try {
                    $output = "$RefLine`n" | & $script:Sh $script:Hook $Remote 'https://example.invalid/repo' 2>&1 | Out-String
                    [pscustomobject]@{ Code = $LASTEXITCODE; Output = $output }
                }
                finally { Pop-Location }
            }

            $script:Made = [System.Collections.Generic.List[string]]::new()
            $script:NoPwsh = -not (Get-Command pwsh -ErrorAction SilentlyContinue)
        }

        AfterAll {
            foreach ($dir in $script:Made) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
        }

        It 'runs no gate when every pushed ref is a delete, and says why' -Skip:($script:NoSh -or $script:NoPwsh) {
            $repo = New-PushRepo; $script:Made.Add($repo.Root)

            $r = Invoke-Hook -Repo $repo -RefLine "(delete) $script:Zero refs/heads/1-story $($repo.Pushed)"

            $r.Code | Should -Be 0 -Because $r.Output
            $r.Output | Should -Not -Match 'runner ran'
            $r.Output | Should -Match 'delete'
        }

        It 'runs no gate for a tag on a commit the remote already has, and says why' -Skip:($script:NoSh -or $script:NoPwsh) {
            $repo = New-PushRepo; $script:Made.Add($repo.Root)

            $r = Invoke-Hook -Repo $repo -RefLine "refs/tags/v1.0.0 $($repo.Pushed) refs/tags/v1.0.0 $script:Zero"

            $r.Code | Should -Be 0 -Because $r.Output
            $r.Output | Should -Not -Match 'runner ran'
            $r.Output | Should -Match 'already on origin'
        }

        It 'runs the gates for a commit the remote does not have' -Skip:($script:NoSh -or $script:NoPwsh) {
            $repo = New-PushRepo; $script:Made.Add($repo.Root)
            git -C $repo.Work commit --quiet --allow-empty -m two --no-verify
            $new = (git -C $repo.Work rev-parse HEAD).Trim()

            $r = Invoke-Hook -Repo $repo -RefLine "refs/heads/1-story $new refs/heads/1-story $($repo.Pushed)"

            $r.Output | Should -Match 'runner ran'
        }

        It 'runs the gates for a commit that only another remote has' -Skip:($script:NoSh -or $script:NoPwsh) {
            $repo = New-PushRepo; $script:Made.Add($repo.Root)
            git -C $repo.Work commit --quiet --allow-empty -m two --no-verify
            $new = (git -C $repo.Work rev-parse HEAD).Trim()
            git -C $repo.Work push --quiet --no-verify fork HEAD:refs/heads/1-story 2>&1 | Out-Null

            $r = Invoke-Hook -Repo $repo -RefLine "refs/heads/1-story $new refs/heads/1-story $($repo.Pushed)"

            $r.Output | Should -Match 'runner ran'
        }
    }
}
