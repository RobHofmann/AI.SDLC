#requires -Version 7.4

Describe 'Every gate is named for what passes, carries one clause, and says what it checks and how to fix it' {
    BeforeDiscovery {
        Import-Module (Join-Path $PSScriptRoot 'GateContractTestHarness.psm1') -Force
        $sourceRoot = Find-ContractSourceRoot -From $PSScriptRoot
        $listed = [System.Collections.Generic.List[object]]::new()
        if ($sourceRoot) {
            $manifests = @(Get-ChildItem -Path (Join-Path $sourceRoot 'core' '.apm' 'skills' '*' 'gates.json'), (Join-Path $sourceRoot 'packs' '*' '.apm' 'skills' '*' 'gates.json') -File | Sort-Object FullName)
            foreach ($manifest in $manifests) {
                $data = Get-Content -LiteralPath $manifest.FullName -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
                foreach ($entry in @($data.gates)) { if ($entry) { $listed.Add(@{ Name = [string]$entry.name; File = [IO.Path]::GetRelativePath($sourceRoot, $manifest.FullName).Replace('\', '/') }) } }
            }
            $config = Get-Content -LiteralPath (Join-Path $sourceRoot 'aisdlc.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
            foreach ($entry in @($config.repoGates)) { if ($entry) { $listed.Add(@{ Name = [string]$entry.name; File = 'aisdlc.json repoGates' }) } }
        }
        $gates = @($listed)
        $skip = -not $sourceRoot
    }

    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'GateContractTestHarness.psm1') -Force
        $script:SourceRoot = Find-ContractSourceRoot -From $PSScriptRoot

        # The one value that is not a clause ID: a rule of the framework itself that no clause holds,
        # such as the sync manifest or a pack convention with no clause page yet.
        $script:FrameworkClause = 'AI-SDLC'

        function Get-AllowedClause {
            param([string]$SourceRoot)
            $allowed = [System.Collections.Generic.List[string]]::new()
            $allowed.Add($script:FrameworkClause)
            $constitution = Join-Path $SourceRoot 'core' '.apm' 'skills' 'ai-sdlc-handbook' 'references' 'constitution.md'
            foreach ($line in Get-Content -LiteralPath $constitution -Encoding utf8) {
                if ($line -match '^## (C\d{2}):') { $allowed.Add($Matches[1]) }
            }
            foreach ($page in @(Get-ChildItem -Path (Join-Path $SourceRoot 'packs' '*' '.apm' 'skills' '*' 'references' 'clauses.md') -File -ErrorAction SilentlyContinue)) {
                foreach ($line in Get-Content -LiteralPath $page.FullName -Encoding utf8) {
                    if ($line -match '^#{2,3}\s+([A-Z]+-\d{2})\b') { $allowed.Add($Matches[1]) }
                }
            }
            return @($allowed | Select-Object -Unique)
        }

        function Get-GateNameProblem {
            param([string]$Name, [string]$Clause, [string[]]$AllowedClause, [string[]]$AllNames)
            $problems = [System.Collections.Generic.List[string]]::new()
            if ([string]::IsNullOrWhiteSpace($Name)) { $problems.Add('the name is empty'); return @($problems) }
            if ($Name -match '^(?:C\d{2}|[A-Z]+-\d{2})\b') { $problems.Add('the name starts with a clause') }
            if ($Name -match '^(?:AI[.-]SDLC|House-style|PR hygiene)\b') { $problems.Add('the name starts with an owner prefix') }
            if ($Name -match '^[^:]{1,40}:\s') { $problems.Add('the name starts with a prefix and a colon') }
            if ($Name -match '[\(\)\[\]]') { $problems.Add('the name holds a bracketed note') }
            if (@($AllNames | Where-Object { $_ -ceq $Name }).Count -gt 1) { $problems.Add('the name is used by more than one gate') }
            if ([string]::IsNullOrWhiteSpace($Clause)) { $problems.Add('the entry has no clause') }
            elseif ($Clause -cnotin $AllowedClause) { $problems.Add("the clause '$Clause' is not a constitution clause, a pack clause or AI-SDLC") }
            return @($problems)
        }

        function Split-GateSentence {
            param([string]$Text)
            return @($Text -split '(?<=[.!?])\s+' | Where-Object { $_.Trim() })
        }

        function Get-ChecksTextProblem {
            param([string]$Checks)
            if ([string]::IsNullOrWhiteSpace($Checks)) { return @('checks is missing or empty') }
            $problems = [System.Collections.Generic.List[string]]::new()
            $sentences = Split-GateSentence -Text $Checks
            if ($sentences.Count -lt 2 -or $sentences.Count -gt 4) { $problems.Add("checks holds $($sentences.Count) sentences, and 2 to 4 are allowed") }
            foreach ($sentence in @($sentences | Where-Object { @($_ -split '\s+').Count -gt 25 })) { $problems.Add("a checks sentence is over 25 words: $sentence") }
            if ($Checks.Contains([string][char]0x2014)) { $problems.Add('checks holds an em-dash') }
            foreach ($code in @(2, 3 | Where-Object { $Checks -notmatch ('(?i)\bexits? ' + $_ + '\b') })) { $problems.Add("checks does not say what exit $code means") }
            return @($problems)
        }

        function Get-FixTextProblem {
            param([string]$Fix)
            if ([string]::IsNullOrWhiteSpace($Fix)) { return @('fix is missing or empty') }
            $problems = [System.Collections.Generic.List[string]]::new()
            $sentences = Split-GateSentence -Text $Fix
            if ($sentences.Count -ne 1) { $problems.Add("fix holds $($sentences.Count) sentences, and 1 is allowed") }
            if (@($Fix -split '\s+').Count -gt 25) { $problems.Add('fix is over 25 words') }
            if ($Fix.Contains([string][char]0x2014)) { $problems.Add('fix holds an em-dash') }
            return @($problems)
        }

        function Get-GateEntry {
            param([string]$SourceRoot)
            $entries = [System.Collections.Generic.List[object]]::new()
            $manifests = @(Get-ChildItem -Path (Join-Path $SourceRoot 'core' '.apm' 'skills' '*' 'gates.json'), (Join-Path $SourceRoot 'packs' '*' '.apm' 'skills' '*' 'gates.json') -File | Sort-Object FullName)
            foreach ($manifest in $manifests) {
                $data = Get-Content -LiteralPath $manifest.FullName -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
                foreach ($entry in @($data.gates)) { if ($entry) { $entries.Add([pscustomobject]@{ Name = [string]$entry.name; Clause = [string]$entry.clause; Checks = [string]$entry.checks; Fix = [string]$entry.fix; Mode = [string]$entry.mode; Script = [string]$entry.script; File = $manifest.FullName }) } }
            }
            $config = Get-Content -LiteralPath (Join-Path $SourceRoot 'aisdlc.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
            foreach ($entry in @($config.repoGates)) { if ($entry) { $entries.Add([pscustomobject]@{ Name = [string]$entry.name; Clause = [string]$entry.clause; Checks = [string]$entry.checks; Fix = [string]$entry.fix; Mode = [string]$entry.mode; Script = [string]$entry.script; File = 'aisdlc.json' }) } }
            return @($entries)
        }

        $script:Allowed = if ($script:SourceRoot) { Get-AllowedClause -SourceRoot $script:SourceRoot } else { @() }
        $script:Entries = if ($script:SourceRoot) { Get-GateEntry -SourceRoot $script:SourceRoot } else { @() }
        $script:AllNames = @($script:Entries | ForEach-Object Name)
    }

    Context 'the rule itself' {
        It 'reads the constitution clauses, the pack clauses and AI-SDLC as the allowed values' -Tag '#47' -Skip:$skip {
            $script:Allowed | Should -Contain 'C01'
            $script:Allowed | Should -Contain 'C12'
            $script:Allowed | Should -Contain 'DOTNET-01'
            $script:Allowed | Should -Contain 'AI-SDLC'
            $script:Allowed | Should -Not -Contain 'house-style'
        }

        It 'flags <Case>' -Tag '#47' -ForEach @(
            @{ Case = 'a clause at the start'; Name = 'C06 no em-dash characters'; Clause = 'C06'; Expect = 'starts with a clause'; Names = @() }
            @{ Case = 'an owner prefix'; Name = 'AI-SDLC skill hygiene'; Clause = 'AI-SDLC'; Expect = 'owner prefix'; Names = @() }
            @{ Case = 'a prefix with a colon'; Name = 'Change completeness: tests moved'; Clause = 'AI-SDLC'; Expect = 'prefix and a colon'; Names = @() }
            @{ Case = 'a bracketed note'; Name = 'The pull request names its story (CI only)'; Clause = 'AI-SDLC'; Expect = 'bracketed note'; Names = @() }
            @{ Case = 'a clause that does not exist'; Name = 'Docs read well'; Clause = 'house-style'; Expect = "clause 'house-style'"; Names = @() }
            @{ Case = 'no clause'; Name = 'Docs read well'; Clause = ''; Expect = 'no clause'; Names = @() }
            @{ Case = 'a name used twice'; Name = 'Docs hold no em-dash characters'; Clause = 'C06'; Expect = 'more than one gate'; Names = @('Docs hold no em-dash characters', 'Docs hold no em-dash characters') }
        ) {
            $problems = @(Get-GateNameProblem -Name $Name -Clause $Clause -AllowedClause @('C06', 'AI-SDLC') -AllNames $Names)

            ($problems -join '; ') | Should -Match ([regex]::Escape($Expect))
        }

        It 'accepts a short statement of what passes, with an allowed clause' -Tag '#47' {
            @(Get-GateNameProblem -Name 'Docs hold no em-dash characters' -Clause 'C06' -AllowedClause @('C06') -AllNames @('Docs hold no em-dash characters')) | Should -BeNullOrEmpty
        }
    }

    Context 'the checks and fix texts' {
        It 'flags <Case>' -Tag '#47' -ForEach @(
            @{ Case = 'one sentence of checks'; Checks = 'It reads the docs and exit 2 and exit 3 mean nothing here.'; Fix = 'Fix it.'; Expect = 'checks holds 1 sentences' }
            @{ Case = 'checks that do not name exit 3'; Checks = 'It reads the docs. Exit 2 means no docs.'; Fix = 'Fix it.'; Expect = 'exit 3' }
            @{ Case = 'two sentences of fix'; Checks = 'It reads the docs. Exit 2 means no docs, and exit 3 means none.'; Fix = 'Fix it. Then push.'; Expect = 'fix holds 2 sentences' }
            @{ Case = 'no fix'; Checks = 'It reads the docs. Exit 2 means no docs, and exit 3 means none.'; Fix = ''; Expect = 'fix is missing' }
        ) {
            $problems = @(@(Get-ChecksTextProblem -Checks $Checks) + @(Get-FixTextProblem -Fix $Fix))

            ($problems -join '; ') | Should -Match ([regex]::Escape($Expect))
        }

        It 'accepts 2 to 4 short sentences of checks and one sentence of fix' -Tag '#47' {
            @(Get-ChecksTextProblem -Checks 'It reads the docs. Exit 2 means no doc layer exists, and exit 3 means it found no page.') | Should -BeNullOrEmpty
            @(Get-FixTextProblem -Fix 'Replace each em-dash with a comma.') | Should -BeNullOrEmpty
        }

        It '<Name> (<File>) has a checks text and a fix text of the right shape' -Tag '#47' -Skip:$skip -ForEach $gates {
            $entry = @($script:Entries | Where-Object { $_.Name -ceq $Name })[0]
            $problems = @(@(Get-ChecksTextProblem -Checks $entry.Checks) + @(Get-FixTextProblem -Fix $entry.Fix))

            $problems | Should -BeNullOrEmpty -Because ($problems -join '; ')
        }
    }

    Context 'every gate in every gates.json and in repoGates' {
        It 'finds the gates of the core, the packs and the repository' -Tag '#47' -Skip:$skip {
            $script:Entries.Count | Should -BeGreaterThan 30
            @($script:Entries | Where-Object File -EQ 'aisdlc.json').Count | Should -BeGreaterThan 0
        }

        It '<Name> (<File>) holds no clause, owner prefix, bracketed note or duplicate, and has an allowed clause' -Tag '#47' -Skip:$skip -ForEach $gates {
            $entries = @($script:Entries | Where-Object { $_.Name -ceq $Name })
            $problems = @($entries | ForEach-Object { Get-GateNameProblem -Name $_.Name -Clause $_.Clause -AllowedClause $script:Allowed -AllNames $script:AllNames })

            $problems | Should -BeNullOrEmpty -Because ($problems -join '; ')
        }
    }
}
