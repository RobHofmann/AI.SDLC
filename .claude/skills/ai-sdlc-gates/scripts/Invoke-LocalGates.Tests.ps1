#requires -Version 7.4

Describe 'Invoke-LocalGates' {
    BeforeAll {
        $script:Runner = Join-Path $PSScriptRoot 'Invoke-LocalGates.ps1'
        Import-Module (Join-Path $PSScriptRoot 'DocToolTestHarness.psm1') -Force

        function New-GateRepo {
            param([string]$Config, [hashtable]$Files, [string]$Packs = '[]')
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('ilg-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value $Config -Encoding utf8
            Set-Content -LiteralPath (Join-Path $root 'apm.yml') -Value ((@('dependencies:', '  apm:') + @($Packs | ConvertFrom-Json | ForEach-Object { "    - ../AI.SDLC/packs/$_" })) -join "`n")
            foreach ($rel in $Files.Keys) {
                $full = Join-Path $root $rel
                New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
                Set-Content -LiteralPath $full -Value $Files[$rel] -Encoding utf8
            }
            return $root
        }

        $script:PassGate = 'param([string]$RepoRoot, [switch]$Strict) Write-Host "ran $($MyInvocation.MyCommand.Name) strict=$Strict"; exit 0'
        $script:FailGate = 'param([string]$RepoRoot) Write-Host "ran failing gate"; exit 1'

        function New-StandardRepo {
            param([string]$Packs = '[]', [string]$RepoGates = '[]', [string]$CoreMode = 'Blocking', [string]$CoreScript = $script:PassGate)
            New-GateRepo -Packs $Packs -Config "{ `"repoGates`": $RepoGates }" -Files @{
                '.claude/skills/ai-sdlc-gates/gates.json'           = "{ `"package`": `"core`", `"gates`": [ { `"name`": `"core gate`", `"script`": `"scripts/Check-Core.ps1`", `"mode`": `"$CoreMode`", `"args`": { `"Strict`": true } } ] }"
                '.claude/skills/ai-sdlc-gates/scripts/Check-Core.ps1' = $CoreScript
                '.claude/skills/dotnet-gates/gates.json'            = '{ "package": "dotnet", "gates": [ { "name": "dotnet gate", "script": "scripts/Check-Dotnet.ps1", "mode": "Blocking" } ] }'
                '.claude/skills/dotnet-gates/scripts/Check-Dotnet.ps1' = $script:PassGate
                'tools/Check-Repo.ps1'                              = $script:PassGate
            }
        }

        function Invoke-Runner {
            param([string]$Root, [string[]]$Extra = @())
            $run = Invoke-ScriptInProcess -Path $script:Runner -Arguments (@('-RepoRoot', $Root) + $Extra)
            return [pscustomobject]@{ Code = $run.ExitCode; Output = $run.Output }
        }
    }

    It 'runs the core gates and skips the gates of a pack that apm.yml does not list' {
        $root = New-StandardRepo

        $result = Invoke-Runner -Root $root

        $result.Code | Should -Be 0
        $result.Output | Should -Match 'ran Check-Core\.ps1'
        $result.Output | Should -Not -Match 'Check-Dotnet'
    }

    It 'runs the gates of a pack that apm.yml lists' {
        $root = New-StandardRepo -Packs '["dotnet"]'

        $result = Invoke-Runner -Root $root

        $result.Output | Should -Match 'ran Check-Dotnet\.ps1'
    }

    It 'runs the repository gates from aisdlc.json, with the script relative to the repository root' {
        $root = New-StandardRepo -RepoGates '[ { "name": "repo gate", "script": "tools/Check-Repo.ps1", "mode": "Blocking" } ]'

        $result = Invoke-Runner -Root $root

        $result.Output | Should -Match 'ran Check-Repo\.ps1'
    }

    It 'passes the arguments from gates.json to the gate' {
        $root = New-StandardRepo

        $result = Invoke-Runner -Root $root

        $result.Output | Should -Match 'strict=True'
    }

    It 'fails on a failing blocking gate' {
        $root = New-StandardRepo -CoreScript $script:FailGate

        $result = Invoke-Runner -Root $root

        $result.Code | Should -Be 1
        $result.Output | Should -Match '1 blocking gate\(s\) failed'
    }

    It 'reports a failing advisory gate without failing the run' {
        $root = New-StandardRepo -CoreScript $script:FailGate -CoreMode 'Advisory'

        $result = Invoke-Runner -Root $root

        $result.Code | Should -Be 0
        $result.Output | Should -Match 'ADVISORY'
    }

    It 'runs the gates side by side, and prints the output of each gate in the order of the list' {
        $flag = Join-Path ([System.IO.Path]::GetTempPath()) ('ilg-flag-' + [guid]::NewGuid().ToString('n'))
        $waits = "param([string]`$RepoRoot) `$n = 0; while (-not (Test-Path -LiteralPath '$flag') -and `$n -lt 100) { Start-Sleep -Milliseconds 100; `$n++ }; if (Test-Path -LiteralPath '$flag') { Write-Host 'first saw second'; exit 0 }; Write-Host 'first waited alone'; exit 1"
        $sets = "param([string]`$RepoRoot) Set-Content -LiteralPath '$flag' -Value x; Write-Host 'second ran'; exit 0"
        $root = New-StandardRepo -CoreScript $waits -RepoGates '[ { "name": "repo gate", "script": "tools/Check-Second.ps1", "mode": "Blocking" } ]'
        Set-Content -LiteralPath (Join-Path $root 'tools' 'Check-Second.ps1') -Value $sets

        $result = Invoke-Runner -Root $root
        Remove-Item -LiteralPath $flag -ErrorAction SilentlyContinue

        $result.Code | Should -Be 0 -Because $result.Output
        $result.Output | Should -Match 'first saw second'
        $result.Output.IndexOf('===== core gate') | Should -BeLessThan $result.Output.IndexOf('===== repo gate')
        $result.Output.IndexOf('first saw second') | Should -BeLessThan $result.Output.IndexOf('===== repo gate')
    }

    It 'leaves out the gates that run Pester tests with -SkipTests, and lists them as skipped' {
        $root = New-StandardRepo -RepoGates '[ { "name": "repo tests", "script": ".claude/skills/ai-sdlc-gates/scripts/Invoke-PesterGate.ps1", "mode": "Blocking", "args": { "Path": [ "tools" ] } }, { "name": "runner tests", "script": "tools/Invoke-PesterParallel.ps1", "mode": "Blocking" } ]'
        Set-Content -LiteralPath (Join-Path $root '.claude' 'skills' 'ai-sdlc-gates' 'scripts' 'Invoke-PesterGate.ps1') -Value 'param([string]$RepoRoot, [string[]]$Path) Write-Host "tests ran"; exit 1'
        Set-Content -LiteralPath (Join-Path $root 'tools' 'Invoke-PesterParallel.ps1') -Value 'param([string]$RepoRoot) Write-Host "tests ran"; exit 1'

        $result = Invoke-Runner -Root $root -Extra @('-SkipTests')

        $result.Code | Should -Be 0 -Because $result.Output
        $result.Output | Should -Not -Match 'tests ran'
        $result.Output | Should -Match 'ran Check-Core\.ps1'
        $result.Output | Should -Match 'repo tests\s+Blocking\s+SKIP'
    }

    It 'leaves out the advisory gates with -BlockingOnly' {
        $root = New-StandardRepo -CoreMode 'Advisory'

        $result = Invoke-Runner -Root $root -Extra @('-BlockingOnly', '-List')

        $result.Output | Should -Match '0 gate\(s\)'
    }

    It 'lists the gates it would run, with their package, and runs none' {
        $root = New-StandardRepo -Packs '["dotnet"]'

        $result = Invoke-Runner -Root $root -Extra @('-List')

        $result.Output | Should -Match 'core\s+Blocking\s+\S+\s+core gate'
        $result.Output | Should -Match 'dotnet\s+Blocking\s+\S+\s+dotnet gate'
        $result.Output | Should -Not -Match 'ran Check-'
    }

    It 'lists the clause of each gate and where it runs: a Blocking gate also in pre-push, an Advisory one not' {
        $root = New-StandardRepo -CoreMode 'Advisory' -Packs '["dotnet"]'

        $result = Invoke-Runner -Root $root -Extra @('-List')

        $lines = @($result.Output -split "`r?`n")
        $core = [Array]::FindIndex($lines, [Predicate[string]] { param($l) $l -match 'core\s+Advisory\s+core\s+core gate' })
        $dotnet = [Array]::FindIndex($lines, [Predicate[string]] { param($l) $l -match 'dotnet\s+Blocking\s+dotnet\s+dotnet gate' })
        $core | Should -BeGreaterThan -1 -Because $result.Output
        $dotnet | Should -BeGreaterThan -1 -Because $result.Output
        $lines[$core + 1] | Should -Match 'runs in: pull request \(as a warning\), local run'
        $lines[$core + 1] | Should -Not -Match 'pre-push'
        $lines[$dotnet + 1] | Should -Match 'runs in: pre-push, pull request, local run'
    }

    It 'lists a gate that needs a coverage file, and says when it runs' {
        $root = New-GateRepo -Config '{}' -Files @{
            '.claude/skills/ai-sdlc-gates/gates.json'             = '{ "package": "core", "gates": [ { "name": "coverage gate", "script": "scripts/Check-Core.ps1", "clause": "C04", "mode": "Blocking", "requires": "CoverageFile" } ] }'
            '.claude/skills/ai-sdlc-gates/scripts/Check-Core.ps1' = $script:PassGate
        }

        $list = Invoke-Runner -Root $root -Extra @('-List')
        $run = Invoke-Runner -Root $root

        $list.Output | Should -Match 'coverage gate'
        $list.Output | Should -Match 'only with -CoverageFile'
        $run.Output | Should -Not -Match 'ran Check-Core'
    }

    It 'reports a gate whose script is missing as could-not-check' {
        $root = New-StandardRepo
        Remove-Item -LiteralPath (Join-Path $root '.claude/skills/ai-sdlc-gates/scripts/Check-Core.ps1')

        $result = Invoke-Runner -Root $root

        $result.Output | Should -Match 'UNVERIFIED'
    }

    It 'fails the run with a clear line, and runs the other gates, when a gate script stops with an error' {
        $root = New-StandardRepo -Packs '["dotnet"]' -CoreScript 'param([string]$RepoRoot, [switch]$Strict) throw "gate bug"'

        $result = Invoke-Runner -Root $root

        $result.Code | Should -Be 1
        $result.Output | Should -Match 'stopped before it could report.*gate bug'
        $result.Output | Should -Match 'ran Check-Dotnet\.ps1'
        $result.Output | Should -Match 'CRASHED'
    }

    Context 'in GitHub Actions' {
        BeforeEach {
            $script:SavedActions = $env:GITHUB_ACTIONS
            $script:SavedSummary = $env:GITHUB_STEP_SUMMARY
            $env:GITHUB_ACTIONS = 'true'
            $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive ('summary-' + [guid]::NewGuid().ToString('n') + '.md')
        }

        AfterEach {
            $env:GITHUB_ACTIONS = $script:SavedActions
            $env:GITHUB_STEP_SUMMARY = $script:SavedSummary
        }

        It 'raises an error for a failing Blocking gate and ends with exit 1' {
            $root = New-StandardRepo -CoreScript 'param([string]$RepoRoot, [switch]$Strict) Write-Host "Rule:"; Write-Host "  docs/a.md:4  bad"; exit 1'

            $result = Invoke-Runner -Root $root

            $result.Code | Should -Be 1
            $result.Output | Should -Match '::error file=docs/a\.md,line=4,title=core gate::core'
            $result.Output | Should -Not -Match '##vso'
        }

        It 'raises a warning for a failing Advisory gate and ends with exit 0' {
            $root = New-StandardRepo -CoreMode 'Advisory' -CoreScript 'param([string]$RepoRoot, [switch]$Strict) Write-Host "Rule:"; Write-Host "  docs/a.md:4  bad"; exit 1'

            $result = Invoke-Runner -Root $root

            $result.Code | Should -Be 0
            $result.Output | Should -Match '(?m)^::warning '
            $result.Output | Should -Not -Match '::error'
        }

        It 'raises a warning, never an error, for a Blocking gate that could not check' {
            $root = New-StandardRepo -CoreScript 'param([string]$RepoRoot, [switch]$Strict) Write-Host "No token, so NOTHING WAS CHECKED."; exit 2'

            $result = Invoke-Runner -Root $root

            $result.Code | Should -Be 0
            $result.Output | Should -Match '::warning title=core gate::.*COULD NOT BE CHECKED'
        }

        It 'writes no annotation when every gate passes, and adds the summary table to the job summary' {
            $root = New-StandardRepo

            $result = Invoke-Runner -Root $root

            $result.Code | Should -Be 0
            $result.Output | Should -Not -Match '::(error|warning)'
            $result.Output | Should -Match 'ran Check-Core\.ps1 strict=True'
            Get-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Raw | Should -Match '\| core gate \| Blocking \| PASS \|'
        }

        It 'reports a gate that stopped with an error as a fault in the gate' {
            $root = New-StandardRepo -CoreScript 'param([string]$RepoRoot, [switch]$Strict) throw "gate bug"'

            $result = Invoke-Runner -Root $root

            $result.Code | Should -Be 1
            $result.Output | Should -Match '::error title=Check-Core\.ps1::.*NOTHING WAS CHECKED'
        }
    }
}
