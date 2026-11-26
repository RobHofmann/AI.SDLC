#requires -Version 7.4

Describe 'Build-GateCatalog' {
    BeforeAll {
        $script:Tool = Join-Path $PSScriptRoot 'Build-GateCatalog.ps1'
        Import-Module (Join-Path $PSScriptRoot '..' 'core' 'tests' 'skills' 'ai-sdlc-gates' 'scripts' 'DocToolTestHarness.psm1') -Force
        $script:SharedPage = 'core/.apm/skills/ai-sdlc-gates/references/gate-catalog.md'
        $script:LocalPage = 'docs/gates.md'

        function New-GateEntry {
            param([string]$Name, [string]$Script = 'scripts/Check-Sample.ps1', [string]$Clause = 'C06', [string]$Mode = 'Blocking', [string]$Checks = 'It reads the docs. Exit 2 means no docs, and exit 3 means no page.', [string]$Fix = 'Fix the page.')
            $entry = [ordered]@{ name = $Name; script = $Script; clause = $Clause; mode = $Mode }
            if ($Checks) { $entry.checks = $Checks }
            if ($Fix) { $entry.fix = $Fix }
            return $entry
        }

        function Write-Json {
            param([string]$Path, $Value)
            New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
            Set-Content -LiteralPath $Path -Value ($Value | ConvertTo-Json -Depth 6) -Encoding utf8
        }

        function New-GateRepo {
            param([object[]]$CoreGates = @(), [object[]]$PackGates = @(), [object[]]$RepoGates = @())
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('bgc-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path (Join-Path $root 'packs') -Force | Out-Null
            Write-Json -Path (Join-Path $root 'core' '.apm' 'skills' 'sample-gates' 'gates.json') -Value ([ordered]@{ package = 'core'; gates = @($CoreGates) })
            if ($PackGates.Count -gt 0) {
                Write-Json -Path (Join-Path $root 'packs' 'contoso' '.apm' 'skills' 'contoso-gates' 'gates.json') -Value ([ordered]@{ package = 'contoso'; gates = @($PackGates) })
            }
            Write-Json -Path (Join-Path $root 'aisdlc.json') -Value ([ordered]@{ repository = 'Contoso'; repoGates = @($RepoGates) })
            return $root
        }

        function Invoke-Tool {
            param([string]$Root, [switch]$Check)
            $extra = @()
            if ($Check) { $extra += '-Check' }
            $run = Invoke-ScriptInProcess -Path $script:Tool -Arguments (@('-RepoRoot', $Root) + $extra)
            return [pscustomobject]@{ Code = $run.ExitCode; Output = $run.Output }
        }

        function New-StandardRepo {
            return New-GateRepo -CoreGates @(New-GateEntry -Name 'Docs hold no em-dash characters') -PackGates @(New-GateEntry -Name 'Added public types carry a doc comment' -Clause 'C10' -Mode 'Advisory') -RepoGates @(New-GateEntry -Name 'Shared files hold no em-dash characters' -Script 'tools/Check-Sample.ps1' -Clause 'AI-SDLC')
        }
    }

    It 'writes the shared page with a section per package, and the repository page with its own gates' -Tag '#47' {
        $root = New-StandardRepo

        $result = Invoke-Tool -Root $root
        $shared = Get-Content -LiteralPath (Join-Path $root $script:SharedPage) -Raw
        $local = Get-Content -LiteralPath (Join-Path $root $script:LocalPage) -Raw

        $result.Code | Should -Be 0
        $shared | Should -Match '(?m)^## core$'
        $shared | Should -Match '(?m)^## contoso$'
        $shared | Should -Match '(?m)^### Docs hold no em-dash characters$'
        $shared | Should -Match '(?m)^- Clause: C10$'
        $shared | Should -Match '(?m)^- Checks: It reads the docs\.'
        $shared | Should -Match '(?m)^- Fix: Fix the page\.$'
        $shared | Should -Not -Match 'Shared files hold no em-dash characters'
        $local | Should -Match '(?m)^### Shared files hold no em-dash characters$'
        $local | Should -Match '(?m)^- Script: `tools/Check-Sample\.ps1`$'
    }

    It 'shows an advisory gate as a warning in where it runs' -Tag '#47' {
        $root = New-StandardRepo
        Invoke-Tool -Root $root | Out-Null

        (Get-Content -LiteralPath (Join-Path $root $script:SharedPage) -Raw) | Should -Match '(?m)^- Runs in: pull request action \(as a warning\), local run$'
    }

    It 'passes the check right after a write' -Tag '#47' {
        $root = New-StandardRepo
        Invoke-Tool -Root $root | Out-Null

        $result = Invoke-Tool -Root $root -Check

        $result.Code | Should -Be 0
        $result.Output | Should -Match 'Gate pages current'
    }

    It 'changes nothing on a second run' -Tag '#47' {
        $root = New-StandardRepo
        Invoke-Tool -Root $root | Out-Null
        $before = Get-Content -LiteralPath (Join-Path $root $script:SharedPage) -Raw
        $stamp = (Get-Item -LiteralPath (Join-Path $root $script:SharedPage)).LastWriteTimeUtc

        $result = Invoke-Tool -Root $root

        $result.Code | Should -Be 0
        $result.Output | Should -Not -Match 'Gate page written'
        (Get-Content -LiteralPath (Join-Path $root $script:SharedPage) -Raw) | Should -BeExactly $before
        (Get-Item -LiteralPath (Join-Path $root $script:SharedPage)).LastWriteTimeUtc | Should -Be $stamp
    }

    It 'writes both pages with LF line endings' -Tag '#47' {
        $root = New-StandardRepo
        Invoke-Tool -Root $root | Out-Null

        [IO.File]::ReadAllText((Join-Path $root $script:SharedPage)) | Should -Not -Match "`r"
        [IO.File]::ReadAllText((Join-Path $root $script:LocalPage)) | Should -Not -Match "`r"
    }

    It 'fails the check, names the page and says how to fix it, when a gate text changed' -Tag '#47' {
        $root = New-StandardRepo
        Invoke-Tool -Root $root | Out-Null
        $manifest = Join-Path $root 'core' '.apm' 'skills' 'sample-gates' 'gates.json'
        Write-Json -Path $manifest -Value ([ordered]@{ package = 'core'; gates = @(New-GateEntry -Name 'Docs hold no em-dash characters' -Fix 'Fix the page in a new way.') })

        $result = Invoke-Tool -Root $root -Check

        $result.Code | Should -Be 1
        $result.Output | Should -Match ([regex]::Escape($script:SharedPage) + ' : differs from the gates')
        $result.Output | Should -Match 'FIX: Run pwsh tools/Build-GateCatalog\.ps1'
        $result.Output | Should -Not -Match ([regex]::Escape($script:LocalPage) + ' :')
    }

    It 'fails the check and names the page when a page is missing' -Tag '#47' {
        $root = New-StandardRepo
        Invoke-Tool -Root $root | Out-Null
        Remove-Item -LiteralPath (Join-Path $root $script:LocalPage)

        $result = Invoke-Tool -Root $root -Check

        $result.Code | Should -Be 1
        $result.Output | Should -Match ([regex]::Escape($script:LocalPage) + ' : missing')
        (Test-Path -LiteralPath (Join-Path $root $script:LocalPage)) | Should -BeFalse
    }

    It 'could not check a gate with no checks text, and says how to fix it (exit 2)' -Tag '#47' {
        $root = New-GateRepo -CoreGates @(New-GateEntry -Name 'Docs hold no em-dash characters' -Checks '')

        $result = Invoke-Tool -Root $root

        $result.Code | Should -Be 2
        $result.Output | Should -Match 'has no checks text'
        $result.Output | Should -Match 'FIX: Add a checks text'
        (Test-Path -LiteralPath (Join-Path $root $script:SharedPage)) | Should -BeFalse
    }

    It 'could not check a gate with no fix text (exit 2)' -Tag '#47' {
        $root = New-GateRepo -RepoGates @(New-GateEntry -Name 'Shared files hold no em-dash characters' -Fix '')

        $result = Invoke-Tool -Root $root -Check

        $result.Code | Should -Be 2
        $result.Output | Should -Match 'has no fix text'
    }

    It 'could not check a folder with no core or packs folder (exit 2)' -Tag '#47' {
        $empty = Join-Path $TestDrive 'no-packages'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null

        $result = Invoke-Tool -Root $empty -Check

        $result.Code | Should -Be 2
        $result.Output | Should -Match 'FIX: Run the tool from the AI\.SDLC repository'
    }

    It 'is not applicable when there is no gate at all (exit 3), and writes no page' -Tag '#47' {
        $root = New-GateRepo

        $result = Invoke-Tool -Root $root

        $result.Code | Should -Be 3
        $result.Output | Should -Match 'Not applicable'
        (Test-Path -LiteralPath (Join-Path $root $script:SharedPage)) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $root $script:LocalPage)) | Should -BeFalse
    }
}
