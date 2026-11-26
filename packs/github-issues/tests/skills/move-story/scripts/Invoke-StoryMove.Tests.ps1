#requires -Version 7.4

BeforeAll { $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm' }

Describe 'Invoke-StoryMove' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $script:ScriptFolder -ChildPath 'Invoke-StoryMove.ps1'

        function Invoke-Move {
            param([hashtable]$Parameters)
            if (-not $Parameters.ContainsKey('Repository')) { $Parameters['Repository'] = 'contoso/portal' }
            if (-not $Parameters.ContainsKey('PullRequest')) { $Parameters['PullRequest'] = 7 }
            if (-not $Parameters.ContainsKey('Label')) { $Parameters['Label'] = 'in-review' }
            return @(& $script:ScriptUnderTest @Parameters 3>$null 6>$null)
        }

        # A fake gh that keeps the labels of each issue. -ExistingLabels is what `gh label list` finds;
        # a number in -FailEdit makes `issue edit` throw; -DropLabel makes `issue edit` do nothing.
        function New-Invoker {
            param(
                [hashtable]$State,
                [hashtable]$Pr,
                [hashtable]$Issues,
                [string[]]$ExistingLabels = @(),
                [int[]]$FailEdit = @(),
                [switch]$DropLabel,
                [switch]$FailPr,
                [switch]$FailCreate
            )
            $State.Calls = [System.Collections.Generic.List[string]]::new()
            $State.Writes = [System.Collections.Generic.List[string]]::new()
            return {
                param($ghArgs)
                $line = ([string[]]$ghArgs) -join ' '
                $State.Calls.Add($line)
                if ($ghArgs[0] -eq 'pr' -and $ghArgs[1] -eq 'view') {
                    if ($FailPr) { throw 'pr refused' }
                    return (ConvertTo-Json -InputObject $Pr -Depth 5)
                }
                if ($ghArgs[0] -eq 'issue' -and $ghArgs[1] -eq 'view') {
                    return (ConvertTo-Json -InputObject $Issues[[int]$ghArgs[2]] -Depth 5)
                }
                if ($ghArgs[0] -eq 'label' -and $ghArgs[1] -eq 'list') {
                    return (ConvertTo-Json -InputObject @($ExistingLabels | ForEach-Object { @{ name = $_ } }) -Depth 5)
                }
                $State.Writes.Add($line)
                if ($ghArgs[0] -eq 'label' -and $ghArgs[1] -eq 'create') {
                    if ($FailCreate) { throw 'create refused' }
                    return ''
                }
                if ($ghArgs[0] -eq 'issue' -and $ghArgs[1] -eq 'edit') {
                    $n = [int]$ghArgs[2]
                    if ($FailEdit -contains $n) { throw "edit $n refused" }
                    if (-not $DropLabel) { $Issues[$n].labels += @{ name = $ghArgs[($ghArgs.IndexOf('--add-label') + 1)] } }
                    return ''
                }
                throw "unexpected gh call: $line"
            }.GetNewClosure()
        }

        function New-Pr {
            param([string]$Branch = '42-short-name', [string]$Body = '', [bool]$IsDraft = $false)
            return @{ number = 7; state = 'OPEN'; isDraft = $IsDraft; headRefName = $Branch; title = 'Add a thing'; body = $Body; url = 'https://github.com/contoso/portal/pull/7' }
        }

        function New-Issue {
            param([int]$Number = 42, [string]$State = 'OPEN', [string[]]$Labels = @('refined'))
            return @{ number = $Number; state = $State; title = "Story $Number"; labels = @($Labels | ForEach-Object { @{ name = $_ } }) }
        }
    }

    It 'adds the label, reads it back and reports the issue as moved' {
        $state = @{}
        $issues = @{ 42 = (New-Issue) }
        $invoker = New-Invoker -State $state -Pr (New-Pr) -Issues $issues -ExistingLabels @('in-review')

        $rows = Invoke-Move @{ PersonSaysPublished = $true; GhInvoker = $invoker }

        $rows.Count | Should -Be 1
        $rows[0].Issue | Should -Be '#42'
        $rows[0].Action | Should -Be 'add-label'
        $rows[0].Status | Should -Be 'moved'
        $state.Writes | Should -Be @('issue edit 42 --repo contoso/portal --add-label in-review')
        $state.Calls[-1] | Should -Be 'issue view 42 --repo contoso/portal --json labels'
    }

    It 'does not create the label when it exists, whatever its letter case' {
        $state = @{}
        $invoker = New-Invoker -State $state -Pr (New-Pr) -Issues @{ 42 = (New-Issue) } -ExistingLabels @('IN-REVIEW', 'in-review-later')

        Invoke-Move @{ PersonSaysPublished = $true; GhInvoker = $invoker } | Out-Null

        ($state.Writes | Where-Object { $_ -like 'label create*' }) | Should -BeNullOrEmpty
        $state.Calls | Should -Contain 'label list --repo contoso/portal --search in-review --json name'
    }

    It 'creates the label once when it is missing, before the first edit' {
        $state = @{}
        $invoker = New-Invoker -State $state -Pr (New-Pr -Body 'Fixes #43') -Issues @{ 42 = (New-Issue); 43 = (New-Issue 43) } -ExistingLabels @('in-review-later')

        Invoke-Move @{ PersonSaysPublished = $true; GhInvoker = $invoker } | Out-Null

        $state.Writes.Count | Should -Be 3
        $state.Writes[0] | Should -Be 'label create in-review --repo contoso/portal --color FBCA04 --description A person published the draft pull request; it waits for review and merge.'
        $state.Writes[1] | Should -BeLike 'issue edit 42 *'
        $state.Writes[2] | Should -BeLike 'issue edit 43 *'
    }

    It 'uses the label name from aisdlc.json when none is passed' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('storymove-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value '{ "tracker": { "inReviewLabel": "waits-for-review" } }' -Encoding utf8
        $state = @{}
        $invoker = New-Invoker -State $state -Pr (New-Pr) -Issues @{ 42 = (New-Issue) } -ExistingLabels @('waits-for-review')

        $rows = @(& $script:ScriptUnderTest -PullRequest 7 -Repository contoso/portal -PersonSaysPublished -GhInvoker $invoker -RepoRoot $root 3>$null 6>$null)

        $rows[0].Status | Should -Be 'moved'
        $state.Writes | Should -Be @('issue edit 42 --repo contoso/portal --add-label waits-for-review')
    }

    It 'makes no write call for a skipped issue' {
        $state = @{}
        $invoker = New-Invoker -State $state -Pr (New-Pr -IsDraft $true) -Issues @{ 42 = (New-Issue) }

        $rows = Invoke-Move @{ PersonSaysPublished = $true; GhInvoker = $invoker }

        $rows[0].Status | Should -Be 'skipped'
        $rows[0].Reason | Should -Be 'pull request is still a draft'
        $state.Writes.Count | Should -Be 0
    }

    It 'reports a failed edit as failed, warns, names it in the summary, and moves the next issue' {
        $state = @{}
        $invoker = New-Invoker -State $state -Pr (New-Pr -Body 'Fixes #43') -Issues @{ 42 = (New-Issue); 43 = (New-Issue 43) } -ExistingLabels @('in-review') -FailEdit @(42)

        $all = & { & $script:ScriptUnderTest -PullRequest 7 -Repository contoso/portal -Label in-review -PersonSaysPublished -GhInvoker $invoker } 3>&1 6>&1
        $warnings = @($all | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        $summary = @($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] })
        $rows = @($all | Where-Object { $_.PSObject.Properties.Name -contains 'Summary' -and $_ -isnot [System.Management.Automation.InformationRecord] })

        $rows[0].Status | Should -Be 'failed'
        $rows[0].Reason | Should -BeLike '*edit 42 refused*'
        $rows[1].Status | Should -Be 'moved'
        $warnings.Count | Should -BeGreaterThan 0
        ($warnings.Message -join ' ') | Should -BeLike '*#42*'
        [string]$summary[-1].MessageData | Should -BeLike 'Story moves: #42 failed (*edit 42 refused*); #43 moved'
    }

    It 'reports a failed label create as failed for the issue and makes no edit' {
        $state = @{}
        $invoker = New-Invoker -State $state -Pr (New-Pr) -Issues @{ 42 = (New-Issue) } -FailCreate

        $rows = Invoke-Move @{ PersonSaysPublished = $true; GhInvoker = $invoker }

        $rows[0].Status | Should -Be 'failed'
        $rows[0].Reason | Should -BeLike '*create refused*'
        ($state.Writes | Where-Object { $_ -like 'issue edit*' }) | Should -BeNullOrEmpty
    }

    It 'reports failed when the read back does not show the label' {
        $state = @{}
        $invoker = New-Invoker -State $state -Pr (New-Pr) -Issues @{ 42 = (New-Issue) } -ExistingLabels @('in-review') -DropLabel

        $rows = Invoke-Move @{ PersonSaysPublished = $true; GhInvoker = $invoker }

        $rows[0].Status | Should -Be 'failed'
        $rows[0].Reason | Should -BeLike '*label in-review is not on the issue*'
    }

    It 'never throws and says nothing moved when the pull request cannot be read' {
        $state = @{}
        $invoker = New-Invoker -State $state -Pr (New-Pr) -Issues @{} -FailPr

        $all = & { & $script:ScriptUnderTest -PullRequest 7 -Repository contoso/portal -Label in-review -PersonSaysPublished -GhInvoker $invoker } 3>&1 6>&1
        $rows = @($all | Where-Object { $_.PSObject.Properties.Name -contains 'Summary' -and $_ -isnot [System.Management.Automation.InformationRecord] })
        $summary = @($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] })

        $rows.Count | Should -Be 1
        $rows[0].Status | Should -Be 'failed'
        $rows[0].Summary | Should -BeLike 'Story moves: none made (could not read pull request #7: *pr refused*)'
        [string]$summary[-1].MessageData | Should -Be $rows[0].Summary
        $state.Writes.Count | Should -Be 0
    }

    It 'puts the same one-line summary on every row and in the information stream' {
        $state = @{}
        $issues = @{ 42 = (New-Issue); 43 = (New-Issue 43 -State 'CLOSED'); 44 = (New-Issue 44) }
        $invoker = New-Invoker -State $state -Pr (New-Pr -Body "Fixes #43`nFixes #44") -Issues $issues -ExistingLabels @('in-review') -FailEdit @(44)

        $all = & { & $script:ScriptUnderTest -PullRequest 7 -Repository contoso/portal -Label in-review -PersonSaysPublished -GhInvoker $invoker } 3>$null 6>&1
        $rows = @($all | Where-Object { $_.PSObject.Properties.Name -contains 'Summary' -and $_ -isnot [System.Management.Automation.InformationRecord] })
        $summary = @($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] })

        @($rows.Summary | Select-Object -Unique).Count | Should -Be 1
        $rows[0].Summary | Should -BeLike 'Story moves: #42 moved; #43 skipped (issue is closed, never moved); #44 failed (*edit 44 refused*)'
        [string]$summary[-1].MessageData | Should -Be $rows[0].Summary
    }

    It 'makes no write call with -WhatIf and reports whatif' {
        $state = @{}
        $invoker = New-Invoker -State $state -Pr (New-Pr) -Issues @{ 42 = (New-Issue) }

        $rows = Invoke-Move @{ PersonSaysPublished = $true; GhInvoker = $invoker; WhatIf = $true }

        $rows[0].Status | Should -Be 'whatif'
        $rows[0].Reason | Should -Be 'would add label in-review'
        $state.Writes.Count | Should -Be 0
    }

    It 'returns no rows and no error when no story is named' {
        $state = @{}
        $invoker = New-Invoker -State $state -Pr (New-Pr -Branch 'main') -Issues @{}

        $rows = Invoke-Move @{ PersonSaysPublished = $true; GhInvoker = $invoker }

        $rows.Count | Should -Be 0
        $state.Writes.Count | Should -Be 0
    }
}
