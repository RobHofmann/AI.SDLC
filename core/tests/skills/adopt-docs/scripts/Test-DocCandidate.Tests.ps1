#requires -Version 7.4

Describe 'Test-DocCandidate' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Test-DocCandidate.ps1'
        $script:FactsWriter = Join-Path -Path $PSScriptRoot -ChildPath 'New-DocCandidate.ps1'

        function New-CheckRepo {
            param([string]$Layer = 'Technical')
            $root = Join-Path $TestDrive ('tdc-' + [guid]::NewGuid().ToString('n'))
            $files = @{
                'apm.yml'                                      = "dependencies:`n  apm:`n    - ../AI.SDLC/packs/bicep"
                'aisdlc.json'                                  = '{ "paths": { "docsRoots": ["docs", "docs-functional"], "technicalDocs": "docs", "functionalDocs": "docs-functional", "bicepRoot": "building-blocks" } }'
                'docs/index.md'                                = "# Docs`n"
                'docs/networking.md'                           = "# Networking`n"
                'docs-functional/index.md'                     = "# Functional`n"
                'building-blocks/hub-network/main.bicep'       = "param x string`n"
                '.claude/skills/bicep-x/gates.json'            = '{ "package": "bicep", "gates": [], "docUnits": [ { "glob": "{bicepRoot}/*", "kind": "building block", "folder": "building-blocks" } ], "docFacts": "scripts/Get-Facts.ps1" }'
                '.claude/skills/bicep-x/scripts/Get-Facts.ps1' = "param([string]`$Unit, [string]`$RepoRoot)`n@('UNIT: ' + `$Unit, '  deploys Microsoft.Network/virtualHubs@2023-04-01', '  param HubName: string, required')"
            }
            foreach ($rel in $files.Keys) {
                $full = Join-Path $root $rel
                New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
                Set-Content -LiteralPath $full -Value $files[$rel] -Encoding utf8
            }
            $root = (Resolve-Path $root).Path
            if ($Layer -eq 'Technical') {
                & $script:FactsWriter -Unit 'building-blocks/hub-network' -RepoRoot $root *> $null
                return [pscustomobject]@{ Root = $root; Facts = 'doc-candidates/building-blocks_hub-network.facts.md'; Draft = 'doc-candidates/docs_building-blocks_hub-network.md' }
            }
            & $script:FactsWriter -Unit 'building-blocks/hub-network' -Layer Functional -Page 'docs-functional/networking.md' -Title 'Networking for teams' -RepoRoot $root *> $null
            return [pscustomobject]@{ Root = $root; Facts = 'doc-candidates/building-blocks_hub-network.facts.md'; Draft = 'doc-candidates/docs-functional_networking.md' }
        }

        function Invoke-Check {
            param($Repo, [string]$Text, [hashtable]$Extra = @{})
            Set-Content -LiteralPath (Join-Path $Repo.Root $Repo.Draft) -Value $Text -Encoding utf8
            $out = & $script:ScriptUnderTest -Draft $Repo.Draft -FactsFile $Repo.Facts -RepoRoot $Repo.Root @Extra *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }

        $script:GoodDraft = "---`nunits:`n  - building-blocks/hub-network`n---`n# hub-network`n`nDeploys ``Microsoft.Network/virtualHubs`` with ``HubName``.`n`n## Related`n`n* [Docs](../index.md) - the index"
    }

    It 'passes a draft that keeps to its facts' {
        $repo = New-CheckRepo

        $r = Invoke-Check -Repo $repo -Text $script:GoodDraft

        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'Draft OK against its facts'
    }

    It 'lists the names the draft invents, and refuses above the limit' {
        $repo = New-CheckRepo
        $draft = $script:GoodDraft + "`n``GhostOne`` ``GhostTwo``"

        $warned = Invoke-Check -Repo $repo -Text $draft
        $refused = Invoke-Check -Repo $repo -Text $draft -Extra @{ MaximumUnverifiedSymbols = 1 }

        $warned.ExitCode | Should -Be 0
        $warned.Output | Should -Match 'UNVERIFIED: 2 symbol'
        $refused.ExitCode | Should -Be 1
        $refused.Output | Should -Match 'names 2 symbols that are not in the facts'
        $refused.Output | Should -Match '(?m)^FIX: '
    }

    It 'does not take a word of the writing rules as a fact' {
        $repo = New-CheckRepo

        $r = Invoke-Check -Repo $repo -Text ($script:GoodDraft + "`n``English``") -Extra @{ MaximumUnverifiedSymbols = 0 }

        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'English'
    }

    It 'refuses a technical draft without the front matter that ties it to its unit' {
        $repo = New-CheckRepo

        $r = Invoke-Check -Repo $repo -Text "# hub-network`n`nText."

        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'front matter does not name the unit'
    }

    It 'refuses a draft whose H1 is not the title' {
        $repo = New-CheckRepo

        $r = Invoke-Check -Repo $repo -Text ($script:GoodDraft -replace '# hub-network', '# Something else')

        $r.Output | Should -Match "its H1 is not '# hub-network'"
    }

    It 'refuses a draft with the em-dash character' {
        $repo = New-CheckRepo

        $r = Invoke-Check -Repo $repo -Text ($script:GoodDraft + "`nA " + [char]0x2014 + ' B')

        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'em-dash'
    }

    It 'reports the reading-level findings of the draft' {
        $repo = New-CheckRepo

        $r = Invoke-Check -Repo $repo -Text ($script:GoodDraft + "`n`nWe utilise the network to facilitate the deployment.")

        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'READING LEVEL: \d+ finding'
    }

    It 'warns when a functional draft reads like a technical page' {
        $repo = New-CheckRepo -Layer Functional
        $names = (1..12 | ForEach-Object { "``Param$_``" }) -join ', '

        $r = Invoke-Check -Repo $repo -Text "# Networking for teams`n`nYou set $names.`n`n## Related`n`n* [Functional](index.md) - the index" -Extra @{ MaximumUnverifiedSymbols = 20 }

        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'FUNCTIONAL: the draft names 12 code items'
    }

    It 'exits 2 when the draft is missing' {
        $repo = New-CheckRepo

        $out = & $script:ScriptUnderTest -Draft 'doc-candidates/none.md' -FactsFile $repo.Facts -RepoRoot $repo.Root *>&1 | Out-String

        $LASTEXITCODE | Should -Be 2
        $out | Should -Match 'Could not check'
    }
}
