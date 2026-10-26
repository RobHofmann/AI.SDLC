#requires -Version 7.4

Describe 'Reply-PullRequestThread' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Reply-PullRequestThread.ps1'

        function global:gh {
            $line = $args -join ' '
            $body = $null
            $index = [array]::IndexOf($args, '--input')
            if ($index -ge 0) {
                $file = $args[$index + 1]
                $global:ReplyTest.BodyFiles.Add($file)
                $body = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
            }
            $operation = if ($body.query -match 'addPullRequestReviewThreadReply') { 'reply' } elseif ($body.query -match 'resolveReviewThread') { 'resolve' } else { 'thread' }
            $global:ReplyTest.Calls.Add([pscustomobject]@{ Line = $line; Operation = $operation; Body = $body })
            $global:LASTEXITCODE = 0
            if ($global:ReplyTest.FailOn -eq $operation) {
                Write-Error 'HTTP 502: Bad Gateway' -ErrorAction Continue
                $global:LASTEXITCODE = 1
                return
            }
            if ($operation -eq 'thread') { return $global:ReplyTest.Thread }
            return '{ "data": {} }'
        }

        function New-ThreadJson {
            param([string]$Login, [string]$Type = 'User', [int]$Number = 42, [switch]$Resolved, [string]$Body = 'a finding')
            ConvertTo-Json -Depth 10 -InputObject @{ data = @{ node = @{
                        id = 'PRRT_t5'; isResolved = [bool]$Resolved; pullRequest = @{ number = $Number }
                        comments = @{ nodes = @(@{ author = @{ __typename = $Type; login = $Login }; body = $Body }) }
                    } } }
        }

        function Invoke-Reply {
            param([hashtable]$Extra = @{}, [string]$Message = 'Fixed in a1b2c3d.')
            $out = & $script:ScriptUnderTest -PullRequestId 42 -ThreadId 'PRRT_t5' -Message $Message @Extra *>&1 | Out-String
            [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out }
        }

        function Get-Call {
            param([string]$Operation)
            @($global:ReplyTest.Calls | Where-Object { $_.Operation -eq $Operation })
        }
    }

    BeforeEach {
        $global:ReplyTest = @{
            Calls     = [System.Collections.Generic.List[object]]::new()
            BodyFiles = [System.Collections.Generic.List[string]]::new()
            FailOn    = $null
            Thread    = New-ThreadJson -Login 'github-actions' -Type 'Bot' -Body 'gitleaks found a secret'
        }
    }

    AfterAll {
        Remove-Item -Path Function:\gh -ErrorAction SilentlyContinue
        Remove-Variable -Name ReplyTest -Scope Global -ErrorAction SilentlyContinue
    }

    It 'exits 1 with a clear message and calls nothing when the message is <Name>' -ForEach @(
        @{ Name = 'empty'; Text = '' }
        @{ Name = 'only spaces'; Text = '   ' }
    ) {
        $r = Invoke-Reply -Message $Text

        $r.Code | Should -Be 1
        $r.Output | Should -Match 'Reply: the message is empty\.'
        $global:ReplyTest.Calls.Count | Should -Be 0
    }

    It 'reads the thread, then posts the reply through gh api graphql' {
        $r = Invoke-Reply

        $r.Code | Should -Be 0
        $read = Get-Call -Operation 'thread'
        $read.Count | Should -Be 1
        $read[0].Line | Should -Match '^api graphql --input '
        $read[0].Body.variables.thread | Should -Be 'PRRT_t5'
        $post = Get-Call -Operation 'reply'
        $post.Count | Should -Be 1
        $post[0].Body.variables.body | Should -Be 'Fixed in a1b2c3d.'
        $post[0].Body.variables.thread | Should -Be 'PRRT_t5'
    }

    It 'keeps quotes and line breaks of the reply, because the body goes in a file' {
        Invoke-Reply -Message "Declined: `"by design`".`nSee the ADR." | Out-Null

        (Get-Call -Operation 'reply')[0].Body.variables.body | Should -BeExactly "Declined: `"by design`".`nSee the ADR."
    }

    It 'resolves a gitleaks thread when asked' {
        Invoke-Reply -Extra @{ Resolve = $true } | Out-Null

        $resolve = Get-Call -Operation 'resolve'
        $resolve.Count | Should -Be 1
        $resolve[0].Body.variables.thread | Should -Be 'PRRT_t5'
    }

    It 'resolves a sonarcloud thread when asked' {
        $global:ReplyTest.Thread = New-ThreadJson -Login 'sonarqubecloud' -Type 'Bot' -Body 'See it in SonarQube Cloud'

        $r = Invoke-Reply -Extra @{ Resolve = $true }

        $r.Code | Should -Be 0
        (Get-Call -Operation 'resolve').Count | Should -Be 1
    }

    It 'exits 1 and writes nothing when asked to resolve the thread of a bot that is not a known tool' {
        $global:ReplyTest.Thread = New-ThreadJson -Login 'review-helper' -Type 'Bot' -Body 'possible null reference'

        $r = Invoke-Reply -Extra @{ Resolve = $true }

        $r.Code | Should -Be 1
        $r.Output | Should -Match 'not a known tool'
        $r.Output | Should -Match 'C09'
        (Get-Call -Operation 'reply').Count | Should -Be 0
        (Get-Call -Operation 'resolve').Count | Should -Be 0
    }

    It 'posts the reply on the thread of a bot that is not a known tool when not asked to resolve' {
        $global:ReplyTest.Thread = New-ThreadJson -Login 'github-actions' -Type 'Bot' -Body 'lint warning'

        $r = Invoke-Reply

        $r.Code | Should -Be 0
        (Get-Call -Operation 'reply').Count | Should -Be 1
        (Get-Call -Operation 'resolve').Count | Should -Be 0
    }

    It 'resolves nothing when not asked' {
        Invoke-Reply | Out-Null

        (Get-Call -Operation 'resolve').Count | Should -Be 0
    }

    It 'does not resolve a bot thread a second time' {
        $global:ReplyTest.Thread = New-ThreadJson -Login 'github-actions' -Type 'Bot' -Body 'gitleaks found a secret' -Resolved

        $r = Invoke-Reply -Extra @{ Resolve = $true }

        $r.Output | Should -Match 'already resolved'
        (Get-Call -Operation 'resolve').Count | Should -Be 0
    }

    It 'posts the reply on a thread a person started but never resolves it' {
        $global:ReplyTest.Thread = New-ThreadJson -Login 'a-reviewer'

        $r = Invoke-Reply -Extra @{ Resolve = $true }

        $r.Code | Should -Be 0
        (Get-Call -Operation 'reply').Count | Should -Be 1
        (Get-Call -Operation 'resolve').Count | Should -Be 0
        $r.Output | Should -Match 'C09'
    }

    It 'removes the temporary body files after the calls' {
        Invoke-Reply -Extra @{ Resolve = $true } | Out-Null

        $global:ReplyTest.BodyFiles.Count | Should -Be 3
        foreach ($file in $global:ReplyTest.BodyFiles) { Test-Path -LiteralPath $file | Should -BeFalse }
    }

    It 'exits 1 and writes nothing when the thread belongs to another pull request' {
        $global:ReplyTest.Thread = New-ThreadJson -Login 'review-helper' -Type 'Bot' -Number 7

        $r = Invoke-Reply -Extra @{ Resolve = $true }

        $r.Code | Should -Be 1
        $r.Output | Should -Match 'belongs to pull request 7'
        (Get-Call -Operation 'reply').Count | Should -Be 0
    }

    It 'exits 1 and writes nothing when the id is not a review thread' {
        $global:ReplyTest.Thread = '{ "data": { "node": null } }'

        $r = Invoke-Reply

        $r.Code | Should -Be 1
        (Get-Call -Operation 'reply').Count | Should -Be 0
    }

    It 'exits 2 and posts nothing when the thread cannot be read' {
        $global:ReplyTest.FailOn = 'thread'

        $r = Invoke-Reply -Extra @{ Resolve = $true }

        $r.Code | Should -Be 2
        (Get-Call -Operation 'reply').Count | Should -Be 0
    }

    It 'exits 2 and leaves the thread open when the reply cannot be posted' {
        $global:ReplyTest.FailOn = 'reply'

        $r = Invoke-Reply -Extra @{ Resolve = $true }

        $r.Code | Should -Be 2
        (Get-Call -Operation 'resolve').Count | Should -Be 0
    }
}
