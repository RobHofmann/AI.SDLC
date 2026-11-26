#requires -Version 7.4

Describe 'Check-StoryBackEdges' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Check-StoryBackEdges.ps1'

        function New-TestRepo([hashtable]$Adrs) {
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $adrDir = Join-Path $root 'docs/adrs'
            New-Item -ItemType Directory -Path $adrDir -Force | Out-Null
            $config = [ordered]@{ paths = [ordered]@{ adrFolder = 'docs/adrs' }; tracker = [ordered]@{ repository = 'contoso/portal' } }
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value ($config | ConvertTo-Json -Depth 5) -Encoding utf8
            foreach ($name in $Adrs.Keys) { Set-Content -LiteralPath (Join-Path $adrDir $name) -Value $Adrs[$name] }
            return $root
        }

        # A temp repo with one graph-anchored ADR (issue #9999), one ADR with no story (ignored) and the template (excluded).
        $script:RepoRoot = New-TestRepo @{
            '0099-test-decision.md' = "---`nstory: `"#9999`"`nphase: governance`nstep: write-adr`n---`n`n# ADR 0099: test"
            '0098-no-story.md'      = "# ADR 0098: no frontmatter, must be ignored"
            '0000-template.md'      = "---`nstory: `"#1234`"`n---`n# template, must be excluded"
        }

        function Invoke-Gate {
            param([hashtable]$P = @{})
            if (-not $P.ContainsKey('RepoRoot')) { $P['RepoRoot'] = $script:RepoRoot }
            # Pin CI and the token so the skip path is not hit unless a case overrides it; gh is never called.
            if (-not $P.ContainsKey('InCi')) { $P['InCi'] = $true }
            if (-not $P.ContainsKey('GhToken')) { $P['GhToken'] = 'token' }
            if (-not $P.ContainsKey('GhCommand')) { $P['GhCommand'] = 'gh-absent-for-test' }
            $out = & $script:ScriptUnderTest @P *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }
    }

    It 'flags an issue whose body does not reference its ADR (exit 1)' {
        $r = Invoke-Gate @{ BodiesForTest = @{ '#9999' = 'no backlink here' } }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'does not reference ADR 0099'
    }

    It 'passes when the body references the ADR by path (exit 0)' {
        $r = Invoke-Gate @{ BodiesForTest = @{ '#9999' = 'see docs/adrs/0099 for the decision' } }
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'OK'
    }

    It 'passes when the body references the ADR by slug (exit 0)' {
        $r = Invoke-Gate @{ BodiesForTest = @{ '#9999' = 'recorded in 0099-test-decision.md' } }
        $r.ExitCode | Should -Be 0
    }

    It 'passes when the body references the ADR as "ADR 0099" (exit 0)' {
        $r = Invoke-Gate @{ BodiesForTest = @{ '#9999' = 'governed by ADR 0099 of the corpus' } }
        $r.ExitCode | Should -Be 0
    }

    It 'reads an unquoted number and a key of the tracker repository as the same issue' {
        $repo = New-TestRepo @{
            '0101-a.md' = "---`nstory: 9999`n---`n# ADR 0101"
            '0102-b.md' = "---`nstory: contoso/portal#9999`n---`n# ADR 0102"
        }
        $r = Invoke-Gate @{ RepoRoot = $repo; BodiesForTest = @{ '#9999' = 'ADR 0101 and ADR 0102' } }
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match '1 issue body'
    }

    It 'reports an ADR whose story value is lost to the YAML comment trap' {
        $repo = New-TestRepo @{ '0103-trap.md' = "---`nstory: #9999`n---`n# ADR 0103" }
        $r = Invoke-Gate @{ RepoRoot = $repo; InCi = $false; GhToken = '' }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match "0103-trap : front matter 'story:' has no value"
        $r.Output | Should -Match 'FIX:'
    }

    It 'reports an ADR whose story value is not a story key, as the artifact graph gate does' {
        $repo = New-TestRepo @{ '0104-bad.md' = "---`nstory: `"PR#9999`"`n---`n# ADR 0104" }
        $r = Invoke-Gate @{ RepoRoot = $repo; InCi = $false; GhToken = '' }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match "0104-bad \('PR#9999'\) : front matter 'story:' is not a story key"
    }

    It 'reports could-not-check (exit 2) when no issue body can be read, rather than calling it a finding' {
        $r = Invoke-Gate @{ BodiesForTest = @{ '#1' = 'unrelated' } }
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'could not be checked'
        $r.Output | Should -Match 'GH_TOKEN'
        $r.Output | Should -Not -Match 'advisory finding'
    }

    It 'is a safe no-op outside CI and with no test seam (exit 0)' {
        $r = Invoke-Gate @{ InCi = $false; GhToken = '' }
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'skipping'
    }

    It 'is a safe no-op in CI when gh is missing (exit 0)' {
        $r = Invoke-Gate @{}
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'skipping'
    }
}
