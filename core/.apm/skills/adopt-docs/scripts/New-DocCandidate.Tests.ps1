#requires -Version 7.4

Describe 'New-DocCandidate' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'New-DocCandidate.ps1'
        Import-Module (Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts' 'DocToolTestHarness.psm1') -Force

        function New-CandidateRepo {
            param([hashtable]$Files = @{})
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('ndc-' + [guid]::NewGuid().ToString('n'))
            $all = @{
                'apm.yml'                                   = "dependencies:`n  apm:`n    - ../AI.SDLC/packs/bicep"
                'aisdlc.json'                               = '{ "paths": { "docsRoots": ["docs", "docs-functional"], "technicalDocs": "docs", "functionalDocs": "docs-functional", "bicepRoot": "building-blocks" } }'
                'docs/index.md'                             = "# Docs`n"
                'docs/networking.md'                        = "# Networking`n"
                'docs-functional/index.md'                  = "# Functional`n"
                'docs/adrs/0001-x.md'                       = "# 0001 X`n"
                'building-blocks/vwan-infra/main.bicep'     = "param x string`n"
                'tools/helper/Do-Thing.ps1'                 = "<#`n.SYNOPSIS`n    Does the thing.`n#>`n"
                '.claude/skills/bicep-x/gates.json'         = '{ "package": "bicep", "gates": [], "docUnits": [ { "glob": "{bicepRoot}/*", "kind": "building block", "folder": "building-blocks" } ], "docFacts": "scripts/Get-Facts.ps1" }'
                '.claude/skills/bicep-x/scripts/Get-Facts.ps1' = "param([string]`$Unit, [string]`$RepoRoot)`n@('UNIT: ' + `$Unit, '  deploys Microsoft.Network/virtualWans@2023-04-01', '  param hubName: string, required')"
            }
            foreach ($k in $Files.Keys) { $all[$k] = $Files[$k] }
            foreach ($rel in $all.Keys) {
                $full = Join-Path $root $rel
                New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
                Set-Content -LiteralPath $full -Value $all[$rel] -Encoding utf8
            }
            return (Resolve-Path $root).Path
        }

        function Invoke-Candidate {
            param([hashtable]$ScriptArgs)
            $out = & $script:ScriptUnderTest @ScriptArgs *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }
    }

    AfterAll {
        Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'ndc-*' -Directory -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'what it refuses before it reads a fact' {
        It 'refuses a page that exists, and names the tool that adds to it' {
            $root = New-CandidateRepo

            $r = Invoke-Candidate -ScriptArgs @{ Unit = 'building-blocks/vwan-infra'; Page = 'docs/networking.md'; RepoRoot = $root; DryRun = $true }

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'exists\. Add to it with write-docs'
        }

        It 'refuses a page in the decision record folder' {
            $root = New-CandidateRepo

            $r = Invoke-Candidate -ScriptArgs @{ Unit = 'building-blocks/vwan-infra'; Page = 'docs/adrs/0002-y.md'; RepoRoot = $root; DryRun = $true }

            $r.Output | Should -Match 'decision record folder'
        }

        It 'refuses a page outside the layer it drafts for' {
            $root = New-CandidateRepo

            $r = Invoke-Candidate -ScriptArgs @{ Unit = 'building-blocks/vwan-infra'; Page = 'docs-functional/x.md'; RepoRoot = $root; DryRun = $true }

            $r.Output | Should -Match 'not in the technical layer docs/'
        }

        It 'refuses a unit outside the repository' {
            $root = New-CandidateRepo

            $r = Invoke-Candidate -ScriptArgs @{ Unit = '../elsewhere'; RepoRoot = $root; DryRun = $true }

            $r.Output | Should -Match 'resolves outside the repository'
        }

        It 'refuses a functional page with no page path or no title' {
            $root = New-CandidateRepo

            (Invoke-Candidate -ScriptArgs @{ Unit = 'building-blocks/vwan-infra'; Layer = 'Functional'; RepoRoot = $root; DryRun = $true }).Output | Should -Match 'needs -Page'
            (Invoke-Candidate -ScriptArgs @{ Unit = 'building-blocks/vwan-infra'; Layer = 'Functional'; Page = 'docs-functional/net.md'; RepoRoot = $root; DryRun = $true }).Output | Should -Match 'needs -Title'
        }
    }

    Context 'the facts' {
        It 'takes the facts from the pack that names the unit, and writes nothing on a dry run' {
            $root = New-CandidateRepo

            $r = Invoke-Candidate -ScriptArgs @{ Unit = 'building-blocks/vwan-infra'; RepoRoot = $root; DryRun = $true }

            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'Facts for building-blocks/vwan-infra from Get-Facts.ps1'
            $r.Output | Should -Match 'deploys Microsoft.Network/virtualWans@2023-04-01'
            $r.Output | Should -Match 'Page          : docs/building-blocks/vwan-infra.md'
            Test-Path (Join-Path $root 'doc-candidates') | Should -BeFalse
        }

        It 'falls back to the folder facts for a unit no pack names' {
            $root = New-CandidateRepo

            $r = Invoke-Candidate -ScriptArgs @{ Unit = 'tools/helper'; RepoRoot = $root; DryRun = $true }

            $r.Output | Should -Match 'from Get-FolderFacts.ps1'
            $r.Output | Should -Match 'Do-Thing.ps1 - Does the thing\.'
        }
    }

    Context 'the facts file' {
        It 'writes one facts file per unit to doc-candidates, never the page, and calls no model' {
            $root = New-CandidateRepo

            $r = Invoke-Candidate -ScriptArgs @{ Unit = 'building-blocks/vwan-infra'; RepoRoot = $root }

            $r.ExitCode | Should -Be 0 -Because $r.Output
            $facts = Join-Path $root 'doc-candidates' 'building-blocks_vwan-infra.facts.md'
            Test-Path $facts | Should -BeTrue
            Test-Path (Join-Path $root 'docs/building-blocks/vwan-infra.md') | Should -BeFalse
            $r.Output | Should -Match 'never edits a page and never commits'
            $r.Output | Should -Match 'Test-DocCandidate\.ps1'
        }

        It 'names the page, the title, the layer, the units, the draft path and the check list' {
            $root = New-CandidateRepo

            Invoke-Candidate -ScriptArgs @{ Unit = 'building-blocks/vwan-infra'; RepoRoot = $root } | Out-Null
            $text = Get-Content -LiteralPath (Join-Path $root 'doc-candidates' 'building-blocks_vwan-infra.facts.md') -Raw

            $text | Should -Match '(?m)^- Page: docs/building-blocks/vwan-infra\.md$'
            $text | Should -Match '(?m)^- Title: vwan-infra$'
            $text | Should -Match '(?m)^- Layer: Technical$'
            $text | Should -Match '(?m)^- Units: building-blocks/vwan-infra$'
            $text | Should -Match '(?m)^- Draft: doc-candidates/docs_building-blocks_vwan-infra\.md$'
            $text | Should -Match 'deploys Microsoft\.Network/virtualWans@2023-04-01'
            $text | Should -Match '(?s)units:\s+- building-blocks/vwan-infra'
            $text | Should -Match '\[Networking\]\(\.\./networking\.md\)'
            $text | Should -Match '(?m)^## Check list'
            $text | Should -Match 'Test-DocCandidate\.ps1 -Draft doc-candidates/docs_building-blocks_vwan-infra\.md -FactsFile doc-candidates/building-blocks_vwan-infra\.facts\.md'
            $text.Contains([char]0x2014) | Should -BeFalse
        }

        It 'writes the functional rules and names the file after the page when it spans several units' {
            $root = New-CandidateRepo

            $r = Invoke-Candidate -ScriptArgs @{ Unit = 'building-blocks/vwan-infra,tools/helper'; Layer = 'Functional'; Page = 'docs-functional/networking.md'; Title = 'Networking for teams'; RepoRoot = $root }

            $r.ExitCode | Should -Be 0 -Because $r.Output
            $text = Get-Content -LiteralPath (Join-Path $root 'doc-candidates' 'docs-functional_networking.facts.md') -Raw
            $text | Should -Match 'FUNCTIONAL page'
            $text | Should -Match '(?m)^- Units: building-blocks/vwan-infra, tools/helper$'
            $text | Should -Not -Match '(?m)^units:'
        }
    }
}
