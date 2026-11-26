#requires -Version 7.4

BeforeAll {
    $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm'
    $script:SkillFolder = Split-Path -Parent $script:ScriptFolder
    $script:BlockPath = Join-Path $script:SkillFolder 'assets' 'recommended.editorconfig'
    $script:PagePath = Join-Path $script:SkillFolder 'references' 'code-style-block.md'

    function Get-BlockLines {
        return @(Get-Content -LiteralPath $script:BlockPath | Where-Object { $_.Trim() -ne '' })
    }

    function Get-Severity {
        param([string]$RuleId)
        $line = Get-BlockLines | Where-Object { $_ -match "^dotnet_diagnostic\.$RuleId\.severity\s*=" }
        if (-not $line) { return $null }
        return ($line -split '=', 2)[1].Trim()
    }

}

Describe 'The recommended .editorconfig block of csharp-conventions' {
    Context 'the content of the block' {
        It 'sets <_> to warning, for a rule of the house style' -ForEach @(
            'IDE0290', 'IDE0090', 'IDE0028', 'IDE0300', 'IDE0007', 'IDE0022', 'IDE0025', 'IDE0161', 'IDE0019'
        ) {
            Get-Severity -RuleId $_ | Should -Be 'warning'
        }

        It 'sets <_> to warning, for a rule of the house style' -ForEach @(
            'IDE0066', 'IDE0041', 'IDE0150', 'CA1507', 'CA2208'
        ) {
            Get-Severity -RuleId $_ | Should -Be 'warning'
        }

        It 'sets IDE0130 to warning, for a namespace that does not match its folder' {
            Get-Severity -RuleId 'IDE0130' | Should -Be 'warning'
        }

        It 'turns on the namespace and folder match option' {
            Get-BlockLines | Should -Contain 'dotnet_style_namespace_match_folder = true'
        }

        It 'sets no rule to error, so a style break does not fail the build' {
            Get-BlockLines | Where-Object { $_ -match '=\s*error\b|:\s*error\b' } | Should -BeNullOrEmpty
        }

        It 'holds no rule for <Point>' -ForEach @(
            @{ Point = 'the Async suffix, which would also flag a controller action'; Pattern = '^dotnet_naming_|IDE1006' }
            @{ Point = 'a conditional expression, which the house style does not ask for'; Pattern = 'IDE0045|IDE0046|prefer_conditional_expression' }
            @{ Point = 'a SonarAnalyzer rule, which acts only with that package'; Pattern = '\bS\d{3,}\b' }
        ) {
            Get-BlockLines | Where-Object { $_ -match $Pattern } | Should -BeNullOrEmpty
        }

        It 'is one [*.cs] section without root, so a repository adds it to its own file' {
            $lines = Get-BlockLines
            $lines[0] | Should -Be '[*.cs]'
            @($lines | Where-Object { $_ -match '^\[' }).Count | Should -Be 1
            $lines | Where-Object { $_ -match '^root\s*=' } | Should -BeNullOrEmpty
        }

        It 'carries no comment lines' {
            Get-BlockLines | Where-Object { $_ -match '^\s*[#;]' } | Should -BeNullOrEmpty
        }

        It 'is described rule by rule on the reference page' {
            $page = Get-Content -LiteralPath $script:PagePath -Raw
            $ids = Get-BlockLines | ForEach-Object { if ($_ -match '^dotnet_diagnostic\.(\w+)\.severity') { $Matches[1] } }
            foreach ($id in $ids) { $page | Should -Match "\b$id\b" }
        }
    }

    Context 'a build with the block' {
        BeforeAll {
            $script:Dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
            if (-not $script:Dotnet) { return }

            $sdks = @(& dotnet --list-sdks)
            if ($LASTEXITCODE -ne 0) { throw "dotnet --list-sdks failed with exit code $LASTEXITCODE" }
            $major = ($sdks | ForEach-Object { [int](($_ -split '\.')[0]) } | Measure-Object -Maximum).Maximum

            function New-Project {
                param([string]$Name, [hashtable]$Files, [string]$RootNamespace)
                $folder = Join-Path $TestDrive $Name
                New-Item -ItemType Directory -Path $folder -Force | Out-Null
                $editorconfig = @('root = true', '') + @(Get-Content -LiteralPath $script:BlockPath)
                Set-Content -LiteralPath (Join-Path $folder '.editorconfig') -Value $editorconfig
                $properties = @(
                    "    <TargetFramework>net$major.0</TargetFramework>"
                    '    <EnforceCodeStyleInBuild>true</EnforceCodeStyleInBuild>'
                    '    <Nullable>disable</Nullable>'
                )
                if ($RootNamespace) { $properties += "    <RootNamespace>$RootNamespace</RootNamespace>" }
                Set-Content -LiteralPath (Join-Path $folder "$Name.csproj") -Value (@(
                        '<Project Sdk="Microsoft.NET.Sdk">'
                        '  <PropertyGroup>'
                    ) + $properties + @(
                        '  </PropertyGroup>'
                        '</Project>'
                    ))
                foreach ($file in $Files.Keys) {
                    $path = Join-Path $folder $file
                    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
                    Set-Content -LiteralPath $path -Value $Files[$file]
                }
                return $folder
            }

            function Invoke-Build {
                param([string]$Folder)
                $output = @(& dotnet build $Folder -nologo 2>&1)
                return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
            }

            $breaks = @'
using System.Collections.Generic;

namespace Probe
{
    public interface IClock
    {
        System.DateTime Now();
    }

    public class Order
    {
        private readonly System.Text.StringBuilder builder = new System.Text.StringBuilder();
        private readonly IClock _clock;

        public Order(IClock clock)
        {
            _clock = clock;
        }

        public string State
        {
            get { return "open"; }
        }

        public int Count()
        {
            return 3;
        }

        public void Build(object input)
        {
            List<string> tags = new List<string>();
            int[] numbers = new int[] { 1, 2, 3 };
            int total = numbers.Length;
            var text = input as string;
            if (text != null)
            {
                tags.Add(text + total + builder + _clock.Now());
            }
        }

        public string Pick(bool value)
        {
            switch (value)
            {
                case true:
                    return "yes";
                default:
                    return "no";
            }
        }

        public bool IsMissing(object input) => ReferenceEquals(input, null);

        public bool IsNotText(string input) => input is not string;

        public void Check(string orderId)
        {
            if (orderId is null)
            {
                throw new System.ArgumentNullException("orderId");
            }
            throw new System.ArgumentException("The order id is not valid.", "value");
        }
    }
}
'@
            $clean = @'
namespace Clean;

public interface IClock
{
    System.DateTime Now();
}

public class Order(IClock clock)
{
    private readonly System.Text.StringBuilder builder = new();

    public string State => "open";

    public string Pick(bool value) => value switch
    {
        true => "yes",
        _ => "no",
    };

    public void Check(string orderId)
    {
        if (orderId is null)
        {
            throw new System.ArgumentNullException(nameof(orderId));
        }
    }

    public void Build(object input)
    {
        var tags = new System.Collections.Generic.List<string>();
        int[] numbers = [1, 2, 3];
        var now = clock.Now();
        if (input is string text)
        {
            tags.Add(text + numbers.Length + now + builder);
        }
    }
}
'@
            $script:BreakBuild = Invoke-Build -Folder (New-Project -Name 'Breaks' -Files @{ 'Order.cs' = $breaks })
            $script:CleanBuild = Invoke-Build -Folder (New-Project -Name 'Clean' -Files @{ 'Order.cs' = $clean })
            $script:NamespacesBuild = Invoke-Build -Folder (New-Project -Name 'Namespaces' -Files @{
                    'Services/Good.cs' = "namespace Namespaces.Services;`n`npublic class Good;"
                    'Services/Bad.cs' = "namespace Namespaces.Other;`n`npublic class Bad;"
                    'Services/Loose.cs' = 'public class Loose;'
                })
            $script:RootedBuild = Invoke-Build -Folder (New-Project -Name 'Rooted' -RootNamespace 'Company.Rooted' -Files @{
                    'Services/WithRoot.cs' = "namespace Company.Rooted.Services;`n`npublic class WithRoot;"
                    'Services/WithName.cs' = "namespace Rooted.Services;`n`npublic class WithName;"
                })
        }

        It 'reports a style break as a warning with rule id <_>' -ForEach @(
            'IDE0290', 'IDE0090', 'IDE0028', 'IDE0300', 'IDE0007', 'IDE0022', 'IDE0025', 'IDE0161', 'IDE0019'
        ) {
            if (-not $script:Dotnet) { Set-ItResult -Skipped -Because 'no .NET SDK on the PATH' }
            $script:BreakBuild.Output | Should -Match "warning $_\b"
        }

        It 'reports a break of a house rule as a warning with rule id <_>' -ForEach @(
            'IDE0066', 'IDE0041', 'IDE0150', 'CA1507', 'CA2208'
        ) {
            if (-not $script:Dotnet) { Set-ItResult -Skipped -Because 'no .NET SDK on the PATH' }
            $script:BreakBuild.Output | Should -Match "warning $_\b"
        }

        It 'reports a namespace that does not match its project and folder as warning IDE0130' {
            if (-not $script:Dotnet) { Set-ItResult -Skipped -Because 'no .NET SDK on the PATH' }
            $script:BreakBuild.Output | Should -Match 'warning IDE0130\b'
        }

        It 'warns on a file whose namespace does not match its folder' {
            if (-not $script:Dotnet) { Set-ItResult -Skipped -Because 'no .NET SDK on the PATH' }
            $script:NamespacesBuild.Output | Should -Match 'Bad\.cs\(\d+,\d+\): warning IDE0130'
        }

        It 'does not warn on a file whose namespace matches its project and folder' {
            if (-not $script:Dotnet) { Set-ItResult -Skipped -Because 'no .NET SDK on the PATH' }
            $script:NamespacesBuild.Output | Should -Not -Match 'Good\.cs\(\d+,\d+\): warning IDE0130'
        }

        It 'compares with the root namespace of the project, not with its name' {
            if (-not $script:Dotnet) { Set-ItResult -Skipped -Because 'no .NET SDK on the PATH' }
            $script:RootedBuild.Output | Should -Match 'WithName\.cs\(\d+,\d+\): warning IDE0130'
        }

        It 'does not warn on a namespace that starts with the root namespace of the project' {
            if (-not $script:Dotnet) { Set-ItResult -Skipped -Because 'no .NET SDK on the PATH' }
            $script:RootedBuild.Output | Should -Not -Match 'WithRoot\.cs\(\d+,\d+\): warning IDE0130'
        }

        It 'does not fail the build on a namespace that does not match, in <Name>' -ForEach @(
            @{ Name = 'a project without a root namespace'; Build = 'NamespacesBuild' }
            @{ Name = 'a project with a root namespace'; Build = 'RootedBuild' }
        ) {
            if (-not $script:Dotnet) { Set-ItResult -Skipped -Because 'no .NET SDK on the PATH' }
            (Get-Variable -Scope Script -Name $Build -ValueOnly).ExitCode | Should -Be 0
        }

        It 'does not warn on a file without a namespace' {
            if (-not $script:Dotnet) { Set-ItResult -Skipped -Because 'no .NET SDK on the PATH' }
            $script:NamespacesBuild.Output | Should -Not -Match 'Loose\.cs\(\d+,\d+\): warning IDE0130'
        }

        It 'does not fail the build on a style break' {
            if (-not $script:Dotnet) { Set-ItResult -Skipped -Because 'no .NET SDK on the PATH' }
            $script:BreakBuild.ExitCode | Should -Be 0
        }

        It 'reports nothing on code in the house style, with a two-case switch expression and nameof' {
            if (-not $script:Dotnet) { Set-ItResult -Skipped -Because 'no .NET SDK on the PATH' }
            $script:CleanBuild.ExitCode | Should -Be 0
            $script:CleanBuild.Output | Should -Not -Match 'warning (IDE|CA)\d+'
        }
    }
}
