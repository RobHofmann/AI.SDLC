#requires -Version 7.4

BeforeAll { $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm' }

Describe 'Check-SpecDrift' {
    BeforeAll {
        $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
        if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' 'tests' 'skills' 'ai-sdlc-gates' 'scripts' }
        Import-Module (Join-Path $aiSdlcGates 'DocToolTestHarness.psm1') -Force
        $script:ScriptUnderTest = Join-Path -Path $script:ScriptFolder -ChildPath 'Check-SpecDrift.ps1'

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

        function Save-Commit {
            param([string]$Message = 'change', [switch]$AsBase)
            if (-not (Test-Path -LiteralPath (Join-Path $script:Root '.git'))) {
                git -C $script:Root init --quiet -b main
                git -C $script:Root config user.email probe@example.invalid
                git -C $script:Root config user.name probe
                git -C $script:Root config core.autocrlf false
            }
            git -C $script:Root add -A
            git -C $script:Root commit --quiet -m $Message --no-verify
            if ($AsBase) { git -C $script:Root update-ref refs/remotes/origin/main HEAD }
        }

        $script:ControllerPath = 'Demo/src/Api.Demo/Controllers/OrderLinesController.cs'
        $script:ControllerText = "[ApiController]`n[Route(`"api/order-lines`")]`npublic class OrderLinesController`n{`n    public void Get() { Log(`"one`"); }`n}`n"
    }

    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        Set-AiSdlcTestConfig -Root $script:Root
        $env:CHANGED_FILES = $null
    }

    Context 'the rule that keeps it safe for code written before specs existed' {
        It 'is not applicable and says so when there is no specs folder at all' -Tag '#46' {
            New-Controller -Relative 'Demo/src/Api.Demo/Controllers/OrderLinesController.cs'

            $r = Invoke-Gate -Changed @('Demo/src/Api.Demo/Controllers/OrderLinesController.cs')

            $r.ExitCode | Should -Be 3
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
        It 'reads CHANGED_FILES from the environment when no list is passed' -Tag '#80' {
            New-Spec
            New-Controller -Relative $script:ControllerPath -Body $script:ControllerText
            Save-Commit -Message base -AsBase
            New-Controller -Relative $script:ControllerPath -Body $script:ControllerText.Replace('/order-lines"', '/order-lines/{id}"')
            Save-Commit
            try {
                $env:CHANGED_FILES = $script:ControllerPath

                $out = & $script:ScriptUnderTest -RepoRoot $script:Root *>&1 | Out-String

                $LASTEXITCODE | Should -Be 1
                $out | Should -Match 'order-lines'
            }
            finally { $env:CHANGED_FILES = $null }
        }

        It 'is not applicable when nothing changed' -Tag '#46' {
            New-Spec

            $r = Invoke-Gate -Changed @()

            $r.ExitCode | Should -Be 3
            $r.Output | Should -Match 'no changed files'
        }
    }

    Context 'it judges only the lines the change adds or removes' {
        It 'passes when the change edits a line of an old controller that is not a route' -Tag '#80' {
            New-Spec
            New-Controller -Relative $script:ControllerPath -Body $script:ControllerText
            Save-Commit -Message base -AsBase
            New-Controller -Relative $script:ControllerPath -Body $script:ControllerText.Replace('Log("one")', 'Log("two")')
            Save-Commit

            $r = Invoke-Gate -RepoRoot $script:Root

            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'Spec drift OK'
        }

        It 'reports a controller whose route line the change edits' -Tag '#80' {
            New-Spec
            New-Controller -Relative $script:ControllerPath -Body $script:ControllerText
            Save-Commit -Message base -AsBase
            New-Controller -Relative $script:ControllerPath -Body $script:ControllerText.Replace('order-lines"', 'order-lines/{id}"')
            Save-Commit

            $r = Invoke-Gate -RepoRoot $script:Root

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match "carries the resource 'order-lines'"
        }

        It 'reports a controller whose route line the change removes' -Tag '#80' {
            New-Spec
            New-Controller -Relative $script:ControllerPath -Body $script:ControllerText
            Save-Commit -Message base -AsBase
            New-Controller -Relative $script:ControllerPath -Body $script:ControllerText.Replace("[Route(`"api/order-lines`")]`n", '')
            Save-Commit

            $r = Invoke-Gate -RepoRoot $script:Root

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match "resource 'order-lines'"
        }

        It 'reports a controller that the change deletes' -Tag '#80' {
            New-Spec
            New-Controller -Relative $script:ControllerPath -Body $script:ControllerText
            Save-Commit -Message base -AsBase
            Remove-Item -LiteralPath (Join-Path $script:Root $script:ControllerPath)
            Save-Commit

            $r = Invoke-Gate -RepoRoot $script:Root

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match "resource 'order-lines'"
        }

        It 'reports a DTO type that the change adds when a spec names it' -Tag '#80' {
            New-Spec
            Set-Content -LiteralPath (Join-Path $script:Root 'specs/order-lines.openapi.yaml') -Value "openapi: 3.0.0`ncomponents:`n  schemas:`n    OrderLineDto:`n      type: object`n" -Encoding utf8
            New-Controller -Relative 'Demo/src/Shared.Demo/Models.cs' -Body "public class Other { }`n"
            Save-Commit -Message base -AsBase
            New-Controller -Relative 'Demo/src/Shared.Demo/Models.cs' -Body "public class Other { }`npublic record OrderLineDto(string Name);`n"
            Save-Commit

            $r = Invoke-Gate -RepoRoot $script:Root

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match "type 'OrderLineDto'"
        }

        It 'passes when the change edits a DTO file but not the declaration of the type the spec names' -Tag '#80' {
            New-Spec
            Set-Content -LiteralPath (Join-Path $script:Root 'specs/order-lines.openapi.yaml') -Value "openapi: 3.0.0`ncomponents:`n  schemas:`n    OrderLineDto:`n      type: object`n" -Encoding utf8
            New-Controller -Relative 'Demo/src/Shared.Demo/Models.cs' -Body "public record OrderLineDto(string Name);`npublic class Other { }`n"
            Save-Commit -Message base -AsBase
            New-Controller -Relative 'Demo/src/Shared.Demo/Models.cs' -Body "public record OrderLineDto(string Name);`npublic class Other { public int Count; }`n"
            Save-Commit

            $r = Invoke-Gate -RepoRoot $script:Root

            $r.ExitCode | Should -Be 0
        }

        It 'passes when the change adds a controller line outside the source root' -Tag '#80' {
            New-Spec
            New-Controller -Relative 'docs/example.cs' -Body $script:ControllerText
            Save-Commit -Message base -AsBase
            New-Controller -Relative 'docs/example.cs' -Body ($script:ControllerText + "`n")
            Save-Commit

            $r = Invoke-Gate -RepoRoot $script:Root

            $r.ExitCode | Should -Be 0
        }

        It 'exits 2 with a FIX line when CHANGED_FILES is set and there is no merge base' -Tag '#80' {
            New-Spec
            New-Controller -Relative $script:ControllerPath -Body $script:ControllerText
            Save-Commit -Message base
            try {
                $env:CHANGED_FILES = $script:ControllerPath

                $out = & $script:ScriptUnderTest -RepoRoot $script:Root *>&1 | Out-String

                $LASTEXITCODE | Should -Be 2
                $out | Should -Match '(?m)^FIX: '
                $out | Should -Not -Match 'carries the resource'
            }
            finally { $env:CHANGED_FILES = $null }
        }

        It 'is not applicable in a local run with no merge base, and does not judge whole files' -Tag '#80' {
            New-Spec
            New-Controller -Relative $script:ControllerPath -Body $script:ControllerText
            Save-Commit -Message base

            $out = & $script:ScriptUnderTest -RepoRoot $script:Root *>&1 | Out-String

            $LASTEXITCODE | Should -Be 3
            $out | Should -Not -Match 'carries the resource'
        }
    }
}
