#requires -Version 7.4
BeforeAll { $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm' }

Describe 'The pre-flight receipt' {
    BeforeAll {
        Import-Module (Join-Path -Path $script:ScriptFolder -ChildPath 'PreflightReceipt.psm1') -Force
        $script:Root = Join-Path -Path $TestDrive -ChildPath 'preflight'
    }

    It 'is found for the tree it was written for, and only when it says PASS' {
        Write-PreflightReceipt -ReceiptRoot $script:Root -Tree 'abc123' -Status PASS -Commit 'deadbeef' | Out-Null
        Test-PreflightReceipt -ReceiptRoot $script:Root -Tree 'abc123' | Should -BeTrue
        Test-PreflightReceipt -ReceiptRoot $script:Root -Tree 'other' | Should -BeFalse
    }

    It 'does not count a FAIL receipt' {
        Write-PreflightReceipt -ReceiptRoot $script:Root -Tree 'fail01' -Status FAIL | Out-Null
        Test-PreflightReceipt -ReceiptRoot $script:Root -Tree 'fail01' | Should -BeFalse
    }

    It 'does not count an empty tree, a missing folder or a broken file' {
        Test-PreflightReceipt -ReceiptRoot $script:Root -Tree '' | Should -BeFalse
        Test-PreflightReceipt -ReceiptRoot (Join-Path $TestDrive 'nowhere') -Tree 'abc123' | Should -BeFalse
        Set-Content -LiteralPath (Get-ReceiptPath -ReceiptRoot $script:Root -Tree 'broken') -Value 'not json'
        Test-PreflightReceipt -ReceiptRoot $script:Root -Tree 'broken' | Should -BeFalse
    }

    It 'records the commit and the checks, so the receipt says what passed' {
        $path = Write-PreflightReceipt -ReceiptRoot $script:Root -Tree 'rec01' -Status PASS -Commit 'c0ffee' -Checks @('Gates', 'Build')
        $receipt = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $receipt.Commit | Should -Be 'c0ffee'
        @($receipt.Checks) | Should -Be @('Gates', 'Build')
    }

    It 'reads the tree of HEAD and a clean status from a real repository' {
        $repo = Join-Path -Path $TestDrive -ChildPath 'repo'
        New-Item -ItemType Directory -Path $repo | Out-Null
        git -C $repo init -q -b main
        git -C $repo config user.email t@example.invalid
        git -C $repo config user.name t
        Set-Content -LiteralPath (Join-Path $repo 'a.txt') -Value 'a'
        git -C $repo add -A
        git -C $repo commit -qm one
        (Get-HeadTree -RepoRoot $repo) | Should -Match '^[0-9a-f]{40}$'
        Test-CleanTree -RepoRoot $repo | Should -BeTrue
        Set-Content -LiteralPath (Join-Path $repo 'a.txt') -Value 'b'
        Test-CleanTree -RepoRoot $repo | Should -BeFalse
    }

    Context 'Find-PreflightBase (#48)' {
        BeforeAll {
            function New-BranchRepo {
                $repo = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
                New-Item -ItemType Directory -Path $repo -Force | Out-Null
                git -C $repo init --quiet -b main
                git -C $repo config user.email probe@example.invalid
                git -C $repo config user.name probe
                git -C $repo commit --quiet --allow-empty -m base --no-verify
                git -C $repo update-ref refs/remotes/origin/main HEAD
                git -C $repo commit --quiet --allow-empty -m one --no-verify
                return $repo
            }
        }

        It 'gives the commit of a passing receipt on this branch' -Tag '#48' {
            $repo = New-BranchRepo
            $receipts = Join-Path $repo 'receipts'
            $commit = (git -C $repo rev-parse HEAD).Trim()
            Write-PreflightReceipt -ReceiptRoot $receipts -Tree (git -C $repo rev-parse 'HEAD^{tree}').Trim() -Status PASS -Commit $commit | Out-Null
            git -C $repo commit --quiet --allow-empty -m fix --no-verify

            Find-PreflightBase -ReceiptRoot $receipts -RepoRoot $repo -MainRef origin/main | Should -Be $commit
        }

        It 'gives nothing for a receipt whose commit is not in the history of HEAD, so a stale receipt checks more' -Tag '#48' {
            $repo = New-BranchRepo
            $receipts = Join-Path $repo 'receipts'
            Write-PreflightReceipt -ReceiptRoot $receipts -Tree 'abc' -Status PASS -Commit ('f' * 40) | Out-Null

            Find-PreflightBase -ReceiptRoot $receipts -RepoRoot $repo -MainRef origin/main | Should -BeNullOrEmpty
        }
    }

    It 'is written by the pre-flight and read by the push hook' {
        (Get-Content -LiteralPath (Join-Path $script:ScriptFolder 'Invoke-Preflight.ps1') -Raw) | Should -Match 'Write-PreflightReceipt'
        (Get-Content -LiteralPath (Join-Path $script:ScriptFolder '..' '..' 'ai-sdlc-hooks' 'scripts' 'Deny-IncompletePush.ps1') -Raw) | Should -Match 'Test-PreflightReceipt'
    }
}
