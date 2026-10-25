#requires -Version 7.4
Describe 'Deny-IncompletePush' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Deny-IncompletePush.ps1'

        $script:GapCheck = Join-Path -Path $TestDrive -ChildPath 'gap.ps1'
        Set-Content -Path $script:GapCheck -Value @'
param([switch]$Strict, [string]$RepoRoot)
Write-Output 'TESTS: behaviour moved with no test'
exit 1
'@

        $script:CleanCheck = Join-Path -Path $TestDrive -ChildPath 'clean.ps1'
        Set-Content -Path $script:CleanCheck -Value @'
param([switch]$Strict, [string]$RepoRoot)
Write-Output 'no behaviour change'
exit 0
'@

        Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' '..' 'ai-sdlc-gates' 'scripts' 'PreflightReceipt.psm1') -Force
        $script:Receipts = Join-Path -Path $TestDrive -ChildPath 'preflight'
        $script:GreenTree = 'a' * 40
        $script:UncheckedTree = 'b' * 40
        $script:FailedTree = 'c' * 40
        Write-PreflightReceipt -ReceiptRoot $script:Receipts -Tree $script:GreenTree -Status PASS | Out-Null
        Write-PreflightReceipt -ReceiptRoot $script:Receipts -Tree $script:FailedTree -Status FAIL | Out-Null

        $script:Installing = Join-Path -Path $TestDrive -ChildPath 'installing-repo'
        New-Item -ItemType Directory -Path $script:Installing -Force | Out-Null
        git -C $script:Installing init --quiet
        Set-Content -LiteralPath (Join-Path $script:Installing 'aisdlc.json') -Value '{ }'

        function Invoke-Hook {
            param([string]$Payload, [string]$CheckScript = $script:GapCheck, [string]$Branch = 'feature/1-x', [string]$Tree = $script:GreenTree)
            $out = & $script:ScriptUnderTest -Payload $Payload -CheckScript $CheckScript -CurrentBranch $Branch -ReceiptRoot $script:Receipts -HeadTree $Tree -RepoRoot $script:Installing *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }

        function New-Payload {
            param([string]$Command)
            return (@{
                hook_event_name = 'PreToolUse'
                tool_name       = 'Bash'
                tool_input      = @{ command = $Command; description = 'probe' }
            } | ConvertTo-Json -Compress)
        }
    }

    Context 'the git push filter, which the configuration cannot be trusted to apply' {
        It 'allows a shell command that is not a push' {
            $r = Invoke-Hook -Payload (New-Payload -Command 'echo hello')
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Not -Match 'permissionDecision'
        }

        It 'allows another git command that is not a push' {
            $r = Invoke-Hook -Payload (New-Payload -Command 'git log --oneline -5')
            $r.Output | Should -Not -Match 'permissionDecision'
        }

        It 'denies a plain push' {
            $r = Invoke-Hook -Payload (New-Payload -Command 'git push')
            $r.Output | Should -Match 'permissionDecision'
        }

        It 'denies a push carrying options' {
            $r = Invoke-Hook -Payload (New-Payload -Command 'git push --dry-run origin HEAD')
            $r.Output | Should -Match 'permissionDecision'
        }

        It 'denies a push reached through a compound command' {
            $r = Invoke-Hook -Payload (New-Payload -Command 'cd /repo && git push origin main')
            $r.Output | Should -Match 'permissionDecision'
        }

        It 'denies a push that sets configuration on the way' {
            $r = Invoke-Hook -Payload (New-Payload -Command 'git -c core.hooksPath=.githooks push')
            $r.Output | Should -Match 'permissionDecision'
        }
    }

    Context 'a push through the PowerShell tool' {
        BeforeAll {
            function New-PowerShellPayload {
                param([string]$Command)
                return (@{
                    hook_event_name = 'PreToolUse'
                    tool_name       = 'PowerShell'
                    tool_input      = @{ command = $Command; description = 'probe' }
                } | ConvertTo-Json -Compress)
            }
        }

        It 'checks the PowerShell form <Command>' -ForEach @(
            @{ Command = 'git push' }
            @{ Command = '& git push origin feature/x' }
            @{ Command = "& 'git' push -u origin feature/x" }
            @{ Command = 'git.exe push' }
            @{ Command = 'Set-Location C:/repo; git push' }
            @{ Command = 'git push origin feature/x 2>&1 | Out-String' }
        ) {
            $r = Invoke-Hook -Payload (New-PowerShellPayload -Command $Command)
            $r.Output | Should -Match 'wrap-up'
            $r.ExitCode | Should -Be 0
        }

        It 'refuses a push to main through git -C in PowerShell' {
            $r = Invoke-Hook -Payload (New-PowerShellPayload -Command '& git -C "C:/repo" push origin main') -CheckScript $script:CleanCheck
            $r.Output | Should -Match 'main or master is refused'
        }

        It 'refuses a push to main that pipes its output on' {
            $r = Invoke-Hook -Payload (New-PowerShellPayload -Command 'git push origin main 2>&1 | Out-String') -CheckScript $script:CleanCheck
            $r.Output | Should -Match 'main or master is refused'
        }

        It 'allows a PowerShell command that only looks like a push: <Command>' -ForEach @(
            @{ Command = 'Push-Location C:/repo; git status' }
            @{ Command = 'git log --grep push' }
            @{ Command = 'Get-ChildItem -Filter *push*' }
        ) {
            $r = Invoke-Hook -Payload (New-PowerShellPayload -Command $Command)
            $r.Output | Should -Not -Match 'permissionDecision'
        }
    }

    Context 'payloads it cannot read' {
        It 'allows a payload that is not JSON' {
            $r = Invoke-Hook -Payload 'not json at all'
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Not -Match 'permissionDecision'
        }

        It 'allows a tool call that carries no shell command' {
            $r = Invoke-Hook -Payload (@{ tool_name = 'Read'; tool_input = @{ file_path = 'a.cs' } } | ConvertTo-Json -Compress)
            $r.Output | Should -Not -Match 'permissionDecision'
        }

        It 'reads the camelCase shape of the Copilot-native configuration' {
            $r = Invoke-Hook -Payload (@{ toolName = 'bash'; toolArgs = @{ command = 'git push' } } | ConvertTo-Json -Compress)
            $r.Output | Should -Match 'permissionDecision'
        }

        It 'reads tool arguments that arrive as a JSON-encoded string' {
            $r = Invoke-Hook -Payload (@{ toolName = 'powershell'; toolArgs = (@{ command = 'git push' } | ConvertTo-Json -Compress) } | ConvertTo-Json -Compress)
            $r.Output | Should -Match 'permissionDecision'
        }

        It 'allows an empty payload rather than running the check on every shell command' {
            $r = Invoke-Hook -Payload ''
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Not -Match 'permissionDecision'
        }
    }

    Context 'the decision it reports' {
        It 'stays silent when the check reports nothing' {
            $r = Invoke-Hook -Payload (New-Payload -Command 'git push') -CheckScript $script:CleanCheck
            $r.ExitCode | Should -Be 0
            $r.Output.Trim() | Should -BeNullOrEmpty
        }

        It 'denies with a reason that names the skill which closes the gap' {
            $r = Invoke-Hook -Payload (New-Payload -Command 'git push')
            $decision = ($r.Output | ConvertFrom-Json).hookSpecificOutput
            $decision.hookEventName | Should -Be 'PreToolUse'
            $decision.permissionDecision | Should -Be 'deny'
            $decision.permissionDecisionReason | Should -Match 'wrap-up'
        }

        It 'repeats the decision at the top level, which is the shape Copilot CLI reads' {
            $r = Invoke-Hook -Payload (New-Payload -Command 'git push')
            $decision = $r.Output | ConvertFrom-Json
            $decision.permissionDecision | Should -Be 'deny'
            $decision.permissionDecisionReason | Should -Match 'wrap-up'
        }

        It 'carries the check report into the reason so the agent knows what is missing' {
            $r = Invoke-Hook -Payload (New-Payload -Command 'git push')
            $decision = ($r.Output | ConvertFrom-Json).hookSpecificOutput
            $decision.permissionDecisionReason | Should -Match 'TESTS: behaviour moved with no test'
        }

        It 'exits zero even when denying, because a non-zero exit denies every call under Copilot CLI' {
            $r = Invoke-Hook -Payload (New-Payload -Command 'git push')
            $r.ExitCode | Should -Be 0
        }

        It 'allows when the check script is absent rather than blocking the push' {
            $r = Invoke-Hook -Payload (New-Payload -Command 'git push') -CheckScript (Join-Path $TestDrive 'missing.ps1')
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Not -Match 'permissionDecision'
        }
    }

    Context 'a push to main or master, which only a merged pull request may change' {
        It 'refuses <Command> even when the change is complete' -ForEach @(
            @{ Command = 'git push origin main' }
            @{ Command = 'git push origin HEAD:main' }
            @{ Command = 'git push -u origin +feature/x:refs/heads/master' }
            @{ Command = 'git -C C:/repo push origin main' }
            @{ Command = 'git -C "C:/my repo" push origin main' }
            @{ Command = 'git push origin :main' }
            @{ Command = 'git push origin feature/x:main' }
            @{ Command = 'git push origin --all' }
            @{ Command = "git push origin HEAD:'main'" }
            @{ Command = 'git push origin "HEAD:refs/heads/main"' }
            @{ Command = 'git push --mirror origin' }
            @{ Command = 'git push --branches origin' }
        ) {
            $r = Invoke-Hook -Payload (New-Payload -Command $Command) -CheckScript $script:CleanCheck
            $r.Output | Should -Match '"permissionDecision":"deny"'
            $r.Output | Should -Match 'main or master is refused'
        }

        It 'refuses a bare push while the current branch is main' {
            $r = Invoke-Hook -Payload (New-Payload -Command 'git push') -CheckScript $script:CleanCheck -Branch 'main'
            $r.Output | Should -Match 'main or master is refused'
        }

        It 'refuses pushing HEAD while the current branch is master' {
            $r = Invoke-Hook -Payload (New-Payload -Command 'git push origin HEAD') -CheckScript $script:CleanCheck -Branch 'master'
            $r.Output | Should -Match 'main or master is refused'
        }

        It 'allows a complete push of a story branch, even one whose name contains main' {
            $r = Invoke-Hook -Payload (New-Payload -Command 'git push -u origin feature/1-maintenance-mode') -CheckScript $script:CleanCheck
            $r.Output.Trim() | Should -BeNullOrEmpty
            $r.ExitCode | Should -Be 0
        }
    }

    Context 'a push whose commit has no green pre-flight, which Checkpoint Bravo relies on' {
        It 'refuses a complete change whose commit has no receipt, and names wrap-up' {
            $r = Invoke-Hook -Payload (New-Payload -Command 'git push -u origin feature/1-x') -CheckScript $script:CleanCheck -Tree $script:UncheckedTree
            $r.Output | Should -Match '"permissionDecision":"deny"'
            $r.Output | Should -Match 'wrap-up'
            $r.Output | Should -Match 'SkipTests'
            $r.ExitCode | Should -Be 0
        }

        It 'refuses a commit whose receipt says FAIL' {
            $r = Invoke-Hook -Payload (New-Payload -Command 'git push') -CheckScript $script:CleanCheck -Tree $script:FailedTree
            $r.Output | Should -Match 'no green pre-flight'
            $r.Output | Should -Match 'when no check fails' -Because 'a REVIEW, SKIP or NOT-AVAIL row does not stop the receipt'
            $r.Output | Should -Match 'paths\.preflightReceipts' -Because 'the receipt folder comes from aisdlc.json'
        }

        It 'allows the push once the receipt for that tree says PASS' {
            $r = Invoke-Hook -Payload (New-Payload -Command 'git push') -CheckScript $script:CleanCheck -Tree $script:GreenTree
            $r.Output.Trim() | Should -BeNullOrEmpty
        }

        It 'reports the unfinished change first, so wrap-up runs before run-preflight' {
            $r = Invoke-Hook -Payload (New-Payload -Command 'git push') -Tree $script:UncheckedTree
            $r.Output | Should -Match 'wrap-up'
            $r.Output | Should -Not -Match 'run-preflight'
        }

        It 'refuses a bare push to main before it looks for a receipt' {
            $r = Invoke-Hook -Payload (New-Payload -Command 'git push') -CheckScript $script:CleanCheck -Branch 'main' -Tree $script:GreenTree
            $r.Output | Should -Match 'main or master is refused'
        }
    }

    Context 'a push that sends nothing new, which needs no receipt' {
        BeforeAll {
            $script:Sent = Join-Path -Path $TestDrive -ChildPath 'sent'
            $script:SentWork = Join-Path $script:Sent 'work'
            git init --quiet -b feature/1-x $script:SentWork
            git -C $script:SentWork config user.email probe@example.invalid
            git -C $script:SentWork config user.name probe
            Set-Content -LiteralPath (Join-Path $script:SentWork 'aisdlc.json') -Value '{ }'
            git -C $script:SentWork add aisdlc.json
            git -C $script:SentWork commit --quiet -m one --no-verify
            foreach ($name in 'origin', 'fork') {
                git init --quiet --bare (Join-Path $script:Sent "$name.git")
                git -C $script:SentWork remote add $name (Join-Path $script:Sent "$name.git")
            }
            git -C $script:SentWork push --quiet --no-verify origin HEAD:refs/heads/1-story 2>&1 | Out-Null
            git -C $script:SentWork tag v1.0.0
            git -C $script:SentWork branch 2-story
            git -C $script:SentWork switch --quiet 2-story
            git -C $script:SentWork commit --quiet --allow-empty -m two --no-verify
            git -C $script:SentWork push --quiet --no-verify fork HEAD:refs/heads/2-story 2>&1 | Out-Null
            git -C $script:SentWork switch --quiet feature/1-x
            git -C $script:SentWork branch 3-story 2-story
            git -C $script:SentWork fetch --quiet origin 2>&1 | Out-Null
            git -C $script:SentWork fetch --quiet fork 2>&1 | Out-Null

            function Invoke-SentHook {
                param([string]$Command, [string]$Tool = 'Bash')
                $payload = @{ hook_event_name = 'PreToolUse'; tool_name = $Tool; tool_input = @{ command = $Command } } | ConvertTo-Json -Compress
                return (& $script:ScriptUnderTest -Payload $payload -CheckScript $script:GapCheck -CurrentBranch 'feature/1-x' -ReceiptRoot $script:Receipts -HeadTree $script:UncheckedTree -RepoRoot $script:SentWork *>&1 | Out-String)
            }
        }

        It 'allows <Command> without a receipt or the finish check' -ForEach @(
            @{ Tool = 'Bash'; Command = 'git push origin v1.0.0' }
            @{ Tool = 'PowerShell'; Command = 'git push origin v1.0.0 2>&1 | Out-String' }
            @{ Tool = 'Bash'; Command = 'git push origin refs/tags/v1.0.0' }
            @{ Tool = 'Bash'; Command = 'git push -u origin feature/1-x:1-story' }
            @{ Tool = 'Bash'; Command = 'git push origin --delete 1-story' }
            @{ Tool = 'Bash'; Command = 'git push origin :1-story' }
            @{ Tool = 'Bash'; Command = 'git push origin --delete 1-story 9-story' }
        ) {
            $out = Invoke-SentHook -Command $Command -Tool $Tool

            $out.Trim() | Should -BeNullOrEmpty
        }

        It 'refuses a new commit without a receipt' {
            git -C $script:SentWork commit --quiet --allow-empty -m new --no-verify
            try {
                $out = Invoke-SentHook -Command 'git push origin feature/1-x'

                $out | Should -Match '"permissionDecision":"deny"'
                $out | Should -Match 'wrap-up'
            }
            finally { git -C $script:SentWork reset --quiet --hard HEAD~1 }
        }

        It 'refuses a commit that only another remote has' {
            $out = Invoke-SentHook -Command 'git push origin 3-story'

            $out | Should -Match '"permissionDecision":"deny"'
        }

        It 'allows the same commit to the remote that has it' {
            $out = Invoke-SentHook -Command 'git push fork 3-story'

            $out.Trim() | Should -BeNullOrEmpty
        }

        It 'keeps every check for <Family>: <Command>' -ForEach @(
            @{ Family = 'a bare push'; Command = 'git push' }
            @{ Family = 'a push with no refspec'; Command = 'git push origin' }
            @{ Family = 'an option that pushes more refs'; Command = 'git push --tags origin v1.0.0' }
            @{ Family = 'a quoted refspec'; Command = "git push origin 'v1.0.0'" }
            @{ Family = 'a wildcard refspec'; Command = 'git push origin refs/tags/*:refs/tags/*' }
            @{ Family = 'a remote that is a URL'; Command = 'git push https://example.invalid/repo v1.0.0' }
            @{ Family = 'a remote that is not configured'; Command = 'git push upstream v1.0.0' }
            @{ Family = 'a known and a new commit together'; Command = 'git push origin v1.0.0 3-story' }
            @{ Family = 'a second push after a known one'; Command = 'git push origin v1.0.0; git push origin 3-story' }
            @{ Family = 'a second push after a known one with &&'; Command = 'git push origin v1.0.0 && git push origin 3-story' }
            @{ Family = 'a commit before the push, which moves HEAD after the hook ran'; Command = 'git commit --allow-empty -m x && git push origin HEAD:1-story' }
            @{ Family = 'a push in a subshell'; Command = '(git push origin v1.0.0)' }
            @{ Family = 'a command substitution'; Command = 'git push origin $(git rev-parse 3-story)' }
            @{ Family = 'a pipe into another command'; Command = 'git push origin v1.0.0 | sh' }
            @{ Family = 'a second line'; Command = "git push origin v1.0.0`ngit push origin 3-story" }
            @{ Family = 'git -C, whose folder the exemption does not read'; Command = 'git -C . push origin v1.0.0' }
            @{ Family = 'a global option that points git at another repository'; Command = 'git --git-dir=../other/.git push origin v1.0.0' }
            @{ Family = 'a configuration value before the push'; Command = 'git -c remote.origin.url=../other.git push origin v1.0.0' }
        ) {
            $out = Invoke-SentHook -Command $Command

            $out | Should -Match '"permissionDecision":"deny"'
        }

        It 'still refuses a push to main first, also a delete' {
            $out = Invoke-SentHook -Command 'git push origin --delete main'

            $out | Should -Match 'main or master is refused'
        }
    }

    Context 'the message' {
        It 'no longer tells the agent to skip the push hooks, which the settings refuse' {
            $r = Invoke-Hook -Payload (New-Payload -Command 'git push')
            $r.Output | Should -Not -Match 'no-verify'
        }
    }

    Context 'a push into another repository with git -C' {
        BeforeAll {
            $script:Other = Join-Path -Path $TestDrive -ChildPath 'other-repo'
            New-Item -ItemType Directory -Path $script:Other -Force | Out-Null
            git -C $script:Other init --quiet
            git -C $script:Other checkout -q -b feature/x 2>$null

            function Invoke-OtherHook {
                param([string]$Command)
                $payload = New-Payload -Command $Command
                return (& $script:ScriptUnderTest -Payload $payload -CheckScript $script:GapCheck *>&1 | Out-String)
            }
        }

        It 'judges the repository the push targets, and allows a story branch of a repository that does not install the AI-SDLC' {
            $out = Invoke-OtherHook -Command ('git -C "{0}" push origin feature/x' -f $script:Other)

            $out | Should -BeNullOrEmpty
        }

        It 'reads a Git Bash drive path such as /c/folder on Windows' -Skip:(-not $IsWindows) {
            $bash = '/' + $script:Other.Substring(0, 1).ToLowerInvariant() + $script:Other.Substring(2).Replace('\', '/')

            $out = Invoke-OtherHook -Command ('git -C {0} push origin feature/x' -f $bash)

            $out | Should -BeNullOrEmpty
        }

        It 'still refuses a push to main in that repository' {
            $out = Invoke-OtherHook -Command ('git -C "{0}" push origin main' -f $script:Other)

            $out | Should -Match 'main or master is refused'
        }

        It 'runs the finish check against a target repository that installs the AI-SDLC' {
            Set-Content -LiteralPath (Join-Path $script:Other 'aisdlc.json') -Value '{ }'
            try {
                $out = Invoke-OtherHook -Command ('git -C "{0}" push origin feature/x' -f $script:Other)

                $out | Should -Match 'wrap-up'
            }
            finally { Remove-Item -LiteralPath (Join-Path $script:Other 'aisdlc.json') }
        }
    }

    Context 'a push after a cd into another repository' {
        BeforeAll {
            $script:CdTarget = Join-Path -Path $TestDrive -ChildPath 'cd-target-repo'
            New-Item -ItemType Directory -Path $script:CdTarget -Force | Out-Null
            git -C $script:CdTarget init --quiet
            git -C $script:CdTarget checkout -q -b feature/x 2>$null
            git -C $script:CdTarget -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m 'first' 2>$null
            $script:Target = $script:CdTarget.Replace('\', '/')
            $script:Parent = $TestDrive.ToString().Replace('\', '/')
            $script:DollarRepo = Join-Path -Path $TestDrive -ChildPath 'cd$repo'
            New-Item -ItemType Directory -Path $script:DollarRepo -Force | Out-Null
            git -C $script:DollarRepo init --quiet

            $script:NamingCheck = Join-Path -Path $TestDrive -ChildPath 'naming.ps1'
            Set-Content -Path $script:NamingCheck -Value @'
param([switch]$Strict, [string]$RepoRoot)
Write-Output "judged $(Split-Path -Leaf $RepoRoot)"
exit 1
'@

            function Invoke-CdHook {
                param([string]$Command, [string]$CheckScript = $script:GapCheck, [string]$Tool = 'Bash')
                $payload = @{ hook_event_name = 'PreToolUse'; tool_name = $Tool; tool_input = @{ command = $Command } } | ConvertTo-Json -Compress
                return (& $script:ScriptUnderTest -Payload $payload -CheckScript $CheckScript -ReceiptRoot $script:Receipts -HeadTree $script:GreenTree -RepoRoot $script:Installing *>&1 | Out-String)
            }
        }

        It 'judges the repository after the plain <Tool> form <Command>, and allows a story branch of a repository that does not install the AI-SDLC' -ForEach @(
            @{ Tool = 'Bash'; Command = 'cd {0} && git push origin feature/x' }
            @{ Tool = 'Bash'; Command = 'cd {0}; git push -u origin feature/x' }
            @{ Tool = 'Bash'; Command = 'pushd {0} && git push origin feature/x' }
            @{ Tool = 'PowerShell'; Command = 'Set-Location {0}; git push origin feature/x' }
            @{ Tool = 'PowerShell'; Command = 'Set-Location {0} && git push origin feature/x' }
            @{ Tool = 'PowerShell'; Command = 'Push-Location {0}; git push origin feature/x; Pop-Location' }
            @{ Tool = 'PowerShell'; Command = 'sl {0}; git push origin feature/x' }
            @{ Tool = 'PowerShell'; Command = 'CD {0}; git push origin feature/x' }
            @{ Tool = 'Bash'; Command = 'cd "{0}" && git push origin feature/x' }
            @{ Tool = 'Bash'; Command = "cd '{0}' && git push origin feature/x" }
            @{ Tool = 'PowerShell'; Command = 'Set-Location "{0}"; git push origin feature/x' }
            @{ Tool = 'PowerShell'; Command = "cd '{0}'; git push origin feature/x" }
        ) {
            $out = Invoke-CdHook -Command ($Command -f $script:Target) -Tool $Tool

            $out | Should -BeNullOrEmpty
        }

        It 'reads a folder relative to the repository the session runs in' {
            $relative = [IO.Path]::GetRelativePath($script:Installing, $script:CdTarget).Replace('\', '/')

            $out = Invoke-CdHook -Command ('cd {0} && git push origin feature/x' -f $relative)

            $out | Should -BeNullOrEmpty
        }

        It 'reads a Git Bash drive path such as /c/folder on Windows' -Skip:(-not $IsWindows) {
            $bash = '/' + $script:CdTarget.Substring(0, 1).ToLowerInvariant() + $script:CdTarget.Substring(2).Replace('\', '/')

            $out = Invoke-CdHook -Command ('cd {0} && git push origin feature/x' -f $bash)

            $out | Should -BeNullOrEmpty
        }

        It 'reads the branch of the target repository, so a bare push from its main is refused' {
            git -C $script:CdTarget checkout -q -b main 2>$null
            try {
                $out = Invoke-CdHook -Command ('cd {0} && git push' -f $script:Target) -CheckScript $script:CleanCheck

                $out | Should -Match 'main or master is refused'
            }
            finally { git -C $script:CdTarget checkout -q feature/x 2>$null }
        }

        It 'runs the finish check against the target repository when it installs the AI-SDLC' {
            Set-Content -LiteralPath (Join-Path $script:CdTarget 'aisdlc.json') -Value '{ }'
            try {
                $out = Invoke-CdHook -Command ('cd {0} && git push origin feature/x' -f $script:Target) -CheckScript $script:NamingCheck

                $out | Should -Match 'judged cd-target-repo'
            }
            finally { Remove-Item -LiteralPath (Join-Path $script:CdTarget 'aisdlc.json') }
        }

        It 'judges the repository the session runs in for a push with no cd' {
            $out = Invoke-CdHook -Command 'git push origin feature/x' -CheckScript $script:NamingCheck

            $out | Should -Match 'judged installing-repo'
        }

        It 'falls back to the repository the session runs in for the <Family> form <Command>' -ForEach @(
            @{ Family = 'variable in double quotes'; Tool = 'Bash'; Command = 'cd "$OTHER_REPO" && git push origin feature/x' }
            @{ Family = 'variable in PowerShell double quotes'; Tool = 'PowerShell'; Command = 'Set-Location "$env:OTHER_REPO"; git push origin feature/x' }
            @{ Family = 'backtick in double quotes'; Tool = 'Bash'; Command = 'cd "`pwd`/x" && git push origin feature/x' }
            @{ Family = 'tilde in quotes'; Tool = 'PowerShell'; Command = "Set-Location '~/cd-target-repo'; git push origin feature/x" }
            @{ Family = 'wildcard in PowerShell quotes'; Tool = 'PowerShell'; Command = 'Set-Location "{1}/cd-target-rep?"; git push origin feature/x' }
            @{ Family = 'unclosed quote'; Tool = 'Bash'; Command = 'cd "{0} && git push origin feature/x' }
            @{ Family = 'dollar in single quotes'; Tool = 'Bash'; Command = "cd '{1}/cd`$repo' && git push origin feature/x" }
            @{ Family = 'dollar in PowerShell single quotes'; Tool = 'PowerShell'; Command = "Set-Location '{1}/cd`$repo'; git push origin feature/x" }
            @{ Family = 'escaped'; Tool = 'Bash'; Command = 'echo x\; cd {0}; git push origin feature/x' }
            @{ Family = 'tilde'; Tool = 'Bash'; Command = 'cd ~/cd-target-repo && git push origin feature/x' }
            @{ Family = 'variable'; Tool = 'Bash'; Command = 'cd $OTHER_REPO && git push origin feature/x' }
            @{ Family = 'previous folder'; Tool = 'Bash'; Command = 'cd - && git push origin feature/x' }
            @{ Family = 'call operator'; Tool = 'PowerShell'; Command = 'Set-Location {0}; & git push origin feature/x' }
            @{ Family = 'chain'; Tool = 'Bash'; Command = 'cd {1} && cd cd-target-repo && git push origin feature/x' }
            @{ Family = 'other command first'; Tool = 'Bash'; Command = 'false && cd {0}; git push origin feature/x' }
            @{ Family = 'subshell'; Tool = 'Bash'; Command = '(cd {0} && git push origin feature/x)' }
            @{ Family = 'or'; Tool = 'Bash'; Command = 'cd {0} || git push origin feature/x' }
            @{ Family = 'several -C'; Tool = 'Bash'; Command = 'git -C {0} -C {0} push origin feature/x' }
            @{ Family = 'cd with -C'; Tool = 'Bash'; Command = 'cd {1} && git -C cd-target-repo push origin feature/x' }
            @{ Family = '--git-dir'; Tool = 'Bash'; Command = 'cd {0} && git --git-dir={0}/.git push origin feature/x' }
            @{ Family = 'environment'; Tool = 'Bash'; Command = 'cd {0} && GIT_DIR={0}/.git git push origin feature/x' }
            @{ Family = 'PowerShell name in bash'; Tool = 'Bash'; Command = 'Set-Location {0}; git push origin feature/x' }
            @{ Family = 'background'; Tool = 'Bash'; Command = 'cd {0} &git push origin feature/x' }
            @{ Family = 'backslash in bash'; Tool = 'Bash'; Command = 'cd {1}/cd-target-rep\o; git push origin feature/x' }
            @{ Family = 'wildcard'; Tool = 'Bash'; Command = 'cd {1}/cd-target-rep* && git push origin feature/x' }
            @{ Family = 'wildcard in PowerShell'; Tool = 'PowerShell'; Command = 'Set-Location {1}/cd-target-rep?; git push origin feature/x' }
        ) {
            $out = Invoke-CdHook -Command ($Command -f $script:Target, $script:Parent) -Tool $Tool -CheckScript $script:NamingCheck

            $out | Should -Match 'judged installing-repo'
        }
    }

    Context 'a push from a session that works in a git worktree, while the hook runs from the main checkout' {
        BeforeAll {
            $script:MainCheckout = Join-Path -Path $TestDrive -ChildPath 'wt-main'
            $script:Worktree = Join-Path -Path $TestDrive -ChildPath 'wt linked'
            $commit = @('-c', 'user.name=test', '-c', 'user.email=test@example.com', 'commit', '-q', '-m')
            New-Item -ItemType Directory -Path $script:MainCheckout -Force | Out-Null
            git -C $script:MainCheckout init --quiet -b main
            Set-Content -LiteralPath (Join-Path $script:MainCheckout 'aisdlc.json') -Value '{ }'
            git -C $script:MainCheckout add aisdlc.json
            git -C $script:MainCheckout @commit 'first' 2>$null
            git -C $script:MainCheckout worktree add -q -b feature/wt $script:Worktree 2>$null
            New-Item -ItemType Directory -Path (Join-Path $script:Worktree 'docs') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $script:Worktree 'docs' 'page.md') -Value 'page'
            git -C $script:Worktree add docs
            git -C $script:Worktree @commit 'second' 2>$null
            $script:WorktreeTree = Get-HeadTree -RepoRoot $script:Worktree
            $script:WorktreeReceipts = Join-Path $script:Worktree 'temp' 'preflight'
            $script:MainReceipts = Join-Path $script:MainCheckout 'temp' 'preflight'

            $script:JudgedLog = Join-Path -Path $TestDrive -ChildPath 'judged.txt'
            $script:RecordingCheck = Join-Path -Path $TestDrive -ChildPath 'recording.ps1'
            Set-Content -Path $script:RecordingCheck -Value (@'
param([switch]$Strict, [string]$RepoRoot)
Set-Content -LiteralPath '{0}' -Value $RepoRoot
exit 0
'@ -f $script:JudgedLog)

            function Invoke-WorktreeHook {
                param([string]$Command, [string]$Cwd = $script:Worktree, [string]$Tool = 'Bash')
                Remove-Item -LiteralPath $script:JudgedLog -ErrorAction SilentlyContinue
                $payload = @{ hook_event_name = 'PreToolUse'; tool_name = $Tool; cwd = $Cwd; tool_input = @{ command = $Command } } | ConvertTo-Json -Compress
                return (& $script:ScriptUnderTest -Payload $payload -CheckScript $script:RecordingCheck *>&1 | Out-String)
            }

            function Get-JudgedRepository {
                if (-not (Test-Path -LiteralPath $script:JudgedLog)) { return '' }
                return (Get-Content -LiteralPath $script:JudgedLog -Raw).Trim()
            }
        }

        BeforeEach {
            Remove-Item -LiteralPath $script:WorktreeReceipts, $script:MainReceipts -Recurse -ErrorAction SilentlyContinue
        }

        It 'judges the worktree of the cwd, finish check and receipt alike, so its green commit goes out' {
            Write-PreflightReceipt -ReceiptRoot $script:WorktreeReceipts -Tree $script:WorktreeTree -Status PASS | Out-Null

            $out = Invoke-WorktreeHook -Command 'git push -u origin feature/wt'

            $out | Should -BeNullOrEmpty
            Get-JudgedRepository | Should -Be (Resolve-Path -LiteralPath $script:Worktree).Path
        }

        It 'judges the worktree from a subfolder of it' {
            Write-PreflightReceipt -ReceiptRoot $script:WorktreeReceipts -Tree $script:WorktreeTree -Status PASS | Out-Null

            $out = Invoke-WorktreeHook -Command 'git push origin feature/wt' -Cwd (Join-Path $script:Worktree 'docs')

            $out | Should -BeNullOrEmpty
        }

        It 'reads a Git Bash drive path such as /c/folder in the cwd on Windows' -Skip:(-not $IsWindows) {
            Write-PreflightReceipt -ReceiptRoot $script:WorktreeReceipts -Tree $script:WorktreeTree -Status PASS | Out-Null
            $bash = '/' + $script:Worktree.Substring(0, 1).ToLowerInvariant() + $script:Worktree.Substring(2).Replace('\', '/')

            $out = Invoke-WorktreeHook -Command 'git push origin feature/wt' -Cwd $bash

            $out | Should -BeNullOrEmpty
        }

        It 'refuses the worktree commit when only the main checkout holds its receipt' {
            Write-PreflightReceipt -ReceiptRoot $script:MainReceipts -Tree $script:WorktreeTree -Status PASS | Out-Null

            $out = Invoke-WorktreeHook -Command 'git push origin feature/wt'

            $out | Should -Match 'no green pre-flight'
            Get-JudgedRepository | Should -Be (Resolve-Path -LiteralPath $script:Worktree).Path
        }

        It 'reads the branch of the worktree, not the main of the main checkout, for a bare push' {
            Write-PreflightReceipt -ReceiptRoot $script:WorktreeReceipts -Tree $script:WorktreeTree -Status PASS | Out-Null

            (Invoke-WorktreeHook -Command 'git push') | Should -BeNullOrEmpty
            (Invoke-WorktreeHook -Command 'git push' -Cwd $script:MainCheckout) | Should -Match 'main or master is refused'
        }

        It 'judges the worktree after the quoted <Tool> form <Command>, with a space in the folder, from the main checkout' -ForEach @(
            @{ Tool = 'Bash'; Command = 'cd "{0}" && git push origin feature/wt' }
            @{ Tool = 'Bash'; Command = 'cd "../wt linked" && git push origin feature/wt' }
            @{ Tool = 'PowerShell'; Command = "Set-Location '{0}'; git push origin feature/wt" }
        ) {
            Write-PreflightReceipt -ReceiptRoot $script:WorktreeReceipts -Tree $script:WorktreeTree -Status PASS | Out-Null

            $out = Invoke-WorktreeHook -Command ($Command -f $script:Worktree.Replace('\', '/')) -Cwd $script:MainCheckout -Tool $Tool

            $out | Should -BeNullOrEmpty
            Get-JudgedRepository | Should -Be (Resolve-Path -LiteralPath $script:Worktree).Path
        }

        It 'reads a relative git -C folder from the cwd' {
            Write-PreflightReceipt -ReceiptRoot $script:WorktreeReceipts -Tree $script:WorktreeTree -Status PASS | Out-Null

            $out = Invoke-WorktreeHook -Command 'git -C "../wt linked" push origin feature/wt' -Cwd $script:MainCheckout

            $out | Should -BeNullOrEmpty
        }

        It 'falls back to the repository of the cwd, not the hook checkout, for a relative git -C after a cd' {
            Invoke-WorktreeHook -Command 'cd elsewhere && git -C ../wt-main push origin feature/wt' | Out-Null

            Get-JudgedRepository | Should -Be (Resolve-Path -LiteralPath $script:Worktree).Path
        }

        It 'falls back to the repository of the cwd, not the hook checkout, for an unquoted git -C folder with a backslash in bash' {
            Invoke-WorktreeHook -Command 'git -C ..\wt-main push origin feature/wt' | Out-Null

            Get-JudgedRepository | Should -Be (Resolve-Path -LiteralPath $script:Worktree).Path
        }

        It 'falls back to the repository of the cwd for an unquoted bash -C folder that ends in an escaped quote' {
            $escaped = Join-Path -Path $TestDrive -ChildPath 'esc' "'"
            New-Item -ItemType Directory -Path $escaped -Force | Out-Null
            git -C $escaped init --quiet
            Set-Content -LiteralPath (Join-Path $escaped 'aisdlc.json') -Value '{ }'

            Invoke-WorktreeHook -Command "git -C ../esc\' push origin feature/wt" | Out-Null

            Get-JudgedRepository | Should -Be (Resolve-Path -LiteralPath $script:Worktree).Path
        }

        It 'falls back to the repository of the cwd for a relative git -C after the <Tool> folder change in <Command>' -ForEach @(
            @{ Tool = 'Bash'; Command = "echo x`ncd elsewhere`ngit -C ../wt-main push origin feature/wt" }
            @{ Tool = 'Bash'; Command = '{ cd elsewhere; git -C ../wt-main push origin feature/wt; }' }
            @{ Tool = 'Bash'; Command = 'builtin cd elsewhere && git -C ../wt-main push origin feature/wt' }
            @{ Tool = 'Bash'; Command = 'true && command cd elsewhere && git -C ../wt-main push origin feature/wt' }
            @{ Tool = 'PowerShell'; Command = 'Set-Location elsewhere; git -C ../wt-main push origin feature/wt' }
        ) {
            Invoke-WorktreeHook -Command $Command -Tool $Tool | Out-Null

            Get-JudgedRepository | Should -Be (Resolve-Path -LiteralPath $script:Worktree).Path
        }

        It 'reads a relative git -C folder after a PowerShell folder change name in bash, which bash does not run' {
            Invoke-WorktreeHook -Command 'Set-Location ignored; git -C ../wt-main push origin feature/wt' | Out-Null

            Get-JudgedRepository | Should -Be (Resolve-Path -LiteralPath $script:MainCheckout).Path
        }

        It 'reads a relative git -C folder when cd is only an argument of an earlier command' {
            Invoke-WorktreeHook -Command 'echo cd; git -C ../wt-main push origin feature/wt' | Out-Null

            Get-JudgedRepository | Should -Be (Resolve-Path -LiteralPath $script:MainCheckout).Path
        }

        It 'falls back to the repository of the cwd, not the hook checkout, for a git -C folder the shell expands: <Command>' -ForEach @(
            @{ Command = 'git -C "../wt$x" push origin feature/wt' }
            @{ Command = 'git -C ../wt$x push origin feature/wt' }
        ) {
            $dollar = Join-Path -Path $TestDrive -ChildPath 'wt$x'
            if (-not (Test-Path -LiteralPath $dollar)) { git -C $script:MainCheckout worktree add -q -b feature/dollar $dollar 2>$null }

            Invoke-WorktreeHook -Command $Command | Out-Null

            Get-JudgedRepository | Should -Be (Resolve-Path -LiteralPath $script:Worktree).Path
        }
    }
}
