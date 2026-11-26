#requires -Version 7.4

Describe 'Check-SpecDrift' {
    BeforeAll {
        $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
        if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
        Import-Module (Join-Path $aiSdlcGates 'DocToolTestHarness.psm1') -Force
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Check-SpecDrift.ps1'

        function Invoke-Gate {
            param([string[]]$Changed = @(), [string]$RepoRoot = $script:Root)
            $out = & $script:ScriptUnderTest -RepoRoot $RepoRoot -ChangedFiles $Changed *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }

        function New-Controller {
            param([string]$Relative, [string]$Route = 'api/order-lines', [string]$Body = '')
            $full = Join-Path $script:Root $Relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
            $text = if ($Body) { $Body } else { "[ApiController]`n[Route(`"$Route`")]`npublic class Thing { }" }
            Set-Content -LiteralPath $full -Value $text -Encoding utf8
        }

        function New-Spec {
            param([string]$Name = 'order-lines.openapi.yaml', [string]$Path = '/api/order-lines')
            $dir = Join-Path $script:Root 'specs'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir $Name) -Value "openapi: 3.0.0`npaths:`n  $($Path):`n    get: {}`n" -Encoding utf8
        }
    }

    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        Set-AiSdlcTestConfig -Root $script:Root
        $env:CHANGED_FILES = $null
    }

    Context 'the rule that keeps it safe for code written before specs existed' {
        It 'passes and says so when there is no specs folder at all' {
            New-Controller -Relative 'Demo/src/Api.Demo/Controllers/OrderLinesController.cs'

            $r = Invoke-Gate -Changed @('Demo/src/Api.Demo/Controllers/OrderLinesController.cs')

            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'no specs yet'
        }

        It 'passes for an endpoint no spec describes, even when other specs exist' {
            New-Spec -Name 'dns.openapi.yaml' -Path '/api/dns'
            New-Controller -Relative 'Demo/src/Api.Demo/Controllers/OrderLinesController.cs'

            $r = Invoke-Gate -Changed @('Demo/src/Api.Demo/Controllers/OrderLinesController.cs')

            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'Spec drift OK'
        }
    }

    Context 'when a described endpoint moves' {
        It 'reports the file, the resource and the spec that describes it' {
            New-Spec
            New-Controller -Relative 'Demo/src/Api.Demo/Controllers/OrderLinesController.cs'

            $r = Invoke-Gate -Changed @('Demo/src/Api.Demo/Controllers/OrderLinesController.cs')

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match "carries the resource 'order-lines'"
            $r.Output | Should -Match 'specs/order-lines.openapi.yaml'
        }

        It 'passes when a spec changed in the same diff' {
            New-Spec
            New-Controller -Relative 'Demo/src/Api.Demo/Controllers/OrderLinesController.cs'

            $r = Invoke-Gate -Changed @('Demo/src/Api.Demo/Controllers/OrderLinesController.cs', 'specs/order-lines.openapi.yaml')

            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'spec file\(s\) changed with the code'
        }

        It 'reads the resource from the class name when the route is the controller token' {
            New-Spec
            New-Controller -Relative 'Demo/src/Api.Demo/Controllers/OrderLinesController.cs' -Route 'api/[controller]'

            $r = Invoke-Gate -Changed @('Demo/src/Api.Demo/Controllers/OrderLinesController.cs')

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match "resource 'order-lines'"
        }

        It 'finds a minimal-API endpoint too' {
            New-Spec
            New-Controller -Relative 'Demo/src/Api.Demo/Endpoints/Routes.cs' -Body 'app.MapGet("api/order-lines", handler);'

            $r = Invoke-Gate -Changed @('Demo/src/Api.Demo/Endpoints/Routes.cs')

            $r.ExitCode | Should -Be 1
        }
    }

    Context 'files it does not read' {
        It 'ignores a C# file with no HTTP surface' {
            New-Spec
            New-Controller -Relative 'Demo/src/Shared.Demo/OrderLineService.cs' -Body 'public class OrderLineService { }'

            $r = Invoke-Gate -Changed @('Demo/src/Shared.Demo/OrderLineService.cs')

            $r.ExitCode | Should -Be 0
        }

        It 'ignores a file outside Demo/src' {
            New-Spec
            New-Controller -Relative 'docs/example.cs'

            $r = Invoke-Gate -Changed @('docs/example.cs')

            $r.ExitCode | Should -Be 0
        }

        It 'ignores a deleted file rather than failing on the missing path' {
            New-Spec

            $r = Invoke-Gate -Changed @('Demo/src/Api.Demo/Controllers/GoneController.cs')

            $r.ExitCode | Should -Be 0
        }

        It 'does not match a token that is only part of a longer path in the spec' {
            New-Spec -Name 'dns.openapi.yaml' -Path '/api/order-lines-archive'
            New-Controller -Relative 'Demo/src/Api.Demo/Controllers/OrderLinesController.cs'

            $r = Invoke-Gate -Changed @('Demo/src/Api.Demo/Controllers/OrderLinesController.cs')

            $r.ExitCode | Should -Be 0
        }
    }

    Context 'where the changed list comes from' {
        It 'reads CHANGED_FILES from the environment when no list is passed' {
            New-Spec
            New-Controller -Relative 'Demo/src/Api.Demo/Controllers/OrderLinesController.cs'
            try {
                $env:CHANGED_FILES = "Demo/src/Api.Demo/Controllers/OrderLinesController.cs"

                $out = & $script:ScriptUnderTest -RepoRoot $script:Root *>&1 | Out-String

                $LASTEXITCODE | Should -Be 1
                $out | Should -Match 'order-lines'
            }
            finally { $env:CHANGED_FILES = $null }
        }

        It 'passes when nothing changed' {
            New-Spec

            $r = Invoke-Gate -Changed @()

            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'no changed files'
        }
    }
}
