#requires -Version 7.4

Describe 'Test-PushReceipt' {
    BeforeAll {
        $script:Script = Join-Path $PSScriptRoot 'Test-PushReceipt.ps1'
        Import-Module (Join-Path $PSScriptRoot 'PreflightReceipt.psm1') -Force
        Import-Module (Join-Path $PSScriptRoot 'DocToolTestHarness.psm1') -Force
        $script:Made = [System.Collections.Generic.List[string]]::new()

        function New-ReceiptRepo {
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('push-receipt-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $root | Out-Null
            $script:Made.Add($root)
            git -C $root init --quiet
            git -C $root config user.email probe@example.invalid
            git -C $root config user.name probe
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value '{}'
            git -C $root add aisdlc.json
            git -C $root commit --quiet -m one --no-verify
            $first = (git -C $root rev-parse HEAD).Trim()
            Set-Content -LiteralPath (Join-Path $root 'a.txt') -Value 'two'
            git -C $root add a.txt
            git -C $root commit --quiet -m two --no-verify
            $second = (git -C $root rev-parse HEAD).Trim()
            return [pscustomobject]@{ Root = $root; First = $first; Second = $second; Receipts = (Join-Path $root 'temp' 'preflight') }
        }

        function Add-Receipt {
            param($Repo, [string]$Commit, [string]$Status = 'PASS')
            $tree = (git -C $Repo.Root rev-parse "$Commit^{tree}").Trim()
            Import-Module (Join-Path $PSScriptRoot 'PreflightReceipt.psm1') -Force
            Write-PreflightReceipt -ReceiptRoot $Repo.Receipts -Tree $tree -Status $Status -Commit $Commit | Out-Null
        }

        function Invoke-Check {
            param($Repo, [string]$Commit)
            $run = Invoke-ScriptInProcess -Path $script:Script -Arguments @('-RepoRoot', $Repo.Root, '-Commit', $Commit)
            [pscustomobject]@{ Code = $run.ExitCode; Output = $run.Output }
        }
    }

    AfterAll {
        foreach ($dir in $script:Made) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'exits 0 when the tree of the pushed commit has a passing receipt' {
        $repo = New-ReceiptRepo
        Add-Receipt -Repo $repo -Commit $repo.Second

        $r = Invoke-Check -Repo $repo -Commit $repo.Second

        $r.Code | Should -Be 0 -Because $r.Output
    }

    It 'exits 0 for several commits, given in one argument, when each has a receipt' {
        $repo = New-ReceiptRepo
        Add-Receipt -Repo $repo -Commit $repo.First
        Add-Receipt -Repo $repo -Commit $repo.Second

        $r = Invoke-Check -Repo $repo -Commit "$($repo.First) $($repo.Second)"

        $r.Code | Should -Be 0 -Because $r.Output
    }

    It 'exits 1 when one of several commits has no receipt' {
        $repo = New-ReceiptRepo
        Add-Receipt -Repo $repo -Commit $repo.Second

        $r = Invoke-Check -Repo $repo -Commit "$($repo.First),$($repo.Second)"

        $r.Code | Should -Be 1
        $r.Output | Should -Match $repo.First.Substring(0, 8)
    }

    It 'exits 1 when the receipt says FAIL' {
        $repo = New-ReceiptRepo
        Add-Receipt -Repo $repo -Commit $repo.Second -Status FAIL

        (Invoke-Check -Repo $repo -Commit $repo.Second).Code | Should -Be 1
    }

    It 'exits 1 for a commit git does not know, and for no commit at all' {
        $repo = New-ReceiptRepo

        (Invoke-Check -Repo $repo -Commit ('b' * 40)).Code | Should -Be 1
        (Invoke-Check -Repo $repo -Commit ' ').Code | Should -Be 1
    }

    It 'reads the receipt folder from paths.preflightReceipts' {
        $repo = New-ReceiptRepo
        Set-Content -LiteralPath (Join-Path $repo.Root 'aisdlc.json') -Value '{ "paths": { "preflightReceipts": "out/receipts" } }'
        $repo.Receipts = Join-Path $repo.Root 'out' 'receipts'
        Add-Receipt -Repo $repo -Commit $repo.Second

        (Invoke-Check -Repo $repo -Commit $repo.Second).Code | Should -Be 0
    }
}
