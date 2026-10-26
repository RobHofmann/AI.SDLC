#requires -Version 7.4
Describe 'Invoke-IssuePreflight' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-IssuePreflight.ps1'
        $script:NoGh = 'gh-absent-for-test'
    }

    It 'returns one NEEDS-GH row and runs nothing when gh cannot read issues' {
        $rows = @(& $script:ScriptUnderTest -RepoRoot $TestDrive -GhCommand $script:NoGh 6>$null)

        $rows.Count | Should -Be 1
        $rows[0].Check | Should -Be 'IssueContract (story + ADR)'
        $rows[0].Status | Should -Be 'NEEDS-GH'
    }

    Context 'on a git branch, without gh' {
        BeforeAll {
            $script:Repo = Join-Path $TestDrive 'repo'
            New-Item -ItemType Directory -Path $script:Repo -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $script:Repo 'aisdlc.json') -Value '{ "tracker": { "repository": "contoso/portal" } }'
            git -C $script:Repo init -q -b main 2>$null
            git -C $script:Repo -c user.name=t -c user.email=t@example.com add . 2>$null
            git -C $script:Repo -c user.name=t -c user.email=t@example.com commit -q -m init 2>$null

            $script:SavedKey = [Environment]::GetEnvironmentVariable('PR_STORY_KEY')
            [Environment]::SetEnvironmentVariable('PR_STORY_KEY', $null)
        }

        AfterAll {
            [Environment]::SetEnvironmentVariable('PR_STORY_KEY', $script:SavedKey)
        }

        It 'returns a FAIL row that names the branch, for a branch with no story key' {
            git -C $script:Repo checkout -q -B feature/no-key 2>$null

            $rows = @(& $script:ScriptUnderTest -RepoRoot $script:Repo -GhCommand $script:NoGh 6>$null)

            $rows.Count | Should -Be 1
            $rows[0].Status | Should -Be 'FAIL'
            $rows[0].Detail | Should -Match 'feature/no-key'
            $rows[0].Detail | Should -Match 'PR_STORY_KEY'
            $rows[0].Detail | Should -Match 'title or body'
        }

        It 'returns NEEDS-GH for a branch that names a story key' {
            git -C $script:Repo checkout -q -B 1234-a-change 2>$null

            $rows = @(& $script:ScriptUnderTest -RepoRoot $script:Repo -GhCommand $script:NoGh 6>$null)

            $rows.Count | Should -Be 1
            $rows[0].Status | Should -Be 'NEEDS-GH'
        }
    }

    Context 'with gh signed in' {
        BeforeAll {
            $script:Skills = Join-Path $TestDrive 'skills'
            $script:Copy = Join-Path $script:Skills 'check-pr-contract' 'scripts'
            $gates = Join-Path $script:Skills 'ai-sdlc-gates' 'scripts'
            New-Item -ItemType Directory -Path $script:Copy, $gates -Force | Out-Null
            Copy-Item -LiteralPath $script:ScriptUnderTest -Destination $script:Copy
            $realGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
            if (-not (Test-Path -LiteralPath $realGates)) { $realGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
            Copy-Item -LiteralPath (Join-Path $realGates 'AiSdlcConfig.psm1') -Destination $gates

            $script:FakeGh = Join-Path $TestDrive 'fake-gh.ps1'
            Set-Content -LiteralPath $script:FakeGh -Value 'exit 0'
        }

        It 'reads <Status> when the contract check exits <Code>' -ForEach @(
            @{ Code = 0; Status = 'PASS' }
            @{ Code = 1; Status = 'FAIL' }
            @{ Code = 2; Status = 'REVIEW' }
        ) {
            Set-Content -LiteralPath (Join-Path $script:Copy 'Check-PrStoryContract.ps1') -Value "exit $Code"

            $rows = @(& (Join-Path $script:Copy 'Invoke-IssuePreflight.ps1') -RepoRoot $TestDrive -GhCommand $script:FakeGh 6>$null)

            $rows.Count | Should -Be 1
            $rows[0].Status | Should -Be $Status
        }
    }

    It 'is the preflight the github-issues pack declares' {
        $manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'gates.json') -Raw | ConvertFrom-Json
        $manifest.package | Should -Be 'github-issues'
        $manifest.preflight | Should -Be 'scripts/Invoke-IssuePreflight.ps1'
    }
}
