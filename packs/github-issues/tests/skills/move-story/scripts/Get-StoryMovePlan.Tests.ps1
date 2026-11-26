#requires -Version 7.4

BeforeAll { $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm' }

Describe 'Get-StoryMovePlan' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $script:ScriptFolder -ChildPath 'Get-StoryMovePlan.ps1'

        function Invoke-Plan {
            param([hashtable]$Parameters)
            if (-not $Parameters.ContainsKey('Repository')) { $Parameters['Repository'] = 'contoso/portal' }
            if (-not $Parameters.ContainsKey('PullRequest')) { $Parameters['PullRequest'] = 7 }
            if (-not $Parameters.ContainsKey('Label')) { $Parameters['Label'] = 'in-review' }
            return @(& $script:ScriptUnderTest @Parameters)
        }

        function New-ConfigRepo {
            param([string]$Json)
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('storymove-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value $Json -Encoding utf8
            return $root
        }

        # A fake gh. -Pr is the pull request JSON, -Issues maps a number to its JSON; a number in -FailIssues throws.
        function New-Invoker {
            param([hashtable]$State, [hashtable]$Pr, [hashtable]$Issues = @{}, [int[]]$FailIssues = @(), [switch]$FailPr)
            $State.Calls = [System.Collections.Generic.List[string]]::new()
            return {
                param($ghArgs)
                $State.Calls.Add(([string[]]$ghArgs) -join ' ')
                if ($ghArgs[0] -eq 'pr' -and $ghArgs[1] -eq 'view') {
                    if ($FailPr) { throw 'pr refused' }
                    return (ConvertTo-Json -InputObject $Pr -Depth 5)
                }
                if ($ghArgs[0] -eq 'issue' -and $ghArgs[1] -eq 'view') {
                    $n = [int]$ghArgs[2]
                    if ($FailIssues -contains $n) { throw "issue $n refused" }
                    return (ConvertTo-Json -InputObject $Issues[$n] -Depth 5)
                }
                throw "unexpected gh call: $($ghArgs -join ' ')"
            }.GetNewClosure()
        }

        function New-Pr {
            param([string]$State = 'OPEN', [bool]$IsDraft = $false, [string]$Branch = '42-short-name', [string]$Title = 'Add a thing', [string]$Body = '')
            return @{ number = 7; state = $State; isDraft = $IsDraft; headRefName = $Branch; title = $Title; body = $Body; url = 'https://github.com/contoso/portal/pull/7' }
        }

        function New-Issue {
            param([int]$Number = 42, [string]$State = 'OPEN', [string[]]$Labels = @('refined'))
            return @{ number = $Number; state = $State; title = "Story $Number"; labels = @($Labels | ForEach-Object { @{ name = $_ } }) }
        }
    }

    It 'plans add-label for an open issue when the person says published and the pull request is open and not a draft' {
        $state = @{}
        $invoker = New-Invoker -State $state -Pr (New-Pr) -Issues @{ 42 = (New-Issue) }

        $rows = Invoke-Plan @{ PersonSaysPublished = $true; GhInvoker = $invoker }

        $rows.Count | Should -Be 1
        $rows[0].Issue | Should -Be '#42'
        $rows[0].Action | Should -Be 'add-label'
        $rows[0].Label | Should -Be 'in-review'
        $rows[0].Reason | Should -Be 'published draft, open issue'
    }

    It 'reads the pull request and the issue with --repo and the fields the plan needs' {
        $state = @{}
        $invoker = New-Invoker -State $state -Pr (New-Pr) -Issues @{ 42 = (New-Issue) }

        Invoke-Plan @{ PersonSaysPublished = $true; GhInvoker = $invoker } | Out-Null

        $state.Calls[0] | Should -Be 'pr view 7 --repo contoso/portal --json number,state,isDraft,headRefName,title,body,url'
        $state.Calls[1] | Should -Be 'issue view 42 --repo contoso/portal --json number,state,labels,title'
    }

    It 'passes no --repo when no repository is known, so gh reads the git remote' {
        $root = New-ConfigRepo -Json '{}'
        $state = @{}
        $invoker = New-Invoker -State $state -Pr (New-Pr) -Issues @{ 42 = (New-Issue) }

        & $script:ScriptUnderTest -PullRequest 7 -PersonSaysPublished -GhInvoker $invoker -RepoRoot $root | Out-Null

        $state.Calls[0] | Should -Be 'pr view 7 --json number,state,isDraft,headRefName,title,body,url'
        $state.Calls[1] | Should -Be 'issue view 42 --json number,state,labels,title'
    }

    It 'skips when the person has not said the draft is published' {
        $state = @{}
        $invoker = New-Invoker -State $state -Pr (New-Pr) -Issues @{ 42 = (New-Issue) }

        $rows = Invoke-Plan @{ GhInvoker = $invoker }

        $rows[0].Action | Should -Be 'skip'
        $rows[0].Reason | Should -Be 'the person has not said the draft is published'
    }

    It 'skips while the pull request is still a draft' {
        $state = @{}
        $invoker = New-Invoker -State $state -Pr (New-Pr -IsDraft $true) -Issues @{ 42 = (New-Issue) }

        $rows = Invoke-Plan @{ PersonSaysPublished = $true; GhInvoker = $invoker }

        $rows[0].Action | Should -Be 'skip'
        $rows[0].Reason | Should -Be 'pull request is still a draft'
    }

    It 'skips a pull request that is <PrState>' -ForEach @(@{ PrState = 'MERGED' }, @{ PrState = 'CLOSED' }) {
        $state = @{}
        $invoker = New-Invoker -State $state -Pr (New-Pr -State $PrState) -Issues @{ 42 = (New-Issue) }

        $rows = Invoke-Plan @{ PersonSaysPublished = $true; GhInvoker = $invoker }

        $rows[0].Action | Should -Be 'skip'
        $rows[0].Reason | Should -Be "pull request is $PrState"
    }

    It 'never moves a closed issue, even with the signal' {
        $state = @{}
        $invoker = New-Invoker -State $state -Pr (New-Pr) -Issues @{ 42 = (New-Issue -State 'CLOSED') }

        $rows = Invoke-Plan @{ PersonSaysPublished = $true; GhInvoker = $invoker }

        $rows[0].Action | Should -Be 'skip'
        $rows[0].Reason | Should -Be 'issue is closed, never moved'
    }

    It 'skips an issue that already has the label, whatever its letter case' {
        $state = @{}
        $invoker = New-Invoker -State $state -Pr (New-Pr) -Issues @{ 42 = (New-Issue -Labels @('refined', 'In-Review')) }

        $rows = Invoke-Plan @{ PersonSaysPublished = $true; GhInvoker = $invoker }

        $rows[0].Action | Should -Be 'skip'
        $rows[0].Reason | Should -Be 'already labelled'
    }

    It 'names the stories from the branch, the title and every closing line, once each, in that order' {
        $body = "Adds the thing.`n`nFixes #43`nCloses contoso/portal#44`nresolves #42`n`nfixes #45"
        $state = @{}
        $issues = @{ 42 = (New-Issue 42); 43 = (New-Issue 43); 44 = (New-Issue 44); 45 = (New-Issue 45); 46 = (New-Issue 46) }
        $invoker = New-Invoker -State $state -Pr (New-Pr -Branch 'feature/46-other' -Title 'Part of #42' -Body $body) -Issues $issues

        $rows = Invoke-Plan @{ PersonSaysPublished = $true; GhInvoker = $invoker }

        @($rows.Issue) | Should -Be @('#46', '#42', '#43', '#44', '#45')
        @($rows.Action | Select-Object -Unique) | Should -Be @('add-label')
    }

    It 'does not name a story from a plain mention in the body' {
        $state = @{}
        $invoker = New-Invoker -State $state -Pr (New-Pr -Branch 'main' -Title 'Add a thing' -Body 'Related to #43 and see #44.')

        $rows = Invoke-Plan @{ PersonSaysPublished = $true; GhInvoker = $invoker } 3>$null

        $rows.Count | Should -Be 0
    }

    It 'skips a key of another repository with a reason, and never reads that issue' {
        $state = @{}
        $invoker = New-Invoker -State $state -Pr (New-Pr -Body 'Fixes fabrikam/billing#9') -Issues @{ 42 = (New-Issue) }

        $rows = Invoke-Plan @{ PersonSaysPublished = $true; GhInvoker = $invoker }

        $other = $rows | Where-Object Issue -eq 'fabrikam/billing#9'
        $other.Action | Should -Be 'skip'
        $other.Reason | Should -Be 'the issue is in another repository (fabrikam/billing)'
        ($state.Calls | Where-Object { $_ -like '*billing*' }) | Should -BeNullOrEmpty
    }

    It 'compares the repository name without regard to letter case' {
        $state = @{}
        $invoker = New-Invoker -State $state -Pr (New-Pr -Branch 'main' -Body 'Fixes Contoso/Portal#43') -Issues @{ 43 = (New-Issue 43) }

        $rows = Invoke-Plan @{ PersonSaysPublished = $true; GhInvoker = $invoker }

        $rows[0].Issue | Should -Be '#43'
        $rows[0].Action | Should -Be 'add-label'
    }

    It 'gives a skip row, not an error, when one issue cannot be read, and goes on' {
        $state = @{}
        $invoker = New-Invoker -State $state -Pr (New-Pr -Body 'Fixes #43') -Issues @{ 43 = (New-Issue 43) } -FailIssues @(42)

        $rows = Invoke-Plan @{ PersonSaysPublished = $true; GhInvoker = $invoker }

        $rows[0].Issue | Should -Be '#42'
        $rows[0].Action | Should -Be 'skip'
        $rows[0].Reason | Should -BeLike 'could not read the issue: *issue 42 refused*'
        $rows[1].Action | Should -Be 'add-label'
    }

    It 'throws when the pull request cannot be read' {
        $state = @{}
        $invoker = New-Invoker -State $state -Pr (New-Pr) -FailPr

        { Invoke-Plan @{ PersonSaysPublished = $true; GhInvoker = $invoker } } | Should -Throw '*pr refused*'
    }

    It 'returns no rows and reads no issue when no story is named' {
        $state = @{}
        $invoker = New-Invoker -State $state -Pr (New-Pr -Branch 'main' -Title 'Tidy up' -Body 'No story.')

        $rows = Invoke-Plan @{ PersonSaysPublished = $true; GhInvoker = $invoker } 3>$null

        $rows.Count | Should -Be 0
        $state.Calls.Count | Should -Be 1
    }

    It 'warns when no story is named' {
        $state = @{}
        $invoker = New-Invoker -State $state -Pr (New-Pr -Branch 'main' -Title 'Tidy up')

        $warnings = @(& { & $script:ScriptUnderTest -PullRequest 7 -Repository contoso/portal -GhInvoker $invoker } 3>&1 |
                Where-Object { $_ -is [System.Management.Automation.WarningRecord] })

        $warnings.Count | Should -Be 1
        $warnings[0].Message | Should -BeLike '*no story*'
    }

    It 'uses the label that the caller passes' {
        $state = @{}
        $invoker = New-Invoker -State $state -Pr (New-Pr) -Issues @{ 42 = (New-Issue -Labels @('in-review')) }

        $rows = Invoke-Plan @{ PersonSaysPublished = $true; GhInvoker = $invoker; Label = 'waits' }

        $rows[0].Action | Should -Be 'add-label'
        $rows[0].Label | Should -Be 'waits'
    }

    It 'reads the label name from tracker.inReviewLabel in aisdlc.json when none is passed' {
        $root = New-ConfigRepo -Json '{ "tracker": { "inReviewLabel": "waits-for-review" } }'
        $state = @{}
        $invoker = New-Invoker -State $state -Pr (New-Pr) -Issues @{ 42 = (New-Issue) }

        $rows = @(& $script:ScriptUnderTest -PullRequest 7 -Repository contoso/portal -PersonSaysPublished -GhInvoker $invoker -RepoRoot $root)

        $rows[0].Label | Should -Be 'waits-for-review'
    }

    It 'prints one line per row with -AsText' {
        $state = @{}
        $invoker = New-Invoker -State $state -Pr (New-Pr) -Issues @{ 42 = (New-Issue) }

        $all = & { & $script:ScriptUnderTest -PullRequest 7 -Repository contoso/portal -PersonSaysPublished -GhInvoker $invoker -AsText } 6>&1
        $text = @($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] })

        $text.Count | Should -Be 1
        [string]$text[0].MessageData | Should -BeLike '*#42*add-label*published draft, open issue*'
    }
}
