#requires -Version 7.4

BeforeAll { $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm' }

Describe 'Request-CopilotReview' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $script:ScriptFolder -ChildPath 'Request-CopilotReview.ps1'
        $script:Sha1 = 'aaaaaaa1111111111111111111111111111111aa'
        $script:Sha2 = 'bbbbbbb2222222222222222222222222222222bb'

        function Invoke-Helper {
            param([hashtable]$Parameters)
            if (-not $Parameters.ContainsKey('Repository')) { $Parameters['Repository'] = 'contoso/portal' }
            if (-not $Parameters.ContainsKey('Id')) { $Parameters['Id'] = 42 }
            return (& $script:ScriptUnderTest @Parameters)
        }

        function New-Review {
            param([string]$Login, [object]$CommitId, [object]$IsCopilot = $null)
            $review = [ordered]@{ user = [ordered]@{ login = $Login }; commit_id = $CommitId }
            if ($null -ne $IsCopilot) { $review['is_copilot_code_review'] = $IsCopilot }
            return $review
        }

        # A fake gh. -Reviews is the list the api call returns; -FailList and -FailRequest make a call throw.
        function New-Invoker {
            param([hashtable]$State, [object[]]$Reviews = @(), [string]$RawList, [switch]$FailList, [switch]$FailRequest)
            $State.Calls = [System.Collections.Generic.List[string]]::new()
            $State.RequestArgs = $null
            return {
                param($ghArgs)
                $State.Calls.Add(([string[]]$ghArgs) -join ' ')
                if ($ghArgs[0] -eq 'api') {
                    if ($FailList) { throw 'list refused' }
                    if ($RawList) { return $RawList }
                    return (ConvertTo-Json -InputObject @($Reviews) -Depth 5)
                }
                if ($ghArgs[0] -eq 'pr' -and $ghArgs[1] -eq 'edit') {
                    $State.RequestArgs = [string[]]$ghArgs
                    if ($FailRequest) { throw 'request refused' }
                    return ''
                }
                throw "unexpected gh call: $($ghArgs -join ' ')"
            }.GetNewClosure()
        }

        function New-GitInvoker {
            param([hashtable]$State, [string]$Output = '', [switch]$Fail)
            $State.GitArgs = $null
            return {
                param($gitArgs)
                $State.GitArgs = [string[]]$gitArgs
                if ($Fail) { throw 'bad object' }
                return $Output
            }.GetNewClosure()
        }
    }

    It 'asks for a review when there is no earlier Copilot review' {
        $state = @{}
        $result = Invoke-Helper -Parameters @{ GhInvoker = (New-Invoker -State $state -Reviews @((New-Review -Login 'maria' -CommitId $script:Sha1))) }

        $result.Requested | Should -BeTrue
        $result.Reason | Should -Be 'first review'
        $result.ReviewedCommit | Should -BeNullOrEmpty
        $state.RequestArgs | Should -Be @('pr', 'edit', '42', '--repo', 'contoso/portal', '--add-reviewer', '@copilot')
    }

    It 'lists the reviews with gh api and --paginate' {
        $state = @{}
        Invoke-Helper -Parameters @{ GhInvoker = (New-Invoker -State $state) } | Out-Null

        $state.Calls[0] | Should -Be 'api repos/contoso/portal/pulls/42/reviews --paginate'
    }

    It 'asks with -Force and does not count' {
        $state = @{}
        $git = New-GitInvoker -State $state
        $result = Invoke-Helper -Parameters @{ Force = $true; GitInvoker = $git; GhInvoker = (New-Invoker -State $state -Reviews @((New-Review -Login 'copilot-pull-request-reviewer[bot]' -CommitId $script:Sha1 -IsCopilot $true))) }

        $result.Requested | Should -BeTrue
        $result.Reason | Should -Be 'forced'
        $state.GitArgs | Should -BeNullOrEmpty
    }

    It 'asks at exactly 20 changed lines' {
        $state = @{}
        $result = Invoke-Helper -Parameters @{
            GitInvoker = (New-GitInvoker -State $state -Output "12`t3`tsrc/a.cs`n5`t0`tsrc/b.cs`n")
            GhInvoker = (New-Invoker -State $state -Reviews @((New-Review -Login 'copilot-pull-request-reviewer[bot]' -CommitId $script:Sha1 -IsCopilot $true)))
        }

        $result.Requested | Should -BeTrue
        $result.ChangedLines | Should -Be 20
        $result.ReviewedCommit | Should -Be $script:Sha1
        $result.Reason | Should -Be 'changed 20 lines since aaaaaaa'
        $state.GitArgs | Should -Be @('diff', '--numstat', $script:Sha1, 'HEAD')
    }

    It 'does not ask at 19 changed lines, and says why' {
        $state = @{}
        $result = Invoke-Helper -Parameters @{
            GitInvoker = (New-GitInvoker -State $state -Output "12`t3`tsrc/a.cs`n4`t0`tsrc/b.cs`n")
            GhInvoker = (New-Invoker -State $state -Reviews @((New-Review -Login 'copilot-pull-request-reviewer[bot]' -CommitId $script:Sha1 -IsCopilot $true)))
        } 6>&1

        $info = @($result | Where-Object { $_ -is [System.Management.Automation.InformationRecord] })
        $object = @($result | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })[-1]
        $object.Requested | Should -BeFalse
        $object.ChangedLines | Should -Be 19
        $object.Reason | Should -Be 'only 19 changed lines since aaaaaaa, below 20'
        $state.RequestArgs | Should -BeNullOrEmpty
        ($info | Out-String) | Should -Match 'only 19 changed lines'
    }

    It 'uses -MinChangedLines as the threshold' {
        $state = @{}
        $result = Invoke-Helper -Parameters @{
            MinChangedLines = 5
            GitInvoker = (New-GitInvoker -State $state -Output "5`t0`tsrc/a.cs")
            GhInvoker = (New-Invoker -State $state -Reviews @((New-Review -Login 'copilot-pull-request-reviewer[bot]' -CommitId $script:Sha1 -IsCopilot $true)))
        }

        $result.Requested | Should -BeTrue
    }

    It 'does not count a binary file row' {
        $state = @{}
        $result = Invoke-Helper -Parameters @{
            GitInvoker = (New-GitInvoker -State $state -Output "-`t-`tlogo.png`n3`t2`tsrc/a.cs`n")
            GhInvoker = (New-Invoker -State $state -Reviews @((New-Review -Login 'copilot-pull-request-reviewer[bot]' -CommitId $script:Sha1 -IsCopilot $true)))
        } 6>$null

        $result.ChangedLines | Should -Be 5
        $result.Requested | Should -BeFalse
    }

    It 'asks when git cannot count' {
        $state = @{}
        $result = Invoke-Helper -Parameters @{
            GitInvoker = (New-GitInvoker -State $state -Fail)
            GhInvoker = (New-Invoker -State $state -Reviews @((New-Review -Login 'copilot-pull-request-reviewer[bot]' -CommitId $script:Sha1 -IsCopilot $true)))
        }

        $result.Requested | Should -BeTrue
        $result.Reason | Should -Be 'could not count, asked'
        $result.ChangedLines | Should -BeNullOrEmpty
        $state.RequestArgs | Should -Contain '@copilot'
    }

    It 'warns and returns Requested false, without throwing, when the request fails' {
        $state = @{}
        { $script:out = @(Invoke-Helper -Parameters @{ Force = $true; GhInvoker = (New-Invoker -State $state -FailRequest) } 3>&1) } | Should -Not -Throw

        $warning = @($script:out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })[0]
        $result = @($script:out | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })[-1]
        $result.Requested | Should -BeFalse
        $result.Reason | Should -BeLike 'request failed: *request refused*'
        $warning.Message | Should -BeLike 'Copilot review not requested on PR 42: *request refused*. Go on without it and say so in the evidence record.'
    }

    It 'warns and does not throw when the review list fails' {
        $state = @{}
        { $script:out = @(Invoke-Helper -Parameters @{ GhInvoker = (New-Invoker -State $state -FailList) } 3>&1) } | Should -Not -Throw

        $warning = @($script:out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })[0]
        $result = @($script:out | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })[-1]
        $result.Requested | Should -BeFalse
        $warning.Message | Should -BeLike 'Copilot review not requested on PR 42: *list refused*. Go on without it and say so in the evidence record.'
        $state.RequestArgs | Should -BeNullOrEmpty
    }

    It 'finds the Copilot review by the flag and ignores a human review' {
        $state = @{}
        $reviews = @(
            (New-Review -Login 'some-bot' -CommitId $script:Sha1 -IsCopilot $true)
            (New-Review -Login 'maria' -CommitId $script:Sha2 -IsCopilot $false)
        )
        $result = Invoke-Helper -Parameters @{
            GitInvoker = (New-GitInvoker -State $state -Output "1`t0`ta")
            GhInvoker = (New-Invoker -State $state -Reviews $reviews)
        } 6>$null

        $result.ReviewedCommit | Should -Be $script:Sha1
    }

    It 'finds the Copilot review by login when the flag is missing' -ForEach @(
        @{ Login = 'copilot-pull-request-reviewer[bot]' }
        @{ Login = 'Copilot' }
    ) {
        $state = @{}
        $reviews = @((New-Review -Login $Login -CommitId $script:Sha1), (New-Review -Login 'maria' -CommitId $script:Sha2))
        $result = Invoke-Helper -Parameters @{
            GitInvoker = (New-GitInvoker -State $state -Output "1`t0`ta")
            GhInvoker = (New-Invoker -State $state -Reviews $reviews)
        } 6>$null

        $result.ReviewedCommit | Should -Be $script:Sha1
    }

    It 'treats a human review as no Copilot review' {
        $state = @{}
        $result = Invoke-Helper -Parameters @{ GhInvoker = (New-Invoker -State $state -Reviews @((New-Review -Login 'copilot-fan' -CommitId $script:Sha1))) }

        $result.Reason | Should -Be 'first review'
    }

    It 'counts from the commit of the LAST Copilot review' {
        $state = @{}
        $reviews = @(
            (New-Review -Login 'copilot-pull-request-reviewer[bot]' -CommitId $script:Sha1 -IsCopilot $true)
            (New-Review -Login 'maria' -CommitId 'ccccccc3333333333333333333333333333333cc' -IsCopilot $false)
            (New-Review -Login 'copilot-pull-request-reviewer[bot]' -CommitId $script:Sha2 -IsCopilot $true)
        )
        $result = Invoke-Helper -Parameters @{
            GitInvoker = (New-GitInvoker -State $state -Output "30`t0`ta")
            GhInvoker = (New-Invoker -State $state -Reviews $reviews)
        }

        $result.ReviewedCommit | Should -Be $script:Sha2
        $state.GitArgs[2] | Should -Be $script:Sha2
    }

    It 'reads a --paginate list that holds several JSON arrays one after the other' {
        $state = @{}
        $page1 = ConvertTo-Json -InputObject @(, (New-Review -Login 'maria' -CommitId $script:Sha1)) -Depth 5 -Compress
        $page2 = ConvertTo-Json -InputObject @(, (New-Review -Login 'copilot-pull-request-reviewer[bot]' -CommitId $script:Sha2 -IsCopilot $true)) -Depth 5 -Compress
        $result = Invoke-Helper -Parameters @{
            GitInvoker = (New-GitInvoker -State $state -Output "30`t0`ta")
            GhInvoker = (New-Invoker -State $state -RawList "$page1$page2")
        }

        $result.ReviewedCommit | Should -Be $script:Sha2
    }

    It 'ignores a Copilot review that has no commit and asks as for a first review' {
        $state = @{}
        $result = Invoke-Helper -Parameters @{ GhInvoker = (New-Invoker -State $state -Reviews @((New-Review -Login 'copilot-pull-request-reviewer[bot]' -CommitId $null -IsCopilot $true))) }

        $result.Reason | Should -Be 'first review'
    }
}
