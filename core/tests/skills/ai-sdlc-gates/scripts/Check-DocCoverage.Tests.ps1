#requires -Version 7.4

Describe 'Check-DocCoverage' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'DocToolTestHarness.psm1') -Force
        Import-Module (Join-Path $PSScriptRoot 'DocCoverage.psm1') -Force
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Check-DocCoverage.ps1'

        function New-CoverageRepo {
            param([hashtable]$Files = @{}, [hashtable]$Docs, [switch]$NoFunctional)
            $all = @{
                'docs/index.md'                   = "# Docs`n"
                'docs/overview.md'                = "# Overview`n"
                'docs-functional/index.md'        = "# Functional`n"
                'docs-functional/glossary.md'     = "# Glossary`n"
                '.claude/skills/bicep-x/gates.json' = '{ "package": "bicep", "gates": [], "docUnits": [ { "glob": "{bicepRoot}/*", "kind": "building block", "folder": "building-blocks" } ] }'
            }
            if ($NoFunctional) { foreach ($k in @('docs-functional/index.md', 'docs-functional/glossary.md')) { $all.Remove($k) } }
            foreach ($k in $Files.Keys) { $all[$k] = $Files[$k] }
            $root = New-DocToolRepo -Files $all -Prefix 'doc-coverage' -NoConfig
            if (-not $script:Made) { $script:Made = [System.Collections.Generic.List[string]]::new() }
            $script:Made.Add($root)
            $config = [ordered]@{
                paths = [ordered]@{ docsRoots = @('docs', 'docs-functional'); technicalDocs = 'docs'; functionalDocs = $(if ($NoFunctional) { '' } else { 'docs-functional' }); bicepRoot = 'building-blocks' }
            }
            if ($Docs) { $config.docs = $Docs }
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value ($config | ConvertTo-Json -Depth 6) -Encoding utf8
            Set-AiSdlcTestPack -Root $root -Packs bicep
            return $root
        }

        function Invoke-Gate {
            param([string]$Root)
            $out = & $script:ScriptUnderTest -RepoRoot $Root *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }
    }

    AfterAll {
        foreach ($dir in @($script:Made)) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Context 'the units a pack names' {
        It 'fails on a building block with no page, and names the page to write' {
            $root = New-CoverageRepo -Files @{ 'building-blocks/vwan-infra/main.bicep' = "param x string`n" }

            $r = Invoke-Gate -Root $root

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'building block building-blocks/vwan-infra has no technical page; write docs/building-blocks/vwan-infra.md'
        }

        It 'passes when a page has the unit name as its file name' {
            $root = New-CoverageRepo -Files @{
                'building-blocks/vwan-infra/main.bicep' = "param x string`n"
                'docs/building-blocks/vwan-infra.md'    = "# Virtual WAN`n"
            }

            $r = Invoke-Gate -Root $root

            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match '1 unit\(s\) each have a technical page'
        }

        It 'passes when the H1 of a page is the unit name' {
            $root = New-CoverageRepo -Files @{
                'building-blocks/vwan-infra/main.bicep' = "param x string`n"
                'docs/networking.md'                    = "# vwan-infra`n"
            }

            (Invoke-Gate -Root $root).ExitCode | Should -Be 0
        }

        It 'passes when the front matter names the unit, the form for a page with another name' {
            $root = New-CoverageRepo -Files @{
                'building-blocks/vwan-infra/main.bicep' = "param x string`n"
                'building-blocks/dns-infra/main.bicep'  = "param x string`n"
                'docs/networking.md'                    = "---`nunits:`n  - building-blocks/vwan-infra`n  - building-blocks/dns-infra/`n---`n# Networking`n"
            }

            (Invoke-Gate -Root $root).ExitCode | Should -Be 0
        }

        It 'reads a unit list written inline in the front matter' {
            (Get-DocPageUnitClaim -Text "---`nunits: [a/b, 'c/d']`n---`n# X") | Should -Be @('a/b', 'c/d')
            (Get-DocPageUnitClaim -Text "---`nunit: a/b`n---`n# X") | Should -Be @('a/b')
        }

        It 'never counts a decision record as the page of a unit' {
            $root = New-CoverageRepo -Files @{
                'building-blocks/vwan-infra/main.bicep'     = "param x string`n"
                'docs/adrs/0001-vwan-infra.md'              = "# vwan-infra`n"
            }

            (Invoke-Gate -Root $root).ExitCode | Should -Be 1
        }

        It 'leaves out a unit the repository excludes by path' {
            $root = New-CoverageRepo -Files @{ 'building-blocks/scratch/main.bicep' = "param x string`n" } -Docs @{ units = @(); unitExclude = @('building-blocks/scratch') }

            (Invoke-Gate -Root $root).ExitCode | Should -Be 0
        }

        It 'skips a pack entry whose path token is empty, so a pack costs nothing where it has no units' {
            $root = New-CoverageRepo
            $config = Get-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Raw | ConvertFrom-Json -AsHashtable
            $config.paths.bicepRoot = ''
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value ($config | ConvertTo-Json -Depth 6)

            @(Get-DocUnit -RepoRoot $root).Count | Should -Be 0
        }
    }

    Context 'the units a repository names itself' {
        It 'replaces the pack list with docs.units, and keeps only folders that hold the named file' {
            $root = New-CoverageRepo -Files @{
                'packs/alpha/gates.json' = '{}'
                'packs/beta/readme.txt'  = 'x'
                'docs/packages/alpha.md' = "# alpha`n"
            } -Docs @{ units = @(@{ glob = 'packs/*'; contains = @('gates.json'); kind = 'package'; folder = 'packages' }) }

            $units = @(Get-DocUnit -RepoRoot $root)

            $units.Path | Should -Be @('packs/alpha')
            (Invoke-Gate -Root $root).ExitCode | Should -Be 0
        }

        It 'takes a glob with no wildcard as the one folder it names, not as the folders inside it' {
            $root = New-CoverageRepo -Files @{
                'core/.apm/skills/x/SKILL.md' = '# x'
                'docs/packages/core.md'       = "# core`n"
            } -Docs @{ units = @(@{ glob = 'core'; kind = 'package'; folder = 'packages' }) }

            @(Get-DocUnit -RepoRoot $root).Path | Should -Be @('core')
            (Invoke-Gate -Root $root).ExitCode | Should -Be 0
        }

        It 'turns a unit name into a page name the wiki uses' {
            ConvertTo-DocPageName -Name 'Workers.BillingSync' | Should -Be 'workers-billing-sync'
            ConvertTo-DocPageName -Name 'vwan-infra' | Should -Be 'vwan-infra'
        }
    }

    Context 'the two layers' {
        It 'fails when the repository has no functional layer' {
            $root = New-CoverageRepo -NoFunctional

            $r = Invoke-Gate -Root $root

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'no functional layer: paths.functionalDocs in aisdlc.json is empty'
        }

        It 'fails when a layer holds only its index' {
            $root = New-CoverageRepo
            Remove-Item -LiteralPath (Join-Path $root 'docs-functional/glossary.md')

            $r = Invoke-Gate -Root $root

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'has no page besides its index'
        }

        It 'fails when a layer has no index' {
            $root = New-CoverageRepo
            Remove-Item -LiteralPath (Join-Path $root 'docs/index.md')

            (Invoke-Gate -Root $root).Output | Should -Match 'the technical layer docs has no index.md'
        }
    }

    Context 'the work list' {
        It 'returns the findings as objects with -AsObject, and does not exit' {
            $root = New-CoverageRepo -Files @{ 'building-blocks/vwan-infra/main.bicep' = "param x string`n" }

            $result = & $script:ScriptUnderTest -RepoRoot $root -AsObject

            $result.Missing.Unit | Should -Be @('building-blocks/vwan-infra')
            $result.Missing.SuggestedPage | Should -Be @('docs/building-blocks/vwan-infra.md')
        }
    }
}
