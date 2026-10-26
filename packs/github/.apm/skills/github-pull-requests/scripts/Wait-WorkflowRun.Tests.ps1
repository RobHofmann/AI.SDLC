#requires -Version 7.4

Describe 'Wait-WorkflowRun' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Wait-WorkflowRun.ps1'

        function New-Run {
            param([long]$Id, [string]$Status, [string]$Result = '', [switch]$Working)
            $jobs = @([pscustomobject]@{ name = 'build'; status = 'completed' })
            if ($Working) { $jobs += [pscustomobject]@{ name = 'deploy-dev'; status = 'in_progress' } }
            [pscustomobject]@{ databaseId = $Id; status = $Status; conclusion = $Result; workflowName = 'release'; url = "https://github.com/contoso/portal/actions/runs/$Id"; jobs = $jobs }
        }

        function New-Reader {
            param([hashtable]$Runs, [hashtable]$LaterRuns = @{}, [long[]]$Approval = @(), [System.Collections.Generic.List[string]]$Calls)
            $pending = @{}
            foreach ($id in $Runs.Keys) { $pending[$id] = if ($Approval -contains $id) { @([pscustomobject]@{ environment = [pscustomobject]@{ name = 'prd' } }) } else { @() } }
            {
                param($Name, $Id)
                if ($null -ne $Calls) { $Calls.Add("$Name $Id") }
                if ($Name -eq 'pending') { return $pending[$Id] }
                $seen = @($Calls | Where-Object { $_ -eq "run $Id" }).Count
                if ($seen -gt 1 -and $LaterRuns.ContainsKey($Id)) { return $LaterRuns[$Id] }
                return $Runs[$Id]
            }.GetNewClosure()
        }

        function Invoke-Wait {
            param([scriptblock]$Reader, [long[]]$RunId, [hashtable]$Extra = @{})
            $out = & $script:ScriptUnderTest -RunId $RunId -Repository 'contoso/portal' -Reader $Reader @Extra *>&1 | Out-String
            [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out; Report = if ($out -match '"State"') { $out | ConvertFrom-Json } }
        }
    }

    It 'is ready with the result of each run when every run is completed' {
        $calls = [System.Collections.Generic.List[string]]::new()
        $reader = New-Reader -Runs @{ [long]1 = (New-Run 1 'completed' 'success'); [long]2 = (New-Run 2 'completed' 'failure') } -Calls $calls
        $r = Invoke-Wait -Reader $reader -RunId 1, 2

        $r.Code | Should -Be 0
        $r.Report.State | Should -Be 'ready'
        ($r.Report.Runs | Where-Object Id -EQ 2).Result | Should -Be 'failure'
        $r.Report.Summary | Should -Match '2 failure'
        @($calls | Where-Object { $_ -like 'pending*' }).Count | Should -Be 0
    }

    It 'takes the run ids as one comma list, the form pwsh -File passes' {
        $reader = New-Reader -Runs @{ [long]1 = (New-Run 1 'completed' 'success'); [long]2 = (New-Run 2 'completed' 'success') }
        $out = & $script:ScriptUnderTest -RunId '1,2' -Repository 'contoso/portal' -Reader $reader *>&1 | Out-String
        $report = $out | ConvertFrom-Json

        @($report.Runs.Id) | Should -Be @(1, 2)
        $report.Runs[1].Url | Should -Be 'https://github.com/contoso/portal/actions/runs/2'
    }

    It 'refuses <RunId>, which holds no run id' -ForEach @(
        @{ RunId = 'abc' }
        @{ RunId = ',' }
        @{ RunId = ' ' }
    ) {
        { & $script:ScriptUnderTest -RunId $RunId -Repository 'contoso/portal' -Reader { } } | Should -Throw '*RunId takes run ids*'
    }

    It 'polls with -Wait until every run is completed' {
        $calls = [System.Collections.Generic.List[string]]::new()
        $reader = New-Reader -Runs @{ [long]1 = (New-Run 1 'in_progress' -Working) } -LaterRuns @{ [long]1 = (New-Run 1 'completed' 'success') } -Calls $calls
        $r = Invoke-Wait -Reader $reader -RunId 1 -Extra @{ Wait = $true; PollSeconds = 0; TimeoutMinutes = 1 }

        $r.Report.State | Should -Be 'ready'
        @($calls | Where-Object { $_ -eq 'run 1' }).Count | Should -Be 2
    }

    It 'stops waiting and says approval when the open run waits for an environment reviewer' {
        $calls = [System.Collections.Generic.List[string]]::new()
        $reader = New-Reader -Runs @{ [long]1 = (New-Run 1 'waiting'); [long]2 = (New-Run 2 'completed' 'success') } -Approval 1 -Calls $calls
        $r = Invoke-Wait -Reader $reader -RunId 1, 2 -Extra @{ Wait = $true; PollSeconds = 0; TimeoutMinutes = 1 }

        $r.Report.State | Should -Be 'approval'
        ($r.Report.Runs | Where-Object Id -EQ 1).Approval | Should -BeTrue
        $r.Report.Summary | Should -Match '1 waits for an approval'
        @($calls | Where-Object { $_ -eq 'run 1' }).Count | Should -Be 1
    }

    It 'reads a pending deployment as an approval when the run status is not waiting' {
        $reader = New-Reader -Runs @{ [long]1 = (New-Run 1 'in_progress') } -Approval 1
        (Invoke-Wait -Reader $reader -RunId 1).Report.State | Should -Be 'approval'
    }

    It 'keeps waiting while another run still works next to one that waits for an approval' {
        $reader = New-Reader -Runs @{ [long]1 = (New-Run 1 'waiting'); [long]2 = (New-Run 2 'in_progress' -Working) } -Approval 1
        (Invoke-Wait -Reader $reader -RunId 1, 2 -Extra @{ Wait = $true; PollSeconds = 0; TimeoutMinutes = 0 }).Report.State | Should -Be 'timeout'
    }

    It 'keeps waiting when one job waits for an approval while another job of the run still works' {
        $reader = New-Reader -Runs @{ [long]1 = (New-Run 1 'in_progress' -Working) } -Approval 1
        $r = Invoke-Wait -Reader $reader -RunId 1 -Extra @{ Wait = $true; PollSeconds = 0; TimeoutMinutes = 0 }

        $r.Report.State | Should -Be 'timeout'
        $r.Report.Runs[0].Approval | Should -BeFalse
    }

    It 'never sleeps past -TimeoutMinutes, however long -PollSeconds is' {
        $reader = New-Reader -Runs @{ [long]1 = (New-Run 1 'in_progress' -Working) }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-Wait -Reader $reader -RunId 1 -Extra @{ Wait = $true; PollSeconds = 600; TimeoutMinutes = 0.05 }

        $r.Report.State | Should -Be 'timeout'
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 30
    }

    It 'reports pending without -Wait while a run is queued' {
        $reader = New-Reader -Runs @{ [long]1 = (New-Run 1 'queued') }
        (Invoke-Wait -Reader $reader -RunId 1).Report.State | Should -Be 'pending'
    }

    It 'goes on after one throttled read with -Wait' {
        $count = [System.Collections.Generic.List[int]]::new()
        $run = New-Run 1 'completed' 'success'
        $reader = { param($Name, $Id) $count.Add(1); if ($count.Count -eq 1) { throw 'HTTP 429: Too Many Requests Retry-After: 1' }; $run }.GetNewClosure()
        $r = Invoke-Wait -Reader $reader -RunId 1 -Extra @{ Wait = $true; PollSeconds = 0; TimeoutMinutes = 1 }

        $r.Report.State | Should -Be 'ready'
        $count.Count | Should -Be 2
    }

    It 'exits 2 and prints no report when GitHub cannot be read' {
        $r = Invoke-Wait -Reader { param($Name, $Id) throw 'HTTP 401: Bad credentials' } -RunId 1 -Extra @{ Wait = $true; PollSeconds = 0; TimeoutMinutes = 1 }

        $r.Code | Should -Be 2
        $r.Output | Should -Match 'NOTHING WAS CHECKED'
        $r.Output | Should -Not -Match '"State"'
    }

    It 'reads a run with gh run view and its pending deployments with gh api' {
        function global:gh {
            $global:WaitRunCalls.Add(($args -join ' '))
            $global:LASTEXITCODE = 0
            if (($args -join ' ') -match 'pending_deployments') { return '[]' }
            return '{ "databaseId": 5, "status": "in_progress", "workflowName": "release", "jobs": [] }'
        }
        $global:WaitRunCalls = [System.Collections.Generic.List[string]]::new()
        try {
            $out = & $script:ScriptUnderTest -RunId 5 -Repository 'contoso/portal' 2>&1 | Out-String
            ($out | ConvertFrom-Json).State | Should -Be 'pending'
            $global:WaitRunCalls | Should -Contain 'run view 5 --repo contoso/portal --json databaseId,status,conclusion,workflowName,url,jobs'
            $global:WaitRunCalls | Should -Contain 'api repos/contoso/portal/actions/runs/5/pending_deployments'
        }
        finally {
            Remove-Item -Path Function:\gh -ErrorAction SilentlyContinue
            Remove-Variable -Name WaitRunCalls -Scope Global -ErrorAction SilentlyContinue
        }
    }
}
