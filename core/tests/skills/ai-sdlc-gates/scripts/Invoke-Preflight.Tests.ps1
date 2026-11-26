#requires -Version 7.4

Describe 'Invoke-Preflight' {
    BeforeAll {
        $script:Made = [System.Collections.Generic.List[string]]::new()

        function New-PreflightRepo {
            param(
                [int]$GatesExit = 0,
                [string]$Packs = '[]',
                [hashtable]$Extra = @{},
                [string]$Config = '{}',
                [string]$GatesWaitFor
            )
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('preflight-' + [guid]::NewGuid().ToString('n'))
            $scripts = Join-Path $root '.claude' 'skills' 'ai-sdlc-gates' 'scripts'
            New-Item -ItemType Directory -Path $scripts -Force | Out-Null
            $script:Made.Add($root)
            git -C $root init --quiet
            git -C $root config user.email probe@example.invalid
            git -C $root config user.name probe
            foreach ($name in 'Invoke-Preflight.ps1', 'AiSdlcConfig.psm1', 'PreflightReceipt.psm1', 'GitleaksConfig.psm1') {
                Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $scripts
            }
            Set-Content -LiteralPath (Join-Path $scripts 'gitleaks-rules.json') -Value $script:RulesPin
            $calls = Join-Path $root 'gate-calls.txt'
            Set-Content -LiteralPath (Join-Path $scripts 'Invoke-LocalGates.ps1') -Value @(
                'param([string]$RepoRoot, [switch]$IncludeToolTests)'
                "Add-Content -LiteralPath '$calls' -Value ""IncludeToolTests=`$IncludeToolTests"""
                $(if ($GatesWaitFor) { "`$n = 0; while (-not (Test-Path -LiteralPath '$GatesWaitFor') -and `$n -lt 100) { Start-Sleep -Milliseconds 100; `$n++ }; if (-not (Test-Path -LiteralPath '$GatesWaitFor')) { Write-Host 'the gates waited alone'; exit 1 }" })
                "exit $GatesExit"
            )
            Set-Content -LiteralPath (Join-Path $scripts '..' 'gates.json') -Value '{ "package": "core", "gates": [] }'
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value $Config
            Set-Content -LiteralPath (Join-Path $root 'apm.yml') -Value ((@('dependencies:', '  apm:') + @($Packs | ConvertFrom-Json | ForEach-Object { "    - ../AI.SDLC/packs/$_" })) -join "`n")
            foreach ($rel in $Extra.Keys) {
                $full = Join-Path $root $rel
                New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
                Set-Content -LiteralPath $full -Value $Extra[$rel]
            }
            git -C $root add aisdlc.json apm.yml
            git -C $root commit --quiet -m init --no-verify
            return $root
        }

        function Invoke-Preflight {
            param([string]$Root, [hashtable]$Options = @{}, [switch]$WithScanners)
            $receipts = Join-Path $Root 'receipts'
            $call = @{ RepoRoot = $Root; ReceiptRoot = $receipts } + $Options
            if (-not $WithScanners) { $call.SkipScanners = $true }
            $out = & (Join-Path $Root '.claude' 'skills' 'ai-sdlc-gates' 'scripts' 'Invoke-Preflight.ps1') @call *>&1 | Out-String
            return [pscustomobject]@{
                Code     = $LASTEXITCODE
                Output   = $out
                Receipts = @(Get-ChildItem -LiteralPath $receipts -Filter '*.json' -ErrorAction SilentlyContinue)
            }
        }

        function gitleaks { }

        $rulesHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('# rules'))).ToLowerInvariant()
        $script:RulesPin = @{ configurations = @{ GitleaksUdmCombo = @{ url = 'https://example.invalid/rules/0123abc/GitleaksUdmCombo.toml'; sha256 = $rulesHash } } } | ConvertTo-Json -Depth 5
    }

    BeforeEach {
        Mock Invoke-WebRequest { Set-Content -LiteralPath $OutFile -Value '# rules' -NoNewline }
        $global:PreflightTest = @{ Findings = 0; WriteReport = $true; Exit = 0; Config = $null }
        Mock gitleaks {
            $configAt = [array]::IndexOf($args, '--config')
            if ($configAt -ge 0 -and (Test-Path -LiteralPath $args[$configAt + 1])) { $global:PreflightTest.Config = Get-Content -LiteralPath $args[$configAt + 1] -Raw }
            $at = [array]::IndexOf($args, '--report-path')
            if ($global:PreflightTest.WriteReport -and $at -ge 0) {
                $findings = @(1..$global:PreflightTest.Findings | Where-Object { $global:PreflightTest.Findings -gt 0 } | ForEach-Object { @{ RuleID = 'r'; Fingerprint = "f$_" } })
                ConvertTo-Json -InputObject @($findings) | Set-Content -LiteralPath $args[$at + 1]
            }
            $global:LASTEXITCODE = $global:PreflightTest.Exit
        }
    }

    AfterAll {
        Remove-Variable -Name PreflightTest -Scope Global -ErrorAction SilentlyContinue
        foreach ($dir in $script:Made) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'runs the gates without the shared self-tests, passes, and writes a receipt for the tree of HEAD' {
        $root = New-PreflightRepo

        $r = Invoke-Preflight -Root $root

        $r.Code | Should -Be 0 -Because $r.Output
        Get-Content -LiteralPath (Join-Path $root 'gate-calls.txt') | Should -Be 'IncludeToolTests=False'
        $r.Output | Should -Not -Match 'self-tests'
        $tree = (git -C $root rev-parse 'HEAD^{tree}').Trim()
        $r.Receipts.Name | Should -Be "$tree.json"
        (Get-Content -LiteralPath $r.Receipts[0].FullName -Raw | ConvertFrom-Json).Status | Should -Be 'PASS'
    }

    It 'fails and writes no receipt when a gate fails' {
        $root = New-PreflightRepo -GatesExit 1

        $r = Invoke-Preflight -Root $root

        $r.Code | Should -Be 1
        $r.Receipts | Should -HaveCount 0
    }

    It 'passes but writes no receipt with -SkipTests' {
        $root = New-PreflightRepo

        $r = Invoke-Preflight -Root $root -Options @{ SkipTests = $true }

        $r.Code | Should -Be 0
        $r.Receipts | Should -HaveCount 0
    }

    It 'passes but writes no receipt when a tracked file has uncommitted changes' {
        $root = New-PreflightRepo
        Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value '{ "repository": "changed" }'

        $r = Invoke-Preflight -Root $root

        $r.Code | Should -Be 0
        $r.Receipts | Should -HaveCount 0
    }

    Context 'the preflight of a pack' {
        BeforeAll {
            $script:PackManifest = '{ "package": "demo", "preflight": "scripts/Invoke-DemoPreflight.ps1", "gates": [] }'
        }

        It 'folds a FAIL row of a listed pack into the result and writes no receipt' {
            $root = New-PreflightRepo -Packs '["demo"]' -Extra @{
                '.claude/skills/demo/gates.json'                     = $script:PackManifest
                '.claude/skills/demo/scripts/Invoke-DemoPreflight.ps1' = 'param([string]$RepoRoot) [pscustomobject]@{ Check = "demo build"; Status = "FAIL"; Detail = "broken" }'
            }

            $r = Invoke-Preflight -Root $root

            $r.Code | Should -Be 1
            $r.Output | Should -Match 'demo build'
            $r.Receipts | Should -HaveCount 0
        }

        It 'passes only the parameters the pack script declares' {
            $seen = Join-Path $TestDrive 'pack-args.txt'
            $root = New-PreflightRepo -Packs '["demo"]' -Extra @{
                '.claude/skills/demo/gates.json'                     = $script:PackManifest
                '.claude/skills/demo/scripts/Invoke-DemoPreflight.ps1' = "param([string]`$RepoRoot, [switch]`$SkipTests) Set-Content -LiteralPath '$seen' -Value ((@(`$PSBoundParameters.Keys) | Sort-Object) -join ','); [pscustomobject]@{ Check = 'demo'; Status = 'PASS'; Detail = '' }"
            }

            $r = Invoke-Preflight -Root $root -Options @{ SkipTests = $true }

            $r.Code | Should -Be 0 -Because $r.Output
            Get-Content -LiteralPath $seen | Should -Be 'RepoRoot,SkipTests'
        }

        It 'does not run the preflight of a pack that apm.yml does not list' {
            $root = New-PreflightRepo -Extra @{
                '.claude/skills/demo/gates.json'                     = $script:PackManifest
                '.claude/skills/demo/scripts/Invoke-DemoPreflight.ps1' = '[pscustomobject]@{ Check = "demo build"; Status = "FAIL"; Detail = "broken" }'
            }

            $r = Invoke-Preflight -Root $root

            $r.Code | Should -Be 0 -Because $r.Output
        }

        It 'writes the receipt when a pack row reads NOT-AVAIL, because only a FAIL row blocks it' {
            $root = New-PreflightRepo -Packs '["demo"]' -Extra @{
                '.claude/skills/demo/gates.json'                     = $script:PackManifest
                '.claude/skills/demo/scripts/Invoke-DemoPreflight.ps1' = 'param([string]$RepoRoot) [pscustomobject]@{ Check = "demo coverage"; Status = "NOT-AVAIL"; Detail = "no report" }'
            }
            git -C $root add .claude
            git -C $root commit --quiet -m pack --no-verify

            $r = Invoke-Preflight -Root $root

            $r.Code | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match 'NOT-AVAIL'
            $r.Receipts | Should -HaveCount 1
        }

        It 'fails when a listed pack names a preflight script that is missing' {
            $root = New-PreflightRepo -Packs '["demo"]' -Extra @{ '.claude/skills/demo/gates.json' = $script:PackManifest }

            $r = Invoke-Preflight -Root $root

            $r.Code | Should -Be 1
        }
    }

    Context 'the test command of the repository' {
        BeforeAll {
            function New-TestCommandRepo {
                param([int]$Exit)
                $cwd = (Join-Path $TestDrive ('cwd-' + [guid]::NewGuid().ToString('n') + '.txt')).Replace('\', '/')
                $command = "Set-Content -LiteralPath '$cwd' -Value (Get-Location).Path; exit $Exit"
                $root = New-PreflightRepo -Config (@{ commands = @{ test = $command } } | ConvertTo-Json -Depth 3)
                return [pscustomobject]@{ Root = $root; Cwd = $cwd }
            }
        }

        It 'runs commands.test from the repository root, shows a PASS row and writes the receipt' {
            $repo = New-TestCommandRepo -Exit 0

            $r = Invoke-Preflight -Root $repo.Root

            $r.Code | Should -Be 0 -Because $r.Output
            (Get-Content -LiteralPath $repo.Cwd).Trim() | Should -Be (Resolve-Path -LiteralPath $repo.Root).Path
            $r.Output | Should -Match 'Tests \(commands\.test\)\s+PASS'
            $r.Receipts | Should -HaveCount 1
        }

        It 'shows a FAIL row, fails and writes no receipt when commands.test exits non-zero' {
            $repo = New-TestCommandRepo -Exit 3

            $r = Invoke-Preflight -Root $repo.Root

            $r.Code | Should -Be 1
            $r.Output | Should -Match 'Tests \(commands\.test\)\s+FAIL'
            $r.Output | Should -Match 'exit 3'
            $r.Receipts | Should -HaveCount 0
        }

        It 'runs commands.test at the same time as the gates, and prints its output after them' {
            $flag = (Join-Path $TestDrive ('flag-' + [guid]::NewGuid().ToString('n'))).Replace('\', '/')
            $root = New-PreflightRepo -GatesWaitFor $flag -Config (@{ commands = @{ test = "Set-Content -LiteralPath '$flag' -Value x; Write-Host 'the tests ran'; exit 0" } } | ConvertTo-Json -Depth 3)

            $r = Invoke-Preflight -Root $root

            $r.Code | Should -Be 0 -Because $r.Output
            $r.Output | Should -Not -Match 'the gates waited alone'
            $r.Output | Should -Match 'the tests ran'
            $r.Output | Should -Match 'Tests \(commands\.test\)\s+PASS'
        }

        It 'runs no test command and adds no test row when commands.test is not set' {
            $root = New-PreflightRepo

            $r = Invoke-Preflight -Root $root

            $r.Code | Should -Be 0 -Because $r.Output
            $r.Output | Should -Not -Match 'commands\.test'
        }

        It 'leaves commands.test to a pack whose preflight runs the tests, so they do not run twice' {
            $cwd = (Join-Path $TestDrive ('cwd-' + [guid]::NewGuid().ToString('n') + '.txt')).Replace('\', '/')
            $root = New-PreflightRepo -Packs '["demo"]' -Config (@{ commands = @{ test = "Set-Content -LiteralPath '$cwd' -Value x" } } | ConvertTo-Json -Depth 3) -Extra @{
                '.claude/skills/demo/gates.json'                     = '{ "package": "demo", "preflight": "scripts/Invoke-DemoPreflight.ps1", "gates": [] }'
                '.claude/skills/demo/scripts/Invoke-DemoPreflight.ps1' = 'param([string]$RepoRoot, [switch]$SkipTests) [pscustomobject]@{ Check = "demo tests"; Status = "PASS"; Detail = "" }'
            }

            $r = Invoke-Preflight -Root $root

            $r.Code | Should -Be 0 -Because $r.Output
            Test-Path -LiteralPath $cwd | Should -BeFalse
            $r.Output | Should -Match 'commands\.test.*demo'
        }

        It 'does not run commands.test with -SkipTests' {
            $repo = New-TestCommandRepo -Exit 0

            $r = Invoke-Preflight -Root $repo.Root -Options @{ SkipTests = $true }

            $r.Code | Should -Be 0 -Because $r.Output
            Test-Path -LiteralPath $repo.Cwd | Should -BeFalse
            $r.Receipts | Should -HaveCount 0
        }
    }

    Context 'the security scanners' {
        It 'names no CI scanner job, because no shipped pipeline runs these scanners' {
            Mock Get-Command { $null } -ParameterFilter { $Name -in 'trivy', 'checkov', 'semgrep', 'docker' }
            $pattern = 'MicrosoftSecurityDevOps|main-only in CI|semgrep ci|SEMGREP_APP_TOKEN'

            $skipped = Invoke-Preflight -Root (New-PreflightRepo)
            $tried = Invoke-Preflight -Root (New-PreflightRepo) -WithScanners

            $skipped.Output | Should -Not -Match $pattern
            $tried.Output | Should -Match 'Trivy'
            $tried.Output | Should -Not -Match $pattern
        }
    }

    Context 'the secret scan' {
        It 'fails the run and writes no receipt when gitleaks finds a secret outside the baseline' {
            $global:PreflightTest.Findings = 2
            $global:PreflightTest.Exit = 1
            $root = New-PreflightRepo

            $r = Invoke-Preflight -Root $root

            $r.Code | Should -Be 1
            $r.Output | Should -Match 'FAIL'
            $r.Output | Should -Match 'gitleaks-baseline\.json'
            $r.Receipts | Should -HaveCount 0
            Should -Invoke gitleaks -Times 1 -Exactly
        }

        It 'passes the repository baseline to gitleaks when there is one' {
            $root = New-PreflightRepo -Extra @{ 'gitleaks-baseline.json' = '[]' }

            Invoke-Preflight -Root $root | Out-Null

            Should -Invoke gitleaks -Times 1 -Exactly -ParameterFilter { ($args -join ' ') -match '--baseline-path' }
        }

        It 'scans with the pinned rules of CI and the allowlist of the AI-SDLC, so the hashes of the sync manifest pass' {
            Invoke-Preflight -Root (New-PreflightRepo) | Out-Null

            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -match 'GitleaksUdmCombo\.toml$' }
            $global:PreflightTest.Config | Should -Match "path = '.*gitleaks-rules-"
            $global:PreflightTest.Config | Should -Not -Match 'useDefault'
            $global:PreflightTest.Config | Should -Match 'sync-manifest'
        }

        It 'fails and scans nothing when the downloaded rules do not match the pinned SHA-256' {
            Mock Invoke-WebRequest { Set-Content -LiteralPath $OutFile -Value '# changed rules' -NoNewline }

            $r = Invoke-Preflight -Root (New-PreflightRepo)

            $r.Code | Should -Be 1
            $r.Output | Should -Match 'SHA-256'
            Should -Invoke gitleaks -Times 0 -Exactly
        }

        It 'skips the scan and says so when the pinned rules cannot be downloaded' {
            Mock Invoke-WebRequest { throw 'offline' }

            $r = Invoke-Preflight -Root (New-PreflightRepo)

            $r.Code | Should -Be 0
            $r.Output | Should -Match 'could not be downloaded'
            Should -Invoke gitleaks -Times 0 -Exactly
        }

        It 'writes the gitleaks report to a new file for each run and removes it, so two runs at the same time do not share one' {
            $reports = [System.Collections.Generic.List[string]]::new()
            Mock gitleaks {
                $at = [array]::IndexOf($args, '--report-path')
                $reports.Add($args[$at + 1])
                ConvertTo-Json -InputObject @() | Set-Content -LiteralPath $args[$at + 1]
                $global:LASTEXITCODE = 0
            }

            Invoke-Preflight -Root (New-PreflightRepo) | Out-Null
            Invoke-Preflight -Root (New-PreflightRepo) | Out-Null

            $reports | Should -HaveCount 2
            $reports[0] | Should -Not -Be $reports[1]
            foreach ($report in $reports) { Test-Path -LiteralPath $report | Should -BeFalse }
        }

        It 'fails when gitleaks writes no report, because the scan did not complete' {
            $global:PreflightTest.WriteReport = $false
            $global:PreflightTest.Exit = 126
            $root = New-PreflightRepo

            $r = Invoke-Preflight -Root $root

            $r.Code | Should -Be 1
            $r.Receipts | Should -HaveCount 0
        }

        It 'skips the scan and still passes when gitleaks is not installed' {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'gitleaks' }
            $root = New-PreflightRepo

            $r = Invoke-Preflight -Root $root

            $r.Code | Should -Be 0
            $r.Output | Should -Match 'SKIP'
            Should -Invoke gitleaks -Times 0 -Exactly
        }
    }
}
