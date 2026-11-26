#requires -Version 7.4

BeforeAll { $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm' }

Describe 'ChangedFiles' {
    BeforeAll {
        Import-Module (Join-Path $script:ScriptFolder 'ChangedFiles.psm1') -Force

        function New-ChangeRepo {
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            git -C $root init --quiet -b main
            git -C $root config user.email probe@example.invalid
            git -C $root config user.name probe
            git -C $root config core.autocrlf false
            Set-Content -LiteralPath (Join-Path $root 'keep.txt') -Value 'keep'
            Set-Content -LiteralPath (Join-Path $root 'gone.txt') -Value 'gone'
            git -C $root add -A
            git -C $root commit --quiet -m base --no-verify
            git -C $root update-ref refs/remotes/origin/main HEAD
            return $root
        }

        $script:SavedChanged = $env:CHANGED_FILES
        $script:SavedTarget = $env:PR_TARGET_BRANCH
    }

    BeforeEach {
        $env:CHANGED_FILES = $null
        $env:PR_TARGET_BRANCH = $null
    }

    AfterAll {
        $env:CHANGED_FILES = $script:SavedChanged
        $env:PR_TARGET_BRANCH = $script:SavedTarget
    }

    Context 'Get-AiSdlcChange' {
        It 'lists the committed files since the merge base, and the files the change deleted' -Tag '#90' {
            $root = New-ChangeRepo
            Set-Content -LiteralPath (Join-Path $root 'new.txt') -Value 'new'
            Remove-Item -LiteralPath (Join-Path $root 'gone.txt')
            git -C $root add -A
            git -C $root commit --quiet -m change --no-verify
            Set-Content -LiteralPath (Join-Path $root 'uncommitted.txt') -Value 'not pushed'

            $change = Get-AiSdlcChange -RepoRoot $root -BaseRef origin/main

            $change.Readable | Should -BeTrue
            $change.Files | Should -Be @('gone.txt', 'new.txt')
            $change.Deleted | Should -Be @('gone.txt')
            $change.Base | Should -Match '^[0-9a-f]{40}$'
        }

        It 'says why when there is no merge base, and never returns an empty change as readable' -Tag '#90' {
            $root = New-ChangeRepo

            $change = Get-AiSdlcChange -RepoRoot $root -BaseRef origin/nope

            $change.Readable | Should -BeFalse
            $change.Reason | Should -Match 'no merge base between origin/nope and HEAD'
        }

        It 'measures against origin/<PR_TARGET_BRANCH> when no -BaseRef is given' -Tag '#90' {
            $root = New-ChangeRepo
            git -C $root update-ref refs/remotes/origin/develop HEAD
            git -C $root update-ref -d refs/remotes/origin/main
            $env:PR_TARGET_BRANCH = 'develop'

            $change = Get-AiSdlcChange -RepoRoot $root

            $change.Readable | Should -BeTrue -Because $change.Reason
        }

        It 'reads CHANGED_FILES before git, and tells the deleted files from HEAD' -Tag '#90' {
            $root = New-ChangeRepo
            $env:CHANGED_FILES = "keep.txt`nmissing.txt"

            $change = Get-AiSdlcChange -RepoRoot $root -BaseRef origin/nope

            $change.Readable | Should -BeTrue
            $change.Files | Should -Be @('keep.txt', 'missing.txt')
            $change.Deleted | Should -Be @('missing.txt')
        }

        It 'takes an explicit list before anything else, with slashes made forward' -Tag '#90' {
            $root = New-ChangeRepo
            $env:CHANGED_FILES = 'keep.txt'

            $change = Get-AiSdlcChange -RepoRoot $root -Explicit @('a\b.txt', 'a\b.txt')

            $change.Files | Should -Be @('a/b.txt')
        }
    }

    Context 'Get-AiSdlcChange -IncludeWorkingTree, Test-AiSdlcPathGlob and Get-AiSdlcChangeBase (#48)' {
        It 'adds the edited, new and deleted files of the working tree to the committed ones' -Tag '#48' {
            $root = New-ChangeRepo
            Add-Content -LiteralPath (Join-Path $root 'keep.txt') -Value 'edited'
            Set-Content -LiteralPath (Join-Path $root 'new.txt') -Value 'new'
            Remove-Item -LiteralPath (Join-Path $root 'gone.txt')

            $change = Get-AiSdlcChange -RepoRoot $root -BaseRef origin/main -IncludeWorkingTree

            $change.Readable | Should -BeTrue
            $change.Files | Should -Contain 'keep.txt'
            $change.Files | Should -Contain 'new.txt'
            $change.Deleted | Should -Be @('gone.txt')
        }

        It 'matches <Path> against <Glob> as <Expected>' -Tag '#48' -ForEach @(
            @{ Path = 'docs/a.md'; Glob = '**/*.md'; Expected = $true }
            @{ Path = 'a.md'; Glob = '**/*.md'; Expected = $true }
            @{ Path = 'docs/sub/a.md'; Glob = 'docs/*.md'; Expected = $false }
            @{ Path = '.claude/skills/x/SKILL.md'; Glob = '.claude/**'; Expected = $true }
            @{ Path = 'src/a.cs'; Glob = '**/*.md'; Expected = $false }
            @{ Path = 'docs/.reading-level-allowlist'; Glob = '**/.reading-level-allowlist'; Expected = $true }
        ) {
            Test-AiSdlcPathGlob -Path $Path -Glob @($Glob) | Should -Be $Expected
        }

        It 'gives the change base only for a full commit hash in the history of HEAD, so a stale value checks more' -Tag '#48' {
            $root = New-ChangeRepo
            $head = (git -C $root rev-parse HEAD).Trim()
            $saved = $env:AISDLC_CHANGE_BASE
            try {
                $env:AISDLC_CHANGE_BASE = $head
                (Get-AiSdlcChangeBase -RepoRoot $root).Base | Should -Be $head
                $env:AISDLC_CHANGE_BASE = 'f' * 40
                $stale = Get-AiSdlcChangeBase -RepoRoot $root
                $stale.Base | Should -BeNullOrEmpty
                $stale.Reason | Should -Match 'not in the history of HEAD'
                $env:AISDLC_CHANGE_BASE = 'abc'
                (Get-AiSdlcChangeBase -RepoRoot $root).Reason | Should -Match 'not a full commit hash'
            }
            finally { $env:AISDLC_CHANGE_BASE = $saved }
        }
    }

    Context 'Get-AiSdlcChangedLine' {
        It 'returns the lines the file gained and lost since the base' -Tag '#80' {
            $root = New-ChangeRepo
            Set-Content -LiteralPath (Join-Path $root 'code.txt') -Value @('one', 'two', 'three')
            git -C $root add -A
            git -C $root commit --quiet -m more --no-verify
            git -C $root update-ref refs/remotes/origin/main HEAD
            Set-Content -LiteralPath (Join-Path $root 'code.txt') -Value @('one', 'TWO', 'three', 'four')
            git -C $root commit --quiet -am edit --no-verify
            $base = (Get-AiSdlcChange -RepoRoot $root -BaseRef origin/main).Base

            $lines = Get-AiSdlcChangedLine -RepoRoot $root -Base $base -Path 'code.txt'

            $lines | Should -Be @('two', 'TWO', 'four')
        }

        It 'returns null without a base' -Tag '#80' {
            $root = New-ChangeRepo

            Get-AiSdlcChangedLine -RepoRoot $root -Base '' -Path 'keep.txt' | Should -BeNullOrEmpty
        }
    }

    Context 'Get-AiSdlcLineChange' {
        BeforeAll {
            function New-LineRepo {
                $root = New-ChangeRepo
                Set-Content -LiteralPath (Join-Path $root 'code.txt') -Value @('one', 'two', 'three')
                git -C $root add -A
                git -C $root commit --quiet -m lines --no-verify
                git -C $root update-ref refs/remotes/origin/main HEAD
                return $root
            }
        }

        It 'returns the added line numbers as they are on disk, and the text of the removed lines' -Tag '#80' {
            $root = New-LineRepo
            Set-Content -LiteralPath (Join-Path $root 'code.txt') -Value @('zero', 'one', 'TWO', 'three')
            git -C $root commit --quiet -am edit --no-verify
            $base = (Get-AiSdlcChange -RepoRoot $root -BaseRef origin/main).Base

            $change = Get-AiSdlcLineChange -RepoRoot $root -Base $base -Path 'code.txt'

            $change.Added | Should -Be @(1, 3)
            $change.Removed | Should -Be @('two')
        }

        It 'counts an edit that is not committed yet, because it diffs the working tree' -Tag '#80' {
            $root = New-LineRepo
            $base = (Get-AiSdlcChange -RepoRoot $root -BaseRef origin/main -Explicit @('code.txt')).Base
            Set-Content -LiteralPath (Join-Path $root 'code.txt') -Value @('one', 'two', 'three', 'four')

            $change = Get-AiSdlcLineChange -RepoRoot $root -Base $base -Path 'code.txt'

            $change.Added | Should -Be @(4)
            $change.Removed | Should -BeNullOrEmpty
        }

        It 'follows a rename, so a moved file does not count as all added' -Tag '#80' {
            $root = New-LineRepo
            git -C $root mv code.txt moved.txt
            Add-Content -LiteralPath (Join-Path $root 'moved.txt') -Value 'four'
            git -C $root add -A
            git -C $root commit --quiet -m move --no-verify
            $base = (Get-AiSdlcChange -RepoRoot $root -BaseRef origin/main).Base

            $change = Get-AiSdlcLineChange -RepoRoot $root -Base $base -Path 'moved.txt'

            $change.Added | Should -Be @(4)
            $change.Removed | Should -BeNullOrEmpty
        }

        It 'returns null without a base' -Tag '#80' {
            $root = New-LineRepo

            Get-AiSdlcLineChange -RepoRoot $root -Base '' -Path 'code.txt' | Should -BeNullOrEmpty
        }

        It 'counts every line as added with -AssumeNew and no base' -Tag '#80' {
            $root = New-LineRepo

            $change = Get-AiSdlcLineChange -RepoRoot $root -Base '' -Path 'code.txt' -AssumeNew

            $change.Added | Should -Be @(1, 2, 3)
            $change.Removed | Should -BeNullOrEmpty
        }
    }
}
