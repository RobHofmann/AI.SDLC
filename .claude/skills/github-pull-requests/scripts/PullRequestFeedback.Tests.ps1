#requires -Version 7.4

Describe 'The pull request feedback loop' {
    BeforeAll {
        $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
        if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
        Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
        Import-Module (Join-Path $PSScriptRoot 'PullRequestFeedback.psm1') -Force
        $script:GetFeedback = Join-Path $PSScriptRoot 'Get-PullRequestFeedback.ps1'
        $script:Reply = Join-Path $PSScriptRoot 'Reply-PullRequestThread.ps1'

        function New-Thread {
            param([string]$Id, [string]$Login, [string]$Content, [string]$Type = 'User', [switch]$Resolved, [string]$Commit = 'head1', [string]$Published = '2026-09-23T10:05:00Z')
            [pscustomobject]@{
                id         = $Id
                isResolved = [bool]$Resolved
                isOutdated = $false
                path       = 'src/a.cs'
                line       = 4
                comments   = [pscustomobject]@{ nodes = @([pscustomobject]@{
                            author         = [pscustomobject]@{ __typename = $Type; login = $Login }
                            body           = $Content
                            createdAt      = $Published
                            originalCommit = [pscustomobject]@{ oid = $Commit }
                        }) }
            }
        }

        function New-Comment {
            param([string]$Id, [string]$Login, [string]$Content, [string]$Type = 'Bot', [string]$Published = '2026-09-23T10:05:00Z')
            [pscustomobject]@{ id = $Id; author = [pscustomobject]@{ __typename = $Type; login = $Login }; body = $Content; createdAt = $Published }
        }

        function New-ThreadsResponse {
            param([object[]]$Threads = @(), [object[]]$Comments = @())
            [pscustomobject]@{ data = [pscustomobject]@{ repository = [pscustomobject]@{ pullRequest = [pscustomobject]@{
                            reviewThreads = [pscustomobject]@{ nodes = @($Threads) }
                            comments      = [pscustomobject]@{ nodes = @($Comments) }
                        } } } }
        }

        function New-CheckRun {
            param([string]$Status = 'COMPLETED', [string]$Conclusion = 'SUCCESS', [string]$Name = 'build-and-test')
            [pscustomobject]@{ __typename = 'CheckRun'; name = $Name; status = $Status; conclusion = $Conclusion; detailsUrl = 'https://github.com/contoso/portal/actions/runs/7/job/70'; workflowName = 'PR' }
        }

        function New-Pr {
            param([object[]]$Checks = @(), [string]$Head = 'head1')
            [pscustomobject]@{ number = 1; headRefOid = $Head; commits = @([pscustomobject]@{ oid = $Head; committedDate = '2026-09-23T10:00:00Z' }); statusCheckRollup = @($Checks) }
        }
    }

    Context 'which source a thread came from' {
        It 'reads <Expected> from the author or the text' -ForEach @(
            @{ Login = 'github-actions[bot]'; Type = 'Bot'; Content = 'gitleaks found a secret'; Expected = 'gitleaks' }
            @{ Login = 'sonarqubecloud'; Type = 'Bot'; Content = 'See it in SonarQube Cloud https://sonarcloud.io/x'; Expected = 'sonarcloud' }
            @{ Login = 'review-helper'; Type = 'Bot'; Content = 'possible null reference'; Expected = 'bot' }
            @{ Login = 'review-helper[bot]'; Type = ''; Content = 'possible null reference'; Expected = 'bot' }
            @{ Login = 'a-reviewer'; Type = 'User'; Content = 'please rename this'; Expected = 'human' }
            @{ Login = 'a-reviewer'; Type = 'User'; Content = 'the gitleaks finding on sonarcloud.io is a false positive'; Expected = 'human' }
            @{ Login = 'robotics-team'; Type = 'User'; Content = 'gitleaks found a secret'; Expected = 'human' }
        ) {
            Get-ThreadKind -Thread (New-Thread -Id 'T1' -Login $Login -Type $Type -Content $Content) | Should -Be $Expected
        }

        It 'writes the login of a bot with the [bot] suffix, as REST does' {
            Get-AuthorLogin -Author ([pscustomobject]@{ __typename = 'Bot'; login = 'sonarqubecloud' }) | Should -Be 'sonarqubecloud[bot]'
            Get-AuthorLogin -Author ([pscustomobject]@{ __typename = 'User'; login = 'a-reviewer' }) | Should -Be 'a-reviewer'
        }

        It 'lists only the unresolved threads, with their file, line and commit' {
            $response = New-ThreadsResponse -Threads @(
                (New-Thread -Id 'T1' -Login 'a-reviewer' -Content 'fix')
                (New-Thread -Id 'T2' -Login 'a-reviewer' -Content 'done' -Resolved)
            )
            $open = @(Get-OpenThread -ThreadsResponse $response)
            $open.Id | Should -Be @('T1')
            $open[0].File | Should -Be 'src/a.cs'
            $open[0].Line | Should -Be 4
            $open[0].CommitId | Should -Be 'head1'
            $open[0].AuthorKind | Should -Be 'human'
        }

        It 'lists the bot comments since a date, and leaves the comments of people out' {
            $response = New-ThreadsResponse -Comments @(
                (New-Comment -Id 'C1' -Login 'sonarqubecloud' -Content 'Quality Gate failed, see sonarcloud.io')
                (New-Comment -Id 'C2' -Login 'sonarqubecloud' -Content 'old run' -Published '2026-09-22T10:00:00Z')
                (New-Comment -Id 'C3' -Login 'a-reviewer' -Type 'User' -Content 'looks fine')
            )
            $comments = @(Get-BotComment -ThreadsResponse $response -Since '2026-09-23T10:00:00Z')
            $comments.Id | Should -Be @('C1')
            $comments[0].Kind | Should -Be 'sonarcloud'
        }
    }

    Context 'Read-ReviewThread reads every page of review threads' {
        BeforeAll {
            function New-Page {
                param([string[]]$Ids, [string]$Next = '')
                $response = New-ThreadsResponse -Threads @($Ids | ForEach-Object { New-Thread -Id $_ -Login 'a-reviewer' -Content 'x' })
                $response.data.repository.pullRequest.reviewThreads | Add-Member -NotePropertyName pageInfo -NotePropertyValue ([pscustomobject]@{ hasNextPage = [bool]$Next; endCursor = $Next })
                $response
            }
        }

        It 'follows pageInfo to the last page and keeps every thread' {
            $pages = @{ '' = (New-Page -Ids 'T1', 'T2' -Next 'c2'); 'c2' = (New-Page -Ids 'T3' -Next 'c3'); 'c3' = (New-Page -Ids 'T4') }
            $asked = [System.Collections.Generic.List[string]]::new()
            $read = { param($Cursor) $asked.Add($Cursor); $pages[$Cursor] }.GetNewClosure()

            $response = Read-ReviewThread -ReadPage $read

            @(Get-OpenThread -ThreadsResponse $response).Id | Should -Be @('T1', 'T2', 'T3', 'T4')
            $asked | Should -Be @('', 'c2', 'c3')
        }

        It 'warns that threads were not read when it reaches the page limit' {
            $pages = @{ '' = (New-Page -Ids 'T1' -Next 'c2'); 'c2' = (New-Page -Ids 'T2' -Next 'c3'); 'c3' = (New-Page -Ids 'T3') }
            $read = { param($Cursor) $pages[$Cursor] }.GetNewClosure()

            $response = Read-ReviewThread -ReadPage $read -MaxPages 2 -WarningVariable warned -WarningAction SilentlyContinue

            @(Get-OpenThread -ThreadsResponse $response).Count | Should -Be 2
            "$warned" | Should -Match 'were not read'
        }

        It 'warns when a later page cannot be read, and keeps the first page' {
            $first = New-Page -Ids 'T1' -Next 'c2'
            $read = { param($Cursor) if ($Cursor) { $null } else { $first } }.GetNewClosure()

            $response = Read-ReviewThread -ReadPage $read -WarningVariable warned -WarningAction SilentlyContinue

            @(Get-OpenThread -ThreadsResponse $response).Id | Should -Be @('T1')
            "$warned" | Should -Match 'could not be read'
        }

        It 'asks GitHub for the page info and takes a cursor in the query' {
            Get-ReviewThreadQuery | Should -Match 'reviewThreads\(first: 100, after: \$cursor\)'
            Get-ReviewThreadQuery | Should -Match 'pageInfo \{ hasNextPage endCursor \}'
        }
    }

    Context 'Get-PullRequestFeedback waits for the checks' {
        It 'reports pending while a check runs, and still lists the threads' {
            $reader = { param($Name) switch ($Name) { 'pr' { New-Pr -Checks @(New-CheckRun -Status 'IN_PROGRESS' -Conclusion '') } 'threads' { New-ThreadsResponse -Threads @(New-Thread -Id 'T9' -Login 'review-helper' -Type 'Bot' -Content 'x') } } }
            $report = & $script:GetFeedback -PullRequestId 1 -Reader $reader | ConvertFrom-Json
            $report.State | Should -Be 'pending'
            $report.OpenThreads[0].Kind | Should -Be 'bot'
        }

        It 'reports pending while a commit status is pending' {
            $status = [pscustomobject]@{ __typename = 'StatusContext'; context = 'ci/legacy'; state = 'PENDING'; targetUrl = '' }
            $pr = New-Pr -Checks @($status)
            $threads = New-ThreadsResponse
            $reader = { param($Name) switch ($Name) { 'pr' { $pr } 'threads' { $threads } } }.GetNewClosure()
            (& $script:GetFeedback -PullRequestId 1 -Reader $reader | ConvertFrom-Json).State | Should -Be 'pending'
        }

        It 'reports ready when the checks are done, with a failed check named with its run id' {
            $reader = { param($Name) switch ($Name) { 'pr' { New-Pr -Checks @(New-CheckRun -Conclusion 'FAILURE') } 'threads' { New-ThreadsResponse } } }
            $report = & $script:GetFeedback -PullRequestId 1 -Reader $reader | ConvertFrom-Json
            $report.State | Should -Be 'ready'
            $report.Checks[0].Status | Should -Be 'fail'
            $report.Checks[0].RunId | Should -Be 7
            $report.Summary | Should -Match '1 failed check'
        }

        It 'reports timeout when -Wait runs out while work is still pending' {
            $reader = { param($Name) switch ($Name) { 'pr' { New-Pr -Checks @(New-CheckRun -Status 'QUEUED' -Conclusion '') } 'threads' { New-ThreadsResponse } } }
            (& $script:GetFeedback -PullRequestId 1 -Reader $reader -Wait -TimeoutMinutes 0 -PollSeconds 0 | ConvertFrom-Json).State | Should -Be 'timeout'
        }

        It 'never sleeps past -TimeoutMinutes, however long -PollSeconds is' {
            $reader = { param($Name) switch ($Name) { 'pr' { New-Pr -Checks @(New-CheckRun -Status 'IN_PROGRESS' -Conclusion '') } 'threads' { New-ThreadsResponse } } }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $report = & $script:GetFeedback -PullRequestId 1 -Reader $reader -Wait -TimeoutMinutes 0.05 -PollSeconds 600 | ConvertFrom-Json
            $report.State | Should -Be 'timeout'
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 30
        }

        It 'polls every 20 seconds by default' {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:GetFeedback, [ref]$null, [ref]$null)
            $poll = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'PollSeconds' }
            $poll.DefaultValue.Value | Should -Be 20
        }

        It 'waits 9 minutes by default' {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:GetFeedback, [ref]$null, [ref]$null)
            $timeout = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'TimeoutMinutes' }
            $timeout.DefaultValue.Value | Should -Be 9
        }
    }

    Context 'Get-PullRequestFeedback -ReturnOnReview hands over the bot threads while the checks run' {
        BeforeAll {
            function New-Reader {
                param([string]$Status = 'IN_PROGRESS', [object[]]$Threads = @(), [System.Collections.Generic.List[string]]$Calls)
                $conclusion = if ($Status -eq 'COMPLETED') { 'SUCCESS' } else { '' }
                $responses = @{
                    pr      = New-Pr -Checks @(New-CheckRun -Status $Status -Conclusion $conclusion)
                    threads = New-ThreadsResponse -Threads $Threads
                }
                {
                    param($Name)
                    if ($null -ne $Calls) { $Calls.Add($Name) }
                    $responses[$Name]
                }.GetNewClosure()
            }
        }

        It 'reports review at once when a bot raised a thread on the head commit and a check still runs' {
            $calls = [System.Collections.Generic.List[string]]::new()
            $reader = New-Reader -Threads @(New-Thread -Id 'T9' -Login 'review-helper' -Type 'Bot' -Content 'bug') -Calls $calls
            $report = & $script:GetFeedback -PullRequestId 1 -Reader $reader -Wait -ReturnOnReview -TimeoutMinutes 1 -PollSeconds 0 | ConvertFrom-Json
            $report.State | Should -Be 'review'
            $report.Checks[0].Status | Should -Be 'pending'
            $report.OpenThreads[0].Id | Should -Be 'T9'
            @($calls | Where-Object { $_ -eq 'pr' }).Count | Should -Be 1
        }

        It 'keeps waiting when the only open bot thread is on an older commit' {
            $reader = New-Reader -Threads @(New-Thread -Id 'T9' -Login 'review-helper' -Type 'Bot' -Content 'old' -Commit 'older')
            (& $script:GetFeedback -PullRequestId 1 -Reader $reader -Wait -ReturnOnReview -TimeoutMinutes 0 -PollSeconds 0 | ConvertFrom-Json).State | Should -Be 'timeout'
        }

        It 'keeps waiting when the open thread of the round is a person''s thread' {
            $reader = New-Reader -Threads @(New-Thread -Id 'T9' -Login 'a-reviewer' -Content 'rename')
            (& $script:GetFeedback -PullRequestId 1 -Reader $reader -Wait -ReturnOnReview -TimeoutMinutes 0 -PollSeconds 0 | ConvertFrom-Json).State | Should -Be 'timeout'
        }

        It 'reports ready, not review, once the checks are done' {
            $reader = New-Reader -Status 'COMPLETED' -Threads @(New-Thread -Id 'T9' -Login 'review-helper' -Type 'Bot' -Content 'bug')
            (& $script:GetFeedback -PullRequestId 1 -Reader $reader -Wait -ReturnOnReview -TimeoutMinutes 1 -PollSeconds 0 | ConvertFrom-Json).State | Should -Be 'ready'
        }

        It 'keeps the state pending for a single check without -Wait' {
            $reader = New-Reader -Threads @(New-Thread -Id 'T9' -Login 'review-helper' -Type 'Bot' -Content 'bug')
            (& $script:GetFeedback -PullRequestId 1 -Reader $reader -ReturnOnReview | ConvertFrom-Json).State | Should -Be 'pending'
        }

        It 'waits for the checks as before without the switch' {
            $reader = New-Reader -Threads @(New-Thread -Id 'T9' -Login 'review-helper' -Type 'Bot' -Content 'bug')
            (& $script:GetFeedback -PullRequestId 1 -Reader $reader -Wait -TimeoutMinutes 0 -PollSeconds 0 | ConvertFrom-Json).State | Should -Be 'timeout'
        }
    }

    Context 'Invoke-GitHubPoll backs off when GitHub throttles' {
        It 'reads <Message> as throttling: <Expected>' -ForEach @(
            @{ Message = 'gh api failed with exit code 1: HTTP 429: Too Many Requests'; Expected = $true }
            @{ Message = 'API rate limit exceeded for user'; Expected = $true }
            @{ Message = 'You have exceeded a secondary rate limit. Retry-After: 60'; Expected = $true }
            @{ Message = 'HTTP 401: Bad credentials'; Expected = $false }
            @{ Message = 'run 14290 failed'; Expected = $false }
        ) {
            Test-GitHubThrottle -Message $Message | Should -Be $Expected
        }

        It 'waits the Retry-After seconds when the error names them, else doubles the poll interval up to five minutes' {
            Get-GitHubRetryDelay -Message '429 Retry-After: 7' -Attempt 3 -PollSeconds 20 | Should -Be 7
            Get-GitHubRetryDelay -Message '429' -Attempt 0 -PollSeconds 20 | Should -Be 20
            Get-GitHubRetryDelay -Message '429' -Attempt 2 -PollSeconds 20 | Should -Be 80
            Get-GitHubRetryDelay -Message '429' -Attempt 9 -PollSeconds 20 | Should -Be 300
        }

        It 'tries a throttled read again after the delay and returns its result' {
            $slept = [System.Collections.Generic.List[int]]::new()
            $tries = [System.Collections.Generic.List[int]]::new()
            $action = { $tries.Add(1); if ($tries.Count -lt 3) { throw 'HTTP 429: Too Many Requests' }; 'ok' }.GetNewClosure()
            $result = Invoke-GitHubPoll -Action $action -Deadline (Get-Date).AddMinutes(30) -PollSeconds 20 -Sleep { param($Seconds) $slept.Add($Seconds) }.GetNewClosure()
            $result | Should -Be 'ok'
            $slept | Should -Be @(20, 40)
        }

        It 'throws at once on an error that is not throttling' {
            $slept = [System.Collections.Generic.List[int]]::new()
            { Invoke-GitHubPoll -Action { throw 'HTTP 401: Bad credentials' } -Deadline (Get-Date).AddMinutes(30) -Sleep { param($Seconds) $slept.Add($Seconds) }.GetNewClosure() } | Should -Throw '*401*'
            $slept.Count | Should -Be 0
        }

        It 'throws instead of waiting past the deadline' {
            $slept = [System.Collections.Generic.List[int]]::new()
            { Invoke-GitHubPoll -Action { throw '429 Retry-After: 120' } -Deadline (Get-Date).AddSeconds(60) -Sleep { param($Seconds) $slept.Add($Seconds) }.GetNewClosure() } | Should -Throw '*429*'
            $slept.Count | Should -Be 0
        }

        It 'Get-PullRequestFeedback -Wait goes on after one throttled read' {
            $count = [System.Collections.Generic.List[int]]::new()
            $pr = New-Pr -Checks @(New-CheckRun)
            $threads = New-ThreadsResponse
            $reader = { param($Name) if ($Name -eq 'pr') { $count.Add(1); if ($count.Count -eq 1) { throw 'HTTP 429: Too Many Requests Retry-After: 1' }; return $pr }; $threads }.GetNewClosure()
            $report = & $script:GetFeedback -PullRequestId 1 -Reader $reader -Wait -TimeoutMinutes 1 -PollSeconds 0 | ConvertFrom-Json
            $report.State | Should -Be 'ready'
            $count.Count | Should -Be 2
        }

        It 'Get-PullRequestFeedback without -Wait does not try a throttled read again' {
            $reader = { param($Name) throw 'HTTP 429: Too Many Requests' }
            $out = & $script:GetFeedback -PullRequestId 1 -Reader $reader *>&1 | Out-String
            $LASTEXITCODE | Should -Be 2
            $out | Should -Match 'NOTHING WAS CHECKED'
        }
    }

    Context 'Get-PullRequestFeedback when GitHub cannot be read' {
        It 'says it could not check when GitHub cannot be read' {
            $reader = { param($Name) throw 'no auth' }
            $out = & $script:GetFeedback -PullRequestId 1 -Reader $reader *>&1 | Out-String
            $LASTEXITCODE | Should -Be 2
            $out | Should -Match 'NOTHING WAS CHECKED'
        }
    }

    Context 'Reply-PullRequestThread never resolves a thread a person started' {
        BeforeAll {
            function New-ThreadNode {
                param([string]$Login, [string]$Type, [string]$Content = 'finding')
                $node = New-Thread -Id 'T5' -Login $Login -Type $Type -Content $Content
                $node | Add-Member -NotePropertyName pullRequest -NotePropertyValue ([pscustomobject]@{ number = 1 })
                [pscustomobject]@{ data = [pscustomobject]@{ node = $node } }
            }
        }

        It 'says only the tags of the known tools may be resolved: <Kind> is <Expected>' -ForEach @(
            @{ Kind = 'sonarcloud'; Expected = $true }
            @{ Kind = 'gitleaks'; Expected = $true }
            @{ Kind = 'bot'; Expected = $false }
            @{ Kind = 'human'; Expected = $false }
            @{ Kind = ''; Expected = $false }
        ) {
            Test-ThreadResolvable -Kind $Kind | Should -Be $Expected
        }

        It 'replies to a gitleaks thread and resolves it' {
            $calls = [System.Collections.Generic.List[string]]::new()
            $fakeThread = New-ThreadNode -Login 'github-actions' -Type 'Bot' -Content 'gitleaks found a secret'
            $invoker = { param($Operation, $Variables) $calls.Add($Operation); if ($Operation -eq 'thread') { $fakeThread } }.GetNewClosure()
            & $script:Reply -PullRequestId 1 -ThreadId 'T5' -Message 'Fixed in abc.' -Resolve -Invoker $invoker *>&1 | Out-Null
            $calls | Should -Contain 'reply'
            $calls | Should -Contain 'resolve'
        }

        It 'replies to a person but leaves the thread open for them (C09)' {
            $calls = [System.Collections.Generic.List[string]]::new()
            $fakeThread = New-ThreadNode -Login 'a-reviewer' -Type 'User'
            $invoker = { param($Operation, $Variables) $calls.Add($Operation); if ($Operation -eq 'thread') { $fakeThread } }.GetNewClosure()
            $out = & $script:Reply -PullRequestId 1 -ThreadId 'T5' -Message 'Renamed in abc.' -Resolve -Invoker $invoker *>&1 | Out-String
            $LASTEXITCODE | Should -Be 0
            $calls | Should -Contain 'reply'
            $calls | Should -Not -Contain 'resolve'
            $out | Should -Match 'C09'
        }

        It 'never resolves the thread of a bot that is not a known tool (C09)' {
            $calls = [System.Collections.Generic.List[string]]::new()
            $fakeThread = New-ThreadNode -Login 'review-helper' -Type 'Bot'
            $invoker = { param($Operation, $Variables) $calls.Add($Operation); if ($Operation -eq 'thread') { $fakeThread } }.GetNewClosure()
            $out = & $script:Reply -PullRequestId 1 -ThreadId 'T5' -Message 'Fixed in abc.' -Resolve -Invoker $invoker *>&1 | Out-String
            $LASTEXITCODE | Should -Be 1
            $calls | Should -Not -Contain 'resolve'
            $out | Should -Match 'C09'
        }
    }

    Context 'the loop can run the scripts without a prompt' {
        It 'allows <Script> in the settings' -ForEach @(
            @{ Script = 'Get-PullRequestFeedback.ps1' }
            @{ Script = 'Reply-PullRequestThread.ps1' }
            @{ Script = 'Wait-WorkflowRun.ps1' }
        ) {
            $settingsPath = Join-Path (Find-AiSdlcRepoRoot -StartPath $PSScriptRoot) '.claude' 'settings.json'
            if (-not (Test-Path -LiteralPath $settingsPath)) {
                Set-ItResult -Skipped -Because 'no .claude/settings.json at the repository root; the allow list belongs to the repository that installs the pack'
                return
            }
            $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
            $settings.permissions.allow | Should -Contain "Bash(pwsh -NoProfile -File .claude/skills/github-pull-requests/scripts/$Script*)" -Because 'the pull request loop runs it without a prompt. Run pwsh .claude/skills/ai-sdlc-hooks/scripts/Initialize-AiSdlc.ps1, which writes the allow rules of the installed packs into .claude/settings.json, then commit that file'
        }
    }
}
