#requires -Version 7.4

Describe 'Get-PrMetrics' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Get-PrMetrics.ps1'

        function New-Pr {
            param(
                [Parameter(Mandatory)][int]$Id,
                [Parameter(Mandatory)][datetime]$Created,
                [Parameter(Mandatory)][datetime]$Closed,
                [string]$Status = 'MERGED',
                [string]$Author = 'author-1'
            )
            return [pscustomobject]@{
                number        = $Id
                state         = $Status
                createdAt     = $Created.ToString('o')
                closedAt      = $Closed.ToString('o')
                author        = [pscustomobject]@{ login = $Author }
            }
        }

        function Invoke-Report {
            param([object[]]$Prs, [hashtable]$Extra = @{})
            return & $script:ScriptUnderTest -PullRequestsForTest $Prs -AsObject @Extra
        }
    }

    BeforeEach {
        $script:Monday = (Get-Date).ToUniversalTime().Date.AddDays(-(([int](Get-Date).ToUniversalTime().DayOfWeek + 6) % 7))
    }

    It 'groups pull requests by the week they closed' {
        $rows = Invoke-Report -Prs @(
            (New-Pr -Id 1 -Created $script:Monday.AddHours(-10) -Closed $script:Monday.AddHours(2))
            (New-Pr -Id 2 -Created $script:Monday.AddDays(1) -Closed $script:Monday.AddDays(1).AddHours(4))
            (New-Pr -Id 3 -Created $script:Monday.AddDays(-7) -Closed $script:Monday.AddDays(-6))
        )

        $rows.Count | Should -Be 2
        ($rows | Where-Object { $_.Week -eq $script:Monday.ToString('yyyy-MM-dd') }).Merged | Should -Be 2
    }

    It 'reports the median lead time in hours, from opening to closing' {
        $rows = Invoke-Report -Prs @(
            (New-Pr -Id 1 -Created $script:Monday -Closed $script:Monday.AddHours(2))
            (New-Pr -Id 2 -Created $script:Monday -Closed $script:Monday.AddHours(4))
            (New-Pr -Id 3 -Created $script:Monday -Closed $script:Monday.AddHours(12))
        )

        $rows[0].LeadHours | Should -Be 4
        $rows[0].LeadHoursP75 | Should -Be 12
    }

    It 'counts an abandoned pull request apart from a merged one' {
        $rows = Invoke-Report -Prs @(
            (New-Pr -Id 1 -Created $script:Monday -Closed $script:Monday.AddHours(2))
            (New-Pr -Id 2 -Created $script:Monday -Closed $script:Monday.AddHours(3) -Status 'CLOSED')
        )

        $rows[0].Merged | Should -Be 1
        $rows[0].Abandoned | Should -Be 1
    }

    It 'leaves an abandoned pull request out of the lead time' {
        $rows = Invoke-Report -Prs @(
            (New-Pr -Id 1 -Created $script:Monday -Closed $script:Monday.AddHours(2))
            (New-Pr -Id 2 -Created $script:Monday -Closed $script:Monday.AddHours(100) -Status 'CLOSED')
        )

        $rows[0].LeadHours | Should -Be 2
    }

    It 'ignores a pull request that closed before the window' {
        $rows = Invoke-Report -Prs @(
            (New-Pr -Id 1 -Created $script:Monday.AddDays(-200) -Closed $script:Monday.AddDays(-200))
            (New-Pr -Id 2 -Created $script:Monday -Closed $script:Monday.AddHours(2))
        ) -Extra @{ Days = 30 }

        $rows.Count | Should -Be 1
        $rows[0].Merged | Should -Be 1
    }

    It 'leaves the review columns empty without -Detail, rather than guessing' {
        $rows = Invoke-Report -Prs @((New-Pr -Id 1 -Created $script:Monday -Closed $script:Monday.AddHours(2)))

        $rows[0].ReviewedHours | Should -BeNullOrEmpty
        $rows[0].Rework | Should -BeNullOrEmpty
    }

    It 'reports the hours to the first comment by someone other than the author with -Detail' {
        $rows = Invoke-Report -Prs @(
            (New-Pr -Id 7 -Created $script:Monday -Closed $script:Monday.AddHours(10))
        ) -Extra @{ Detail = $true; FirstCommentForTest = @{ 7 = $script:Monday.AddHours(3) }; IterationsForTest = @{ 7 = 1 } }

        $rows[0].ReviewedHours | Should -Be 3
    }

    It 'counts rework as the iterations after the first, so one push is zero rework' {
        $rows = Invoke-Report -Prs @(
            (New-Pr -Id 7 -Created $script:Monday -Closed $script:Monday.AddHours(10))
            (New-Pr -Id 8 -Created $script:Monday -Closed $script:Monday.AddHours(10))
        ) -Extra @{ Detail = $true; IterationsForTest = @{ 7 = 1; 8 = 4 }; FirstCommentForTest = @{} }

        $rows[0].Rework | Should -Be 1.5
    }

    It 'has no column that names a person, by design' {
        $rows = Invoke-Report -Prs @((New-Pr -Id 1 -Created $script:Monday -Closed $script:Monday.AddHours(2)))

        $names = $rows[0].PSObject.Properties.Name
        $names | Should -Not -Contain 'Author'
        $names | Should -Not -Contain 'CreatedBy'
    }

    It 'returns nothing to report when no pull request closed in the window' {
        $rows = Invoke-Report -Prs @()

        @($rows).Count | Should -Be 0
    }

    It 'prints a table and the honest limits when not asked for objects' {
        $prs = @((New-Pr -Id 1 -Created $script:Monday -Closed $script:Monday.AddHours(2)))

        $out = & $script:ScriptUnderTest -PullRequestsForTest $prs *>&1 | Out-String

        $out | Should -Match 'Delivery per week'
        $out | Should -Match 'LeadHours is a floor'
        $out | Should -Match 'pass -Detail'
    }

    Context 'when it reads GitHub through gh' {
        BeforeAll {
            function global:gh {
                $line = $args -join ' '
                $global:MetricsCalls.Add($line)
                $global:LASTEXITCODE = 0
                if ($line -match '^pr list') { return $global:MetricsPrs }
                return $global:MetricsDetail
            }
        }

        AfterAll {
            Remove-Item -Path Function:\gh -ErrorAction SilentlyContinue
            Remove-Variable -Name MetricsCalls, MetricsPrs, MetricsDetail -Scope Global -ErrorAction SilentlyContinue
        }

        BeforeEach {
            $global:MetricsCalls = [System.Collections.Generic.List[string]]::new()
            $created = $script:Monday
            $global:MetricsPrs = ConvertTo-Json -Depth 5 -InputObject @(
                @{ number = 7; state = 'MERGED'; createdAt = $created.ToString('o'); closedAt = $created.AddHours(10).ToString('o'); mergedAt = $created.AddHours(10).ToString('o'); author = @{ login = 'author-1' } }
                @{ number = 8; state = 'CLOSED'; createdAt = $created.ToString('o'); closedAt = $created.AddHours(1).ToString('o'); mergedAt = $null; author = @{ login = 'author-1' } }
            )
            $global:MetricsDetail = ConvertTo-Json -Depth 10 -InputObject @{ data = @{ repository = @{ pullRequest = @{
                            commits  = @{ nodes = @(@{ commit = @{ committedDate = $created.AddHours(-1).ToString('o') } }, @{ commit = @{ committedDate = $created.AddHours(4).ToString('o') } }) }
                            reviews  = @{ nodes = @(@{ author = @{ __typename = 'Bot'; login = 'review-helper' }; submittedAt = $created.AddMinutes(5).ToString('o') }, @{ author = @{ __typename = 'User'; login = 'a-reviewer' }; submittedAt = $created.AddHours(3).ToString('o') }) }
                            comments = @{ nodes = @(@{ author = @{ __typename = 'User'; login = 'author-1' }; createdAt = $created.AddHours(1).ToString('o') }) }
                        } } } }
        }

        It 'lists the closed pull requests into the target branch, and counts one without a merge as abandoned' {
            $rows = & $script:ScriptUnderTest -Repository 'contoso/portal' -AsObject

            $global:MetricsCalls[0] | Should -Match '^pr list --repo contoso/portal --state closed --base main --limit 1000 --search closed:>=\d{4}-\d{2}-\d{2} --json number,state,createdAt,closedAt,mergedAt,author$'
            $rows[0].Merged | Should -Be 1
            $rows[0].Abandoned | Should -Be 1
        }

        It 'counts the first review by a person other than the author, and leaves bots out, with -Detail' {
            $rows = & $script:ScriptUnderTest -Repository 'contoso/portal' -AsObject -Detail

            $rows[0].ReviewedHours | Should -Be 3
            $rows[0].Rework | Should -Be 1
            @($global:MetricsCalls | Where-Object { $_ -match '^api graphql' }).Count | Should -Be 1
        }
    }
}
