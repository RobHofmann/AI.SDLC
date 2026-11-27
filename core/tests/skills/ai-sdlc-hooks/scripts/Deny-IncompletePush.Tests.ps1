#requires -Version 7.4
BeforeAll { $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm' }

Describe 'Deny-IncompletePush' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $script:ScriptFolder -ChildPath 'Deny-IncompletePush.ps1'

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

        Import-Module (Join-Path -Path $script:ScriptFolder -ChildPath '..' '..' 'ai-sdlc-gates' 'scripts' 'PreflightReceipt.psm1') -Force
        $script:Receipts = Join-Path -Path $TestDrive -ChildPath 'preflight'
        $script:GreenTree = 'a' * 40
        $script:UncheckedTree = 'b' * 40
        $script:FailedTree = 'c' * 40
        Write-PreflightReceipt -ReceiptRoot $script:Receipts -Tree $script:GreenTree -Status PASS | Out-Null
        Write-PreflightReceipt -ReceiptRoot $script:Receipts -Tree $script:FailedTree -Status FAIL | Out-Null

        $script:Installing = Join-Path -Path $TestDrive -ChildPath 'installing-repo'
        New-Item -ItemType Directory -Path $script:Installing -Force | Out-Null
        git -C $script:Installing init --quiet -b feature/1-x
        git -C $script:Installing -c user.email=probe@example.invalid -c user.name=probe commit --quiet --allow-empty -m one --no-verify
        foreach ($branch in 'feature/x', 'feature/1-maintenance-mode', '1-story', 'main', 'master') { git -C $script:Installing branch $branch }
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

        It 'still refuses a push to main when -RepoRoot is provider-qualified' {
            $payload = New-Payload -Command 'git push origin main'
            $out = & $script:ScriptUnderTest -Payload $payload -CheckScript $script:CleanCheck -CurrentBranch 'main' -ReceiptRoot $script:Receipts -HeadTree $script:GreenTree -RepoRoot ('Microsoft.PowerShell.Core\FileSystem::' + $script:Installing) *>&1 | Out-String
            $out | Should -Match '"permissionDecision":"deny"'
            $out | Should -Match 'main or master is refused'
        }
        It 'refuses a push to main that comes second in a chain' {
            $r = Invoke-Hook -Payload (New-Payload -Command 'git push origin 1-story && git push origin main') -CheckScript $script:CleanCheck
            $r.Output | Should -Match 'main or master is refused'
        }

        It 'refuses a push of <Command> while the current branch is main, because git reads it as HEAD' -Tag '#52' -ForEach @(
            @{ Command = 'git push origin @' }
            @{ Command = 'git push origin head' }
        ) {
            $r = Invoke-Hook -Payload (New-Payload -Command $Command) -CheckScript $script:CleanCheck -Branch 'main'
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

    Context 'a repository that sets git.allowTrunkPush, which may update its trunk with a plain push' {
        BeforeAll {
            $script:OptedIn = Join-Path -Path $TestDrive -ChildPath 'trunk-push-repo'
            New-Item -ItemType Directory -Path $script:OptedIn -Force | Out-Null
            git -C $script:OptedIn init --quiet
            git -C $script:OptedIn config user.email probe@example.invalid
            git -C $script:OptedIn config user.name probe
            Set-Content -LiteralPath (Join-Path $script:OptedIn 'aisdlc.json') -Value '{ "git": { "allowTrunkPush": true } }'
            git -C $script:OptedIn add aisdlc.json
            git -C $script:OptedIn commit --quiet -m on --no-verify
            # The setting counts only on the remote main branch, so the remote-tracking refs hold it.
            git -C $script:OptedIn update-ref refs/remotes/origin/main HEAD
            git -C $script:OptedIn update-ref refs/remotes/origin/master HEAD
            git -C $script:OptedIn update-ref refs/heads/main HEAD
            git -C $script:OptedIn update-ref refs/heads/master HEAD

            # A repository whose working tree switches the setting on, while the remote main branch does not.
            $script:LocalOnly = Join-Path -Path $TestDrive -ChildPath 'local-only-repo'
            New-Item -ItemType Directory -Path $script:LocalOnly -Force | Out-Null
            git -C $script:LocalOnly init --quiet
            git -C $script:LocalOnly config user.email probe@example.invalid
            git -C $script:LocalOnly config user.name probe
            Set-Content -LiteralPath (Join-Path $script:LocalOnly 'aisdlc.json') -Value '{}'
            git -C $script:LocalOnly add aisdlc.json
            git -C $script:LocalOnly commit --quiet -m off --no-verify
            git -C $script:LocalOnly update-ref refs/remotes/origin/main HEAD
            Set-Content -LiteralPath (Join-Path $script:LocalOnly 'aisdlc.json') -Value '{ "git": { "allowTrunkPush": true } }'

            function Invoke-OptedInHook {
                param([string]$Command, [string]$Branch = 'main', [string]$CheckScript = $script:CleanCheck)
                $payload = New-Payload -Command $Command
                $out = & $script:ScriptUnderTest -Payload $payload -CheckScript $CheckScript -CurrentBranch $Branch -ReceiptRoot $script:Receipts -HeadTree $script:GreenTree -RepoRoot $script:OptedIn *>&1 | Out-String
                return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
            }
        }

        It 'allows <Command> when the change is complete' -ForEach @(
            @{ Command = 'git push origin main' }
            @{ Command = 'git push' }
            @{ Command = 'git push -u origin HEAD:main' }
            @{ Command = 'git push origin master' }
            @{ Command = 'git -C C:/repo push origin main' }
            @{ Command = 'git push origin main 2>&1' }
            @{ Command = 'git push --set-upstream --follow-tags origin main' }
            @{ Command = 'git push -uq origin main' }
        ) {
            $r = Invoke-OptedInHook -Command $Command
            $r.Output | Should -Not -Match 'permissionDecision'
        }

        It 'allows a plain push to main when -RepoRoot is provider-qualified, because git gets the plain path' {
            $payload = New-Payload -Command 'git push origin main'
            $out = & $script:ScriptUnderTest -Payload $payload -CheckScript $script:CleanCheck -CurrentBranch 'main' -ReceiptRoot $script:Receipts -HeadTree $script:GreenTree -RepoRoot ('Microsoft.PowerShell.Core\FileSystem::' + $script:OptedIn) *>&1 | Out-String
            $out | Should -Not -Match 'permissionDecision'
        }

        It 'allows a plain push to main when -RepoRoot is a UNC path' -Skip:(-not $IsWindows) {
            $unc = '\\localhost\' + $script:OptedIn.Substring(0, 1) + '$' + $script:OptedIn.Substring(2)
            if (-not (Test-Path -LiteralPath $unc)) { Set-ItResult -Skipped -Because 'the admin share is not available'; return }
            $names = 'GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0'
            $saved = @{}
            foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
            try {
                $env:GIT_CONFIG_COUNT = '1'; $env:GIT_CONFIG_KEY_0 = 'safe.directory'; $env:GIT_CONFIG_VALUE_0 = '*'
                $payload = New-Payload -Command 'git push origin main'
                $out = & $script:ScriptUnderTest -Payload $payload -CheckScript $script:CleanCheck -CurrentBranch 'main' -ReceiptRoot $script:Receipts -HeadTree $script:GreenTree -RepoRoot $unc *>&1 | Out-String
            }
            finally {
                foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
            }
            $out | Should -Not -Match 'permissionDecision'
        }
        It 'refuses <Command>, which may delete or rewrite the trunk' -ForEach @(
            @{ Command = 'git push --force origin main' }
            @{ Command = 'git push -f origin main' }
            @{ Command = 'git push --force-with-lease origin main' }
            @{ Command = 'git push origin +main' }
            @{ Command = 'git push origin :main' }
            @{ Command = 'git push --delete origin main' }
            @{ Command = 'git push --mirror origin' }
            @{ Command = 'git push --all origin' }
            @{ Command = 'git push --no-verify origin main' }
            @{ Command = 'git -c remote.origin.mirror=true push origin main' }
            @{ Command = 'git push origin main && git push -f origin main' }
            @{ Command = 'git push origin main; git push origin :main' }
            @{ Command = 'git push origin main | tee out.txt' }
            @{ Command = 'git push $(echo origin) main' }
            @{ Command = 'git push --dele origin main' }
            @{ Command = 'git push --no-verif origin main' }
            @{ Command = 'git push --forc origin main' }
            @{ Command = 'git push --mirr origin' }
            @{ Command = 'git push -uf origin main' }
            @{ Command = 'git push --repo=other main' }
            @{ Command = 'git push origin main \--force' }
            @{ Command = 'git push origin main ${X}' }
            @{ Command = 'git push origin main {--force,}' }
        ) {
            $r = Invoke-OptedInHook -Command $Command
            $r.Output | Should -Match '"permissionDecision":"deny"'
            $r.Output | Should -Match 'allowTrunkPush'
        }

        It 'refuses a trunk push when only the working tree switches the setting on' {
            $payload = New-Payload -Command 'git push origin main'
            $out = & $script:ScriptUnderTest -Payload $payload -CheckScript $script:CleanCheck -CurrentBranch 'main' -ReceiptRoot $script:Receipts -HeadTree $script:GreenTree -RepoRoot $script:LocalOnly *>&1 | Out-String
            $out | Should -Match '"permissionDecision":"deny"'
            $out | Should -Match 'refs/remotes/origin/main'
        }

        It 'still runs the completeness check on a trunk push' {
            $r = Invoke-OptedInHook -Command 'git push origin main' -CheckScript $script:GapCheck
            $r.Output | Should -Match '"permissionDecision":"deny"'
            $r.Output | Should -Not -Match 'main or master is refused'
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

    Context 'the exit code of the completeness check' {
        BeforeAll {
            $script:CouldNotCheck = Join-Path -Path $TestDrive -ChildPath 'could-not-check.ps1'
            Set-Content -Path $script:CouldNotCheck -Value "param([switch]`$Strict, [string]`$RepoRoot)`nWrite-Output 'Change completeness: no merge base with origin/main.'`nexit 2"
            $script:NotApplicable = Join-Path -Path $TestDrive -ChildPath 'not-applicable.ps1'
            Set-Content -Path $script:NotApplicable -Value "param([switch]`$Strict, [string]`$RepoRoot)`nWrite-Output 'Change completeness: no behaviour change to check.'`nexit 3"
            $script:OddCode = Join-Path -Path $TestDrive -ChildPath 'odd-code.ps1'
            Set-Content -Path $script:OddCode -Value "param([switch]`$Strict, [string]`$RepoRoot)`nWrite-Output 'TESTS: something went wrong'`nexit 5"
        }

        It 'allows a push after exit 2 when the receipt is there, with a note and no allow decision' -Tag '#46' {
            $r = Invoke-Hook -Payload (New-Payload -Command 'git push') -CheckScript $script:CouldNotCheck -Tree $script:GreenTree
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match '"systemMessage":"The completeness check could not check \(exit 2\)'
            $r.Output | Should -Match 'no merge base with origin/main'
            $r.Output | Should -Not -Match 'permissionDecision'
        }

        It 'stays silent after exit 3 when the receipt is there' -Tag '#46' {
            $r = Invoke-Hook -Payload (New-Payload -Command 'git push') -CheckScript $script:NotApplicable -Tree $script:GreenTree
            $r.ExitCode | Should -Be 0
            $r.Output.Trim() | Should -BeNullOrEmpty
        }

        It 'still asks for the receipt after exit 2 or 3' -Tag '#46' {
            foreach ($check in $script:CouldNotCheck, $script:NotApplicable) {
                $r = Invoke-Hook -Payload (New-Payload -Command 'git push') -CheckScript $check -Tree $script:UncheckedTree
                $r.Output | Should -Match 'no green pre-flight'
            }
        }

        It 'does not start an Off completeness gate, and still asks for the receipt' -Tag '#49' {
            $root = Join-Path -Path $TestDrive -ChildPath 'off-repo'
            New-Item -ItemType Directory -Path (Join-Path $root '.claude' 'skills' 'ai-sdlc-gates') -Force | Out-Null
            git -C $root init --quiet -b main
            git -C $root config user.email probe@example.invalid
            git -C $root config user.name probe
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value '{ "gateModes": { "A change moves its tests": "Off" } }'
            Set-Content -LiteralPath (Join-Path $root '.claude' 'skills' 'ai-sdlc-gates' 'gates.json') -Value '{ "package": "core", "gates": [ { "name": "A change moves its tests", "script": "scripts/gap.ps1", "mode": "Advisory" } ] }'
            git -C $root add -A
            git -C $root commit --quiet -m init --no-verify
            $payload = New-Payload -Command 'git push'

            $green = & $script:ScriptUnderTest -Payload $payload -CheckScript $script:GapCheck -CurrentBranch 'feature/1-x' -ReceiptRoot $script:Receipts -HeadTree $script:GreenTree -RepoRoot $root *>&1 | Out-String
            $unchecked = & $script:ScriptUnderTest -Payload $payload -CheckScript $script:GapCheck -CurrentBranch 'feature/1-x' -ReceiptRoot $script:Receipts -HeadTree $script:UncheckedTree -RepoRoot $root *>&1 | Out-String

            $green.Trim() | Should -BeNullOrEmpty -Because 'the gap check would deny, but its gate is Off'
            $unchecked | Should -Match 'no green pre-flight'
        }

        It 'denies on an exit code other than 0, 2 or 3, as on exit 1' -Tag '#46' {
            $r = Invoke-Hook -Payload (New-Payload -Command 'git push') -CheckScript $script:OddCode -Tree $script:GreenTree
            $r.Output | Should -Match '"permissionDecision":"deny"'
            $r.Output | Should -Match 'something went wrong'
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

        It 'judges the worktree when the cwd is provider-qualified' {
            Write-PreflightReceipt -ReceiptRoot $script:WorktreeReceipts -Tree $script:WorktreeTree -Status PASS | Out-Null

            $out = Invoke-WorktreeHook -Command 'git push -u origin feature/wt' -Cwd ('Microsoft.PowerShell.Core\FileSystem::' + $script:Worktree)

            $out | Should -BeNullOrEmpty
            Get-JudgedRepository | Should -Be (Resolve-Path -LiteralPath $script:Worktree).ProviderPath
        }

        Context 'a session on a network share (UNC path)' {
            BeforeAll {
                $script:SavedGit = @{}
                foreach ($name in 'GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0') {
                    $script:SavedGit[$name] = [Environment]::GetEnvironmentVariable($name)
                }
                $env:GIT_CONFIG_COUNT = '1'
                $env:GIT_CONFIG_KEY_0 = 'safe.directory'
                $env:GIT_CONFIG_VALUE_0 = '*'
            }

            AfterAll {
                foreach ($name in $script:SavedGit.Keys) { [Environment]::SetEnvironmentVariable($name, $script:SavedGit[$name]) }
            }

            It 'judges the worktree when the cwd is a UNC path' -Skip:(-not $IsWindows) {
                $unc = '\\localhost\' + $script:Worktree.Substring(0, 1) + '$' + $script:Worktree.Substring(2)
                if (-not (Test-Path -LiteralPath $unc)) { Set-ItResult -Skipped -Because 'the admin share is not available'; return }
                Write-PreflightReceipt -ReceiptRoot $script:WorktreeReceipts -Tree $script:WorktreeTree -Status PASS | Out-Null

                $out = Invoke-WorktreeHook -Command 'git push -u origin feature/wt' -Cwd $unc

                $out | Should -BeNullOrEmpty
                Get-JudgedRepository | Should -Not -Match 'FileSystem::'
                (Get-JudgedRepository).Replace('\', '/') | Should -Be (Resolve-Path -LiteralPath $unc).ProviderPath.Replace('\', '/')
            }
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

    Context 'a completeness check that cannot start (#52)' {
        BeforeAll {
            function pwsh { throw 'boom' }
        }

        It 'goes on to the receipt check and notes it on a green receipt' -Tag '#52' {
            $r = Invoke-Hook -Payload (New-Payload -Command 'git push') -CheckScript $script:CleanCheck -Tree $script:GreenTree
            $r.ExitCode | Should -Be 0
            $json = $r.Output | ConvertFrom-Json
            @($json.PSObject.Properties.Name) | Should -Be @('systemMessage')
            $json.systemMessage | Should -Match 'completeness check could not start'
            $json.systemMessage | Should -Match 'boom'
        }

        It 'refuses a commit with no receipt' -Tag '#52' {
            $r = Invoke-Hook -Payload (New-Payload -Command 'git push') -CheckScript $script:CleanCheck -Tree $script:UncheckedTree
            $r.ExitCode | Should -Be 0
            ($r.Output | ConvertFrom-Json).permissionDecision | Should -Be 'deny'
            $r.Output | Should -Match 'no green pre-flight'
        }
    }

    Context 'a completeness check script that is missing (#52)' {
        It 'goes on to the receipt check and notes it on a green receipt' -Tag '#52' {
            $r = Invoke-Hook -Payload (New-Payload -Command 'git push') -CheckScript (Join-Path $TestDrive 'missing.ps1') -Tree $script:GreenTree
            $r.ExitCode | Should -Be 0
            $json = $r.Output | ConvertFrom-Json
            @($json.PSObject.Properties.Name) | Should -Be @('systemMessage')
            $json.systemMessage | Should -Match 'could not check'
            $json.systemMessage | Should -Match 'script is missing: missing\.ps1'
            $json.systemMessage | Should -Not -Match ([regex]::Escape($TestDrive))
        }

        It 'refuses a commit with no receipt' -Tag '#52' {
            $r = Invoke-Hook -Payload (New-Payload -Command 'git push') -CheckScript (Join-Path $TestDrive 'missing.ps1') -Tree $script:UncheckedTree
            $r.ExitCode | Should -Be 0
            ($r.Output | ConvertFrom-Json).permissionDecision | Should -Be 'deny'
            $r.Output | Should -Match 'no green pre-flight'
        }
    }

    Context 'a settings file that cannot be read (#52)' {
        BeforeAll {
            $script:Broken = Join-Path -Path $TestDrive -ChildPath 'broken-repo'
            New-Item -ItemType Directory -Path $script:Broken -Force | Out-Null
            git -C $script:Broken init --quiet
            Set-Content -LiteralPath (Join-Path $script:Broken 'aisdlc.json') -Value '{ not json'

            function Invoke-BrokenHook {
                param([string]$Command, [string]$Branch = 'feature/x')
                $out = & $script:ScriptUnderTest -Payload (New-Payload -Command $Command) -CheckScript $script:CleanCheck -CurrentBranch $Branch -HeadTree $script:GreenTree -RepoRoot $script:Broken *>&1 | Out-String
                return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
            }
        }

        It 'refuses a push when aisdlc.json is not valid JSON, and says how to fix it' -Tag '#52' {
            $r = Invoke-BrokenHook -Command 'git push origin feature/x'
            $r.ExitCode | Should -Be 0
            ($r.Output | ConvertFrom-Json).permissionDecision | Should -Be 'deny'
            $r.Output | Should -Match 'aisdlc.json cannot be read'
            $r.Output | Should -Match 'Fix aisdlc.json, commit, and push again'
            $r.Output | Should -Not -Match ([regex]::Escape($script:Broken))
        }

        It 'refuses a push when aisdlc.json is valid JSON but paths is not an object' -Tag '#52' {
            $text = Get-Content -LiteralPath (Join-Path $script:Broken 'aisdlc.json') -Raw
            Set-Content -LiteralPath (Join-Path $script:Broken 'aisdlc.json') -Value '{ "paths": "temp" }'
            try {
                $r = Invoke-BrokenHook -Command 'git push origin feature/x'
                ($r.Output | ConvertFrom-Json).permissionDecision | Should -Be 'deny'
                $r.Output | Should -Match 'aisdlc.json cannot be read'
            }
            finally { Set-Content -LiteralPath (Join-Path $script:Broken 'aisdlc.json') -Value $text -NoNewline }
        }

        It 'refuses a push to main with the settings message, not the main message' -Tag '#52' {
            $r = Invoke-BrokenHook -Command 'git push origin main'
            ($r.Output | ConvertFrom-Json).permissionDecision | Should -Be 'deny'
            $r.Output | Should -Match 'aisdlc.json cannot be read'
            $r.Output | Should -Not -Match 'main or master is refused'
        }

        It 'does not refuse a valid settings file, and finds the receipt in the default folder' -Tag '#52' {
            $valid = Join-Path -Path $TestDrive -ChildPath 'valid-repo'
            New-Item -ItemType Directory -Path $valid -Force | Out-Null
            git -C $valid init --quiet
            git -C $valid -c user.email=probe@example.invalid -c user.name=probe commit --quiet --allow-empty -m one --no-verify
            git -C $valid branch feature/x
            Set-Content -LiteralPath (Join-Path $valid 'aisdlc.json') -Value '{ }'
            Write-PreflightReceipt -ReceiptRoot (Join-Path $valid 'temp' 'preflight') -Tree $script:GreenTree -Status PASS | Out-Null

            $out = & $script:ScriptUnderTest -Payload (New-Payload -Command 'git push origin feature/x') -CheckScript $script:CleanCheck -CurrentBranch 'feature/x' -HeadTree $script:GreenTree -RepoRoot $valid *>&1 | Out-String

            $out | Should -Not -Match 'permissionDecision'
        }

        It 'still allows a command that is not a push' -Tag '#52' {
            $r = Invoke-BrokenHook -Command 'git log --grep push'
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Not -Match 'permissionDecision'
        }
    }

    Context 'a module of the hook that cannot load or lacks a function (#52)' {
        BeforeAll {
            function New-BrokenInstall {
                param([string]$Name, [string]$BrokenModule)
                $root = Join-Path -Path $TestDrive -ChildPath $Name
                $hooks = Join-Path $root 'skills' 'ai-sdlc-hooks' 'scripts'
                $gates = Join-Path $root 'skills' 'ai-sdlc-gates' 'scripts'
                New-Item -ItemType Directory -Path $hooks, $gates -Force | Out-Null
                Copy-Item -LiteralPath $script:ScriptUnderTest -Destination $hooks
                foreach ($module in 'PreflightReceipt.psm1', 'AiSdlcConfig.psm1') {
                    if ($module -eq $BrokenModule) { Set-Content -LiteralPath (Join-Path $gates $module) -Value "throw 'broken module'" }
                    else { Copy-Item -LiteralPath (Join-Path $script:ScriptFolder '..' '..' 'ai-sdlc-gates' 'scripts' $module) -Destination $gates }
                }
                return (Join-Path $hooks 'Deny-IncompletePush.ps1')
            }

            function Invoke-InstalledHook {
                param([string]$Hook, [string]$Command)
                $shell = Get-Command -Name pwsh -CommandType Application | Select-Object -First 1
                $out = & $shell -NoProfile -File $Hook -Payload (New-Payload -Command $Command) -CheckScript $script:CleanCheck -CurrentBranch 'feature/x' -ReceiptRoot $script:Receipts -HeadTree $script:GreenTree -RepoRoot $script:Installing 2>&1 | Out-String
                return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
            }
        }

        It 'refuses <Command> when <Module> cannot load' -Tag '#52' -ForEach @(
            @{ Module = 'PreflightReceipt.psm1'; Command = 'git push origin feature/x' }
            @{ Module = 'AiSdlcConfig.psm1'; Command = 'git push origin feature/x' }
            @{ Module = 'PreflightReceipt.psm1'; Command = 'git push origin main' }
        ) {
            $hook = New-BrokenInstall -Name ('broken-' + [guid]::NewGuid().ToString('N')) -BrokenModule $Module

            $r = Invoke-InstalledHook -Hook $hook -Command $Command

            $r.ExitCode | Should -Be 0
            ($r.Output | ConvertFrom-Json).permissionDecision | Should -Be 'deny'
            $r.Output | Should -Match 'cannot load its module'
            $r.Output | Should -Match ([regex]::Escape($Module))
            $r.Output | Should -Match 'apm install'
        }

        It 'refuses a push and names <Module> and <Function> when the module no longer exports it' -Tag '#52' -ForEach @(
            @{ Module = 'PreflightReceipt.psm1'; Function = 'Test-PushSendsNothingNew' }
            @{ Module = 'PreflightReceipt.psm1'; Function = 'Test-PreflightReceipt' }
            @{ Module = 'AiSdlcConfig.psm1'; Function = 'Find-AiSdlcRepoRoot' }
            @{ Module = 'AiSdlcConfig.psm1'; Function = 'Get-AiSdlcConfig' }
            @{ Module = 'AiSdlcConfig.psm1'; Function = 'Test-AiSdlcGateOff' }
            @{ Module = 'AiSdlcConfig.psm1'; Function = 'Test-AiSdlcTrunkPushAllowed' }
        ) {
            $hook = New-BrokenInstall -Name ('without-' + [guid]::NewGuid().ToString('N')) -BrokenModule ''
            $modulePath = Join-Path -Path (Split-Path $hook -Parent) -ChildPath '..' -AdditionalChildPath '..', 'ai-sdlc-gates', 'scripts', $Module
            $lines = Get-Content -LiteralPath $modulePath | ForEach-Object { if ($_ -match '^Export-ModuleMember') { $_ -replace ('\b' + [regex]::Escape($Function) + '\b,\s*|,\s*\b' + [regex]::Escape($Function) + '\b'), '' } else { $_ } }
            Set-Content -LiteralPath $modulePath -Value $lines

            $r = Invoke-InstalledHook -Hook $hook -Command 'git push origin feature/x'

            $r.ExitCode | Should -Be 0
            ($r.Output | ConvertFrom-Json).permissionDecision | Should -Be 'deny'
            $r.Output | Should -Match ([regex]::Escape("module $Module"))
            $r.Output | Should -Match ([regex]::Escape("no function $Function"))
            $r.Output | Should -Match 'apm install'
        }

        It 'allows a shell command that is not a push, also when a module cannot load' -Tag '#52' {
            $hook = New-BrokenInstall -Name 'broken-not-a-push' -BrokenModule 'PreflightReceipt.psm1'

            $r = Invoke-InstalledHook -Hook $hook -Command 'git log --grep push'

            $r.ExitCode | Should -Be 0
            $r.Output | Should -Not -Match 'permissionDecision'
        }

        It 'allows a complete push when both modules load' -Tag '#52' {
            $hook = New-BrokenInstall -Name 'whole-install' -BrokenModule ''

            $r = Invoke-InstalledHook -Hook $hook -Command 'git push origin feature/x'

            $r.ExitCode | Should -Be 0
            $r.Output | Should -Not -Match 'permissionDecision'
        }
    }

    Context 'a matching or wildcard push, and a heads/ target, which may reach main (#52)' {
        It 'refuses <Command> as one that may reach main' -Tag '#52' -ForEach @(
            @{ Command = 'git push origin :' }
            @{ Command = 'git push origin +:' }
            @{ Command = 'git push -f origin :' }
            @{ Command = "git push origin 'refs/heads/*:refs/heads/*'" }
            @{ Command = 'git push -f origin +refs/heads/*:refs/heads/*' }
            @{ Command = 'git push origin feature/x && git push origin :' }
            @{ Command = 'git push origin HEAD:heads/main' }
            @{ Command = 'git push origin feature/x:heads/master' }
            @{ Command = 'git push origin HEAD:refs/heads/main' }
        ) {
            $r = Invoke-Hook -Payload (New-Payload -Command $Command) -CheckScript $script:CleanCheck

            $r.Output | Should -Match '"permissionDecision":"deny"'
            $r.Output | Should -Match 'main or master is refused'
        }

        It 'does not call a tag wildcard a push to main' -Tag '#52' {
            $r = Invoke-Hook -Payload (New-Payload -Command 'git push origin refs/tags/*:refs/tags/*') -CheckScript $script:CleanCheck

            $r.Output | Should -Not -Match 'main or master is refused'
        }

        It 'keeps refusing a matching push in a repository that sets git.allowTrunkPush' -Tag '#52' {
            $opted = Join-Path -Path $TestDrive -ChildPath 'trunk-matching-repo'
            git init --quiet -b main $opted
            git -C $opted -c user.email=probe@example.invalid -c user.name=probe commit --quiet --allow-empty -m one --no-verify
            Set-Content -LiteralPath (Join-Path $opted 'aisdlc.json') -Value '{ "git": { "allowTrunkPush": true } }'
            git -C $opted add aisdlc.json
            git -C $opted -c user.email=probe@example.invalid -c user.name=probe commit --quiet -m on --no-verify
            git -C $opted update-ref refs/remotes/origin/main HEAD

            $out = & $script:ScriptUnderTest -Payload (New-Payload -Command 'git push origin :') -CheckScript $script:CleanCheck -CurrentBranch 'main' -ReceiptRoot $script:Receipts -HeadTree $script:GreenTree -RepoRoot $opted *>&1 | Out-String

            $out | Should -Match '"permissionDecision":"deny"'
            $out | Should -Match 'allowTrunkPush'
        }
    }

    Context 'a git -c option that changes what a push sends or turns off the git pre-push hook (#52)' {
        It 'refuses <Command>' -Tag '#52' -ForEach @(
            @{ Command = 'git -c push.default=matching push origin' }
            @{ Command = 'git -c remote.origin.push=: push origin' }
            @{ Command = 'git -c core.hooksPath=/dev/null push origin feature/x' }
            @{ Command = 'git -c Core.HooksPath= push origin feature/x' }
            @{ Command = "git -c 'push.default=matching' push origin" }
            @{ Command = 'git -c "push.default"=matching push origin' }
            @{ Command = 'git -c remote.origin.mirror=true push origin' }
            @{ Command = 'git -c "remote.origin.mirror"=true push' }
            @{ Command = 'git -c remote.origin.mirror push origin' }
            @{ Command = 'git -c core.hooksPath push origin feature/x' }
            @{ Command = 'git -c push.followTags push origin feature/x' }
            @{ Command = 'git -c "user.name=A B" -c push.default=matching push origin' }
        ) {
            $r = Invoke-Hook -Payload (New-Payload -Command $Command) -CheckScript $script:CleanCheck

            ($r.Output | ConvertFrom-Json).permissionDecision | Should -Be 'deny'
            $r.Output | Should -Match 'git -c'
            $r.Output | Should -Match 'remote.<name>.mirror'
        }

        It 'refuses any other git -c or --config-env option on a push too, also quoted: <Command>' -Tag '#52' -ForEach @(
            @{ Command = 'git -c "user.name=A B" push origin feature/x' }
            @{ Command = "git -c 'user.name=A B' push origin feature/x" }
            @{ Command = 'git -c include.path=../x.cfg push origin feature/x' }
            @{ Command = 'git -c branch.feature/x.merge=refs/heads/main push origin' }
            @{ Command = 'git --config-env=remote.pushDefault=X push' }
        ) {
            $r = Invoke-Hook -Payload (New-Payload -Command $Command) -CheckScript $script:CleanCheck

            $r.Output | Should -Match '"permissionDecision":"deny"'
            $r.Output | Should -Match 'git -c or --config-env'
        }

        It 'refuses a push to main whose git -c value is quoted and holds a space: <Command>' -Tag '#52' -ForEach @(
            @{ Command = 'git -c "user.name=A B" push origin main' }
            @{ Command = "git -c 'user.name=A B' push origin HEAD:main" }
            @{ Command = 'git -c color.ui push origin main' }
        ) {
            $r = Invoke-Hook -Payload (New-Payload -Command $Command) -CheckScript $script:CleanCheck

            $r.Output | Should -Match 'main or master is refused'
        }

        It 'does not read git -C <dir> as a git -c option' -Tag '#52' {
            $r = Invoke-Hook -Payload (New-Payload -Command 'git -C . push origin feature/x') -CheckScript $script:CleanCheck

            $r.Output | Should -Not -Match 'git -c or --config-env'
        }
    }

    Context 'a push with no refspec in a repository set up to push matching or wildcard refs (#52)' {
        BeforeAll {
            function New-ConfiguredRepo {
                param([string]$Name, [string]$Key, [string]$Value)
                $repo = Join-Path -Path $TestDrive -ChildPath $Name
                git init --quiet -b feature/x $repo
                git -C $repo -c user.email=probe@example.invalid -c user.name=probe commit --quiet --allow-empty -m one --no-verify
                Set-Content -LiteralPath (Join-Path $repo 'aisdlc.json') -Value '{ }'
                git -C $repo config $Key $Value
                return $repo
            }

            function Invoke-ConfiguredHook {
                param([string]$Repo, [string]$Command)
                return (& $script:ScriptUnderTest -Payload (New-Payload -Command $Command) -CheckScript $script:CleanCheck -CurrentBranch 'feature/x' -ReceiptRoot $script:Receipts -HeadTree $script:GreenTree -RepoRoot $Repo *>&1 | Out-String)
            }
        }

        It 'refuses <Command> when <Key> is <Value>' -Tag '#52' -ForEach @(
            @{ Key = 'push.default'; Value = 'matching'; Command = 'git push origin' }
            @{ Key = 'push.default'; Value = 'matching'; Command = 'git push' }
            @{ Key = 'remote.origin.push'; Value = ':'; Command = 'git push origin' }
            @{ Key = 'remote.origin.push'; Value = 'refs/heads/*:refs/heads/*'; Command = 'git push' }
            @{ Key = 'remote.origin.push'; Value = 'HEAD:refs/heads/main'; Command = 'git push origin' }
            @{ Key = 'remote.origin.mirror'; Value = 'true'; Command = 'git push origin' }
            @{ Key = 'remote.origin.mirror'; Value = 'true'; Command = 'git push' }
            @{ Key = 'branch.feature/x.merge'; Value = 'refs/heads/main'; Command = 'git push' }
            @{ Key = 'branch.feature/x.merge'; Value = 'refs/heads/master'; Command = 'git push origin' }
            @{ Key = 'remote.origin.push'; Value = 'refs/heads/feature/x:refs/heads/main'; Command = 'git push origin feature/x' }
        ) {
            $repo = New-ConfiguredRepo -Name ('configured-' + [guid]::NewGuid().ToString('N')) -Key $Key -Value $Value

            $out = Invoke-ConfiguredHook -Repo $repo -Command $Command

            $out | Should -Match 'main or master is refused'
        }

        It 'reads only the remote a bare push goes to, not a backup mirror' -Tag '#52' {
            $repo = New-ConfiguredRepo -Name 'configured-backup' -Key 'remote.backup.mirror' -Value 'true'

            $out = Invoke-ConfiguredHook -Repo $repo -Command 'git push'

            $out | Should -Not -Match 'permissionDecision'
        }

        It 'reads the push remote set for the branch on a bare push' -Tag '#52' {
            $repo = New-ConfiguredRepo -Name 'configured-pushremote' -Key 'remote.backup.mirror' -Value 'true'
            git -C $repo config branch.feature/x.pushRemote backup

            $out = Invoke-ConfiguredHook -Repo $repo -Command 'git push'

            $out | Should -Match 'main or master is refused'
        }

        It 'reads the remote that <Command> names' -Tag '#52' -ForEach @(
            @{ Command = 'git push --repo=backup' }
            @{ Command = 'git push --repo backup' }
        ) {
            $repo = New-ConfiguredRepo -Name ('configured-repo-' + [guid]::NewGuid().ToString('N')) -Key 'remote.backup.mirror' -Value 'true'

            $out = Invoke-ConfiguredHook -Repo $repo -Command $Command

            $out | Should -Match 'main or master is refused'
        }

        It 'allows a complete push when the configured push refspec names a story branch' -Tag '#52' {
            $repo = New-ConfiguredRepo -Name 'configured-story' -Key 'remote.origin.push' -Value 'refs/heads/feature/x:refs/heads/feature/x'

            $out = Invoke-ConfiguredHook -Repo $repo -Command 'git push origin'

            $out | Should -Not -Match 'permissionDecision'
        }

        It 'refuses a bare push with push.default=matching in a repository that sets git.allowTrunkPush' -Tag '#52' {
            $opted = Join-Path -Path $TestDrive -ChildPath 'trunk-config-repo'
            git init --quiet -b feature/x $opted
            Set-Content -LiteralPath (Join-Path $opted 'aisdlc.json') -Value '{ "git": { "allowTrunkPush": true } }'
            git -C $opted add aisdlc.json
            git -C $opted -c user.email=probe@example.invalid -c user.name=probe commit --quiet -m on --no-verify
            git -C $opted update-ref refs/remotes/origin/main HEAD
            git -C $opted update-ref refs/remotes/origin/feature/x HEAD
            git -C $opted config push.default matching

            $out = Invoke-ConfiguredHook -Repo $opted -Command 'git push'

            $out | Should -Match '"permissionDecision":"deny"'
        }
    }

    Context 'the receipt of the commit a push sends, not of HEAD (#52)' {
        BeforeAll {
            $script:Tips = Join-Path -Path $TestDrive -ChildPath 'tips'
            $script:TipsWork = Join-Path $script:Tips 'work'
            git init --quiet -b feature/x $script:TipsWork
            git -C $script:TipsWork config user.email probe@example.invalid
            git -C $script:TipsWork config user.name probe
            Set-Content -LiteralPath (Join-Path $script:TipsWork 'aisdlc.json') -Value '{ }'
            git -C $script:TipsWork add aisdlc.json
            git -C $script:TipsWork commit --quiet -m one --no-verify
            git -C $script:TipsWork branch other
            git -C $script:TipsWork switch --quiet other
            Set-Content -LiteralPath (Join-Path $script:TipsWork 'other.txt') -Value 'other'
            git -C $script:TipsWork add other.txt
            git -C $script:TipsWork commit --quiet -m other --no-verify
            git -C $script:TipsWork switch --quiet feature/x
            git init --quiet --bare (Join-Path $script:Tips 'origin.git')
            git -C $script:TipsWork remote add origin (Join-Path $script:Tips 'origin.git')
            $script:HeadTreeOfTips = ([string](git -C $script:TipsWork rev-parse 'HEAD^{tree}')).Trim()
            $script:OtherTree = ([string](git -C $script:TipsWork rev-parse 'other^{tree}')).Trim()

            function Invoke-TipsHook {
                param([string]$Command, [string]$ReceiptRoot)
                return (& $script:ScriptUnderTest -Payload (New-Payload -Command $Command) -CheckScript $script:CleanCheck -CurrentBranch 'feature/x' -ReceiptRoot $ReceiptRoot -RepoRoot $script:TipsWork *>&1 | Out-String)
            }
        }

        It 'refuses a push of another branch when only HEAD has a receipt' -Tag '#52' {
            $receipts = Join-Path $script:Tips 'head-only'
            Write-PreflightReceipt -ReceiptRoot $receipts -Tree $script:HeadTreeOfTips -Status PASS | Out-Null

            $out = Invoke-TipsHook -Command 'git push origin other' -ReceiptRoot $receipts

            $out | Should -Match '"permissionDecision":"deny"'
            $out | Should -Match 'no green pre-flight'
        }

        It 'allows a push of another branch that has its own receipt' -Tag '#52' {
            $receipts = Join-Path $script:Tips 'other-only'
            Write-PreflightReceipt -ReceiptRoot $receipts -Tree $script:OtherTree -Status PASS | Out-Null

            $out = Invoke-TipsHook -Command 'git push origin other' -ReceiptRoot $receipts

            $out | Should -Not -Match 'permissionDecision'
        }

        It 'checks HEAD for <Command>, which sends the current branch' -Tag '#52' -ForEach @(
            @{ Command = 'git push' }
            @{ Command = 'git push origin' }
            @{ Command = 'git push -u origin HEAD' }
            @{ Command = 'git push origin HEAD:refs/heads/feature/y' }
        ) {
            $receipts = Join-Path $script:Tips 'head-for-bare'
            Write-PreflightReceipt -ReceiptRoot $receipts -Tree $script:HeadTreeOfTips -Status PASS | Out-Null

            $out = Invoke-TipsHook -Command $Command -ReceiptRoot $receipts

            $out | Should -Not -Match 'permissionDecision'
        }

        It 'checks the receipt of the pushed branch, not of HEAD, for <Command>' -Tag '#52' -ForEach @(
            @{ Command = "git push origin 'other'" }
            @{ Command = 'git push origin "other"' }
            @{ Command = 'git push origin other:refs/heads/elsewhere' }
            @{ Command = 'git push origin other 2>&1 | Select-Object -Last 1' }
        ) {
            $headOnly = Join-Path $script:Tips 'head-only-forms'
            Write-PreflightReceipt -ReceiptRoot $headOnly -Tree $script:HeadTreeOfTips -Status PASS | Out-Null
            $otherOnly = Join-Path $script:Tips 'other-only-forms'
            Write-PreflightReceipt -ReceiptRoot $otherOnly -Tree $script:OtherTree -Status PASS | Out-Null

            Invoke-TipsHook -Command $Command -ReceiptRoot $headOnly | Should -Match 'no green pre-flight'
            Invoke-TipsHook -Command $Command -ReceiptRoot $otherOnly | Should -Not -Match 'permissionDecision'
        }

        It 'refuses <Command>, because it cannot tell which commit is pushed' -Tag '#52' -ForEach @(
            @{ Command = 'git push origin no-such-branch' }
            @{ Command = 'git commit --allow-empty -m x && git push origin HEAD:refs/heads/feature/y' }
            @{ Command = 'git push --tags origin' }
            @{ Command = 'git push --no-verify origin other' }
            @{ Command = 'git push origin refs/tags/*:refs/tags/*' }
            @{ Command = 'git push origin other$x' }
            @{ Command = 'git --git-dir=.git push origin other' }
            @{ Command = 'cd "$OTHER_REPO" && git push origin other' }
            @{ Command = 'cd ~/elsewhere && git push origin other' }
            @{ Command = 'git push --unknown-option origin other' }
            @{ Command = 'git -C ../wt$x push origin feature/x' }
        ) {
            $receipts = Join-Path $script:Tips 'both-for-unknown'
            Write-PreflightReceipt -ReceiptRoot $receipts -Tree $script:HeadTreeOfTips -Status PASS | Out-Null
            Write-PreflightReceipt -ReceiptRoot $receipts -Tree $script:OtherTree -Status PASS | Out-Null

            $out = Invoke-TipsHook -Command $Command -ReceiptRoot $receipts

            ($out | ConvertFrom-Json).permissionDecision | Should -Be 'deny'
            $out | Should -Match 'cannot tell which commit'
            $out | Should -Not -Match 'systemMessage'
        }

        It 'refuses a chain whose pushes go to two repositories' -Tag '#52' {
            $second = Join-Path $script:Tips 'second'
            git init --quiet -b feature/x $second
            $receipts = Join-Path $script:Tips 'both-for-chain'
            Write-PreflightReceipt -ReceiptRoot $receipts -Tree $script:HeadTreeOfTips -Status PASS | Out-Null

            $out = Invoke-TipsHook -Command "git push origin feature/x && git -C '$second' push origin feature/x" -ReceiptRoot $receipts

            ($out | ConvertFrom-Json).permissionDecision | Should -Be 'deny'
            $out | Should -Match 'one repository'
        }

        It 'allows a chain of two pushes into the same repository when each pushed commit has a receipt' -Tag '#52' {
            $receipts = Join-Path $script:Tips 'both-for-same'
            Write-PreflightReceipt -ReceiptRoot $receipts -Tree $script:HeadTreeOfTips -Status PASS | Out-Null
            Write-PreflightReceipt -ReceiptRoot $receipts -Tree $script:OtherTree -Status PASS | Out-Null

            $out = Invoke-TipsHook -Command "git push origin feature/x && git -C '$($script:TipsWork)' push origin other" -ReceiptRoot $receipts

            $out | Should -Not -Match 'permissionDecision'
        }

        It 'refuses a chain of two pushes when only one pushed commit has a receipt' -Tag '#52' {
            $receipts = Join-Path $script:Tips 'one-of-two'
            Write-PreflightReceipt -ReceiptRoot $receipts -Tree $script:HeadTreeOfTips -Status PASS | Out-Null

            $out = Invoke-TipsHook -Command 'git push origin feature/x && git push origin other' -ReceiptRoot $receipts

            $out | Should -Match 'no green pre-flight'
        }
    }

    Context 'an unexpected error after the push filter (#52)' {
        BeforeAll {
            $script:Partial = Join-Path -Path $TestDrive -ChildPath 'partial-install'
            $partialHooks = Join-Path $script:Partial 'skills' 'ai-sdlc-hooks' 'scripts'
            $partialGates = Join-Path $script:Partial 'skills' 'ai-sdlc-gates' 'scripts'
            New-Item -ItemType Directory -Path $partialHooks, $partialGates -Force | Out-Null
            Copy-Item -LiteralPath $script:ScriptUnderTest -Destination $partialHooks
            Copy-Item -LiteralPath (Join-Path $script:ScriptFolder '..' '..' 'ai-sdlc-gates' 'scripts' 'AiSdlcConfig.psm1') -Destination $partialGates
            Set-Content -LiteralPath (Join-Path $partialGates 'PreflightReceipt.psm1') -Value 'function Get-HeadTree { param([string]$RepoRoot) return ''a'' * 40 }'
            $script:PartialHook = Join-Path $partialHooks 'Deny-IncompletePush.ps1'
        }

        It 'refuses the push and names the missing function when a module loads but lacks it' -Tag '#52' {
            $shell = Get-Command -Name pwsh -CommandType Application | Select-Object -First 1
            $out = & $shell -NoProfile -File $script:PartialHook -Payload (New-Payload -Command 'git push origin feature/x') -CheckScript $script:CleanCheck -CurrentBranch 'feature/x' -ReceiptRoot $script:Receipts -HeadTree $script:GreenTree -RepoRoot $script:Installing 2>&1 | Out-String

            $LASTEXITCODE | Should -Be 0
            ($out | ConvertFrom-Json).permissionDecision | Should -Be 'deny'
            $out | Should -Match 'no function Test-PushSendsNothingNew'
        }

        It 'allows the push with a warning that names the unexpected error' -Tag '#52' {
            $missing = Join-Path -Path $TestDrive -ChildPath 'no-such-folder'
            $shell = Get-Command -Name pwsh -CommandType Application | Select-Object -First 1

            $out = & $shell -NoProfile -File $script:ScriptUnderTest -Payload (New-Payload -Command 'git push origin feature/x') -CheckScript $script:CleanCheck -CurrentBranch 'feature/x' -ReceiptRoot $script:Receipts -HeadTree $script:GreenTree -RepoRoot $missing 2>&1 | Out-String

            $LASTEXITCODE | Should -Be 0
            $out | Should -Not -Match 'permissionDecision'
            ($out | ConvertFrom-Json).systemMessage | Should -Match 'unexpected error'
            ($out | ConvertFrom-Json).systemMessage | Should -Match 'no-such-folder'
        }

        It 'stays silent for a shell command that is not a push' -Tag '#52' {
            $shell = Get-Command -Name pwsh -CommandType Application | Select-Object -First 1
            $out = & $shell -NoProfile -File $script:PartialHook -Payload (New-Payload -Command 'git log --grep push') -CheckScript $script:CleanCheck -RepoRoot $script:Installing 2>&1 | Out-String

            $out.Trim() | Should -BeNullOrEmpty
        }
    }

    Context 'the exit code of git rev-parse (#52)' {
        BeforeAll {
            $script:RevTarget = Join-Path -Path $TestDrive -ChildPath 'rev-target-repo'
            New-Item -ItemType Directory -Path $script:RevTarget -Force | Out-Null
            git -C $script:RevTarget init --quiet -b feature/x
            Set-Content -LiteralPath (Join-Path $script:RevTarget 'aisdlc.json') -Value '{ }'
            $script:RevBroken = Join-Path -Path $TestDrive -ChildPath 'rev-broken'
            New-Item -ItemType Directory -Path $script:RevBroken -Force | Out-Null
            $script:RevNaming = Join-Path -Path $TestDrive -ChildPath 'rev-naming.ps1'
            Set-Content -Path $script:RevNaming -Value @'
param([switch]$Strict, [string]$RepoRoot)
Write-Output "judged $(Split-Path -Leaf $RepoRoot)"
exit 1
'@
        }

        It 'keeps the old target when git rev-parse fails for the cd folder, even when it prints a path' -Tag '#52' {
            $printedTop = $script:RevTarget
            $realGit = Get-Command -Name git -CommandType Application | Select-Object -First 1
            Set-Item -Path Function:\git -Value ({
                if ($args.Count -ge 4 -and $args[0] -eq '-C' -and (Split-Path -Leaf ([string]$args[1])) -eq 'rev-broken' -and $args[2] -eq 'rev-parse' -and $args[3] -eq '--show-toplevel') {
                    $printedTop
                    $global:LASTEXITCODE = 128
                    return
                }
                & $realGit @args
            }.GetNewClosure())
            try {
                $payload = @{ hook_event_name = 'PreToolUse'; tool_name = 'Bash'; tool_input = @{ command = ('cd {0} && git push origin feature/x' -f $script:RevBroken.Replace('\', '/')) } } | ConvertTo-Json -Compress
                $out = & $script:ScriptUnderTest -Payload $payload -CheckScript $script:RevNaming -ReceiptRoot $script:Receipts -HeadTree $script:GreenTree -RepoRoot $script:Installing *>&1 | Out-String

                $out | Should -Match 'judged installing-repo'
                $out | Should -Not -Match 'judged rev-target-repo'
            }
            finally { Remove-Item -Path Function:\git }
        }
    }

    Context 'the refusal text names no way past the git hook (#52)' {
        It 'tells an agent to stop and ask, and names no --no-verify step for it, when it refuses <Command>' -Tag '#52' -ForEach @(
            @{ Command = 'git -c core.hooksPath=/dev/null push origin feature/x'; Reason = 'git -c' }
            @{ Command = 'git push --tags origin'; Reason = 'cannot tell which commit' }
        ) {
            $r = Invoke-Hook -Payload (New-Payload -Command $Command) -CheckScript $script:CleanCheck

            ($r.Output | ConvertFrom-Json).permissionDecision | Should -Be 'deny'
            $r.Output | Should -Match $Reason
            $r.Output | Should -Match 'an agent stops and asks the person, and gives the push command in a code block the person can run'
            $r.Output | Should -Not -Match 'no-verify is the override|no-verify stays allowed|or push with --no-verify'
        }

        It 'says that only a person pushes with --no-verify when it refuses a git -c override' -Tag '#52' {
            $r = Invoke-Hook -Payload (New-Payload -Command 'git -c core.hooksPath=/dev/null push origin feature/x') -CheckScript $script:CleanCheck

            $r.Output | Should -Match 'Only a person pushes with git push --no-verify'
        }

        It 'names no --no-verify in a refusal for a missing receipt, a gap or a push to main' -Tag '#52' {
            foreach ($case in @(
                    @{ Command = 'git push'; Check = $script:CleanCheck; Branch = 'feature/1-x'; Tree = $script:UncheckedTree }
                    @{ Command = 'git push'; Check = $script:GapCheck; Branch = 'feature/1-x'; Tree = $script:GreenTree }
                    @{ Command = 'git push origin main'; Check = $script:CleanCheck; Branch = 'feature/1-x'; Tree = $script:GreenTree }
                )) {
                $r = Invoke-Hook -Payload (New-Payload -Command $case.Command) -CheckScript $case.Check -Branch $case.Branch -Tree $case.Tree
                $r.Output | Should -Match 'permissionDecision'
                $r.Output | Should -Not -Match 'no-verify'
            }
        }
    }
}
