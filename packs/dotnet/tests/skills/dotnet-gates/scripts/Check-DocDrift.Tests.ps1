#requires -Version 7.4

Describe 'Check-DocDrift' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Check-DocDrift.ps1'

        $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
        if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
        Import-Module (Join-Path $aiSdlcGates 'DocToolTestHarness.psm1') -Force

        function New-Repo {
            param([hashtable]$Files)
            $root = New-DocToolRepo -Files $Files -Prefix 'ddr' -InitialiseGit
            Set-AiSdlcTestConfig -Root $root -Paths @{ sourceDocMap = @(@{ source = 'Demo/src/Shared.'; docs = @('docs/libraries/') }, @{ source = 'Demo/src/Workers.'; docs = @('docs/handlers/') }) }
            git -C $root commit -qam 'project families' *> $null
            return $root
        }

        function Invoke-Drift {
            param([hashtable]$ScriptArgs)
            $out = & $script:ScriptUnderTest @ScriptArgs *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }
    }

    AfterAll {
        Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'ddr-*' -Directory -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'reports a public member the page never names' {
        $root = New-Repo -Files @{
            'src/Policy.cs' = 'public static class Policy { public const string Alpha = "a"; public const string Beta = "b"; }'
            'docs/p.md'     = "# Policy`n`nOnly ``Alpha`` is documented here. See ``Policy.cs``."
        }

        $r = Invoke-Drift -ScriptArgs @{ RepoRoot = $root }

        $r.Output | Should -Match '\[missing\].*Beta'
        $r.Output | Should -Not -Match '\[missing\].*Alpha'
    }

    It 'reports a file the page names that no longer exists' {
        $root = New-Repo -Files @{
            'src/Policy.cs' = 'public static class Policy { }'
            'docs/p.md'     = "# Policy`n`nSee ``Policy.cs`` and the old ``Removed.cs``."
        }

        $r = Invoke-Drift -ScriptArgs @{ RepoRoot = $root }

        $r.Output | Should -Match '\[stale\].*Removed\.cs'
    }

    It 'does not invent a dead .cs file out of a .css or .csproj name' {
        $root = New-Repo -Files @{
            'src/Policy.cs' = 'public static class Policy { public const string Alpha = "a"; }'
            'docs/p.md'     = "# Policy`n`n``Alpha`` lives in ``Policy.cs``. Styled by ``theme.css``, built by ``Portal.Demo.csproj``."
        }

        $r = Invoke-Drift -ScriptArgs @{ RepoRoot = $root }

        $r.Output | Should -Not -Match 'theme\.cs\b'
        $r.Output | Should -Not -Match 'Demo\.cs\b'
        $r.Output | Should -Match 'No drift found'
    }

    It 'reads a multi-part file name whole, so a real file is not reported as gone' {
        $root = New-Repo -Files @{
            'src/Thing.razor.cs'   = 'public partial class Thing {}'
            'tools/Run.Tests.ps1'  = 'Describe "x" {}'
            'docs/p.md'            = "# Thing`n`nSee ``Thing.razor.cs`` and ``Run.Tests.ps1``."
        }

        $r = Invoke-Drift -ScriptArgs @{ RepoRoot = $root }

        $r.Output | Should -Not -Match '\[stale\]'
    }

    It 'does not read a file name out of a fenced code block, which is sample code' {
        $page = @(
            '# P'
            ''
            '```bicep'
            "module webAppModule 'webApp.bicep' = {"
            '}'
            '```'
            ''
            'See ``Real.cs``.'
        ) -join [Environment]::NewLine
        $root = New-Repo -Files @{
            'src/Real.cs' = 'public class Real { }'
            'docs/p.md'   = $page
        }

        $r = Invoke-Drift -ScriptArgs @{ RepoRoot = $root }

        $r.Output | Should -Not -Match 'webApp\.bicep'
        $r.Output | Should -Match 'No drift found'
    }

    It 'does not chase a placeholder name used to illustrate a rule' {
        $root = New-Repo -Files @{
            'src/Real.cs' = 'public class Real { }'
            'docs/p.md'   = "# P`n`nA scoped stylesheet ``Foo.razor.css`` only reaches ``Foo.razor``. See ``Real.cs``."
        }

        $r = Invoke-Drift -ScriptArgs @{ RepoRoot = $root }

        $r.Output | Should -Not -Match 'Foo\.razor'
        $r.Output | Should -Match 'No drift found'
    }

    It 'asks only the pages that document a project to name its services' {
        $files = @{
            'docs/api/thing.md'       = "# Thing`n`nSee ``AlphaService.cs`` and ``GammaService.cs``."
            'docs/libraries/thing.md' = "# Thing`n`nSee ``AlphaService.cs`` and ``GammaService.cs``."
        }
        foreach ($n in @('AlphaService', 'GammaService', 'BetaService')) {
            $files["Demo/src/Shared.Thing/Services/$n.cs"] = "namespace X;`npublic class $n`n{`n}"
        }
        $root = New-Repo -Files $files

        $r = Invoke-Drift -ScriptArgs @{ RepoRoot = $root }

        $r.Output | Should -Match '(?s)docs/libraries/thing\.md.*?\[service\].*?BetaService'
        $r.Output | Should -Not -Match '(?s)docs/api/thing\.md.*?\[service\]'
    }

    It 'checks a library page against the library it is named for, not the one it cites most' {
        $files = @{
            'Demo/src/Shared.Thing/Services/BetaService.cs'  = "namespace X;`npublic class BetaService`n{`n}"
            'Demo/src/Shared.Other/Services/OtherService.cs' = "namespace X;`npublic class OtherService`n{`n}"
            'Demo/src/Shared.Other/Services/MoreService.cs'  = "namespace X;`npublic class MoreService`n{`n}"
            'Demo/src/Shared.Other/Services/LastService.cs'  = "namespace X;`npublic class LastService`n{`n}"
            'docs/libraries/thing.md'                             = "# Thing`n`nIt talks to ``OtherService.cs``, ``MoreService.cs`` and ``LastService.cs``."
            'docs/libraries/other.md'                             = "# Other`n`nSee ``OtherService.cs``, ``MoreService.cs`` and ``LastService.cs``."
        }
        $root = New-Repo -Files $files

        $r = Invoke-Drift -ScriptArgs @{ RepoRoot = $root }

        $r.Output | Should -Match '(?s)docs/libraries/thing\.md.*?\[service\].*?BetaService'
        $r.Output | Should -Not -Match '(?s)docs/libraries/thing\.md.*?\[service\].*?OtherService'
    }

    It 'does not send a handler page to the library of the same name' {
        $root = New-Repo -Files @{
            'Demo/src/Shared.Ledger/Services/LibraryOnlyService.cs'      = "namespace X;`npublic class LibraryOnlyService`n{`n}"
            'Demo/src/Workers.LedgerHandler/Services/AlphaService.cs' = "namespace X;`npublic class AlphaService`n{`n}"
            'Demo/src/Workers.LedgerHandler/Services/BetaService.cs'  = "namespace X;`npublic class BetaService`n{`n}"
            'docs/libraries/ledger.md'                                        = "# Ledger library`n`nSee ``LibraryOnlyService.cs``."
            'docs/handlers/ledger.md'                                         = "# Ledger handler`n`nSee ``AlphaService.cs`` and ``BetaService.cs``."
        }

        $r = Invoke-Drift -ScriptArgs @{ RepoRoot = $root }

        $r.Output | Should -Not -Match '(?s)docs/handlers/ledger\.md.*?LibraryOnlyService'
        $r.Output | Should -Not -Match 'no page that documents them'
    }

    It 'says which projects no page documents, so a clean service run is not read as full coverage' {
        $root = New-Repo -Files @{
            'Demo/src/Shared.Thing/Services/AlphaService.cs'   = "namespace X;`npublic class AlphaService`n{`n}"
            'Demo/src/Shared.Unseen/Services/HiddenService.cs' = "namespace X;`npublic class HiddenService`n{`n}"
            'docs/libraries/thing.md'                               = "# Thing`n`nSee ``AlphaService.cs``."
        }

        $r = Invoke-Drift -ScriptArgs @{ RepoRoot = $root }

        $r.Output | Should -Match 'no page that documents them'
        $r.Output | Should -Match 'Shared.Unseen'
    }

    It 'counts the routes it read, so the coverage block cannot claim routes are unchecked' {
        $root = New-Repo -Files @{
            'Demo/src/Api.Demo/Controllers/ThingController.cs' = 'namespace X; [Route("things")] public class ThingController { }'
            'docs/api/thing.md'                                    = "# Thing API`n`n### GET /things - list`n`n### POST /things - create"
        }

        $r = Invoke-Drift -ScriptArgs @{ RepoRoot = $root }

        $r.Output | Should -Match 'API routes\s+: 2 documented route'
        $r.Output | Should -Not -Match 'behaviour, routes, config keys'
    }

    It 'reports an identifier the page names that exists nowhere' {
        $page = @(
                '# Thing'
                ''
                'Call `AddThingServices()` to wire `AlphaService` and `GhostRepository`.'
            ) -join [Environment]::NewLine
        $root = New-Repo -Files @{
            'Demo/src/Shared.Thing/Services/AlphaService.cs' = 'namespace X; public class AlphaService { }'
            'docs/libraries/thing.md'                             = $page
        }

        $r = Invoke-Drift -ScriptArgs @{ RepoRoot = $root }

        $r.Output | Should -Match '\[phantom\].*GhostRepository'
        $r.Output | Should -Match '\[phantom\].*AddThingServices'
        $r.Output | Should -Not -Match '\[phantom\].*AlphaService'
    }

    It '<Name>' -ForEach @(
        @{
            Name        = 'accepts a framework type the documentation legitimately names'
            Files       = @{
                'Demo/src/Shared.Thing/Services/AlphaService.cs' = 'namespace X; public class AlphaService { }'
                'docs/libraries/thing.md'                             = (@('# Thing', '', 'It extends `WebApplicationBuilder` and wires `AlphaService`.') -join [Environment]::NewLine)
            }
            Expected    = @('named symbols    : 1 identifier')
            NotExpected = @('\[phantom\]')
        }
        @{
            Name        = 'counts a symbol declared only by a test, since a test is proof it exists'
            Files       = @{
                'Demo/tests/Thing.Tests/FakeAlphaClient.cs' = 'namespace X; public class FakeAlphaClient { }'
                'docs/libraries/thing.md'                     = (@('# Thing', '', 'Tests use `FakeAlphaClient`.') -join [Environment]::NewLine)
            }
            Expected    = @('named symbols    : 1 identifier')
            NotExpected = @('\[phantom\]')
        }
        @{
            Name        = 'reads only backticked identifiers, so ordinary prose is not a reference'
            Files       = @{
                'Demo/src/Shared.Thing/Services/AlphaService.cs' = 'namespace X; public class AlphaService { }'
                'docs/libraries/thing.md'                             = (@('# Thing', '', 'The GhostService idea was rejected; we wire `AlphaService` instead.') -join [Environment]::NewLine)
            }
            Expected    = @('named symbols    : 1 identifier')
            NotExpected = @('GhostService')
        }
    ) {
        $root = New-Repo -Files $Files

        $r = Invoke-Drift -ScriptArgs @{ RepoRoot = $root }

        (@($Expected).Count + @($NotExpected).Count) | Should -BeGreaterThan 0
        foreach ($pattern in $Expected) { $r.Output | Should -Match $pattern }
        foreach ($pattern in $NotExpected) { $r.Output | Should -Not -Match $pattern }
    }

    It 'never calls an ADR wrong for naming a type that has since been renamed' {
        $page = @(
                '# ADR 0001'
                ''
                'We chose `OldNameService` at the time. It lives beside `AlphaService.cs`.'
            ) -join [Environment]::NewLine
        $root = New-Repo -Files @{
            'Demo/src/Shared.Thing/Services/AlphaService.cs' = 'namespace X; public class AlphaService { }'
            'docs/adrs/0001-a-decision.md'                        = $page
        }

        $r = Invoke-Drift -ScriptArgs @{ RepoRoot = $root }

        $r.Output | Should -Not -Match '\[phantom\]'
    }

    It '<Name>' -ForEach @(
        @{
            Name        = 'reports a documented endpoint that no controller carries'
            Files       = @{
                'Demo/src/Api.Demo/Controllers/ThingController.cs' = 'namespace X; [Route("things")] public class ThingController { }'
                'docs/api/thing.md'                                    = "# Thing API`n`n### `GET /things` - list`n`n### `GET /things/unread-count` - phantom"
            }
            Expected    = @('\[route\].*unread-count')
            NotExpected = @('\[route\].*GET /things$')
        }
        @{
            Name        = 'accepts a route mapped without a controller, which a controller-only corpus called phantom'
            Files       = @{
                'Demo/src/Shared.Demo/Framework/ThingEndpoints.cs' = 'namespace X; public static class ThingEndpoints { public const string DrainPath = "/thing/drain"; }'
                'docs/api/thing.md'                                       = "# Thing API`n`n### `GET /thing/drain` - drain"
            }
            Expected    = @()
            NotExpected = @('\[route\]')
        }
        @{
            Name        = 'still reports a route whose segment appears only in a file that carries no route'
            Files       = @{
                'Demo/src/Api.Demo/Controllers/ThingController.cs' = 'namespace X; [Route("things")] public class ThingController { }'
                'Demo/src/Shared.Thing/Services/AlphaService.cs'  = 'namespace X; public class AlphaService { const string Note = "drain-queue"; }'
                'docs/api/thing.md'                                    = "# Thing API`n`n### `GET /things/drain-queue` - phantom"
            }
            Expected    = @('\[route\].*drain-queue')
            NotExpected = @()
        }
        @{
            Name        = 'leaves a page alone once it says the endpoint was removed'
            Files       = @{
                'Demo/src/Api.Demo/Controllers/ThingController.cs' = 'namespace X; [Route("things")] public class ThingController { }'
                'docs/api/gone.md'                                     = "# Gone API`n`n> **Removed.** The controller no longer exists.`n`n### `POST /vanished/refresh-all` - what it did"
            }
            Expected    = @()
            NotExpected = @('\[route\]')
        }
        @{
            Name        = 'asks about routes only on API pages, since a library page documents no endpoint'
            Files       = @{
                'Demo/src/Api.Demo/Controllers/ThingController.cs' = 'namespace X; [Route("things")] public class ThingController { }'
                'docs/libraries/thing.md'                              = "# Thing`n`nSee `ThingController.cs`. The portal calls `GET /nowhere-at-all` for this."
            }
            Expected    = @()
            NotExpected = @('\[route\]')
        }
    ) {
        $root = New-Repo -Files $Files

        $r = Invoke-Drift -ScriptArgs @{ RepoRoot = $root }

        (@($Expected).Count + @($NotExpected).Count) | Should -BeGreaterThan 0
        foreach ($pattern in $Expected) { $r.Output | Should -Match $pattern }
        foreach ($pattern in $NotExpected) { $r.Output | Should -Not -Match $pattern }
    }

    It 'reports a project page as thin when it names few of the project methods, without calling it drift' {
        $methods = (1..10 | ForEach-Object { "    public void Method$_() { }" }) -join "`n"
        $root = New-Repo -Files @{
            'Demo/src/Shared.Thing/Services/AlphaService.cs' = "namespace X;`npublic class AlphaService`n{`n$methods`n}"
            'docs/libraries/thing.md'                             = "# Thing`n`nSee `AlphaService.cs`. It has `Method1`."
        }

        $r = Invoke-Drift -ScriptArgs @{ RepoRoot = $root }

        $r.Output | Should -Match '\[thin\].*names 1 of 10 public methods'
        $r.Output | Should -Match '0 page\(s\) have drifted.*1 more are thin but not wrong'
    }

    It 'does not carry one page thin counters into the next page' {
        $methods = (1..12 | ForEach-Object { "    public void Method$_() { }" }) -join "`n"
        $root = New-Repo -Files @{
            'Demo/src/Shared.Alpha/Services/AlphaService.cs' = "namespace X;`npublic class AlphaService`n{`n$methods`n}"
            'docs/libraries/alpha.md'                             = "# Alpha`n`nSee ``AlphaService.cs``. It has ``Method1``."
            'Demo/src/Shared.Zeta/ZetaThing.cs'              = "namespace X;`npublic class ZetaThing`n{`n}"
            'docs/libraries/zeta-record.md'                       = "# Zeta`n`nA point-in-time record. See ``ZetaThing.cs``."
        }

        $r = Invoke-Drift -ScriptArgs @{ RepoRoot = $root; RecordPattern = @('zeta-record') }

        $r.Output | Should -Match '\[thin\].*Shared.Alpha'
        $r.Output | Should -Not -Match 'zeta-record'
    }

    It 'does not call a well-covered project page thin' {
        $methods = (1..8 | ForEach-Object { "    public void Method$_() { }" }) -join "`n"
        $named = (1..8 | ForEach-Object { [char]96 + "Method$_" + [char]96 }) -join ', '
        $root = New-Repo -Files @{
            'Demo/src/Shared.Thing/Services/AlphaService.cs' = "namespace X;`npublic class AlphaService`n{`n$methods`n}"
            'docs/libraries/thing.md'                             = "# Thing`n`nSee `AlphaService.cs`: $named."
        }

        $r = Invoke-Drift -ScriptArgs @{ RepoRoot = $root }

        $r.Output | Should -Not -Match '\[thin\]'
    }

    It 'passes a page that names everything the code declares' {
        $root = New-Repo -Files @{
            'src/Policy.cs' = 'public static class Policy { public const string Alpha = "a"; }'
            'docs/p.md'     = "# Policy`n`n``Alpha`` lives in ``Policy.cs``."
        }

        $r = Invoke-Drift -ScriptArgs @{ RepoRoot = $root }

        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'No drift found'
    }

    It 'never reports a missing member on an ADR, because its conclusions are immutable' {
        $root = New-Repo -Files @{
            'src/Policy.cs'       = 'public static class Policy { public const string Alpha = "a"; public const string Beta = "b"; }'
            'docs/adrs/0001-x.md' = "# ADR`n`nAt the time only ``Alpha`` existed. See ``Policy.cs``."
        }

        $r = Invoke-Drift -ScriptArgs @{ RepoRoot = $root }

        $r.Output | Should -Not -Match '\[missing\]'
    }

    It 'leaves a removal record alone about files that are gone, which is what the record says' {
        $root = New-Repo -Files @{
            'Demo/src/Shared.Thing/Services/AlphaService.cs' = 'namespace X; public class AlphaService { }'
            'docs/tools/gone.md'                                  = "# Gone tool`n`n> **Removed.** The tool was deleted in PR 12345.`n`nIt lived in ``GoneTool.cs`` and used ``GoneHelper.cs``."
        }

        $r = Invoke-Drift -ScriptArgs @{ RepoRoot = $root }

        $r.Output | Should -Not -Match '\[stale\]'
    }

    It 'still reports a file that is gone on a page carrying no removal banner' {
        $root = New-Repo -Files @{
            'Demo/src/Shared.Thing/Services/AlphaService.cs' = 'namespace X; public class AlphaService { }'
            'docs/tools/live.md'                                  = "# Live tool`n`nIt lives in ``GoneTool.cs``."
        }

        $r = Invoke-Drift -ScriptArgs @{ RepoRoot = $root }

        $r.Output | Should -Match '\[stale\].*GoneTool\.cs'
    }

    It 'still reports a broken file reference on an ADR, because a rotted pointer is not a conclusion' {
        $root = New-Repo -Files @{
            'src/Policy.cs'       = 'public static class Policy { public const string Alpha = "a"; }'
            'docs/adrs/0001-x.md' = "# ADR`n`nDecided against ``Policy.cs``, replacing ``Gone.cs``."
        }

        $r = Invoke-Drift -ScriptArgs @{ RepoRoot = $root }

        $r.Output | Should -Match '\[stale\].*Gone\.cs'
        $r.Output | Should -Match 'point-in-time records'
    }

    It '<Name>' -ForEach @(
        @{
            Name        = 'reports a service in the documented project that the page never names'
            Files       = @{
                'Demo/src/Shared.Thing/Services/AlphaService.cs' = "namespace X;`npublic class AlphaService`n{`n}"
                'Demo/src/Shared.Thing/Services/GammaService.cs' = "namespace X;`npublic class GammaService`n{`n}"
                'Demo/src/Shared.Thing/Services/BetaService.cs'  = "namespace X;`npublic class BetaService`n{`n}"
                'docs/libraries/thing.md'                             = "# Thing`n`nSee ``AlphaService.cs`` and ``GammaService.cs``."
            }
            Expected    = @('\[service\].*BetaService')
            NotExpected = @('\[service\].*AlphaService')
        }
        @{
            Name        = 'does not call a model a service because its name ends in Provider'
            Files       = @{
                'Demo/src/Shared.Thing/Services/AlphaService.cs'                = "namespace X;`npublic class AlphaService`n{`n}"
                'Demo/src/Shared.Thing/Services/GammaService.cs'                = "namespace X;`npublic class GammaService`n{`n}"
                'Demo/src/Shared.Thing/Common/Models/Azure/ResourceProvider.cs' = "namespace X;`npublic class ResourceProvider(string name)`n{`n}"
                'docs/libraries/thing.md'                                            = "# Thing`n`nSee ``AlphaService.cs`` and ``GammaService.cs``."
            }
            Expected    = @()
            NotExpected = @('ResourceProvider')
        }
        @{
            Name        = 'does not drag another project onto a page over a single passing mention'
            Files       = @{
                'Demo/src/Shared.Thing/Services/AlphaService.cs' = "namespace X;`npublic class AlphaService`n{`n}"
                'Demo/src/Shared.Thing/Services/GammaService.cs' = "namespace X;`npublic class GammaService`n{`n}"
                'Demo/src/Shared.Other/Services/OtherService.cs' = "namespace Y;`npublic class OtherService`n{`n}"
                'docs/libraries/thing.md'                             = "# Thing`n`n``AlphaService.cs``, ``GammaService.cs`` and one mention of ``OtherService.cs``. AlphaService and GammaService do the work."
            }
            Expected    = @()
            NotExpected = @('OtherService')
        }
        @{
            Name        = 'ignores test doubles, which a reference page has no business listing'
            Files       = @{
                'Demo/src/Shared.Thing/Services/AlphaService.cs'      = "namespace X;`npublic class AlphaService`n{`n}"
                'Demo/src/Shared.Thing/Services/MockThingService.cs' = "namespace X;`npublic class MockThingService`n{`n}"
                'docs/libraries/thing.md'                                 = "# Thing`n`nSee ``AlphaService.cs`` and ``MockThingService.cs``. AlphaService does the work."
            }
            Expected    = @()
            NotExpected = @('\[service\].*MockThingService')
        }
    ) {
        $root = New-Repo -Files $Files

        $r = Invoke-Drift -ScriptArgs @{ RepoRoot = $root }

        (@($Expected).Count + @($NotExpected).Count) | Should -BeGreaterThan 0
        foreach ($pattern in $Expected) { $r.Output | Should -Match $pattern }
        foreach ($pattern in $NotExpected) { $r.Output | Should -Not -Match $pattern }
    }

    It 'can be switched off when only the fast signals are wanted' {
        $root = New-Repo -Files @{
            'Demo/src/Shared.Thing/Services/AlphaService.cs' = "namespace X;`npublic class AlphaService`n{`n}"
            'Demo/src/Shared.Thing/Services/BetaService.cs'  = "namespace X;`npublic class BetaService`n{`n}"
            'docs/libraries/thing.md'                             = "# Thing`n`nSee ``AlphaService.cs`` and ``BetaService.cs``."
        }

        $r = Invoke-Drift -ScriptArgs @{ RepoRoot = $root; SkipServiceCheck = $true }

        $r.Output | Should -Not -Match '\[service\]'
    }

    It 'reports how much of the declared surface it actually verifies' {
        $root = New-Repo -Files @{
            'src/Policy.cs' = "public static class Policy`n{`n    public const string Alpha = `"a`";`n    public string Doit()`n    {`n        return `"x`";`n    }`n}"
            'docs/p.md'     = "# Policy`n`n``Alpha`` lives in ``Policy.cs``."
        }

        $r = Invoke-Drift -ScriptArgs @{ RepoRoot = $root }

        $r.Output | Should -Match 'named constants'
        $r.Output | Should -Match 'public methods.*NOT CHECKED'
        $r.Output | Should -Match 'not that the pages are correct'
    }

    It 'does not fail the gate on a thin page alone, because thin is not drift' {
        $methods = (1..12 | ForEach-Object { "    public void Method$_() { }" }) -join "`n"
        $root = New-Repo -Files @{
            'Demo/src/Shared.Thing/Services/AlphaService.cs' = "namespace X;`npublic class AlphaService`n{`n$methods`n}"
            'docs/libraries/thing.md'                             = "# Thing`n`nSee ``AlphaService.cs``. It has ``Method1``."
        }

        $r = Invoke-Drift -ScriptArgs @{ RepoRoot = $root; FailOnDrift = $true }

        $r.Output | Should -Match '\[thin\]'
        $r.Output | Should -Match '0 page\(s\) have drifted'
        $r.ExitCode | Should -Be 0
    }

    It 'stays advisory by default and fails only when asked' {
        $root = New-Repo -Files @{
            'src/Policy.cs' = 'public static class Policy { public const string Beta = "b"; }'
            'docs/p.md'     = "# Policy`n`nSee ``Policy.cs``."
        }

        $advisory = Invoke-Drift -ScriptArgs @{ RepoRoot = $root }
        $gating = Invoke-Drift -ScriptArgs @{ RepoRoot = $root; FailOnDrift = $true }

        $advisory.ExitCode | Should -Be 0
        $gating.ExitCode | Should -Be 1
    }

    It 'needs no code graph, so it runs for everyone on every push' {
        $root = New-Repo -Files @{
            'src/Policy.cs' = 'public static class Policy { public const string Beta = "b"; }'
            'docs/p.md'     = "# Policy`n`nSee ``Policy.cs``."
        }
        Test-Path -LiteralPath (Join-Path $root 'graphify-out') | Should -BeFalse

        $r = Invoke-Drift -ScriptArgs @{ RepoRoot = $root }

        $r.Output | Should -Match '\[missing\].*Beta'
        $r.Output | Should -Not -Match 'graphify-out'
    }

    It 'skips a page whose only citation is an ambiguous file name, rather than guessing' {
        $root = New-Repo -Files @{
            'a/Policy.cs' = 'public static class Policy { public const string Beta = "b"; }'
            'b/Policy.cs' = 'public static class Policy { public const string Gamma = "g"; }'
            'docs/p.md'   = "# Policy`n`nSee ``Policy.cs``."
        }

        $r = Invoke-Drift -ScriptArgs @{ RepoRoot = $root }

        $r.Output | Should -Not -Match '\[missing\]'
    }

    It 'ignores a directory that holds no documentation' {
        $root = New-Repo -Files @{ 'src/Policy.cs' = 'public static class Policy { }' }

        $r = Invoke-Drift -ScriptArgs @{ RepoRoot = $root }

        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'No documentation pages matched'
    }
}
