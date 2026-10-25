#requires -Version 7.4
Describe 'Deny-AgentMerge' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Deny-AgentMerge.ps1'

        function Invoke-Hook {
            param([string]$Payload)
            $out = & $script:ScriptUnderTest -Payload $Payload *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }

        function New-Payload {
            param([string]$Command, [string]$Tool = 'Bash', [switch]$Copilot)
            if ($Copilot) {
                return (@{ toolName = $Tool; toolArgs = (@{ command = $Command } | ConvertTo-Json -Compress) } | ConvertTo-Json -Compress)
            }
            return (@{ hook_event_name = 'PreToolUse'; tool_name = $Tool; tool_input = @{ command = $Command } } | ConvertTo-Json -Compress)
        }
    }

    Context 'the merge commands it refuses' {
        It 'refuses <Command>' -ForEach @(
            @{ Command = 'gh pr merge 42 --squash' }
            @{ Command = 'gh pr merge --auto --squash 42' }
            @{ Command = 'gh -R contoso/portal pr merge 42' }
            @{ Command = 'gh pr -R contoso/portal merge' }
            @{ Command = 'git push && gh pr merge' }
            @{ Command = 'gh.exe pr merge 42' }
            @{ Command = 'gh api -X PUT repos/contoso/portal/pulls/42/merge' }
            @{ Command = 'gh api repos/contoso/portal/pulls/42/merge --method PUT' }
            @{ Command = 'gh api graphql -f query="mutation { mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }"' }
            @{ Command = 'gh api graphql -f query="mutation { enablePullRequestAutoMerge(input: {}) { clientMutationId } }"' }
        ) {
            $r = Invoke-Hook -Payload (New-Payload -Command $Command)

            $r.ExitCode | Should -Be 0
            $decision = $r.Output | ConvertFrom-Json
            $decision.permissionDecision | Should -Be 'deny'
            $decision.hookSpecificOutput.permissionDecision | Should -Be 'deny'
            $decision.permissionDecisionReason | Should -Match 'owner'
        }

        It 'refuses a merge through the PowerShell tool and in the Copilot payload shape' {
            $r = Invoke-Hook -Payload (New-Payload -Command 'gh pr merge 42' -Tool 'PowerShell' -Copilot)

            ($r.Output | ConvertFrom-Json).permissionDecision | Should -Be 'deny'
        }
    }

    Context 'the commands it allows' {
        It 'allows <Command>' -ForEach @(
            @{ Command = 'gh pr view 42' }
            @{ Command = 'gh pr create --title "Merge the two lists" --body "Fixes #42"' }
            @{ Command = 'gh pr checks 42' }
            @{ Command = 'git merge origin/main' }
            @{ Command = 'gh api repos/contoso/portal/pulls/42' }
            @{ Command = 'gh pr view 42 && git merge --ff-only' }
            @{ Command = 'echo merge' }
        ) {
            $r = Invoke-Hook -Payload (New-Payload -Command $Command)

            $r.ExitCode | Should -Be 0
            $r.Output | Should -Not -Match 'permissionDecision'
        }
    }

    Context 'fail-open' {
        It 'allows a payload it cannot read' {
            $r = Invoke-Hook -Payload '{ not json merge'

            $r.ExitCode | Should -Be 0
            $r.Output | Should -Not -Match 'permissionDecision'
        }

        It 'allows an empty payload' {
            $r = Invoke-Hook -Payload ''

            $r.ExitCode | Should -Be 0
            $r.Output | Should -BeNullOrEmpty
        }

        It 'allows a payload with no command' {
            $r = Invoke-Hook -Payload '{ "tool_input": { "file_path": "merge.md" } }'

            $r.Output | Should -Not -Match 'permissionDecision'
        }
    }
}
