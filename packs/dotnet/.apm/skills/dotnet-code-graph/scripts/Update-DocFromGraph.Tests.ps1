#requires -Version 7.4

Describe 'Update-DocFromGraph' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Update-DocFromGraph.ps1'

        $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
        if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
        Import-Module (Join-Path $aiSdlcGates 'DocToolTestHarness.psm1') -Force

        function New-Repo {
            param([hashtable]$Files)
            $root = New-DocToolRepo -Files $Files -Prefix 'udg'
            Set-AiSdlcTestConfig -Root $root -Paths @{ sourceDocMap = @(@{ source = 'Demo/src/Shared.'; docs = @('docs/libraries/') }, @{ source = 'Demo/src/Workers.'; docs = @('docs/handlers/') }) }
            return $root
        }

        function New-LinkedGraph {
            param(
                [Parameter(Mandatory)][string]$Path,
                [Parameter(Mandatory)][string]$DocFile,
                [Parameter(Mandatory)][string[]]$SourceFiles
            )
            $nodes = @(); $links = @()
            foreach ($f in $SourceFiles) {
                $id = ($f -replace '[^A-Za-z0-9]', '_').ToLowerInvariant()
                $nodes += [pscustomobject]@{ id = $id; label = [System.IO.Path]::GetFileName($f); source_file = $f }
                $links += [pscustomobject]@{ source = 'doc_node'; target = $id; relation = 'documents'; source_file = $DocFile }
            }
            $nodes += [pscustomobject]@{ id = 'doc_node'; label = 'doc'; source_file = $DocFile }
            [ordered]@{ nodes = $nodes; links = $links } | ConvertTo-Json -Depth 8 |
                Set-Content -LiteralPath $Path -Encoding utf8
        }

        function Invoke-Update {
            param([hashtable]$ScriptArgs)
            $out = & $script:ScriptUnderTest @ScriptArgs *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }
    }

    AfterAll {
        Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'udg-*' -Directory -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'a stale graph' {
        BeforeAll {
            function New-StaleRepo {
                $root = New-DocToolRepo -Prefix 'udg' -InitialiseGit -Files @{
                    'docs/libraries/thing.md'                            = "# Thing`n`nSee ``AlphaService.cs``."
                    'Demo/src/Shared.Thing/Services/AlphaService.cs' = 'namespace X; public class AlphaService { }'
                }
                $head = [string](git -C $root rev-parse HEAD)
                $graphFile = Join-Path $root 'graphify-out/graph.json'
                New-Item -ItemType Directory -Path (Split-Path $graphFile -Parent) -Force | Out-Null
                [ordered]@{
                    nodes           = @(
                        [pscustomobject]@{ id = 'a'; label = 'AlphaService'; source_file = 'Demo/src/Shared.Thing/Services/AlphaService.cs' }
                        [pscustomobject]@{ id = 'doc'; label = 'thing'; source_file = 'docs/libraries/thing.md' }
                    )
                    links           = @([pscustomobject]@{ source = 'doc'; target = 'a'; relation = 'documents'; source_file = 'docs/libraries/thing.md' })
                    built_at_commit = $head
                } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $graphFile -Encoding utf8
                Set-Content -LiteralPath (Join-Path $root 'Demo/src/Shared.Thing/Services/AlphaService.cs') `
                    -Value 'namespace X; public class AlphaService { public void Run() { } }' -Encoding utf8
                return $root
            }
        }

        It 'refuses to draft, because a claim written from an old graph still reads as verified' {
            # Arrange
            $root = New-StaleRepo

            # Act
            $r = Invoke-Update -ScriptArgs @{ DocPath = 'docs/libraries/thing.md'; RepoRoot = $root; DryRun = $true }

            # Assert
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'STALE GRAPH'
            $r.Output | Should -Match 'Refusing to draft'
        }

        It 'drafts anyway when told to, so the check is a guard and not a wall' {
            # Arrange
            $root = New-StaleRepo

            # Act
            $r = Invoke-Update -ScriptArgs @{ DocPath = 'docs/libraries/thing.md'; RepoRoot = $root; DryRun = $true; AllowStaleGraph = $true }

            # Assert
            $r.Output | Should -Match 'STALE GRAPH'
            $r.Output | Should -Not -Match 'Refusing to draft'
        }
    }

    Context 'refusing point-in-time records' {
        It 'refuses <Path>, which must never be rewritten to match current code' -ForEach @(
            @{ Path = 'docs/adrs/0001-something.md' }
            @{ Path = 'docs/stories/42-login.md' }
        ) {
            $root = New-Repo -Files @{ $Path = '# Record' }

            $r = Invoke-Update -ScriptArgs @{ DocPath = $Path; RepoRoot = $root }

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'point-in-time record'
            $r.Output | Should -Match 'Append-only'
        }

        It 'refuses the record before it needs a graph, so the rule cannot be bypassed by ordering' {
            $root = New-Repo -Files @{ 'docs/adrs/0001-x.md' = '# Record' }

            $r = Invoke-Update -ScriptArgs @{ DocPath = 'docs/adrs/0001-x.md'; RepoRoot = $root; GraphPath = (Join-Path $root 'absent.json') }

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'point-in-time record'
            $r.Output | Should -Not -Match 'No graph at'
        }
    }

    Context 'assembling the facts' {
        It 'collects public types and named members from the cited sources' {
            $root = New-Repo -Files @{
                'src/Policy.cs' = 'public static class Policy { public const string Alpha = "a"; public const string Beta = "b"; }'
                'docs/p.md'     = "# Policy`n`nSee ``Policy.cs``."
            }
            $graph = Join-Path $root 'graph.json'
            New-LinkedGraph -Path $graph -DocFile 'docs/p.md' -SourceFiles @('src/Policy.cs')

            $r = Invoke-Update -ScriptArgs @{ DocPath = 'docs/p.md'; RepoRoot = $root; GraphPath = $graph; DryRun = $true }

            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'public types: Policy'
            $r.Output | Should -Match 'public named members: Alpha, Beta'
        }

        It 'sends nothing and writes nothing on a dry run' {
            $root = New-Repo -Files @{
                'src/Policy.cs' = 'public static class Policy { public const string Alpha = "a"; }'
                'docs/p.md'     = "# Policy`n`nSee ``Policy.cs``."
            }
            $graph = Join-Path $root 'graph.json'
            New-LinkedGraph -Path $graph -DocFile 'docs/p.md' -SourceFiles @('src/Policy.cs')

            $r = Invoke-Update -ScriptArgs @{ DocPath = 'docs/p.md'; RepoRoot = $root; GraphPath = $graph; DryRun = $true }

            $r.Output | Should -Match 'Dry run; nothing written'
            Test-Path -LiteralPath (Join-Path $root 'doc-candidates') | Should -BeFalse
        }
    }

    Context 'the facts file' {
        BeforeAll {
            function New-FactsRepo {
                $root = New-Repo -Files @{
                    'src/Policy.cs' = 'public static class Policy { public const string Alpha = "a"; }'
                    'docs/p.md'     = "# Policy`n`nSee ``Policy.cs``."
                }
                $graph = Join-Path $root 'graph.json'
                New-LinkedGraph -Path $graph -DocFile 'docs/p.md' -SourceFiles @('src/Policy.cs')
                return [pscustomobject]@{ Root = $root; Graph = $graph }
            }
        }

        It 'writes the page, the candidate path, the drafting rules and the facts to doc-candidates' {
            # Arrange
            $repo = New-FactsRepo

            # Act
            $r = Invoke-Update -ScriptArgs @{ DocPath = 'docs/p.md'; RepoRoot = $repo.Root; GraphPath = $repo.Graph }

            # Assert
            $r.ExitCode | Should -Be 0
            $facts = Join-Path $repo.Root 'doc-candidates/docs_p.facts.md'
            Test-Path -LiteralPath $facts | Should -BeTrue
            $text = Get-Content -LiteralPath $facts -Raw
            $text | Should -Match '- Page: docs/p\.md'
            $text | Should -Match '- Candidate: doc-candidates/docs_p\.md'
            $text | Should -Match 'You ADD missing entries'
            $text | Should -Match 'public named members: Alpha'
            $text | Should -Match '-Check'
        }

        It 'never edits the page and writes no candidate itself' {
            # Arrange
            $repo = New-FactsRepo

            # Act
            $null = Invoke-Update -ScriptArgs @{ DocPath = 'docs/p.md'; RepoRoot = $repo.Root; GraphPath = $repo.Graph }

            # Assert
            Get-Content -LiteralPath (Join-Path $repo.Root 'docs/p.md') -Raw | Should -Match '^# Policy'
            Test-Path -LiteralPath (Join-Path $repo.Root 'doc-candidates/docs_p.md') | Should -BeFalse
        }

        It 'calls no model and needs no secret' {
            # Arrange, Act
            $content = Get-Content -LiteralPath $script:ScriptUnderTest -Raw -Encoding utf8

            # Assert
            $content | Should -Not -Match 'DocModel'
            $content | Should -Not -Match 'Invoke-RestMethod'
            $content | Should -Not -Match 'Invoke-WebRequest'
            $content | Should -Not -Match 'get-access-token'
        }
    }

    Context 'checking a drafted candidate' {
        BeforeAll {
            function New-CheckRepo {
                param([string]$Candidate)
                $page = "# Policy`n`n## Constants`n`nThe policy holds ``Alpha``, the first value of the set that every caller reads at start."
                $root = New-Repo -Files @{
                    'docs/p.md'                     = $page
                    'doc-candidates/docs_p.facts.md' = "FILE: src/Policy.cs`n  public types: Policy`n  public named members: Alpha, Beta"
                    'doc-candidates/docs_p.md'      = $Candidate
                }
                return $root
            }
        }

        It 'passes a candidate that only adds' {
            # Arrange
            $root = New-CheckRepo -Candidate "# Policy`n`n## Constants`n`nThe policy holds ``Alpha``, the first value of the set that every caller reads at start. It also holds ``Beta``."

            # Act
            $r = Invoke-Update -ScriptArgs @{ DocPath = 'docs/p.md'; RepoRoot = $root; Check = $true }

            # Assert
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'Candidate checked'
            $r.Output | Should -Not -Match 'UNVERIFIED'
        }

        It 'refuses a candidate that lost words, because the first design silently gutted pages' {
            # Arrange
            $root = New-CheckRepo -Candidate "# Policy`n`n## Constants`n`nIt holds ``Alpha``."

            # Act
            $r = Invoke-Update -ScriptArgs @{ DocPath = 'docs/p.md'; RepoRoot = $root; Check = $true }

            # Assert
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'kept only \d+% of the words'
            $r.Output | Should -Match 'FIX:'
        }

        It 'refuses a candidate that dropped a heading' {
            # Arrange
            $root = New-CheckRepo -Candidate "# Policy`n`nThe policy holds ``Alpha``, the first value of the set that every caller reads at start. It also holds ``Beta``."

            # Act
            $r = Invoke-Update -ScriptArgs @{ DocPath = 'docs/p.md'; RepoRoot = $root; Check = $true }

            # Assert
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'dropped 1 heading\(s\): Constants'
        }

        It 'lists a name that matches neither the facts nor the page, and refuses above the limit' {
            # Arrange
            $root = New-CheckRepo -Candidate "# Policy`n`n## Constants`n`nThe policy holds ``Alpha``, the first value of the set that every caller reads at start. It also holds ``Gamma``."

            # Act
            $listed = Invoke-Update -ScriptArgs @{ DocPath = 'docs/p.md'; RepoRoot = $root; Check = $true }
            $refused = Invoke-Update -ScriptArgs @{ DocPath = 'docs/p.md'; RepoRoot = $root; Check = $true; MaximumUnverifiedSymbols = 0 }

            # Assert
            $listed.ExitCode | Should -Be 0
            $listed.Output | Should -Match 'UNVERIFIED: 1 symbol'
            $listed.Output | Should -Match 'Gamma'
            $refused.ExitCode | Should -Be 1
            $refused.Output | Should -Match 'names 1 symbols found in neither the facts nor the page'
        }

        It 'replaces an em-dash in the candidate' {
            # Arrange
            $dash = [string][char]0x2014
            $root = New-CheckRepo -Candidate "# Policy`n`n## Constants`n`nThe policy holds ``Alpha``, the first value of the set that every caller reads at start $dash and ``Beta``."

            # Act
            $r = Invoke-Update -ScriptArgs @{ DocPath = 'docs/p.md'; RepoRoot = $root; Check = $true }

            # Assert
            $r.ExitCode | Should -Be 0
            (Get-Content -LiteralPath (Join-Path $root 'doc-candidates/docs_p.md') -Raw).Contains($dash) | Should -BeFalse
        }

        It 'fails without a facts file, and needs no graph' {
            # Arrange
            $root = New-Repo -Files @{ 'docs/p.md' = '# P'; 'doc-candidates/docs_p.md' = '# P' }

            # Act
            $r = Invoke-Update -ScriptArgs @{ DocPath = 'docs/p.md'; RepoRoot = $root; Check = $true; GraphPath = (Join-Path $root 'absent.json') }

            # Assert
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'No facts file'
            $r.Output | Should -Not -Match 'No graph at'
        }
    }

    Context 'which pages are asked to list services' {
        It 'asks a library page for the services of the library it is named for' {
            $root = New-Repo -Files @{
                'Demo/src/Shared.Thing/Services/AlphaService.cs' = "namespace X;`npublic class AlphaService`n{`n}"
                'Demo/src/Shared.Thing/Services/BetaService.cs'  = "namespace X;`npublic class BetaService`n{`n}"
                'docs/libraries/thing.md'                             = "# Thing`n`nSee ``AlphaService.cs``."
            }
            $graph = Join-Path $root 'graph.json'
            New-LinkedGraph -Path $graph -DocFile 'docs/libraries/thing.md' -SourceFiles @('Demo/src/Shared.Thing/Services/AlphaService.cs')

            $r = Invoke-Update -ScriptArgs @{ DocPath = 'docs/libraries/thing.md'; RepoRoot = $root; GraphPath = $graph; DryRun = $true }

            $r.Output | Should -Match 'SERVICES IN THIS PROJECT'
            $r.Output | Should -Match 'BetaService'
        }

        It 'lists the project public types the page never names, so a thin page can see what exists' {
            $root = New-Repo -Files @{
                'Demo/src/Shared.Thing/Services/AlphaService.cs' = "namespace X;`npublic class AlphaService`n{`n}"
                'Demo/src/Shared.Thing/Models/ThingRequest.cs'   = "namespace X;`npublic class ThingRequest`n{`n}"
                'docs/libraries/thing.md'                             = "# Thing`n`nSee `AlphaService.cs`."
            }
            $graph = Join-Path $root 'graph.json'
            New-LinkedGraph -Path $graph -DocFile 'docs/libraries/thing.md' -SourceFiles @('Demo/src/Shared.Thing/Services/AlphaService.cs')

            $r = Invoke-Update -ScriptArgs @{ DocPath = 'docs/libraries/thing.md'; RepoRoot = $root; GraphPath = $graph; DryRun = $true }

            $r.Output | Should -Match 'OTHER PUBLIC TYPES IN THIS PROJECT'
            $r.Output | Should -Match 'ThingRequest'
        }

        It 'never asks an API reference page, which documents an endpoint and not a project' {
            $root = New-Repo -Files @{
                'Demo/src/Shared.Thing/Services/AlphaService.cs' = "namespace X;`npublic class AlphaService`n{`n}"
                'Demo/src/Shared.Thing/Services/GammaService.cs' = "namespace X;`npublic class GammaService`n{`n}"
                'Demo/src/Shared.Thing/Services/BetaService.cs'  = "namespace X;`npublic class BetaService`n{`n}"
                'docs/api/thing.md'                                   = "# Thing API`n`nSee ``AlphaService.cs`` and ``GammaService.cs``."
            }
            $graph = Join-Path $root 'graph.json'
            New-LinkedGraph -Path $graph -DocFile 'docs/api/thing.md' -SourceFiles @('Demo/src/Shared.Thing/Services/AlphaService.cs', 'Demo/src/Shared.Thing/Services/GammaService.cs')

            $r = Invoke-Update -ScriptArgs @{ DocPath = 'docs/api/thing.md'; RepoRoot = $root; GraphPath = $graph; DryRun = $true }

            $r.Output | Should -Not -Match 'SERVICES IN THIS PROJECT'
            $r.Output | Should -Not -Match 'BetaService'
        }
    }

    Context 'where the candidate is written' {
        It 'writes outside docs and outside graphify-out, the two places that destroyed it' {
            $help = Get-Content -LiteralPath $script:ScriptUnderTest -Raw

            $help | Should -Match "Join-Path \`$RepoRoot 'doc-candidates'"
            $help | Should -Not -Match "Join-Path \`$RepoRoot 'graphify-out' 'doc-candidates'"
        }

    }

    Context 'the additive contract' {
        It 'tells the drafter to add rather than rewrite, and requires the result to grow' {
            $script = Get-Content -LiteralPath $script:ScriptUnderTest -Raw

            $script | Should -Match 'You ADD missing entries'
            $script | Should -Match 'must be LONGER than the input'
            $script | Should -Match 'Change NOTHING ELSE'
        }

        It 'never asks the drafter to remove a file reference, because absent facts are not a deleted file' {
            $content = Get-Content -LiteralPath $script:ScriptUnderTest -Raw -Encoding utf8

            $content | Should -Match 'Leave every file name on the page exactly as it is'
            $content | Should -Match 'absence proves nothing'
            $content | Should -Not -Match 'because that file no\s+longer exists'
        }

        It 'takes the shared rules from the module rather than keeping its own copy' {
            $content = Get-Content -LiteralPath $script:ScriptUnderTest -Raw -Encoding utf8

            $content | Should -Match "Import-Module \(Join-Path \`$PSScriptRoot '\.\.' '\.\.' 'dotnet-gates' 'scripts' 'DocSurface\.psm1'\)"
            $content | Should -Not -Match 'function Test-ServiceShaped'
            $content | Should -Not -Match 'function Get-PublicTypeName'
        }

        It 'asks only a page that documents a project to list that project services' {
            $content = Get-Content -LiteralPath $script:ScriptUnderTest -Raw -Encoding utf8

            $content | Should -Match 'ServiceCheckFolder = Get-ProjectPageFolder'
            $content | Should -Match 'Resolve-DocumentedProject'
            $content.IndexOf('$documentsAProject') | Should -BeGreaterThan -1
            $content.IndexOf('Resolve-DocumentedProject -DocPath') | Should -BeGreaterThan -1
            $content.IndexOf('$documentsAProject') | Should -BeLessThan $content.IndexOf('Resolve-DocumentedProject -DocPath')

            Import-Module (Join-Path $PSScriptRoot '..' '..' 'dotnet-gates' 'scripts' 'DocSurface.psm1') -Force
            $root = New-Repo -Files @{ 'Demo/src/Shared.Thing/A.cs' = 'public class A { }' }
            ((Get-ProjectPageFolder -RepoRoot $root) -join ',') | Should -Be 'docs/libraries/,docs/handlers/'
        }

        It 'forbids the row that carries no fact, which once filled 467 lines of documentation' {
            $content = Get-Content -LiteralPath $script:ScriptUnderTest -Raw -Encoding utf8

            $content | Should -Match 'NEVER write that something is'
            $content | Should -Match 'name and the path'
            $content | Should -Not -Match 'add\s+the entry and write that it is not described'
        }

        It 'guards the word count strictly, because the first design silently gutted pages' {
            $script = Get-Content -LiteralPath $script:ScriptUnderTest -Raw

            $script | Should -Match '\$MinimumWordsKeptPercent = 98'
            $script | Should -Match '1902 words\s*\r?\n?\s*(#\s*)?to 333|from 1902 words'
        }

        It 'refuses on a dropped heading as well as on lost words' {
            $script = Get-Content -LiteralPath $script:ScriptUnderTest -Raw

            $script | Should -Match 'lostHeadings'
            $script | Should -Match 'dropped \$\(\$lostHeadings\.Count\) heading'
        }
    }

    Context 'the repository boundary' {
        It 'refuses a page that resolves outside the repository, before it reads anything' {
            $root = New-Repo -Files @{ 'docs/p.md' = '# P' }

            $r = Invoke-Update -ScriptArgs @{ DocPath = '../../../etc/passwd'; RepoRoot = $root; DryRun = $true }

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'resolves outside the repository'
        }

        It 'refuses before it needs a graph, so the boundary does not depend on what was indexed' {
            $root = New-Repo -Files @{ 'docs/p.md' = '# P' }

            $r = Invoke-Update -ScriptArgs @{ DocPath = '../outside.md'; RepoRoot = $root; GraphPath = (Join-Path $root 'no-such-graph.json'); DryRun = $true }

            $r.Output | Should -Match 'resolves outside the repository'
            $r.Output | Should -Not -Match 'No graph at'
        }
    }

    Context 'bad input' {
        It 'fails when the page does not exist' {
            $root = New-Repo -Files @{ 'docs/other.md' = '# Other' }

            $r = Invoke-Update -ScriptArgs @{ DocPath = 'docs/missing.md'; RepoRoot = $root }

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'No page at'
        }

        It 'fails when the graph records no sources for the page' {
            $root = New-Repo -Files @{ 'docs/p.md' = '# Policy' }
            $graph = Join-Path $root 'graph.json'
            [ordered]@{ nodes = @(); links = @() } | ConvertTo-Json | Set-Content -LiteralPath $graph -Encoding utf8

            $r = Invoke-Update -ScriptArgs @{ DocPath = 'docs/p.md'; RepoRoot = $root; GraphPath = $graph }

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'no source files'
        }
    }
}
