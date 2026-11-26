#requires -Version 7.4

Describe 'Get-ProjectFacts' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Get-ProjectFacts.ps1'

        $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
        if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
        Import-Module (Join-Path $aiSdlcGates 'DocToolTestHarness.psm1') -Force

        function New-ProjectRepo {
            return New-DocToolRepo -Prefix 'gpf' -Files @{
                'Demo/src/Shared.Thing/Shared.Thing.csproj'           = '<Project Sdk="Microsoft.NET.Sdk"><ItemGroup><ProjectReference Include="..\Shared.Core\Shared.Core.csproj" /><PackageReference Include="Polly" /></ItemGroup></Project>'
                'Demo/src/Shared.Thing/Services/AlphaService.cs'      = "namespace X;`npublic class AlphaService`n{`n    public const string Name = `"a`";`n    public void Run() { }`n    public async Task StopAsync() { }`n}"
                'Demo/src/Shared.Thing/Services/FakeAlphaService.cs'  = "namespace X;`npublic class FakeAlphaService { }"
                'Demo/src/Shared.Thing/obj/Generated.cs'              = "public class Generated { }"
            }
        }
    }

    AfterAll {
        Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'gpf-*' -Directory -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'reads the SDK, the project references and the package references from the project file' {
        $root = New-ProjectRepo

        $text = (& $script:ScriptUnderTest -Unit 'Demo/src/Shared.Thing' -RepoRoot $root) -join "`n"

        $text | Should -Match 'UNIT: Demo/src/Shared.Thing \(project Shared.Thing\)'
        $text | Should -Match 'sdk: Microsoft.NET.Sdk'
        $text | Should -Match 'project references: Shared.Core'
        $text | Should -Match 'package references: Polly'
    }

    It 'lists the public types, methods and named members per file' {
        $root = New-ProjectRepo

        $text = (& $script:ScriptUnderTest -Unit 'Demo/src/Shared.Thing' -RepoRoot $root) -join "`n"

        $text | Should -Match 'FILE: Demo/src/Shared.Thing/Services/AlphaService.cs'
        $text | Should -Match 'public types: AlphaService'
        $text | Should -Match 'public methods: Run, StopAsync'
        $text | Should -Match 'public named members: Name'
    }

    It 'leaves out a constructor, which a model would read as a method named after its type' {
        $root = New-ProjectRepo
        Set-Content -LiteralPath (Join-Path $root 'Demo/src/Shared.Thing/Services/BetaService.cs') -Value "namespace X;`npublic class BetaService`n{`n    public BetaService(int x) { }`n    public void Go() { }`n}"

        $text = (& $script:ScriptUnderTest -Unit 'Demo/src/Shared.Thing' -RepoRoot $root) -join "`n"

        $text | Should -Match 'public methods: Go'
        $text | Should -Not -Match 'public methods: BetaService'
    }

    It 'leaves out test doubles and the generated files under obj' {
        $root = New-ProjectRepo

        $text = (& $script:ScriptUnderTest -Unit 'Demo/src/Shared.Thing' -RepoRoot $root) -join "`n"

        $text | Should -Not -Match 'FakeAlphaService'
        $text | Should -Not -Match 'Generated'
    }

    It 'says the relationships are left out when there is no code graph, so absence is not read as none' {
        $root = New-ProjectRepo

        $text = (& $script:ScriptUnderTest -Unit 'Demo/src/Shared.Thing' -RepoRoot $root) -join "`n"

        $text | Should -Match 'RELATIONSHIPS: not included, because there is no code graph'
    }

    It 'caps the methods listed per file' {
        $root = New-ProjectRepo

        $text = (& $script:ScriptUnderTest -Unit 'Demo/src/Shared.Thing' -RepoRoot $root -MaximumMethodsPerFile 1) -join "`n"

        $text | Should -Match 'public methods: Run \(and 1 more\)'
    }

    It 'refuses a unit that is not a folder in the repository' {
        $root = New-ProjectRepo

        { & $script:ScriptUnderTest -Unit 'Demo/src/Gone' -RepoRoot $root } | Should -Throw '*is not a folder*'
    }
}
