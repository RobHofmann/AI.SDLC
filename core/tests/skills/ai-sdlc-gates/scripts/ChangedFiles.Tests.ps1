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
}
