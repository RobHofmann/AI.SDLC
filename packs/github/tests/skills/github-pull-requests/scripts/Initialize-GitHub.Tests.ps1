#requires -Version 7.4
Describe 'Initialize-GitHub' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Initialize-GitHub.ps1'
    }

    AfterEach {
        Remove-Item -Path Function:\gh -ErrorAction SilentlyContinue
    }

    It 'leaves .claude/settings.json alone, because Sync-AllowRules.ps1 of the core writes the allow rules' {
        function global:gh { $global:LASTEXITCODE = 0; 'gh version 2.60.0' }
        $repo = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'settings') -Force
        & $script:ScriptUnderTest -RepoRoot $repo.FullName 6>$null | Out-Null
        Test-Path -LiteralPath (Join-Path $repo.FullName '.claude' 'settings.json') | Should -BeFalse
    }

    It 'lists the pull request scripts in the allow list of its gates.json' {
        $allow = (Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'gates.json') -Raw | ConvertFrom-Json).allow
        foreach ($name in 'Get-PullRequestFeedback.ps1', 'Reply-PullRequestThread.ps1', 'Wait-WorkflowRun.ps1', 'New-PullRequest.ps1', 'Update-PullRequest.ps1') {
            $allow | Should -Contain "pwsh -NoProfile -File .claude/skills/github-pull-requests/scripts/$name*"
        }
    }

    It 'never allows a merge or an approval in its gates.json' {
        $allow = (Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'gates.json') -Raw | ConvertFrom-Json).allow
        @($allow | Where-Object { $_ -match 'gh pr merge|--approve|gh pr review|gh api' }).Count | Should -Be 0
    }

    It 'reports OK rows when gh is installed and signed in' {
        function global:gh { $global:LASTEXITCODE = 0; if ($args[0] -eq '--version') { 'gh version 2.60.0' } else { 'Logged in to github.com' } }
        $rows = @(& $script:ScriptUnderTest -RepoRoot $TestDrive 6>$null)
        ($rows | Where-Object Step -EQ 'GitHub CLI').Status | Should -Be 'OK'
        ($rows | Where-Object Step -EQ 'GitHub CLI').Detail | Should -Match '2\.60\.0'
        ($rows | Where-Object Step -EQ 'GitHub sign-in').Status | Should -Be 'OK'
    }

    It 'reports a WARN row with the command to run when gh is not signed in, and does not fail' {
        function global:gh { if ($args[0] -eq 'auth') { $global:LASTEXITCODE = 1; 'You are not logged into any GitHub hosts.' } else { $global:LASTEXITCODE = 0; 'gh version 2.60.0' } }
        $rows = @(& $script:ScriptUnderTest -RepoRoot $TestDrive 6>$null)
        $row = $rows | Where-Object Step -EQ 'GitHub sign-in'
        $row.Status | Should -Be 'WARN'
        $row.Detail | Should -Match 'gh auth login'
    }

    It 'answers -Plan with its step and checks nothing' {
        function global:gh { $global:GhCalled = $true }
        $global:GhCalled = $false
        $result = @(& $script:ScriptUnderTest -Plan)
        $result | Should -Be @('GitHub CLI check')
        $global:GhCalled | Should -BeFalse
        Remove-Variable -Name GhCalled -Scope Global -ErrorAction SilentlyContinue
    }

    It 'names the repository from aisdlc.json in what it prints' {
        function global:gh { $global:LASTEXITCODE = 0; 'ok' }
        Set-Content -LiteralPath (Join-Path $TestDrive 'aisdlc.json') -Value '{ "github": { "repository": "contoso/portal" } }'
        $out = & $script:ScriptUnderTest -RepoRoot $TestDrive *>&1 | Out-String
        $out | Should -Match 'contoso/portal'
    }
}
