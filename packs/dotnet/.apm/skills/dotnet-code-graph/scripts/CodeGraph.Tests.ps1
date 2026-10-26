#requires -Version 7.4

Describe 'CodeGraph' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'CodeGraph.psm1') -Force

        function New-Graph {
            param([Parameter(Mandatory)][hashtable]$Nodes, [object[]]$Links = @())

            $nodeList = @()
            foreach ($id in $Nodes.Keys) {
                $spec = $Nodes[$id]
                $node = [ordered]@{
                    id          = $id
                    label       = $spec.Label
                    source_file = $spec.SourceFile
                }
                if ($spec.ContainsKey('Callable')) { $node['_callable'] = $spec.Callable }
                if ($spec.ContainsKey('CallableClass')) { $node['_callable_class'] = $spec.CallableClass }
                $nodeList += [pscustomobject]$node
            }

            $folder = Join-Path ([System.IO.Path]::GetTempPath()) ("cg-" + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $folder 'aisdlc.json') -Value '{ "paths": { "sourceRoot": "Demo/src" } }' -Encoding utf8
            $path = Join-Path $folder 'graph.json'
            [ordered]@{ nodes = $nodeList; links = $Links } | ConvertTo-Json -Depth 8 |
                Set-Content -LiteralPath $path -Encoding utf8
            return $path
        }

        function New-Link {
            param([string]$Source, [string]$Target, [string]$Relation = 'calls')
            return [pscustomobject]@{ source = $Source; target = $Target; relation = $Relation }
        }
    }

    AfterAll {
        Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'cg-*' -Directory -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Module CodeGraph -Force -ErrorAction SilentlyContinue
    }

    Context 'the freshness of the graph' {
        BeforeAll {
            $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
            if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
            Import-Module (Join-Path $aiSdlcGates 'DocToolTestHarness.psm1') -Force

            function New-CodeRepo {
                param([hashtable]$Files = @{ 'Demo/src/Shared.Thing/A.cs' = 'public class A { }' })
                return New-DocToolRepo -Prefix 'cgf' -InitialiseGit -Files $Files
            }

            function Get-Head {
                param([string]$Root)
                return [string](git -C $Root rev-parse HEAD)
            }
        }

        It 'reports Current when no file the graph covers has changed' {
            # Arrange
            $root = New-CodeRepo

            # Act
            $verdict = Get-GraphFreshness -BuiltAtCommit (Get-Head -Root $root) -RepoRoot $root -CoveredExtension @('.cs')

            # Assert
            $verdict.State | Should -Be 'Current'
        }

        It 'reports Stale when a covered file is edited but not yet committed' {
            # Arrange
            $root = New-CodeRepo
            $head = Get-Head -Root $root
            Set-Content -LiteralPath (Join-Path $root 'Demo/src/Shared.Thing/A.cs') -Value 'public class A { void B() { } }' -Encoding utf8

            # Act
            $verdict = Get-GraphFreshness -BuiltAtCommit $head -RepoRoot $root -CoveredExtension @('.cs')

            # Assert
            $verdict.State | Should -Be 'Stale'
            @($verdict.ChangedFiles) | Should -Contain 'Demo/src/Shared.Thing/A.cs'
        }

        It 'reports Stale when a covered file arrives in a later commit' {
            # Arrange
            $root = New-CodeRepo
            $head = Get-Head -Root $root
            Set-Content -LiteralPath (Join-Path $root 'Demo/src/Shared.Thing/B.cs') -Value 'public class B { }' -Encoding utf8
            git -C $root add -A *> $null
            git -C $root commit -m second --quiet *> $null

            # Act
            $verdict = Get-GraphFreshness -BuiltAtCommit $head -RepoRoot $root -CoveredExtension @('.cs')

            # Assert
            $verdict.State | Should -Be 'Stale'
            @($verdict.ChangedFiles) | Should -Contain 'Demo/src/Shared.Thing/B.cs'
        }

        It 'stays Current when the commit moved but only a file type the graph does not hold changed' {
            # Arrange
            $root = New-CodeRepo
            $head = Get-Head -Root $root
            Set-Content -LiteralPath (Join-Path $root 'notes.txt') -Value 'a release note' -Encoding utf8
            git -C $root add -A *> $null
            git -C $root commit -m note --quiet *> $null

            # Act
            $verdict = Get-GraphFreshness -BuiltAtCommit $head -RepoRoot $root -CoveredExtension @('.cs')

            # Assert
            $verdict.State | Should -Be 'Current'
            $verdict.HeadCommit | Should -Not -Be $head
        }

        It 'counts an untracked covered file, which no diff against a commit would see' {
            # Arrange
            $root = New-CodeRepo
            $head = Get-Head -Root $root
            Set-Content -LiteralPath (Join-Path $root 'Demo/src/Shared.Thing/C.cs') -Value 'public class C { }' -Encoding utf8

            # Act
            $verdict = Get-GraphFreshness -BuiltAtCommit $head -RepoRoot $root -CoveredExtension @('.cs')

            # Assert
            $verdict.State | Should -Be 'Stale'
            @($verdict.ChangedFiles) | Should -Contain 'Demo/src/Shared.Thing/C.cs'
        }

        It 'reports Unknown, not Current, when the graph records no build commit' {
            # Arrange
            $root = New-CodeRepo

            # Act
            $verdict = Get-GraphFreshness -BuiltAtCommit '' -RepoRoot $root -CoveredExtension @('.cs')

            # Assert
            $verdict.State | Should -Be 'Unknown'
            $verdict.Reason | Should -Match 'no build commit'
        }

        It 'reports Unknown when the commit it was built at is gone, which a rebase does' {
            # Arrange
            $root = New-CodeRepo

            # Act
            $verdict = Get-GraphFreshness -BuiltAtCommit ('0' * 40) -RepoRoot $root -CoveredExtension @('.cs')

            # Assert
            $verdict.State | Should -Be 'Unknown'
            $verdict.Reason | Should -Match 'no longer in this repository'
        }

        It 'reports Unknown outside a git repository rather than guessing' {
            # Arrange
            $outside = Join-Path ([System.IO.Path]::GetTempPath()) ('cgf-nogit-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $outside -Force | Out-Null

            # Act
            $verdict = Get-GraphFreshness -BuiltAtCommit ('a' * 40) -RepoRoot $outside -CoveredExtension @('.cs')

            # Assert
            $verdict.State | Should -Be 'Unknown'
        }

        It 'carries the verdict on the index, so every caller has it without asking' {
            # Arrange
            $root = New-CodeRepo
            $graphFile = Join-Path $root 'graphify-out/graph.json'
            New-Item -ItemType Directory -Path (Split-Path $graphFile -Parent) -Force | Out-Null
            [ordered]@{
                nodes            = @([pscustomobject]@{ id = 'a'; label = 'A'; source_file = 'Demo/src/Shared.Thing/A.cs' })
                links            = @()
                built_at_commit  = (Get-Head -Root $root)
            } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $graphFile -Encoding utf8

            # Act
            $index = Get-GraphIndex -GraphPath $graphFile

            # Assert
            $index.Freshness.State | Should -Be 'Current'
        }

        It 'warns on a stale graph, and says nothing when asked to be quiet' {
            # Arrange
            $root = New-CodeRepo
            $graphFile = Join-Path $root 'graphify-out/graph.json'
            New-Item -ItemType Directory -Path (Split-Path $graphFile -Parent) -Force | Out-Null
            [ordered]@{
                nodes            = @([pscustomobject]@{ id = 'a'; label = 'A'; source_file = 'Demo/src/Shared.Thing/A.cs' })
                links            = @()
                built_at_commit  = (Get-Head -Root $root)
            } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $graphFile -Encoding utf8
            Set-Content -LiteralPath (Join-Path $root 'Demo/src/Shared.Thing/A.cs') -Value 'public class A { void B() { } }' -Encoding utf8

            # Act
            $loud = (Get-GraphIndex -GraphPath $graphFile 6>&1 | Out-String)
            $quiet = (Get-GraphIndex -GraphPath $graphFile -Quiet 6>&1 | Out-String)

            # Assert
            $loud | Should -Match 'STALE GRAPH'
            $quiet | Should -Not -Match 'STALE GRAPH'
        }
    }

    Context 'loading the graph' {
        It 'refuses a path with no graph, rather than reporting an empty codebase' {
            # Act / Assert
            { Get-GraphIndex -GraphPath (Join-Path ([System.IO.Path]::GetTempPath()) 'no-such-graph.json') } |
                Should -Throw -ExpectedMessage '*No graph at*'
        }

        It 'maps a node to the project its source file sits in' {
            $graph = New-Graph -Nodes @{
                'a' = @{ Label = 'AlphaService'; SourceFile = 'Demo/src/Shared.Thing/Services/AlphaService.cs'; CallableClass = $true }
            }

            $index = Get-GraphIndex -GraphPath $graph

            $index.Projects['a'] | Should -Be 'Shared.Thing'
        }

        It 'ignores a node that came from a project file, which would connect everything to everything' {
            $graph = New-Graph -Nodes @{
                'moniker' = @{ Label = 'net10.0'; SourceFile = 'Demo/src/Shared.Thing/Shared.Thing.csproj' }
            }

            $index = Get-GraphIndex -GraphPath $graph

            $index.Projects.ContainsKey('moniker') | Should -BeFalse
        }
    }

    Context 'who consumes a project' {
        BeforeEach {
            $script:Nodes = @{
                'svc'   = @{ Label = 'AlphaService'; SourceFile = 'Demo/src/Shared.Thing/Services/AlphaService.cs'; CallableClass = $true }
                'iface' = @{ Label = 'IAlphaService'; SourceFile = 'Demo/src/Shared.Thing/Contracts/IAlphaService.cs'; CallableClass = $true }
                'user'  = @{ Label = 'Consumer'; SourceFile = 'Demo/src/Workers.OtherHandler/Consumer.cs'; CallableClass = $true }
                'enum'  = @{ Label = 'Group'; SourceFile = 'Demo/src/Shared.Thing/Models/PrincipalType.cs' }
                'far'   = @{ Label = 'Unrelated'; SourceFile = 'Demo/src/Services.FarAway/Unrelated.cs'; CallableClass = $true }
            }
        }

        It 'reports a caller in another project and what it reaches for' {
            $graph = New-Graph -Nodes $script:Nodes -Links @(New-Link -Source 'user' -Target 'iface')
            $index = Get-GraphIndex -GraphPath $graph

            $consumers = @(Get-ProjectConsumer -Index $index -Project 'Shared.Thing')

            $consumers.Count | Should -Be 1
            $consumers[0].Project | Should -Be 'Workers.OtherHandler'
            $consumers[0].Reaches | Should -Contain 'IAlphaService'
        }

        It 'never counts a project as consuming itself' {
            $graph = New-Graph -Nodes $script:Nodes -Links @(New-Link -Source 'svc' -Target 'iface')
            $index = Get-GraphIndex -GraphPath $graph

            $consumers = @(Get-ProjectConsumer -Index $index -Project 'Shared.Thing')

            $consumers.Count | Should -Be 0
        }

        It 'ignores an edge onto an enum member, which is how a name collision invents a dependency' {
            $graph = New-Graph -Nodes $script:Nodes -Links @(New-Link -Source 'user' -Target 'enum')
            $index = Get-GraphIndex -GraphPath $graph

            $consumers = @(Get-ProjectConsumer -Index $index -Project 'Shared.Thing')

            $consumers.Count | Should -Be 0
        }

        It 'reports what a project calls into, which is the other direction' {
            $graph = New-Graph -Nodes $script:Nodes -Links @(New-Link -Source 'user' -Target 'iface')
            $index = Get-GraphIndex -GraphPath $graph

            $dependencies = @(Get-ProjectDependency -Index $index -Project 'Workers.OtherHandler')

            $dependencies.Count | Should -Be 1
            $dependencies[0].Project | Should -Be 'Shared.Thing'
            $dependencies[0].Uses | Should -Contain 'IAlphaService'
        }

        It 'sees two projects as connected whichever way the edge points' {
            $graph = New-Graph -Nodes $script:Nodes -Links @(New-Link -Source 'user' -Target 'iface')
            $index = Get-GraphIndex -GraphPath $graph

            # Act / Assert
            Test-ProjectsConnected -Index $index -First 'Shared.Thing' -Second 'Workers.OtherHandler' | Should -BeTrue
            Test-ProjectsConnected -Index $index -First 'Workers.OtherHandler' -Second 'Shared.Thing' | Should -BeTrue
        }

        It 'sees no connection between two projects that never touch' {
            $graph = New-Graph -Nodes $script:Nodes -Links @(New-Link -Source 'user' -Target 'iface')
            $index = Get-GraphIndex -GraphPath $graph

            # Act / Assert
            Test-ProjectsConnected -Index $index -First 'Shared.Thing' -Second 'Services.FarAway' | Should -BeFalse
        }
    }

    Context 'what implements what' {
        It 'pairs a contract with every implementation in the project' {
            $nodes = @{
                'iface' = @{ Label = 'INotifier'; SourceFile = 'Demo/src/Shared.Notify/Contracts/INotifier.cs'; CallableClass = $true }
                'one'   = @{ Label = 'SmsNotifier'; SourceFile = 'Demo/src/Shared.Notify/Services/SmsNotifier.cs'; CallableClass = $true }
                'two'   = @{ Label = 'LoggingNotifier'; SourceFile = 'Demo/src/Shared.Notify/Services/LoggingNotifier.cs'; CallableClass = $true }
            }
            $graph = New-Graph -Nodes $nodes -Links @(
                New-Link -Source 'one' -Target 'iface' -Relation 'implements'
                New-Link -Source 'two' -Target 'iface' -Relation 'implements'
            )
            $index = Get-GraphIndex -GraphPath $graph

            $pairs = @(Get-ProjectImplementation -Index $index -Project 'Shared.Notify')

            $pairs.Count | Should -Be 1
            $pairs[0].Contract | Should -Be 'INotifier'
            $pairs[0].Implementations | Should -Be @('LoggingNotifier', 'SmsNotifier')
        }

        It 'drops a contract whose only implementer in the project is a double, rather than pairing it with nothing' {
            $nodes = @{
                'iface' = @{ Label = 'IPaymentGatewayService'; SourceFile = 'Demo/src/Api.Demo/Contracts/IPaymentGatewayService.cs'; CallableClass = $true }
                'mock'  = @{ Label = 'MockPaymentGatewayService'; SourceFile = 'Demo/src/Api.Demo/Services/MockPaymentGatewayService.cs'; CallableClass = $true }
            }
            $graph = New-Graph -Nodes $nodes -Links @(
                New-Link -Source 'mock' -Target 'iface' -Relation 'implements'
            )
            $index = Get-GraphIndex -GraphPath $graph

            $pairs = @(Get-ProjectImplementation -Index $index -Project 'Api.Demo')

            $pairs.Count | Should -Be 0
        }

        It 'leaves test doubles out, since a reference page has no business listing every mock' {
            $nodes = @{
                'iface' = @{ Label = 'IThingActivity'; SourceFile = 'Demo/src/Shared.Flow/Contracts/IThingActivity.cs'; CallableClass = $true }
                'real'  = @{ Label = 'ThingActivity'; SourceFile = 'Demo/src/Shared.Flow/Activities/ThingActivity.cs'; CallableClass = $true }
                'mock'  = @{ Label = 'MockThingActivity'; SourceFile = 'Demo/src/Shared.Flow/Activities/MockThingActivity.cs'; CallableClass = $true }
            }
            $graph = New-Graph -Nodes $nodes -Links @(
                New-Link -Source 'real' -Target 'iface' -Relation 'implements'
                New-Link -Source 'mock' -Target 'iface' -Relation 'implements'
            )
            $index = Get-GraphIndex -GraphPath $graph

            $pairs = @(Get-ProjectImplementation -Index $index -Project 'Shared.Flow')

            $pairs[0].Implementations | Should -Be @('ThingActivity')
        }
    }

    Context 'who calls one type' {
        It 'reports each caller once, with the file it calls from' {
            $nodes = @{
                'svc'  = @{ Label = 'AlphaService'; SourceFile = 'Demo/src/Shared.Thing/Services/AlphaService.cs'; CallableClass = $true }
                'one'  = @{ Label = 'FirstCaller'; SourceFile = 'Demo/src/Api.Demo/One.cs'; CallableClass = $true }
                'two'  = @{ Label = 'SecondCaller'; SourceFile = 'Demo/src/Api.Demo/Two.cs'; CallableClass = $true }
            }
            $graph = New-Graph -Nodes $nodes -Links @(
                New-Link -Source 'one' -Target 'svc'
                New-Link -Source 'one' -Target 'svc' -Relation 'references'
                New-Link -Source 'two' -Target 'svc'
            )
            $index = Get-GraphIndex -GraphPath $graph

            $callers = @(Get-TypeCaller -Index $index -TypeName 'AlphaService')

            $callers.Count | Should -Be 2
            @($callers.Caller) | Should -Contain 'FirstCaller'
            @($callers.Caller) | Should -Contain 'SecondCaller'
        }

        It 'returns nothing for a name the graph does not hold' {
            $graph = New-Graph -Nodes @{ 'a' = @{ Label = 'AlphaService'; SourceFile = 'Demo/src/Shared.Thing/A.cs'; CallableClass = $true } }
            $index = Get-GraphIndex -GraphPath $graph

            $callers = @(Get-TypeCaller -Index $index -TypeName 'NoSuchType')

            $callers.Count | Should -Be 0
        }
    }
}
