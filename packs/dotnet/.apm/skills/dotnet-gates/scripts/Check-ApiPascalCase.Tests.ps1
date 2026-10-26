#requires -Version 7.4

Describe 'Check-ApiPascalCase' {
    BeforeAll {
        $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
        if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
        Import-Module (Join-Path $aiSdlcGates 'DocToolTestHarness.psm1') -Force
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Check-ApiPascalCase.ps1'
        $script:YamlAvailable = $null -ne (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)

        function Invoke-Gate {
            param([Parameter(Mandatory)][string]$RepoRoot, [hashtable]$Extra = @{})
            $out = & $script:ScriptUnderTest -RepoRoot $RepoRoot @Extra *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }

        function New-CsFile {
            param(
                [Parameter(Mandatory)][string]$RepoRoot,
                [Parameter(Mandatory)][string]$RelativePath,
                [Parameter(Mandatory)][string]$Content
            )
            $full = Join-Path -Path $RepoRoot -ChildPath $RelativePath
            $dir = Split-Path -Path $full -Parent
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath $full -Value $Content -Encoding UTF8
        }

        function New-SpecFile {
            param(
                [Parameter(Mandatory)][string]$RepoRoot,
                [Parameter(Mandatory)][string]$RelativePath,
                [Parameter(Mandatory)][string]$Content
            )
            $full = Join-Path -Path $RepoRoot -ChildPath $RelativePath
            $dir = Split-Path -Path $full -Parent
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath $full -Value $Content -Encoding UTF8
        }
    }

    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path -Path $script:Root -ChildPath 'Demo/src') -Force | Out-Null
        Set-AiSdlcTestConfig -Root $script:Root
    }

    It 'passes a PascalCase wire name that deliberately differs from the property (exit 0)' {
        New-CsFile -RepoRoot $script:Root -RelativePath 'Demo/src/Shared.Demo/Dto.cs' -Content @'
public class Dto
{
    [JsonPropertyName("CustomerName")]
    public string Name { get; set; }
}
'@

        $result = Invoke-Gate -RepoRoot $script:Root

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'DOTNET-01 OK'
    }

    It 'fails on a redundant [JsonPropertyName] equal to the auto-property name (exit 1)' {
        New-CsFile -RepoRoot $script:Root -RelativePath 'Demo/src/Shared.Demo/Dto.cs' -Content @'
public class Dto
{
    [JsonPropertyName("CustomerName")]
    public string CustomerName { get; set; }
}
'@

        $result = Invoke-Gate -RepoRoot $script:Root

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'redundant'
        $result.Output | Should -Match 'CustomerName'
    }

    It 'fails on a redundant [JsonPropertyName] on a collection auto-property with an initializer (exit 1)' {
        New-CsFile -RepoRoot $script:Root -RelativePath 'Demo/src/Shared.Demo/Dto.cs' -Content @'
public class Dto
{
    [JsonPropertyName("Members")]
    public List<string> Members { get; set; } = [];
}
'@

        $result = Invoke-Gate -RepoRoot $script:Root

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'redundant'
        $result.Output | Should -Match 'Members'
    }

    It 'does not flag a redundant attribute when the member cannot be determined (exit 0)' {
        New-CsFile -RepoRoot $script:Root -RelativePath 'Demo/src/Shared.Demo/Dto.cs' -Content @'
public class Dto
{
    [JsonPropertyName("CustomerName")]
}
'@

        $result = Invoke-Gate -RepoRoot $script:Root

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'DOTNET-01 OK'
    }

    It 'passes when an allowlisted system field wire name is used (exit 0)' {
        New-CsFile -RepoRoot $script:Root -RelativePath 'Demo/src/Shared.Demo.Data/Document.cs' -Content @'
public class Document
{
    [JsonPropertyName("id")]
    public string Id { get; set; }
}
'@

        $result = Invoke-Gate -RepoRoot $script:Root

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'DOTNET-01 OK'
    }

    It 'fails on a snake_case wire name (exit 1)' {
        New-CsFile -RepoRoot $script:Root -RelativePath 'Demo/src/Shared.Demo/Dto.cs' -Content @'
public class Dto
{
    [JsonPropertyName("customer_name")]
    public string CustomerName { get; set; }
}
'@

        $result = Invoke-Gate -RepoRoot $script:Root

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'DOTNET-01 violation'
        $result.Output | Should -Match 'customer_name'
    }

    It 'fails on a camelCase wire name (exit 1)' {
        New-CsFile -RepoRoot $script:Root -RelativePath 'Demo/src/Shared.Demo/Dto.cs' -Content @'
public class Dto
{
    [JsonPropertyName("customerName")]
    public string CustomerName { get; set; }
}
'@

        $result = Invoke-Gate -RepoRoot $script:Root

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'DOTNET-01 violation'
        $result.Output | Should -Match 'customerName'
    }

    It 'scopes a partition-key wire name to its declaring file: <Case>' -TestCases @(
        @{
            Case     = 'allowed where it is declared (exit 0)'
            Path     = 'Demo/src/Shared.Demo.Domain/Common/Models/Core/Notification.cs'
            Exit     = 0
            Patterns = @('allow-partition-key', 'reason: Cosmos partition key path /userId')
        }
        @{
            Case     = 'still a violation anywhere else (exit 1)'
            Path     = 'Demo/src/Shared.Demo/Dto.cs'
            Exit     = 1
            Patterns = @('DOTNET-01 violation', 'userId')
        }
    ) {
        New-CsFile -RepoRoot $script:Root -RelativePath $Path -Content @'
public class Model
{
    [JsonPropertyName("userId")]
    public string UserId { get; set; }
}
'@

        $result = Invoke-Gate -RepoRoot $script:Root

        $result.ExitCode | Should -Be $Exit
        foreach ($pattern in $Patterns) { $result.Output | Should -Match $pattern }
    }

    It 'passes an exact-allowlist system field other than id (exit 0)' {
        New-CsFile -RepoRoot $script:Root -RelativePath 'Demo/src/Shared.Demo.Data/Document.cs' -Content @'
public class Document
{
    [JsonPropertyName("_etag")]
    public string Etag { get; set; }

    [JsonPropertyName("ttl")]
    public int Ttl { get; set; }
}
'@

        $result = Invoke-Gate -RepoRoot $script:Root

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'DOTNET-01 OK'
    }

    It 'passes a leading-underscore wire name as system metadata (exit 0)' {
        New-CsFile -RepoRoot $script:Root -RelativePath 'Demo/src/Shared.Demo.Data/Document.cs' -Content @'
public class Document
{
    [JsonPropertyName("_self")]
    public string Self { get; set; }
}
'@

        $result = Invoke-Gate -RepoRoot $script:Root

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'DOTNET-01 OK'
    }

    It 'passes a dotted JSON path wire name (exit 0)' {
        New-CsFile -RepoRoot $script:Root -RelativePath 'Demo/src/Shared.Demo/Projection.cs' -Content @'
public class Projection
{
    [JsonPropertyName("customer.orderLine.id")]
    public string Key { get; set; }
}
'@

        $result = Invoke-Gate -RepoRoot $script:Root

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'DOTNET-01 OK'
    }

    It 'passes an all-lowercase external-contract wire name (exit 0)' {
        New-CsFile -RepoRoot $script:Root -RelativePath 'Demo/src/Shared.Shipping/CarrierResponse.cs' -Content @'
public class CarrierResponse
{
    [JsonPropertyName("ok")]
    public bool Ok { get; set; }
}
'@

        $result = Invoke-Gate -RepoRoot $script:Root

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'DOTNET-01 OK'
    }

    It 'reports could-not-check (exit 2) when a spec exists but no YAML parser does' {
        New-CsFile -RepoRoot $script:Root -RelativePath 'Demo/src/Shared.Demo/Dto.cs' -Content @'
public class Dto
{
    public string Name { get; set; }
}
'@
        $specsDir = Join-Path $script:Root 'specs'
        New-Item -ItemType Directory -Path $specsDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $specsDir 'demo.openapi.yaml') -Value "openapi: 3.0.0`ninfo:`n  title: demo`n" -NoNewline

        $result = Invoke-Gate -RepoRoot $script:Root -Extra @{ YamlParserAvailableForTest = $false }

        $result.ExitCode | Should -Be 2
        $result.Output | Should -Match 'COULD NOT BE CHECKED'
        $result.Output | Should -Match 'powershell-yaml'
        $result.Output | Should -Not -Match 'Part B FAILED'
    }

    It 'reports no specs yet when specs/ is absent (exit 0)' {
        New-CsFile -RepoRoot $script:Root -RelativePath 'Demo/src/Shared.Demo/Dto.cs' -Content @'
public class Dto
{
    [JsonPropertyName("CustomerName")]
    public string Name { get; set; }
}
'@

        $result = Invoke-Gate -RepoRoot $script:Root

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'DOTNET-01 OK'
    }
}
