#requires -Version 7.4

Describe 'DocCoverage' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'DocToolTestHarness.psm1') -Force
        Import-Module (Join-Path $PSScriptRoot 'DocCoverage.psm1') -Force

        function New-UnitRepo {
            param([hashtable]$Files = @{}, [hashtable]$Paths, [hashtable]$Docs)
            $root = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            foreach ($rel in $Files.Keys) {
                $full = Join-Path $root $rel
                New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
                Set-Content -LiteralPath $full -Value $Files[$rel] -Encoding utf8
            }
            Set-AiSdlcTestConfig -Root $root -Paths $Paths
            if ($Docs) {
                $file = Join-Path $root 'aisdlc.json'
                $config = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
                $config.docs = $Docs
                Set-Content -LiteralPath $file -Value ($config | ConvertTo-Json -Depth 6) -Encoding utf8
            }
            return $root
        }
    }

    Context 'ConvertTo-DocPageName' {
        It 'turns <Name> into <Expected>' -ForEach @(
            @{ Name = 'Workers.BillingSync'; Expected = 'workers-billing-sync' }
            @{ Name = 'vwan-infra'; Expected = 'vwan-infra' }
            @{ Name = 'Net8Api'; Expected = 'net8-api' }
            @{ Name = '_Shared  Lib_'; Expected = 'shared-lib' }
            @{ Name = 'ABCService'; Expected = 'abcservice' }
        ) {
            ConvertTo-DocPageName -Name $Name | Should -Be $Expected
        }
    }

    Context 'Get-DocPageUnitClaim' {
        It 'returns no claim for a page without front matter' {
            (Get-DocPageUnitClaim -Text "# Page`n`nunit: a/b`n").Count | Should -Be 0
        }

        It 'reads one unit after unit:, without its quotes' {
            (Get-DocPageUnitClaim -Text "---`nunit: 'a/b'`n---`n# X") | Should -Be @('a/b')
        }

        It 'reads an inline list after units:, without quotes or spaces' {
            (Get-DocPageUnitClaim -Text "---`nunits: [ a/b , `"c/d`", 'e/f' ]`n---`n# X") | Should -Be @('a/b', 'c/d', 'e/f')
        }

        It 'reads a block list after units:, and stops at the first line that is not an item' {
            $text = "---`nunits:`n  - a/b`n  - 'c/d'`ntitle: x`n  - not/a/claim`n---`n# X"

            (Get-DocPageUnitClaim -Text $text) | Should -Be @('a/b', 'c/d')
        }

        It 'returns no claim for units: with no value and no list under it' {
            (Get-DocPageUnitClaim -Text "---`nunits:`ntitle: x`n---`n# X").Count | Should -Be 0
        }

        It 'drops empty items of an inline list' {
            (Get-DocPageUnitClaim -Text "---`nunits: [a/b, , ]`n---`n# X") | Should -Be @('a/b')
        }

        It 'writes a claim with forward slashes and no trailing slash' {
            (Get-DocPageUnitClaim -Text "---`nunits: [src\Lib\, a/b/]`n---`n# X") | Should -Be @('src/Lib', 'a/b')
        }

        It 'reads front matter with Windows line endings' {
            (Get-DocPageUnitClaim -Text "---`r`nunit: a/b`r`n---`r`n# X") | Should -Be @('a/b')
        }

        It 'reads front matter behind a byte order mark' {
            (Get-DocPageUnitClaim -Text ([string][char]0xFEFF + "---`nunit: a/b`n---`n# X")) | Should -Be @('a/b')
        }

        It 'returns no claim when the front matter is not at the start of the page' {
            (Get-DocPageUnitClaim -Text "# X`n---`nunit: a/b`n---`n").Count | Should -Be 0
        }

        It 'returns no claim when the front matter never closes' {
            (Get-DocPageUnitClaim -Text "---`nunit: a/b`n# X`n").Count | Should -Be 0
        }

        It 'reads both unit: and units: in one front matter' {
            (Get-DocPageUnitClaim -Text "---`nunit: a/b`nunits: [c/d]`n---`n") | Should -Be @('a/b', 'c/d')
        }
    }

    Context 'Get-DocUnitSpec' {
        It 'returns docs.units of aisdlc.json, and ignores the units the packs name' {
            $root = New-UnitRepo -Files @{
                '.claude/skills/dotnet-x/gates.json' = '{ "package": "dotnet", "gates": [], "docUnits": [ { "glob": "{sourceRoot}/*" } ] }'
            } -Docs @{ units = @(@{ glob = 'packs/*'; kind = 'package' }) }

            $spec = Get-DocUnitSpec -RepoRoot $root

            $spec.Count | Should -Be 1
            $spec[0]['glob'] | Should -Be 'packs/*'
        }

        It 'returns the docUnits of the installed packs that run, when docs.units is empty' {
            $root = New-UnitRepo -Files @{
                '.claude/skills/dotnet-x/gates.json' = '{ "package": "dotnet", "gates": [], "docUnits": [ { "glob": "{sourceRoot}/*", "kind": "project" } ] }'
                '.claude/skills/bicep-x/gates.json'  = '{ "package": "bicep", "gates": [], "docUnits": [ { "glob": "{bicepRoot}/*" } ] }'
                '.claude/skills/core-x/gates.json'   = '{ "package": "core", "gates": [] }'
            }

            $spec = Get-DocUnitSpec -RepoRoot $root

            @($spec | ForEach-Object { $_['glob'] }) | Should -Be @('{sourceRoot}/*')
        }

        It 'returns an empty list when no pack names a unit' {
            $root = New-UnitRepo

            $spec = Get-DocUnitSpec -RepoRoot $root

            , $spec | Should -BeOfType [object[]]
            $spec.Count | Should -Be 0
        }
    }

    Context 'Get-DocUnit' {
        It 'fills a path token from aisdlc.json and returns each folder the glob finds, sorted' {
            $root = New-UnitRepo -Files @{
                'Demo/src/Zeta/Zeta.csproj'   = '<Project />'
                'Demo/src/Alpha/Alpha.csproj' = '<Project />'
            }

            $units = @(Get-DocUnit -RepoRoot $root -Spec @(@{ glob = '{sourceRoot}/*'; kind = 'project'; folder = 'projects' }))

            $units.Path | Should -Be @('Demo/src/Alpha', 'Demo/src/Zeta')
            $units.Name | Should -Be @('Alpha', 'Zeta')
            $units[0].Kind | Should -Be 'project'
            $units[0].Folder | Should -Be 'projects'
        }

        It 'uses the first value of a list token, with forward slashes and no trailing slash' {
            $root = New-UnitRepo -Files @{ 'lib/One/x.txt' = 'x' } -Paths @{ docsRoots = @('lib\', 'other') }

            @(Get-DocUnit -RepoRoot $root -Spec @(@{ glob = '{docsRoots}/*' })).Path | Should -Be @('lib/One')
        }

        It 'skips an entry whose token is <Case>' -ForEach @(
            @{ Case = 'empty in aisdlc.json'; Glob = '{bicepRoot}/*'; Paths = @{ bicepRoot = '' } }
            @{ Case = 'not a path aisdlc.json knows'; Glob = '{noSuchPath}/*'; Paths = @{} }
        ) {
            $root = New-UnitRepo -Files @{ 'building-blocks/a/main.bicep' = 'x' } -Paths $Paths

            @(Get-DocUnit -RepoRoot $root -Spec @(@{ glob = $Glob })).Count | Should -Be 0
        }

        It 'gives a unit the kind unit and no folder when the entry names neither' {
            $root = New-UnitRepo -Files @{ 'packs/alpha/x.txt' = 'x' }

            $unit = Get-DocUnit -RepoRoot $root -Spec @(@{ glob = 'packs/*' })

            $unit.Kind | Should -Be 'unit'
            $unit.Folder | Should -Be ''
        }

        It 'never counts a hidden, bin, obj or node_modules folder as a unit' {
            $root = New-UnitRepo -Files @{
                'packs/.hidden/x.txt'      = 'x'
                'packs/bin/x.txt'          = 'x'
                'packs/obj/x.txt'          = 'x'
                'packs/node_modules/x.txt' = 'x'
                'packs/binder/x.txt'       = 'x'
            }

            @(Get-DocUnit -RepoRoot $root -Spec @(@{ glob = 'packs/*' })).Path | Should -Be @('packs/binder')
        }

        It 'takes a glob with no wildcard as the one folder it names' {
            $root = New-UnitRepo -Files @{ 'core/inner/x.txt' = 'x' }

            @(Get-DocUnit -RepoRoot $root -Spec @(@{ glob = 'core' })).Path | Should -Be @('core')
        }

        It 'returns nothing for a glob with no wildcard whose folder does not exist' {
            $root = New-UnitRepo

            @(Get-DocUnit -RepoRoot $root -Spec @(@{ glob = 'missing' })).Count | Should -Be 0
        }

        It 'returns nothing for a glob with a wildcard that finds no folder' {
            $root = New-UnitRepo

            @(Get-DocUnit -RepoRoot $root -Spec @(@{ glob = 'missing/*' })).Count | Should -Be 0
        }

        It 'keeps only the folders that hold a file the entry names, directly and not in a subfolder' {
            $root = New-UnitRepo -Files @{
                'packs/alpha/gates.json'     = '{}'
                'packs/beta/readme.txt'      = 'x'
                'packs/gamma/deep/gates.json' = '{}'
                'packs/delta/apm.yml'        = 'x'
            }

            $units = @(Get-DocUnit -RepoRoot $root -Spec @(@{ glob = 'packs/*'; contains = @('gates.json', '*.yml') }))

            $units.Path | Should -Be @('packs/alpha', 'packs/delta')
        }

        It 'leaves out a unit that docs.unitExclude names by path, written with a backslash or a trailing slash' {
            $root = New-UnitRepo -Files @{
                'packs/alpha/x.txt' = 'x'
                'packs/beta/x.txt'  = 'x'
                'packs/gamma/x.txt' = 'x'
            } -Docs @{ units = @(); unitExclude = @('packs\alpha', 'packs/beta/') }

            @(Get-DocUnit -RepoRoot $root -Spec @(@{ glob = 'packs/*' })).Path | Should -Be @('packs/gamma')
        }

        It 'leaves out a folder whose name matches an exclude pattern of the entry' {
            $root = New-UnitRepo -Files @{
                'packs/alpha/x.txt'      = 'x'
                'packs/alpha.Tests/x.txt' = 'x'
            }

            @(Get-DocUnit -RepoRoot $root -Spec @(@{ glob = 'packs/*'; exclude = @('*.Tests') })).Path | Should -Be @('packs/alpha')
        }

        It 'returns a folder that two entries find only once, with the kind of the first entry' {
            $root = New-UnitRepo -Files @{ 'packs/alpha/x.txt' = 'x' }

            $units = @(Get-DocUnit -RepoRoot $root -Spec @(@{ glob = 'packs/*'; kind = 'first' }, @{ glob = 'packs/alpha'; kind = 'second' }))

            $units.Count | Should -Be 1
            $units[0].Kind | Should -Be 'first'
        }

        It 'reads the spec from aisdlc.json when no spec is given' {
            $root = New-UnitRepo -Files @{ 'packs/alpha/x.txt' = 'x' } -Docs @{ units = @(@{ glob = 'packs/*'; kind = 'package' }) }

            $unit = Get-DocUnit -RepoRoot $root

            $unit.Path | Should -Be 'packs/alpha'
            $unit.Kind | Should -Be 'package'
        }

        It 'returns nothing for an empty spec, even when aisdlc.json names units' {
            $root = New-UnitRepo -Files @{ 'packs/alpha/x.txt' = 'x' } -Docs @{ units = @(@{ glob = 'packs/*' }) }

            @(Get-DocUnit -RepoRoot $root -Spec @()).Count | Should -Be 0
        }

    }

    Context 'Get-DocPage' {
        It 'returns nothing when the layer folder does not exist' {
            $root = New-UnitRepo

            @(Get-DocPage -RepoRoot $root -Layer 'docs').Count | Should -Be 0
        }

        It 'returns each markdown page of the layer, in its subfolders too, sorted by path' {
            $root = New-UnitRepo -Files @{
                'docs/zeta.md'          = "# Zeta`n"
                'docs/sub/alpha.md'     = "# Alpha`n"
                'docs/notes.txt'        = 'not a page'
                'docs-functional/x.md'  = "# Other layer`n"
            }

            @(Get-DocPage -RepoRoot $root -Layer 'docs').Path | Should -Be @('docs/sub/alpha.md', 'docs/zeta.md')
        }

        It 'reads an empty page as a page with no title and no claims, instead of failing' {
            $root = New-UnitRepo -Files @{ 'docs/zeta.md' = "# Zeta`n" }
            [System.IO.File]::WriteAllText((Join-Path $root 'docs' 'empty.md'), '')

            $pages = @(Get-DocPage -RepoRoot $root -Layer 'docs')

            $pages.Path | Should -Be @('docs/empty.md', 'docs/zeta.md')
            @($pages[0].Units).Count | Should -Be 0
        }

        It 'gives a page its file name without extension, its first H1 without backticks, and its unit claims' {
            $root = New-UnitRepo -Files @{ 'docs/billing-sync.md' = "---`nunit: Demo/src/Billing`n---`n## Not the title`n# The ``Billing`` sync  `n# Second`n" }

            $page = Get-DocPage -RepoRoot $root -Layer 'docs'

            $page.Stem | Should -Be 'billing-sync'
            $page.Title | Should -Be 'The Billing sync'
            $page.Units | Should -Be @('Demo/src/Billing')
        }


        It 'leaves out the decision records under paths.adrFolder' {
            $root = New-UnitRepo -Files @{
                'docs/adrs/0001-x.md' = "# x`n"
                'docs/adrsx/page.md'  = "# y`n"
            } -Paths @{ adrFolder = 'docs\adrs\' }

            @(Get-DocPage -RepoRoot $root -Layer 'docs').Path | Should -Be @('docs/adrsx/page.md')
        }

        It 'keeps every page when paths.adrFolder is empty' {
            $root = New-UnitRepo -Files @{ 'docs/adrs/0001-x.md' = "# x`n" } -Paths @{ adrFolder = '' }

            @(Get-DocPage -RepoRoot $root -Layer 'docs').Path | Should -Be @('docs/adrs/0001-x.md')
        }
    }

    Context 'Get-DocLayerFinding' {
        It 'finds nothing when both layers have an index and a page' {
            $root = New-UnitRepo -Files @{
                'docs/index.md'            = "# Docs`n"
                'docs/overview.md'         = "# Overview`n"
                'docs-functional/index.md' = "# Functional`n"
                'docs-functional/sub/a.md' = "# A`n"
            }

            @(Get-DocLayerFinding -RepoRoot $root).Count | Should -Be 0
        }

        It 'reports a layer whose path in aisdlc.json is empty' {
            $root = New-UnitRepo -Files @{ 'docs/index.md' = "# Docs`n"; 'docs/a.md' = "# A`n" } -Paths @{ functionalDocs = '' }

            $findings = @(Get-DocLayerFinding -RepoRoot $root)

            $findings.Layer | Should -Be @('functional')
            $findings.Problem | Should -Be @('no functional layer: paths.functionalDocs in aisdlc.json is empty')
        }

        It 'reports a layer whose folder does not exist' {
            $root = New-UnitRepo -Files @{ 'docs-functional/index.md' = "# F`n"; 'docs-functional/a.md' = "# A`n" }

            $findings = @(Get-DocLayerFinding -RepoRoot $root)

            $findings.Layer | Should -Be @('technical')
            $findings.Problem | Should -Be @('no technical layer: the folder docs does not exist')
        }

        It 'reports a layer with no index.md' {
            $root = New-UnitRepo -Files @{ 'docs/a.md' = "# A`n"; 'docs-functional/index.md' = "# F`n"; 'docs-functional/a.md' = "# A`n" }

            @(Get-DocLayerFinding -RepoRoot $root).Problem | Should -Be @('the technical layer docs has no index.md')
        }

        It 'reports a layer that holds only its index and a README' {
            $root = New-UnitRepo -Files @{ 'docs/index.md' = "# D`n"; 'docs/a.md' = "# A`n"; 'docs-functional/index.md' = "# F`n"; 'docs-functional/README.md' = "# R`n" }

            @(Get-DocLayerFinding -RepoRoot $root).Problem | Should -Be @('the functional layer docs-functional has no page besides its index')
        }

        It 'reports both a missing index and a missing page for an empty layer folder' {
            $root = New-UnitRepo -Files @{ 'docs/index.md' = "# D`n"; 'docs/a.md' = "# A`n" }
            New-Item -ItemType Directory -Path (Join-Path $root 'docs-functional') | Out-Null

            @(Get-DocLayerFinding -RepoRoot $root).Problem | Should -Be @(
                'the functional layer docs-functional has no index.md'
                'the functional layer docs-functional has no page besides its index'
            )
        }
    }

    Context 'Get-DocCoverage' {
        It 'names no page and suggests one in the folder of the kind when no page covers a unit' {
            $root = New-UnitRepo -Files @{ 'Demo/src/Workers.BillingSync/x.csproj' = '<Project />'; 'docs/index.md' = "# D`n" }

            $result = Get-DocCoverage -RepoRoot $root -Spec @(@{ glob = '{sourceRoot}/*'; kind = 'project'; folder = 'projects' })

            $result.Unit | Should -Be 'Demo/src/Workers.BillingSync'
            $result.Name | Should -Be 'Workers.BillingSync'
            $result.Kind | Should -Be 'project'
            @($result.Pages).Count | Should -Be 0
            $result.SuggestedPage | Should -Be 'docs/projects/workers-billing-sync.md'
        }

        It 'suggests a page at the root of the technical layer when the entry names no folder' {
            $root = New-UnitRepo -Files @{ 'packs/alpha/x.txt' = 'x' } -Paths @{ technicalDocs = 'docs/' }

            (Get-DocCoverage -RepoRoot $root -Spec @(@{ glob = 'packs/*' })).SuggestedPage | Should -Be 'docs/alpha.md'
        }

        It 'counts a page whose <Case>' -ForEach @(
            @{ Case = 'file name is the unit name read without case and punctuation'; Page = 'docs/projects/workers-billingsync.md'; Text = "# Something else`n" }
            @{ Case = 'H1 is the unit name in another case'; Page = 'docs/sync.md'; Text = "# workers.billingsync`n" }
            @{ Case = 'front matter names the unit path'; Page = 'docs/sync.md'; Text = "---`nunits: [Demo/src/Workers.BillingSync/]`n---`n# Sync`n" }
        ) {
            $root = New-UnitRepo -Files @{ 'Demo/src/Workers.BillingSync/x.csproj' = '<Project />'; $Page = $Text }

            (Get-DocCoverage -RepoRoot $root -Spec @(@{ glob = '{sourceRoot}/*' })).Pages | Should -Be @($Page)
        }

        It 'does not count a page whose H1 only contains the unit name' {
            $root = New-UnitRepo -Files @{ 'Demo/src/Billing/x.csproj' = '<Project />'; 'docs/sync.md' = "# Billing sync`n" }

            @((Get-DocCoverage -RepoRoot $root -Spec @(@{ glob = '{sourceRoot}/*' })).Pages).Count | Should -Be 0
        }

        It 'names every page that covers a unit' {
            $root = New-UnitRepo -Files @{
                'Demo/src/Billing/x.csproj' = '<Project />'
                'docs/billing.md'           = "# Billing`n"
                'docs/flows/money.md'       = "---`nunit: Demo/src/Billing`n---`n# Money`n"
            }

            (Get-DocCoverage -RepoRoot $root -Spec @(@{ glob = '{sourceRoot}/*' })).Pages | Should -Be @('docs/billing.md', 'docs/flows/money.md')
        }

        It 'never counts a decision record as the page of a unit' {
            $root = New-UnitRepo -Files @{ 'Demo/src/Billing/x.csproj' = '<Project />'; 'docs/adrs/0001-billing.md' = "# Billing`n" }

            @((Get-DocCoverage -RepoRoot $root -Spec @(@{ glob = '{sourceRoot}/*' })).Pages).Count | Should -Be 0
        }

        It 'returns nothing when the repository has no unit' {
            $root = New-UnitRepo -Files @{ 'docs/a.md' = "# A`n" }

            @(Get-DocCoverage -RepoRoot $root -Spec @()).Count | Should -Be 0
        }
    }

    Context 'Get-DocUnverifiedSymbol' {
        It 'lists a name in backticks that the facts do not hold, and not one they hold' {
            $invented = Get-DocUnverifiedSymbol -Candidate 'Uses `AlphaService` and `GhostHelper`.' -Facts 'FILE: a.cs  public types: AlphaService'

            $invented | Should -Be @('GhostHelper')
        }

        It 'counts a name the page already uses as verified' {
            $invented = Get-DocUnverifiedSymbol -Candidate '`OldName`' -Facts '' -Page 'See `OldName`.'

            @($invented).Count | Should -Be 0
        }
    }
}
