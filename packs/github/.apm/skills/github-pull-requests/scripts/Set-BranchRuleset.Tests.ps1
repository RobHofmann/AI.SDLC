#requires -Version 7.4

Describe 'Set-BranchRuleset' {
    BeforeAll {
        $script:Tool = Join-Path $PSScriptRoot 'Set-BranchRuleset.ps1'

        function global:New-RulesetJson {
            param([int]$Id = 9, [string[]]$Checks = @('build-and-test', 'ai-sdlc'), [int]$Approvals = 0, [string]$Enforcement = 'active', [switch]$NoBranchGuards)
            $rules = @(
                @{ type = 'pull_request'; parameters = @{ required_approving_review_count = $Approvals } }
                @{ type = 'required_status_checks'; parameters = @{ required_status_checks = @($Checks | ForEach-Object { @{ context = $_ } }) } }
            )
            if (-not $NoBranchGuards) { $rules += @(@{ type = 'deletion' }, @{ type = 'non_fast_forward' }) }
            ConvertTo-Json -Depth 10 -InputObject @{
                id = $Id; name = 'ai-sdlc default branch'; target = 'branch'; enforcement = $Enforcement
                conditions = @{ ref_name = @{ include = @('~DEFAULT_BRANCH'); exclude = @() } }
                rules = $rules
            }
        }

        function New-Invoker {
            param([hashtable]$State)
            {
                param($ghArgs)
                $line = $ghArgs -join ' '
                $body = $null
                $index = [array]::IndexOf($ghArgs, '--input')
                if ($index -ge 0) { $body = Get-Content -LiteralPath $ghArgs[$index + 1] -Raw | ConvertFrom-Json }
                $State.Calls.Add([pscustomobject]@{ Line = $line; Body = $body })
                if ($line -match '--method (POST|PUT)') {
                    $checks = @(($body.rules | Where-Object type -EQ 'required_status_checks').parameters.required_status_checks.context)
                    $guards = @($body.rules | Where-Object { $_.type -in 'deletion', 'non_fast_forward' }).Count -eq 2
                    $State.Current = New-RulesetJson -Id 9 -Checks $checks -NoBranchGuards:(-not $guards)
                    return $State.Current
                }
                if ($line -match 'rulesets$') { return $State.List }
                if ($line -match 'rulesets/9$') { if ($State.BrokenReadBack -and @($State.Calls | Where-Object { $_.Line -match '--method' }).Count -gt 0) { return (New-RulesetJson -Approvals 1) }; return $State.Current }
            }.GetNewClosure()
        }

        function Invoke-Tool {
            param([hashtable]$State, [hashtable]$Extra = @{})
            & $script:Tool -RequiredCheck 'build-and-test', 'ai-sdlc' -Repository 'contoso/portal' -Invoker (New-Invoker -State $State) @Extra *>&1 | Out-String
        }

        function Get-Write {
            param([hashtable]$State)
            @($State.Calls | Where-Object { $_.Line -match '--method' })
        }
    }

    AfterAll {
        Remove-Item -Path Function:\New-RulesetJson -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $script:State = @{ Calls = [System.Collections.Generic.List[object]]::new(); List = '[]'; Current = $null; BrokenReadBack = $false }
    }

    It 'creates the ruleset on the default branch with zero approvals and the required checks, and reads it back' {
        $out = Invoke-Tool -State $script:State

        $writes = Get-Write -State $script:State
        $writes.Count | Should -Be 1
        $writes[0].Line | Should -Match '^api --method POST repos/contoso/portal/rulesets --input '
        $writes[0].Body.target | Should -Be 'branch'
        $writes[0].Body.enforcement | Should -Be 'active'
        $writes[0].Body.conditions.ref_name.include | Should -Be @('~DEFAULT_BRANCH')
        ($writes[0].Body.rules | Where-Object type -EQ 'pull_request').parameters.required_approving_review_count | Should -Be 0
        @(($writes[0].Body.rules | Where-Object type -EQ 'required_status_checks').parameters.required_status_checks.context) | Should -Be @('build-and-test', 'ai-sdlc')
        @($writes[0].Body.rules.type) | Should -Contain 'deletion'
        @($writes[0].Body.rules.type) | Should -Contain 'non_fast_forward'
        $out | Should -Match 'Created ruleset'
        $out | Should -Match 'Read back and verified'
    }

    It 'updates a ruleset that does not block a force push and the deletion of the branch' {
        $script:State.List = '[{ "id": 9, "name": "ai-sdlc default branch" }]'
        $script:State.Current = New-RulesetJson -NoBranchGuards

        $out = Invoke-Tool -State $script:State

        (Get-Write -State $script:State).Count | Should -Be 1 -Because $out
        $out | Should -Match 'Updated ruleset'
    }

    It 'keeps a check name with a comma whole when the checks come as more than one value' {
        & $script:Tool -RequiredCheck 'ai-sdlc', 'Test consumer: bicep-only,setup-script (fresh)' -Repository 'contoso/portal' -Invoker (New-Invoker -State $script:State) *>&1 | Out-Null

        @(((Get-Write -State $script:State)[0].Body.rules | Where-Object type -EQ 'required_status_checks').parameters.required_status_checks.context) | Should -Be @('ai-sdlc', 'Test consumer: bicep-only,setup-script (fresh)')
    }

    It 'changes nothing when the ruleset already matches' {
        $script:State.List = '[{ "id": 9, "name": "ai-sdlc default branch" }]'
        $script:State.Current = New-RulesetJson -Checks @('ai-sdlc', 'build-and-test')

        $out = Invoke-Tool -State $script:State

        (Get-Write -State $script:State).Count | Should -Be 0
        $out | Should -Match 'Nothing changed'
    }

    It 'updates the ruleset when its checks or approvals differ' {
        $script:State.List = '[{ "id": 9, "name": "ai-sdlc default branch" }]'
        $script:State.Current = New-RulesetJson -Checks @('build') -Approvals 1

        $out = Invoke-Tool -State $script:State

        $writes = Get-Write -State $script:State
        $writes.Count | Should -Be 1
        $writes[0].Line | Should -Match '^api --method PUT repos/contoso/portal/rulesets/9 '
        $out | Should -Match 'Updated ruleset'
    }

    It 'leaves a ruleset with another name alone and creates its own' {
        $script:State.List = '[{ "id": 3, "name": "release tags" }]'

        Invoke-Tool -State $script:State | Out-Null

        (Get-Write -State $script:State)[0].Line | Should -Match '--method POST'
        @($script:State.Calls | Where-Object { $_.Line -match 'rulesets/3' }).Count | Should -Be 0
    }

    It 'writes nothing with -WhatIf' {
        Invoke-Tool -State $script:State -Extra @{ WhatIf = $true } | Out-Null

        (Get-Write -State $script:State).Count | Should -Be 0
    }

    It 'throws when the ruleset does not read back as written' {
        $script:State.BrokenReadBack = $true
        $script:State.List = '[{ "id": 9, "name": "ai-sdlc default branch" }]'
        $script:State.Current = New-RulesetJson -Checks @('build')

        { Invoke-Tool -State $script:State } | Should -Throw '*does not read back as written*'
    }

    It 'takes the checks as one comma list, the form pwsh -File passes' {
        & $script:Tool -RequiredCheck 'build-and-test,ai-sdlc' -Repository 'contoso/portal' -Invoker (New-Invoker -State $script:State) *>&1 | Out-Null

        @(((Get-Write -State $script:State)[0].Body.rules | Where-Object type -EQ 'required_status_checks').parameters.required_status_checks.context) | Should -Be @('build-and-test', 'ai-sdlc')
    }
}
