#requires -Version 7.4

BeforeAll { $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm' }

Describe 'Check-StoryBackEdges' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $script:ScriptFolder -ChildPath 'Check-StoryBackEdges.ps1'

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
            # The temp repos have no git history, so name the ADRs as the change; every line of a listed file counts as added.
            if (-not $P.ContainsKey('ChangedFiles')) { $P['ChangedFiles'] = @(Get-ChildItem -LiteralPath (Join-Path $P['RepoRoot'] 'docs/adrs') -Filter *.md | ForEach-Object { "docs/adrs/$($_.Name)" }) }
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
        $r.Output | Should -Match '(?m)^FIX: \S'
        $r.Output | Should -Not -Match 'advisory finding'
    }

    It 'is not applicable outside CI and with no test seam (exit 3)' -Tag '#46' {
        $r = Invoke-Gate @{ InCi = $false; GhToken = '' }
        $r.ExitCode | Should -Be 3
        $r.Output | Should -Match 'not applicable'
    }

    It 'is not applicable in CI when gh is missing (exit 3)' -Tag '#46' {
        $r = Invoke-Gate @{}
        $r.ExitCode | Should -Be 3
        $r.Output | Should -Match 'not applicable'
    }

    It 'is not applicable when no ADR is anchored to a story (exit 3)' -Tag '#46' {
        $repo = New-TestRepo @{ '0101-a.md' = "# ADR 0101" }
        $r = Invoke-Gate @{ RepoRoot = $repo; BodiesForTest = @{ '#9999' = 'unrelated' } }
        $r.ExitCode | Should -Be 3
        $r.Output | Should -Match 'not applicable'
    }

    Context 'it reads only an ADR whose story line the change adds or changes' {
        BeforeAll {
            function New-GitAdrRepo {
                $repo = New-TestRepo @{
                    '0001-old.md' = "---`nstory: `"#9999`"`nphase: governance`n---`n`n# ADR 0001`n"
                }
                git -C $repo init --quiet -b main
                git -C $repo config user.email probe@example.invalid
                git -C $repo config user.name probe
                git -C $repo config core.autocrlf false
                git -C $repo add -A
                git -C $repo commit --quiet -m base --no-verify
                return $repo
            }

            function Save-AdrChange([string]$Repo) {
                git -C $Repo add -A
                git -C $Repo commit --quiet -m change --no-verify
            }

            function Invoke-GitGate([string]$Repo) {
                $out = & $script:ScriptUnderTest -RepoRoot $Repo -InCi $true -GhToken 'token' -GhCommand 'gh-absent-for-test' -BodiesForTest @{ '#9999' = 'no backlink here'; '#9998' = 'no backlink here' } *>&1 | Out-String
                return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
            }
        }

        AfterEach { $env:CHANGED_FILES = $null }

        It 'skips an ADR whose story line is older than the change, although the ADR file changed' -Tag '#80' {
            $repo = New-GitAdrRepo
            git -C $repo update-ref refs/remotes/origin/main HEAD
            Add-Content -LiteralPath (Join-Path $repo 'docs/adrs/0001-old.md') -Value 'A new sentence in the body.'
            Save-AdrChange $repo

            $r = Invoke-GitGate $repo

            $r.ExitCode | Should -Be 3
            $r.Output | Should -Match 'not applicable'
            $r.Output | Should -Not -Match 'does not reference ADR'
        }

        It 'reads an ADR whose story line the change adds' -Tag '#80' {
            $repo = New-GitAdrRepo
            git -C $repo update-ref refs/remotes/origin/main HEAD
            Set-Content -LiteralPath (Join-Path $repo 'docs/adrs/0002-new.md') -Value "---`nstory: `"#9998`"`n---`n`n# ADR 0002`n"
            Save-AdrChange $repo

            $r = Invoke-GitGate $repo

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'does not reference ADR 0002-new'
            $r.Output | Should -Not -Match 'ADR 0001-old'
        }

        It 'reads an ADR whose story line the change edits' -Tag '#80' {
            $repo = New-GitAdrRepo
            git -C $repo update-ref refs/remotes/origin/main HEAD
            $path = Join-Path $repo 'docs/adrs/0001-old.md'
            Set-Content -LiteralPath $path -Value ((Get-Content -LiteralPath $path -Raw).Replace('#9999', '#9998'))
            Save-AdrChange $repo

            $r = Invoke-GitGate $repo

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'does not reference ADR 0001-old'
        }

        It 'exits 2 with a FIX line when CHANGED_FILES is set and there is no merge base' -Tag '#80' {
            $repo = New-GitAdrRepo
            $env:CHANGED_FILES = 'docs/adrs/0001-old.md'

            $r = Invoke-GitGate $repo

            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match '(?m)^FIX: \S'
            $r.Output | Should -Not -Match 'does not reference ADR'
        }

        It 'is not applicable in a local run with no merge base, and does not read every ADR' -Tag '#80' {
            $repo = New-GitAdrRepo

            $r = Invoke-GitGate $repo

            $r.ExitCode | Should -Be 3
            $r.Output | Should -Not -Match 'does not reference ADR'
        }
    }
}