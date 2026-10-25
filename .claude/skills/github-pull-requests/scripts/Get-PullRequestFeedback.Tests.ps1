#requires -Version 7.4

Describe 'Get-PullRequestFeedback' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Get-PullRequestFeedback.ps1'

        function global:gh {
            $global:FeedbackTest.Calls.Add(($args -join ' '))
            $global:LASTEXITCODE = 0
            $line = $args -join ' '
            if ($global:FeedbackTest.Fail) {
                Write-Error 'HTTP 401: Bad credentials' -ErrorAction Continue
                $global:LASTEXITCODE = 1
                return
            }
            if ($line -match '^pr view') {
                if ($global:FeedbackTest.LaterPr.Count -gt 0 -and @($global:FeedbackTest.Calls | Where-Object { $_ -match '^pr view' }).Count -gt 1) {
                    return $global:FeedbackTest.LaterPr.Dequeue()
                }
                return $global:FeedbackTest.Pr
            }
            if ($line -match '^api graphql' -and $line -match 'cursor=(\S+)') { return $global:FeedbackTest.ThreadPages[$Matches[1]] }
            if ($line -match '^api graphql') { return $global:FeedbackTest.Threads }
        }

        function New-PrJson {
            param([object[]]$Checks, [string]$CommittedDate = '2026-09-23T10:00:00Z')
            ConvertTo-Json -Depth 8 -InputObject @{
                number            = 42
                headRefOid        = 'head1'
                commits           = @(@{ oid = 'head1'; committedDate = $CommittedDate })
                statusCheckRollup = @($Checks)
            }
        }

        function New-Check {
            param([string]$Status = 'COMPLETED', [string]$Conclusion = 'SUCCESS')
            @{ __typename = 'CheckRun'; name = 'build-and-test'; status = $Status; conclusion = $Conclusion; detailsUrl = 'https://github.com/contoso/portal/actions/runs/11/job/12' }
        }

        function New-ThreadsJson {
            param([object[]]$Threads = @(), [object[]]$Comments = @(), [string]$NextCursor = '')
            $pageInfo = @{ hasNextPage = [bool]$NextCursor; endCursor = $(if ($NextCursor) { $NextCursor } else { $null }) }
            ConvertTo-Json -Depth 12 -InputObject @{ data = @{ repository = @{ pullRequest = @{ reviewThreads = @{ pageInfo = $pageInfo; nodes = @($Threads) }; comments = @{ nodes = @($Comments) } } } } }
        }

        function New-Thread {
            param([string]$Id, [string]$Login, [string]$Type, [string]$Content)
            @{ id = $Id; isResolved = $false; isOutdated = $false; path = 'src/a.cs'; line = 3
                comments = @{ nodes = @(@{ author = @{ __typename = $Type; login = $Login }; body = $Content; createdAt = '2026-09-23T10:05:00Z'; originalCommit = @{ oid = 'head1' } }) }
            }
        }

        function Invoke-Feedback {
            param([hashtable]$Extra = @{})
            $out = & $script:ScriptUnderTest -PullRequestId 42 -Repository 'contoso/portal' @Extra 2>&1 | Out-String
            [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out }
        }
    }

    BeforeEach {
        $global:FeedbackTest = @{
            Calls   = [System.Collections.Generic.List[string]]::new()
            Fail    = $false
            Pr      = New-PrJson -Checks @(New-Check)
            LaterPr = [System.Collections.Generic.Queue[string]]::new()
            Threads = New-ThreadsJson
            ThreadPages = @{}
        }
    }

    AfterAll {
        Remove-Item -Path Function:\gh -ErrorAction SilentlyContinue
        Remove-Variable -Name FeedbackTest -Scope Global -ErrorAction SilentlyContinue
    }

    It 'reads the checks with gh pr view and the threads with gh api graphql' {
        $r = Invoke-Feedback

        $r.Code | Should -Be 0
        $calls = $global:FeedbackTest.Calls
        @($calls | Where-Object { $_ -match '^pr view 42 --repo contoso/portal --json number,headRefOid,commits,statusCheckRollup$' }).Count | Should -Be 1
        @($calls | Where-Object { $_ -match '(?s)^api graphql -f query=.*reviewThreads.* -F owner=contoso -F name=portal -F number=42$' }).Count | Should -Be 1
    }

    It 'is ready when every check is done' {
        $report = (Invoke-Feedback).Output | ConvertFrom-Json

        $report.State | Should -Be 'ready'
        $report.HeadCommit | Should -Be 'head1'
        $report.Checks[0].RunId | Should -Be 11
    }

    It 'counts a skipped or neutral check as passed' {
        $global:FeedbackTest.Pr = New-PrJson -Checks @((New-Check -Conclusion 'SKIPPED'), (New-Check -Conclusion 'NEUTRAL'))

        $report = (Invoke-Feedback).Output | ConvertFrom-Json

        @($report.Checks | Where-Object Status -EQ 'pass').Count | Should -Be 2
    }

    It 'is ready with a note when no check ran on a head commit older than the grace period' {
        $global:FeedbackTest.Pr = New-PrJson -Checks @()

        $report = (Invoke-Feedback).Output | ConvertFrom-Json

        $report.State | Should -Be 'ready'
        $report.Note | Should -Match 'No check ran on the head commit'
    }

    It 'is pending, not ready, when no check has registered yet on a new head commit' {
        $global:FeedbackTest.Pr = New-PrJson -Checks @() -CommittedDate (Get-Date).ToUniversalTime().ToString('o')

        $report = (Invoke-Feedback).Output | ConvertFrom-Json

        $report.State | Should -Be 'pending'
        $report.Note | Should -BeNullOrEmpty
    }

    It 'keeps polling with -Wait until the first check registers and is done' {
        $now = (Get-Date).ToUniversalTime().ToString('o')
        $global:FeedbackTest.Pr = New-PrJson -Checks @() -CommittedDate $now
        $global:FeedbackTest.LaterPr.Enqueue((New-PrJson -Checks @(New-Check -Status 'QUEUED' -Conclusion '') -CommittedDate $now))
        $global:FeedbackTest.LaterPr.Enqueue((New-PrJson -Checks @(New-Check) -CommittedDate $now))

        $report = (Invoke-Feedback -Extra @{ Wait = $true; PollSeconds = 0; TimeoutMinutes = 1 }).Output | ConvertFrom-Json

        $report.State | Should -Be 'ready'
        @($report.Checks).Count | Should -Be 1
        @($global:FeedbackTest.Calls | Where-Object { $_ -match '^pr view' }).Count | Should -Be 3
    }

    It 'returns ready with a note once the grace period passes with still no check' {
        $global:FeedbackTest.Pr = New-PrJson -Checks @() -CommittedDate (Get-Date).ToUniversalTime().ToString('o')

        $report = (Invoke-Feedback -Extra @{ Wait = $true; PollSeconds = 0; TimeoutMinutes = 1; NoCheckGraceMinutes = 0.01 }).Output | ConvertFrom-Json

        $report.State | Should -Be 'ready'
        $report.Note | Should -Match 'No check ran on the head commit'
    }

    It 'reads every page of review threads when GitHub has more than one page' {
        $global:FeedbackTest.Threads = New-ThreadsJson -Threads @(New-Thread -Id 'T1' -Login 'a-reviewer' -Type 'User' -Content 'one') -NextCursor 'page2'
        $global:FeedbackTest.ThreadPages['page2'] = New-ThreadsJson -Threads @(New-Thread -Id 'T2' -Login 'a-reviewer' -Type 'User' -Content 'two')

        $report = (Invoke-Feedback).Output | ConvertFrom-Json

        @($report.OpenThreads.Id) | Should -Be @('T1', 'T2')
        @($global:FeedbackTest.Calls | Where-Object { $_ -match '(?s)^api graphql .* -f cursor=page2$' }).Count | Should -Be 1
    }

    It 'lists the open threads by source' {
        $global:FeedbackTest.Threads = New-ThreadsJson -Threads @(
            (New-Thread -Id 'T1' -Login 'review-helper' -Type 'Bot' -Content 'bug')
            (New-Thread -Id 'T2' -Login 'a-reviewer' -Type 'User' -Content 'rename')
            (New-Thread -Id 'T3' -Login 'github-actions' -Type 'Bot' -Content 'gitleaks found a secret')
        )

        $report = (Invoke-Feedback).Output | ConvertFrom-Json

        @($report.OpenThreads).Count | Should -Be 3
        ($report.OpenThreads | Where-Object Id -EQ 'T3').Kind | Should -Be 'gitleaks'
        ($report.OpenThreads | Where-Object Id -EQ 'T3').Author | Should -Be 'github-actions[bot]'
        $report.Summary | Should -Match '3 open thread'
    }

    It 'lists a bot comment since the head commit, such as a quality gate summary' {
        $global:FeedbackTest.Threads = New-ThreadsJson -Comments @(@{ id = 'C1'; author = @{ __typename = 'Bot'; login = 'sonarqubecloud' }; body = 'Quality Gate failed on sonarcloud.io'; createdAt = '2026-09-23T10:20:00Z' })

        $report = (Invoke-Feedback).Output | ConvertFrom-Json

        $report.BotComments[0].Kind | Should -Be 'sonarcloud'
        $report.Summary | Should -Match '1 new bot comment'
    }

    It 'polls again with -Wait until the checks are no longer pending' {
        $global:FeedbackTest.Pr = New-PrJson -Checks @(New-Check -Status 'IN_PROGRESS' -Conclusion '')
        $global:FeedbackTest.LaterPr.Enqueue((New-PrJson -Checks @(New-Check)))

        $report = (Invoke-Feedback -Extra @{ Wait = $true; PollSeconds = 0; TimeoutMinutes = 1 }).Output | ConvertFrom-Json

        $report.State | Should -Be 'ready'
        @($global:FeedbackTest.Calls | Where-Object { $_ -match '^pr view' }).Count | Should -Be 2
    }

    It 'exits 2 and prints no report when gh fails' {
        $global:FeedbackTest.Fail = $true

        $r = Invoke-Feedback

        $r.Code | Should -Be 2
        $r.Output | Should -Not -Match '"State"'
    }
}
