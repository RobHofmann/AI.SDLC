#requires -Version 7.4

Describe 'Test-PushSendsNothingNew' {
    BeforeAll {
        $script:Script = Join-Path $PSScriptRoot 'Test-PushSendsNothingNew.ps1'
        Import-Module (Join-Path $PSScriptRoot 'PreflightReceipt.psm1') -Force
        Import-Module (Join-Path $PSScriptRoot 'DocToolTestHarness.psm1') -Force
        $script:Zero = '0' * 40

        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('push-nothing-new-' + [guid]::NewGuid().ToString('n'))
        $script:Root = $root
        $script:Work = Join-Path $root 'work'
        git init --quiet -b main $script:Work
        git -C $script:Work config user.email probe@example.invalid
        git -C $script:Work config user.name probe
        git -C $script:Work commit --quiet --allow-empty -m one --no-verify
        $script:Known = (git -C $script:Work rev-parse HEAD).Trim()
        foreach ($name in 'origin', 'fork') {
            git init --quiet --bare (Join-Path $root "$name.git")
            git -C $script:Work remote add $name (Join-Path $root "$name.git")
        }
        git -C $script:Work push --quiet --no-verify origin HEAD:refs/heads/1-story 2>&1 | Out-Null
        git -C $script:Work commit --quiet --allow-empty -m two --no-verify
        $script:OnFork = (git -C $script:Work rev-parse HEAD).Trim()
        git -C $script:Work push --quiet --no-verify fork HEAD:refs/heads/1-story 2>&1 | Out-Null
        git -C $script:Work fetch --quiet origin 2>&1 | Out-Null
        git -C $script:Work fetch --quiet fork 2>&1 | Out-Null

        function Invoke-Check {
            param([string]$Remote, [string]$Commit)
            $run = Invoke-ScriptInProcess -Path $script:Script -Arguments @('-RepoRoot', $script:Work, '-Remote', $Remote, '-Commit', $Commit)
            [pscustomobject]@{ Code = $run.ExitCode; Output = $run.Output }
        }
    }

    AfterAll {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'is true for a commit the remote already has' {
        Test-PushSendsNothingNew -RepoRoot $script:Work -Remote origin -Commit $script:Known | Should -BeTrue
    }

    It 'is true when every pushed ref is a delete, and when no ref is pushed' {
        Test-PushSendsNothingNew -RepoRoot $script:Work -Remote origin -Commit $script:Zero | Should -BeTrue
        Test-PushSendsNothingNew -RepoRoot $script:Work -Remote origin -Commit @() | Should -BeTrue
    }

    It 'is false for a commit that only another remote has' {
        Test-PushSendsNothingNew -RepoRoot $script:Work -Remote origin -Commit $script:OnFork | Should -BeFalse
        Test-PushSendsNothingNew -RepoRoot $script:Work -Remote fork -Commit $script:OnFork | Should -BeTrue
    }

    It 'is false when one of several commits is new, given in one argument' {
        Test-PushSendsNothingNew -RepoRoot $script:Work -Remote origin -Commit "$script:Known $script:OnFork" | Should -BeFalse
    }

    It 'is false for a remote that is not configured, a glob or a URL, so nothing slips through' {
        foreach ($remote in 'upstream', 'o*', '', 'https://example.invalid/repo') {
            Test-PushSendsNothingNew -RepoRoot $script:Work -Remote $remote -Commit $script:Known | Should -BeFalse -Because $remote
        }
    }

    It 'is false for a commit git does not know' {
        Test-PushSendsNothingNew -RepoRoot $script:Work -Remote origin -Commit ('b' * 40) | Should -BeFalse
    }

    It 'exits 0 and says why for a known commit and for a delete' {
        $known = Invoke-Check -Remote origin -Commit $script:Known
        $known.Code | Should -Be 0
        $known.Output | Should -Match 'already on origin'

        $delete = Invoke-Check -Remote origin -Commit $script:Zero
        $delete.Code | Should -Be 0
        $delete.Output | Should -Match 'delete'
    }

    It 'exits 1 without output for a new commit' {
        $new = Invoke-Check -Remote origin -Commit $script:OnFork
        $new.Code | Should -Be 1
        "$($new.Output)".Trim() | Should -BeNullOrEmpty
    }
}
