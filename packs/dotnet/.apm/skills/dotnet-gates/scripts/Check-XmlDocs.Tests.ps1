#requires -Version 7.4

Describe 'Check-XmlDocs' {
    BeforeAll {
        $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
        if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
        Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Check-XmlDocs.ps1'

        function New-Diff {
            param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Added, [int]$Start = 1)
            $lines = @("diff --git a/$Path b/$Path", "--- a/$Path", "+++ b/$Path", "@@ -$Start,0 +$Start,$($Added.Count) @@")
            $lines += $Added | ForEach-Object { "+$_" }
            $lines -join "`n"
        }

        function Invoke-Check {
            param([Parameter(Mandatory)][AllowEmptyString()][string]$Diff)
            $out = & $script:ScriptUnderTest -DiffText $Diff -TestRoot 'Demo/tests' *>&1 | Out-String
            [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }
    }

    It 'passes public declarations that carry a doc comment, also above an attribute' {
        $r = Invoke-Check (New-Diff 'Demo/src/Api.Demo/Order.cs' @(
                'namespace Api.Demo;',
                '/// <summary>An order a customer placed.</summary>',
                '[Serializable]',
                'public sealed class Order',
                '{',
                '    /// <summary>The order lines.</summary>',
                '    public IReadOnlyList<Line> Lines { get; init; } = [];',
                '    private int count;',
                '}'))
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'XML docs OK: 9 added'
    }

    It 'passes an empty change' {
        $r = Invoke-Check ''
        $r.ExitCode | Should -Be 0
    }

    It 'reports a public type and a public and protected member without a doc comment, by file and line' {
        $r = Invoke-Check (New-Diff 'Demo/src/Api.Demo/Order.cs' @(
                'public class Order',
                '{',
                '    public decimal Total() => 0m;',
                '    protected void Reset() { }',
                '    internal void Hidden() { }',
                '}'))
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Order.cs:1  public class Order'
        $r.Output | Should -Match 'Order.cs:3  public decimal Total'
        $r.Output | Should -Match 'Order.cs:4  protected void Reset'
        $r.Output | Should -Match 'Found 3 undocumented declaration'
        $r.Output | Should -Match 'FIX: '
    }

    It 'reports only the added member, and reads the existing type from the context lines' {
        $diff = "--- a/Demo/src/Api.Demo/Order.cs`n+++ b/Demo/src/Api.Demo/Order.cs`n@@ -1,4 +1,5 @@`n /// <summary>An order.</summary>`n public class Order`n {`n+    public int Count { get; set; }`n     public int Old { get; set; }`n }"
        $r = Invoke-Check $diff
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Order.cs:4  public int Count'
        $r.Output | Should -Match 'Found 1 undocumented'
    }

    It 'does not report public members of a type that is not public' {
        $r = Invoke-Check (New-Diff 'Demo/src/Api.Demo/Mapper.cs' @(
                'internal sealed class Mapper',
                '{',
                '    public string Map(string s) => s;',
                '    public class Nested { public int X { get; set; } }',
                '}',
                'class Plain { public void Run() { } }'))
        $r.ExitCode | Should -Be 0
    }

    It 'does not report a type marked [GeneratedCode] or its members' {
        $r = Invoke-Check (New-Diff 'Demo/src/Api.Demo/Client.cs' @(
                '[System.CodeDom.Compiler.GeneratedCode("NSwag", "14.0.0")]',
                'public partial class Client',
                '{',
                '    public Task SendAsync() => Task.CompletedTask;',
                '}'))
        $r.ExitCode | Should -Be 0
    }

    It 'does not report an override' {
        $r = Invoke-Check (New-Diff 'Demo/src/Api.Demo/Order.cs' @(
                '/// <summary>An order.</summary>',
                'public class Order',
                '{',
                '    public override string ToString() => "order";',
                '}'))
        $r.ExitCode | Should -Be 0
    }

    It 'leaves the type stack after a nested type closes' {
        $r = Invoke-Check (New-Diff 'Demo/src/Api.Demo/Order.cs' @(
                '/// <summary>An order.</summary>',
                'public class Order',
                '{',
                '    private sealed class Cache { public int Size { get; set; } }',
                '    public int Count { get; set; }',
                '}'))
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Order.cs:5  public int Count'
        $r.Output | Should -Match 'Found 1 undocumented'
    }

    It 'treats a record without a body as a declaration with no body' {
        $r = Invoke-Check (New-Diff 'Demo/src/Api.Demo/Dto.cs' @(
                'internal record Hidden(int A);',
                'public record Shown(int A);'))
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Dto.cs:2  public record Shown'
        $r.Output | Should -Match 'Found 1 undocumented'
    }

    It 'skips the test root, generated files and Razor files' {
        $diff = (New-Diff 'Demo/tests/Api.Demo.Tests/OrderTests.cs' @('public class OrderTests { }')) + "`n" +
            (New-Diff 'Demo/src/Api.Demo/Resources.Designer.cs' @('public class Resources { }')) + "`n" +
            (New-Diff 'Demo/src/Portal.Demo/Pages/Foo.razor' @('@code { public int X { get; set; } }'))
        $r = Invoke-Check $diff
        $r.ExitCode | Should -Be 0
    }

    It 'reports that it could not check when the base ref has no merge base' {
        $out = & $script:ScriptUnderTest -BaseRef 'refs/heads/no-such-branch-for-this-test' *>&1 | Out-String
        $LASTEXITCODE | Should -Be 2
        $out | Should -Match 'NOTHING WAS CHECKED'
    }

    It 'is registered as an advisory C10 gate of the dotnet pack' {
        (Get-Content (Join-Path $PSScriptRoot '..' 'gates.json') -Raw) | Should -Match '"script": "scripts/Check-XmlDocs.ps1", "clause": "C10", "mode": "Advisory"'
    }
}
