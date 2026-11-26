#requires -Version 7.4

BeforeAll { $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm' }

Describe 'Invoke-LocalGates' {
    BeforeAll {
        $script:Runner = Join-Path $script:ScriptFolder 'Invoke-LocalGates.ps1'
        Import-Module (Join-Path $PSScriptRoot 'DocToolTestHarness.psm1') -Force

        # Every gate entry needs a checks and a fix text (#47). A fixture that does not test those texts
        # gets plain ones here, so each test keeps its JSON short. -RawText leaves the entries as written.
        function Add-GateText {
            param([string]$Json)
            if (-not $Json) { return $Json }
            $data = $Json | ConvertFrom-Json -AsHashtable
            foreach ($list in @($data['gates'], $data['repoGates'])) {
                foreach ($entry in @($list | Where-Object { $_ -is [System.Collections.IDictionary] })) {
                    if (-not $entry.Contains('checks')) { $entry['checks'] = 'It checks the fixture. Exit 2 means it could not check, and exit 3 means nothing to check.' }
                    if (-not $entry.Contains('fix')) { $entry['fix'] = 'Fix the fixture.' }
                }
            }
            return ($data | ConvertTo-Json -Depth 10)
        }

        function New-GateRepo {
            param([string]$Config, [hashtable]$Files, [string]$Packs = '[]', [switch]$RawText)
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('ilg-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            if (-not $RawText) { $Config = Add-GateText -Json $Config }
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value $Config -Encoding utf8
            Set-Content -LiteralPath (Join-Path $root 'apm.yml') -Value ((@('dependencies:', '  apm:') + @($Packs | ConvertFrom-Json | ForEach-Object { "    - ../AI.SDLC/packs/$_" })) -join "`n")
            foreach ($rel in $Files.Keys) {
                $full = Join-Path $root $rel
                New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
                $text = $Files[$rel]
                if (-not $RawText -and (Split-Path -Leaf $rel) -eq 'gates.json') { $text = Add-GateText -Json $text }
                Set-Content -LiteralPath $full -Value $text -Encoding utf8
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

    It 'leaves out a gate by its script file name with -SkipScript, in any case, and lists it as SKIP' -Tag '#90' {
        $root = New-StandardRepo -RepoGates '[ { "name": "repo gate", "script": "tools/Check-Repo.ps1", "mode": "Blocking" } ]'

        $result = Invoke-Runner -Root $root -Extra @('-SkipScript', 'check-core.ps1')

        $result.Code | Should -Be 0 -Because $result.Output
        $result.Output | Should -Not -Match 'ran Check-Core'
        $result.Output | Should -Match 'ran Check-Repo\.ps1'
        $result.Output | Should -Match 'core gate\s+Blocking\s+SKIP'
    }

    It 'fails a gate entry with no <Field> text, names the field, and does not run that gate' -Tag '#47' -ForEach @(@{ Field = 'checks' }, @{ Field = 'fix' }) {
        $other = if ($Field -eq 'checks') { '"fix": "Fix it."' } else { '"checks": "It checks. Exit 2 means x, and exit 3 means y."' }
        $root = New-GateRepo -RawText -Config '{}' -Files @{
            '.claude/skills/ai-sdlc-gates/gates.json'             = "{ `"package`": `"core`", `"gates`": [ { `"name`": `"core gate`", `"script`": `"scripts/Check-Core.ps1`", `"mode`": `"Advisory`", $other } ] }"
            '.claude/skills/ai-sdlc-gates/scripts/Check-Core.ps1' = $script:PassGate
        }

        $result = Invoke-Runner -Root $root

        $result.Code | Should -Be 1 -Because $result.Output
        $result.Output | Should -Match "Invalid gate entry 'core gate': $Field is missing or empty"
        $result.Output | Should -Not -Match 'ran Check-Core'
        $result.Output | Should -Match 'core gate\s+Blocking\s+FAIL'
    }

    It 'keeps an Advisory entry that is not valid in a -BlockingOnly run, so the push fails on it' -Tag '#47' {
        $root = New-GateRepo -RawText -Config '{}' -Files @{
            '.claude/skills/ai-sdlc-gates/gates.json'             = '{ "package": "core", "gates": [ { "name": "core gate", "script": "scripts/Check-Core.ps1", "mode": "Advisory" } ] }'
            '.claude/skills/ai-sdlc-gates/scripts/Check-Core.ps1' = $script:PassGate
        }

        $result = Invoke-Runner -Root $root -Extra @('-BlockingOnly')

        $result.Code | Should -Be 1 -Because $result.Output
        $result.Output | Should -Match 'Invalid gate entry'
    }

    It 'fails both entries when two gates share a name' -Tag '#47' {
        $root = New-StandardRepo -RepoGates '[ { "name": "core gate", "script": "tools/Check-Repo.ps1", "mode": "Blocking" } ]'

        $result = Invoke-Runner -Root $root

        $result.Code | Should -Be 1 -Because $result.Output
        ([regex]::Matches($result.Output, 'the name is used by 2 gates')).Count | Should -Be 2
        $result.Output | Should -Not -Match 'ran Check-Core'
        $result.Output | Should -Not -Match 'ran Check-Repo'
    }

    It 'prints the checks text before the output of a gate that failed, and not for a gate that passed' -Tag '#47' {
        $root = New-StandardRepo -CoreScript $script:FailGate -RepoGates '[ { "name": "repo gate", "script": "tools/Check-Repo.ps1", "mode": "Blocking", "checks": "Repo checks text. Exit 2 means x, and exit 3 means y." } ]'

        $result = Invoke-Runner -Root $root

        $result.Output | Should -Match '(?s)What this gate checks: It checks the fixture\..*ran failing gate'
        $result.Output | Should -Not -Match 'What this gate checks: Repo checks text'
    }

    It 'prints the checks text under each gate with -List' -Tag '#47' {
        $root = New-StandardRepo

        $result = Invoke-Runner -Root $root -Extra @('-List')

        $result.Output | Should -Match 'checks: It checks the fixture\.'
    }

    Context 'a local run checks only the gates the change touches (#48)' {
        BeforeAll {
            function New-ScopedRepo {
                $root = New-StandardRepo -RepoGates '[ { "name": "repo gate", "script": "tools/Check-Repo.ps1", "mode": "Blocking", "inputs": [ "**/*.md" ] } ]'
                New-Item -ItemType Directory -Path (Join-Path $root 'src') -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $root 'src' 'app.cs') -Value 'class A {}'
                Set-Content -LiteralPath (Join-Path $root 'README.md') -Value '# Readme'
                git -C $root init --quiet -b main
                git -C $root config user.email probe@example.invalid
                git -C $root config user.name probe
                git -C $root add -A
                git -C $root commit --quiet -m base --no-verify
                git -C $root update-ref refs/remotes/origin/main HEAD
                return $root
            }
        }

        It 'does not run a gate whose inputs the change does not touch, and shows it as NOT TOUCHED' -Tag '#48' {
            $root = New-ScopedRepo
            Add-Content -LiteralPath (Join-Path $root 'src' 'app.cs') -Value '// more'

            $result = Invoke-Runner -Root $root

            $result.Code | Should -Be 0 -Because $result.Output
            $result.Output | Should -Not -Match 'ran Check-Repo'
            $result.Output | Should -Match 'repo gate\s+Blocking\s+NOT TOUCHED'
            $result.Output | Should -Match 'ran Check-Core\.ps1' -Because 'a gate without inputs always runs'
        }

        It 'runs the gate when the change touches one of its inputs' -Tag '#48' {
            $root = New-ScopedRepo
            Add-Content -LiteralPath (Join-Path $root 'README.md') -Value 'more'

            $result = Invoke-Runner -Root $root

            $result.Output | Should -Match 'ran Check-Repo\.ps1'
        }

        It 'runs every gate when the change <Case>' -Tag '#48' -ForEach @(
            @{ Case = 'deletes a file'; Act = { param($r) Remove-Item -LiteralPath (Join-Path $r 'src' 'app.cs') } }
            @{ Case = 'touches aisdlc.json'; Act = { param($r) Add-Content -LiteralPath (Join-Path $r 'aisdlc.json') -Value ' ' } }
        ) {
            $root = New-ScopedRepo
            & $Act $root

            $result = Invoke-Runner -Root $root

            $result.Output | Should -Match 'ran Check-Repo\.ps1'
            $result.Output | Should -Match 'Every gate runs, because'
        }

        It 'runs every gate when the change cannot be read' -Tag '#48' {
            $root = New-ScopedRepo
            git -C $root update-ref -d refs/remotes/origin/main

            $result = Invoke-Runner -Root $root

            $result.Output | Should -Match 'ran Check-Repo\.ps1'
            $result.Output | Should -Match 'the change cannot be read'
        }

        It 'runs every gate with -All and in GitHub Actions' -Tag '#48' {
            $root = New-ScopedRepo
            Add-Content -LiteralPath (Join-Path $root 'src' 'app.cs') -Value '// more'

            $all = Invoke-Runner -Root $root -Extra @('-All')
            $saved = $env:GITHUB_ACTIONS; $savedSummary = $env:GITHUB_STEP_SUMMARY
            $env:GITHUB_ACTIONS = 'true'; $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive 'scoped-summary.md'
            try { $ci = Invoke-Runner -Root $root }
            finally { $env:GITHUB_ACTIONS = $saved; $env:GITHUB_STEP_SUMMARY = $savedSummary }

            $all.Output | Should -Match 'ran Check-Repo\.ps1'
            $ci.Output | Should -Match 'ran Check-Repo\.ps1'
        }

        It 'fails a gate whose inputs is not a list of path globs' -Tag '#48' {
            $root = New-StandardRepo -RepoGates '[ { "name": "repo gate", "script": "tools/Check-Repo.ps1", "mode": "Blocking", "inputs": "**/*.md" } ]'

            $result = Invoke-Runner -Root $root

            $result.Code | Should -Be 1
            $result.Output | Should -Match 'it must be a list of one or more path globs'
        }
    }

    Context 'gate modes and gateModes (#49)' {
        It 'does not run an Off gate, shows it as OFF, and does not fail on its missing script' -Tag '#49' {
            $root = New-StandardRepo -CoreMode 'off'
            Remove-Item -LiteralPath (Join-Path $root '.claude/skills/ai-sdlc-gates/scripts/Check-Core.ps1')

            $result = Invoke-Runner -Root $root

            $result.Code | Should -Be 0 -Because $result.Output
            $result.Output | Should -Match 'core gate\s+Off\s+OFF\s+package'
            $result.Output | Should -Match '1 gate\(s\) are Off'
        }

        It 'lets gateModes in aisdlc.json set the mode of a shared gate, in any case, with aisdlc.json as the source' -Tag '#49' {
            $root = New-StandardRepo -CoreScript $script:FailGate
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value '{ "gateModes": { "CORE GATE": "advisory" } }'

            $result = Invoke-Runner -Root $root

            $result.Code | Should -Be 0 -Because $result.Output
            $result.Output | Should -Match 'core gate\s+Advisory\s+ADVISORY\s+aisdlc\.json'
            $result.Output | Should -Match "AI-SDLC: the gate 'core gate' has the package mode Blocking, but gateModes in aisdlc\.json sets it to Advisory"
        }

        It 'prints the mode source on a mode from: line with -List' -Tag '#49' {
            $root = New-StandardRepo
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value '{ "gateModes": { "core gate": "Off" } }'

            $result = Invoke-Runner -Root $root -Extra @('-List')

            $result.Output | Should -Match 'mode from: aisdlc\.json \(gateModes\), package mode Blocking'
            $result.Output | Should -Match 'runs in: OFF'
        }

        It 'fails the run on a gateModes name that no shared gate has, and uses no key of gateModes, also with -BlockingOnly' -Tag '#49' {
            $root = New-StandardRepo
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value '{ "gateModes": { "core gate": "Off", "no such gate": "Off" } }'

            $result = Invoke-Runner -Root $root -Extra @('-BlockingOnly')

            $result.Code | Should -Be 1 -Because $result.Output
            $result.Output | Should -Match "Invalid gateModes in aisdlc\.json: gateModes sets 'no such gate' to 'Off', but no shared gate that runs has this name"
            $result.Output | Should -Match 'ran Check-Core\.ps1'
        }

        It 'fails a gate whose mode is not allowed, and does not run it' -Tag '#49' {
            $root = New-StandardRepo -CoreMode 'Silent'

            $result = Invoke-Runner -Root $root

            $result.Code | Should -Be 1 -Because $result.Output
            $result.Output | Should -Match "the mode is 'Silent', and the allowed values are Blocking, Advisory and Off"
            $result.Output | Should -Not -Match 'ran Check-Core'
        }

        It 'runs an Off gate in a push whose commits do not hold the Off setting' -Tag '#49' {
            $root = New-StandardRepo
            git -C $root init --quiet -b main
            git -C $root config user.email probe@example.invalid
            git -C $root config user.name probe
            git -C $root add -A
            git -C $root commit --quiet -m base --no-verify
            $pushed = (git -C $root rev-parse HEAD).Trim()
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value '{ "gateModes": { "core gate": "Off" } }'

            $saved = $env:AISDLC_PUSHED_COMMITS
            $env:AISDLC_PUSHED_COMMITS = $pushed
            try { $result = Invoke-Runner -Root $root -Extra @('-BlockingOnly') }
            finally { $env:AISDLC_PUSHED_COMMITS = $saved }

            $result.Output | Should -Match 'ran Check-Core\.ps1'
            $result.Output | Should -Match 'is Off in the working tree, but not in every pushed commit'
        }
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

    It 'keeps exit 2 of a Blocking gate a warning in a local run, and the run exits 0' -Tag '#46' {
        $root = New-StandardRepo -CoreScript 'param([string]$RepoRoot, [switch]$Strict) Write-Host "No token, so NOTHING WAS CHECKED."; exit 2'

        $result = Invoke-Runner -Root $root

        $result.Code | Should -Be 0 -Because $result.Output
        $result.Output | Should -Match 'core gate\s+Blocking\s+UNVERIFIED'
        $result.Output | Should -Match 'Run locally they are warnings'
    }

    It 'shows a gate that exits 3 as N/A, and never fails the run on it' -Tag '#46' {
        $root = New-StandardRepo -CoreScript 'param([string]$RepoRoot, [switch]$Strict) Write-Host "No pull request here, so there is nothing to check."; exit 3'

        $result = Invoke-Runner -Root $root

        $result.Code | Should -Be 0 -Because $result.Output
        $result.Output | Should -Match 'core gate\s+Blocking\s+N/A'
        $result.Output | Should -Match '1 gate\(s\) not applicable here \(exit 3\)'
    }

    It 'counts an exit code other than 0, 1, 2 or 3 as a finding' -Tag '#46' {
        $root = New-StandardRepo -CoreScript 'param([string]$RepoRoot, [switch]$Strict) exit 5'

        $result = Invoke-Runner -Root $root

        $result.Code | Should -Be 1
        $result.Output | Should -Match 'core gate\s+Blocking\s+FAIL'
    }

    It 'reports a crashed Advisory gate as a warning, and the run exits 0' -Tag '#46' {
        $root = New-StandardRepo -CoreMode 'Advisory' -CoreScript 'param([string]$RepoRoot, [switch]$Strict) throw "gate bug"'

        $result = Invoke-Runner -Root $root

        $result.Code | Should -Be 0 -Because $result.Output
        $result.Output | Should -Match 'CRASHED'
        $result.Output | Should -Match '1 advisory gate\(s\) stopped before they could report'
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

        It 'raises an error and fails the job for a Blocking gate that could not check' -Tag '#46' {
            $root = New-StandardRepo -CoreScript 'param([string]$RepoRoot, [switch]$Strict) Write-Host "No token, so NOTHING WAS CHECKED."; exit 2'

            $result = Invoke-Runner -Root $root

            $result.Code | Should -Be 1 -Because $result.Output
            $result.Output | Should -Match '::error title=core gate::.*COULD NOT BE CHECKED'
            $result.Output | Should -Match '1 of them could not check \(exit 2\)'
        }

        It 'raises a warning and passes the job for an Advisory gate that could not check' -Tag '#46' {
            $root = New-StandardRepo -CoreMode 'Advisory' -CoreScript 'param([string]$RepoRoot, [switch]$Strict) Write-Host "No token."; exit 2'

            $result = Invoke-Runner -Root $root

            $result.Code | Should -Be 0 -Because $result.Output
            $result.Output | Should -Match '::warning title=core gate::.*COULD NOT BE CHECKED'
        }

        It 'writes no annotation for a gate that exits 3, and lists it as N/A in the job summary' -Tag '#46' {
            $root = New-StandardRepo -CoreScript 'param([string]$RepoRoot, [switch]$Strict) Write-Host "nothing to check"; exit 3'

            $result = Invoke-Runner -Root $root

            $result.Code | Should -Be 0 -Because $result.Output
            $result.Output | Should -Not -Match '::(error|warning)'
            Get-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Raw | Should -Match '\| core gate \| Blocking \| N/A \|'
        }

        It 'fails the job for a Blocking gate whose script is missing' -Tag '#46' {
            $root = New-StandardRepo
            Remove-Item -LiteralPath (Join-Path $root '.claude/skills/ai-sdlc-gates/scripts/Check-Core.ps1')

            $result = Invoke-Runner -Root $root

            $result.Code | Should -Be 1 -Because $result.Output
            $result.Output | Should -Match '::error title=core gate::.*COULD NOT BE CHECKED'
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
