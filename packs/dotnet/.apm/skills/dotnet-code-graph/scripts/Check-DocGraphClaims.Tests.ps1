#requires -Version 7.4

Describe 'Check-DocGraphClaims' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Check-DocGraphClaims.ps1'

        $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
        if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
        Import-Module (Join-Path $aiSdlcGates 'DocToolTestHarness.psm1') -Force

        function New-Repo {
            param([hashtable]$Files)
            $root = New-DocToolRepo -Files $Files -Prefix 'dgc'
            Set-AiSdlcTestConfig -Root $root -Paths @{ sourceDocMap = @(@{ source = 'Demo/src/Shared.'; docs = @('docs/libraries/') }, @{ source = 'Demo/src/Workers.'; docs = @('docs/handlers/') }) }
            return $root
        }

        function New-Graph {
            param(
                [Parameter(Mandatory)][string]$Root,
                [Parameter(Mandatory)][hashtable]$Nodes,
                [object[]]$Links = @()
            )
            $nodeList = @()
            foreach ($id in $Nodes.Keys) {
                $spec = $Nodes[$id]
                $nodeList += [pscustomobject]@{
                    id              = $id
                    label           = $spec.Label
                    source_file     = $spec.SourceFile
                    _callable_class = $true
                }
            }
            $path = Join-Path $Root 'graph.json'
            [ordered]@{ nodes = $nodeList; links = $Links } | ConvertTo-Json -Depth 8 |
                Set-Content -LiteralPath $path -Encoding utf8
            return $path
        }

        function Invoke-Claims {
            param([hashtable]$ScriptArgs)
            $out = & $script:ScriptUnderTest @ScriptArgs *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }

        function New-Link {
            param([string]$Source, [string]$Target, [string]$Relation = 'calls')
            return [pscustomobject]@{ source = $Source; target = $Target; relation = $Relation }
        }
    }

    AfterAll {
        Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'dgc-*' -Directory -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'says so and exits clean when there is no graph, because this is the optional half' {
        $root = New-Repo -Files @{ 'docs/libraries/thing.md' = '# Thing' }

        $r = Invoke-Claims -ScriptArgs @{ RepoRoot = $root; GraphPath = (Join-Path $root 'absent.json') }

        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'No code graph at'
        $r.Output | Should -Match 'needs no graph'
    }

    It '<Name>' -ForEach @(
        @{
            Name        = 'reports a page linking a project the graph records no edge to'
            Related     = '- [Other handler](../handlers/other.md) - uses this library heavily.'
            Connected   = $false
            Expected    = @('\[unused\].*Workers.OtherHandler')
            NotExpected = @()
        }
        @{
            Name        = 'stays quiet when the two projects really do touch, whichever way the edge points'
            Related     = '- [Other handler](../handlers/other.md) - calls into this library.'
            Connected   = $true
            Expected    = @()
            NotExpected = @('\[unused\]')
        }
        @{
            Name        = 'leaves a page alone when it links a project to say the code never reaches it'
            Related     = '- [Other handler](../handlers/other.md) - reached only through an interface, so there is no direct code path from here.'
            Connected   = $false
            Expected    = @()
            NotExpected = @('\[unused\]')
        }
    ) {
        $page = @(
            '# Thing'
            ''
            'See `AlphaService.cs`.'
            ''
            '## Related'
            ''
            $Related
        ) -join [Environment]::NewLine
        $root = New-Repo -Files @{
            'Demo/src/Shared.Thing/Services/AlphaService.cs' = 'namespace X; public class AlphaService { }'
            'Demo/src/Workers.OtherHandler/Worker.cs'          = 'namespace X; public class Worker { }'
            'docs/libraries/thing.md'                             = $page
            'docs/handlers/other.md'                              = "# Other`n`nSee ``Worker.cs``."
        }
        $links = @(
            [pscustomobject]@{ source = 'doc1'; target = 'svc'; relation = 'documents'; source_file = 'docs/libraries/thing.md' }
            [pscustomobject]@{ source = 'doc2'; target = 'worker'; relation = 'documents'; source_file = 'docs/handlers/other.md' }
            [pscustomobject]@{ source = 'doc2'; target = 'worker'; relation = 'documents'; source_file = 'docs/handlers/other.md' }
        )
        if ($Connected) { $links += (New-Link -Source 'worker' -Target 'svc') }
        $graph = New-Graph -Root $root -Nodes @{
            'svc'    = @{ Label = 'AlphaService'; SourceFile = 'Demo/src/Shared.Thing/Services/AlphaService.cs' }
            'worker' = @{ Label = 'Worker'; SourceFile = 'Demo/src/Workers.OtherHandler/Worker.cs' }
            'doc1'   = @{ Label = 'thing'; SourceFile = 'docs/libraries/thing.md' }
            'doc2'   = @{ Label = 'other'; SourceFile = 'docs/handlers/other.md' }
        } -Links $links

        $r = Invoke-Claims -ScriptArgs @{ RepoRoot = $root; GraphPath = $graph }

        (@($Expected).Count + @($NotExpected).Count) | Should -BeGreaterThan 0
        foreach ($pattern in $Expected) { $r.Output | Should -Match $pattern }
        foreach ($pattern in $NotExpected) { $r.Output | Should -Not -Match $pattern }
    }

    It 'reads a sibling link written without a ./ prefix, which is how five pages here write them' {
        $page = @(
            '# Thing'
            ''
            'See `AlphaService.cs`.'
            ''
            '## Related'
            ''
            '- [Beta library](beta.md) - uses this one heavily.'
        ) -join [Environment]::NewLine
        $root = New-Repo -Files @{
            'Demo/src/Shared.Thing/Services/AlphaService.cs' = 'namespace X; public class AlphaService { }'
            'Demo/src/Shared.Beta/Services/BetaService.cs'   = 'namespace Y; public class BetaService { }'
            'docs/libraries/thing.md'                             = $page
            'docs/libraries/beta.md'                              = "# Beta`n`nSee ``BetaService.cs``."
        }
        $graph = New-Graph -Root $root -Nodes @{
            'alpha' = @{ Label = 'AlphaService'; SourceFile = 'Demo/src/Shared.Thing/Services/AlphaService.cs' }
            'beta'  = @{ Label = 'BetaService'; SourceFile = 'Demo/src/Shared.Beta/Services/BetaService.cs' }
            'doc1'  = @{ Label = 'thing'; SourceFile = 'docs/libraries/thing.md' }
            'doc2'  = @{ Label = 'beta'; SourceFile = 'docs/libraries/beta.md' }
        } -Links @(
            [pscustomobject]@{ source = 'doc1'; target = 'alpha'; relation = 'documents'; source_file = 'docs/libraries/thing.md' }
            [pscustomobject]@{ source = 'doc2'; target = 'beta'; relation = 'documents'; source_file = 'docs/libraries/beta.md' }
            [pscustomobject]@{ source = 'doc2'; target = 'beta'; relation = 'documents'; source_file = 'docs/libraries/beta.md' }
        )

        $r = Invoke-Claims -ScriptArgs @{ RepoRoot = $root; GraphPath = $graph }

        $r.Output | Should -Match '\[unused\].*Shared.Beta'
    }

    It 'reports an implementation the page never names' {
        $page = @(
            '# Thing'
            ''
            'See `IAlphaService.cs`. The only implementation is `AlphaService`.'
        ) -join [Environment]::NewLine
        $root = New-Repo -Files @{
            'Demo/src/Shared.Thing/Contracts/IAlphaService.cs'  = 'namespace X; public interface IAlphaService { }'
            'Demo/src/Shared.Thing/Services/AlphaService.cs'    = 'namespace X; public class AlphaService { }'
            'Demo/src/Shared.Thing/Services/CachingAlphaService.cs' = 'namespace X; public class CachingAlphaService { }'
            'docs/libraries/thing.md'                                = $page
        }
        $graph = New-Graph -Root $root -Nodes @{
            'iface' = @{ Label = 'IAlphaService'; SourceFile = 'Demo/src/Shared.Thing/Contracts/IAlphaService.cs' }
            'one'   = @{ Label = 'AlphaService'; SourceFile = 'Demo/src/Shared.Thing/Services/AlphaService.cs' }
            'two'   = @{ Label = 'CachingAlphaService'; SourceFile = 'Demo/src/Shared.Thing/Services/CachingAlphaService.cs' }
        } -Links @(
            (New-Link -Source 'one' -Target 'iface' -Relation 'implements')
            (New-Link -Source 'two' -Target 'iface' -Relation 'implements')
        )

        $r = Invoke-Claims -ScriptArgs @{ RepoRoot = $root; GraphPath = $graph }

        $r.Output | Should -Match '\[impl\].*CachingAlphaService'
        $r.Output | Should -Not -Match '\[impl\].*implemented here by AlphaService'
        $r.Output | Should -Match 'declared in Shared.Thing'
    }

    It 'does not fail on an informational finding alone, because a page may link selectively' {
        $root = New-Repo -Files @{
            'Demo/src/Shared.Thing/Services/AlphaService.cs' = 'namespace X; public class AlphaService { }'
            'Demo/src/Workers.OtherHandler/Worker.cs'          = 'namespace X; public class Worker { }'
            'docs/libraries/thing.md'                             = "# Thing`n`nSee ``AlphaService.cs``."
            'docs/handlers/other.md'                              = "# Other`n`nSee ``Worker.cs``."
        }
        $graph = New-Graph -Root $root -Nodes @{
            'svc'    = @{ Label = 'AlphaService'; SourceFile = 'Demo/src/Shared.Thing/Services/AlphaService.cs' }
            'worker' = @{ Label = 'Worker'; SourceFile = 'Demo/src/Workers.OtherHandler/Worker.cs' }
            'doc1'   = @{ Label = 'thing'; SourceFile = 'docs/libraries/thing.md' }
            'doc2'   = @{ Label = 'other'; SourceFile = 'docs/handlers/other.md' }
        } -Links @(
            [pscustomobject]@{ source = 'doc1'; target = 'svc'; relation = 'documents'; source_file = 'docs/libraries/thing.md' }
            [pscustomobject]@{ source = 'doc2'; target = 'worker'; relation = 'documents'; source_file = 'docs/handlers/other.md' }
            [pscustomobject]@{ source = 'doc2'; target = 'worker'; relation = 'documents'; source_file = 'docs/handlers/other.md' }
            (New-Link -Source 'worker' -Target 'svc')
        )

        $r = Invoke-Claims -ScriptArgs @{ RepoRoot = $root; GraphPath = $graph; FailOnFinding = $true }

        $r.Output | Should -Match '\[unlisted\]'
        $r.Output | Should -Match '0 contradicted outright'
        $r.ExitCode | Should -Be 0
    }

    Context 'a graph older than the working tree' {
        BeforeAll {
            function New-GitGraphRepo {
                param([ValidateSet('Fresh', 'CommitDiffers', 'DirtySource')][string]$State)

                $root = New-DocToolRepo -Prefix 'dgc' -InitialiseGit -Files @{
                    'Demo/src/Shared.Thing/Services/AlphaService.cs' = 'namespace X; public class AlphaService { }'
                    'docs/libraries/thing.md'                        = "# Thing`n`nSee ``AlphaService.cs``."
                }
                $builtAt = [string](git -C $root rev-parse HEAD)
                $source = Join-Path $root 'Demo/src/Shared.Thing/Services/AlphaService.cs'
                if ($State -ne 'Fresh') {
                    Set-Content -LiteralPath $source -Value 'namespace X; public class AlphaService { void B() { } }' -Encoding utf8
                }
                if ($State -eq 'CommitDiffers') {
                    git -C $root add -A *> $null
                    git -C $root commit -m change --quiet *> $null
                }
                $graphFile = Join-Path $root 'graphify-out' 'graph.json'
                New-Item -ItemType Directory -Path (Split-Path $graphFile -Parent) -Force | Out-Null
                [ordered]@{
                    nodes           = @([pscustomobject]@{ id = 'svc'; label = 'AlphaService'; source_file = 'Demo/src/Shared.Thing/Services/AlphaService.cs' })
                    links           = @()
                    built_at_commit = $builtAt
                } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $graphFile -Encoding utf8
                return [pscustomobject]@{ Root = $root; Graph = $graphFile }
            }
        }

        It 'gives no warning when the graph was built at HEAD and nothing changed since' {
            $repo = New-GitGraphRepo -State Fresh

            $r = Invoke-Claims -ScriptArgs @{ RepoRoot = $repo.Root; GraphPath = $repo.Graph }

            $r.Output | Should -Not -Match 'older than the working tree'
            $r.ExitCode | Should -Be 0
        }

        It 'warns when a commit since the build changed a file the graph covers, and keeps the exit code' {
            $repo = New-GitGraphRepo -State CommitDiffers

            $r = Invoke-Claims -ScriptArgs @{ RepoRoot = $repo.Root; GraphPath = $repo.Graph; FailOnFinding = $true }

            $r.Output | Should -Match 'older than the working tree'
            $r.Output | Should -Match 'Invoke-DocGraphLink\.ps1'
            $r.ExitCode | Should -Be 0
        }

        It 'warns when the source tree has an edit that is not committed, and keeps the exit code' {
            $repo = New-GitGraphRepo -State DirtySource

            $r = Invoke-Claims -ScriptArgs @{ RepoRoot = $repo.Root; GraphPath = $repo.Graph; FailOnFinding = $true }

            $r.Output | Should -Match 'older than the working tree'
            $r.ExitCode | Should -Be 0
        }
    }

    It 'fails on request, so it can be registered as a gate' {
        $page = @(
            '# Thing'
            ''
            'See `IAlphaService.cs`.'
        ) -join [Environment]::NewLine
        $root = New-Repo -Files @{
            'Demo/src/Shared.Thing/Contracts/IAlphaService.cs' = 'namespace X; public interface IAlphaService { }'
            'Demo/src/Shared.Thing/Services/AlphaService.cs'   = 'namespace X; public class AlphaService { }'
            'docs/libraries/thing.md'                               = $page
        }
        $graph = New-Graph -Root $root -Nodes @{
            'iface' = @{ Label = 'IAlphaService'; SourceFile = 'Demo/src/Shared.Thing/Contracts/IAlphaService.cs' }
            'one'   = @{ Label = 'AlphaService'; SourceFile = 'Demo/src/Shared.Thing/Services/AlphaService.cs' }
        } -Links @((New-Link -Source 'one' -Target 'iface' -Relation 'implements'))

        $r = Invoke-Claims -ScriptArgs @{ RepoRoot = $root; GraphPath = $graph; FailOnFinding = $true }

        $r.ExitCode | Should -Be 1
    }
}
