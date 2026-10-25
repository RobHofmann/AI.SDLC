#requires -Version 7.4

Describe 'Check-CommentHygiene' {
    BeforeAll {
        $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
        if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
        Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Check-CommentHygiene.ps1'

        function New-Diff {
            param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Added, [int]$Start = 10)
            $lines = @("diff --git a/$Path b/$Path", "--- a/$Path", "+++ b/$Path", "@@ -$Start,0 +$Start,$($Added.Count) @@")
            $lines += $Added | ForEach-Object { "+$_" }
            $lines -join "`n"
        }

        function Invoke-Check {
            param([Parameter(Mandatory)][AllowEmptyString()][string]$Diff)
            $out = & $script:ScriptUnderTest -DiffText $Diff *>&1 | Out-String
            [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }
    }

    Context 'comments that help pass' {
        It 'passes a change that adds only code' {
            $r = Invoke-Check (New-Diff 'Demo/src/Api.Demo/Foo.cs' @('public int Count { get; set; }', 'var url = "https://example.com";'))
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'Comment hygiene OK: 2 added'
        }

        It 'passes an empty change' {
            $r = Invoke-Check ''
            $r.ExitCode | Should -Be 0
        }

        It 'passes a doc comment, also one with code in it' {
            $r = Invoke-Check (New-Diff 'Demo/src/Api.Demo/Foo.cs' @('/// <summary>Gets the count.</summary>', '/// <code>var total = Count(items);</code>', 'public int Count { get; }'))
            $r.ExitCode | Should -Be 0
        }

        It 'passes a why comment, a block comment and a trailing comment' {
            $r = Invoke-Check (New-Diff 'Demo/src/Api.Demo/Foo.cs' @('// The ledger API rejects a batch over 500 rows, see #12.', '/*', ' * Retry once: the token cache can be cold after a slot swap.', ' */', 'var a = 1; // milliseconds, not seconds'))
            $r.ExitCode | Should -Be 0
        }

        It 'passes a prose comment that starts with a code word' {
            $r = Invoke-Check (New-Diff 'Demo/src/Api.Demo/Foo.cs' @('// return early when the cache is empty', '// public members need a doc comment', '// the route is /orders/{id}'))
            $r.ExitCode | Should -Be 0
        }

        It 'passes a TODO that carries an issue key' {
            $r = Invoke-Check (New-Diff 'Demo/src/Api.Demo/Foo.cs' @('// TODO #42: drop the v1 route after the clients moved', '// FIXME owner/repo#7 the paging is off by one'))
            $r.ExitCode | Should -Be 0
        }

        It 'allows the Arrange, Act and Assert test markers, also combined' {
            $r = Invoke-Check (New-Diff 'Demo/tests/Api.Demo.Tests/FooTests.cs' @('// Arrange', '// Act', '// Assert', '// Act & Assert', '// Arrange and Act'))
            $r.ExitCode | Should -Be 0
        }

        It 'passes compiler directives' {
            $r = Invoke-Check (New-Diff 'Demo/src/Api.Demo/Foo.cs' @('#nullable enable', '#pragma warning disable CA1822'))
            $r.ExitCode | Should -Be 0
        }
    }

    Context 'commented-out code' {
        It 'fails a line comment that ends like a statement and names the file and the line' {
            $r = Invoke-Check (New-Diff 'Demo/src/Api.Demo/Foo.cs' @('var a = 1;', '// var b = a + 1;') -Start 20)
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'Demo/src/Api.Demo/Foo.cs:21  \[commented-out code\]  // var b = a \+ 1;'
            $r.Output | Should -Match 'FIX: '
        }

        It 'fails a comment that starts like code: <Line>' -ForEach @(
            @{ Line = '// if (order.IsPaid)' }
            @{ Line = '// return Map(order)' }
            @{ Line = '// await client.SendAsync(request)' }
            @{ Line = '// public int Total { get' }
            @{ Line = '// [Fact]' }
            @{ Line = '//}' }
        ) {
            $r = Invoke-Check (New-Diff 'Demo/src/Api.Demo/Foo.cs' @($Line))
            $r.ExitCode | Should -Be 1
        }

        It 'fails each code line of a block comment' {
            $r = Invoke-Check (New-Diff 'Demo/src/Api.Demo/Foo.cs' @('/*', 'foreach (var x in items)', '{', '    Handle(x);', '}', '*/'))
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'Found 4 comment problem'
        }

        It 'fails a trailing comment that holds code' {
            $r = Invoke-Check (New-Diff 'Demo/src/Api.Demo/Foo.cs' @('var a = 1; // a = Load();'))
            $r.ExitCode | Should -Be 1
        }

        It 'fails commented-out code inside a Razor code block and a Razor comment' {
            $r = Invoke-Check (New-Diff 'Demo/src/Portal.Demo/Pages/Foo.razor' @('@code {', '    // await LoadAsync();', '}', '@* StateHasChanged(); *@'))
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'Found 2 comment problem'
        }
    }

    Context 'open TODOs and AI tool names' {
        It 'fails a TODO, FIXME or HACK without an issue key' {
            $r = Invoke-Check (New-Diff 'Demo/src/Api.Demo/Foo.cs' @('// TODO: handle the empty list', '// FIXME later', 'var a = 1; // HACK'))
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'Found 3 comment problem'
            $r.Output | Should -Match '\[TODO without an issue key\]'
        }

        It 'fails a comment that names an AI tool: <Line>' -ForEach @(
            @{ Line = '// Written with Claude' }
            @{ Line = '// Suggested by Copilot' }
            @{ Line = '/// <remarks>Generated by ChatGPT.</remarks>' }
            @{ Line = '// GPT-4 wrote this mapping' }
            @{ Line = '// AI-generated helper' }
        ) {
            $r = Invoke-Check (New-Diff 'Demo/src/Api.Demo/Foo.cs' @($Line))
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match '\[names an AI tool\]'
        }

        It 'does not read an AI tool name inside a string as a comment' {
            $r = Invoke-Check (New-Diff 'Demo/src/Api.Demo/Foo.cs' @('var name = "Copilot";'))
            $r.ExitCode | Should -Be 0
        }
    }

    Context 'reading the diff' {
        It 'does not read a URL or a slash inside a string as a comment' {
            $r = Invoke-Check (New-Diff 'Demo/src/Api.Demo/Foo.cs' @('var u = $"https://{host}/api";', 'var p = @"C:\x\//y";', 'var c = ''/'';', 'var d = a / b;', 'var s = $"{(secure ? "https://" : "http://")}{host}";'))
            $r.ExitCode | Should -Be 0
        }

        It 'follows a multi-line raw string, so code-like text inside it is not a comment' {
            $r = Invoke-Check (New-Diff 'Demo/src/Api.Demo/Query.cs' @('var q = """', '    // var x = 1;', '    | where type == "x"', '    """;', 'var n = 1;'))
            $r.ExitCode | Should -Be 0
        }

        It 'still finds a comment after a multi-line string closes' {
            $r = Invoke-Check (New-Diff 'Demo/src/Api.Demo/Query.cs' @('var q = """', '    // kql', '    """; // var old = q;', 'var n = 1;') -Start 1)
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'Query.cs:3'
            $r.Output | Should -Match 'Found 1 comment problem'
        }

        It 'reads the context lines, so a line added inside a block comment that was already there is a comment' {
            $diff = "--- a/Demo/src/Api.Demo/Foo.cs`n+++ b/Demo/src/Api.Demo/Foo.cs`n@@ -10,3 +10,4 @@`n /*`n  * old reason`n+ Handle(x);`n  */"
            $r = Invoke-Check $diff
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'Foo.cs:12'
        }

        It 'does not take an added line that starts with ++ for a file header' {
            $r = Invoke-Check (New-Diff 'Demo/src/Api.Demo/Foo.cs' @('++ count;', '// count++;'))
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match '// count\+\+;'
        }

        It 'ignores other languages' {
            $r = Invoke-Check (New-Diff 'Demo/tools/Foo.ps1' @('# $a = 1;'))
            $r.ExitCode | Should -Be 0
        }

        It 'skips generated files' {
            $r = Invoke-Check (New-Diff 'Demo/src/Api.Demo/Resources.Designer.cs' @('// <auto-generated> generated by a tool; </auto-generated>'))
            $r.ExitCode | Should -Be 0
        }

        It 'reads the line numbers of a second hunk in the same file' {
            $diff = (New-Diff 'Demo/src/Api.Demo/Foo.cs' @('var a = 1;') -Start 5) + "`n@@ -40,0 +41,1 @@`n+// TODO later"
            $r = Invoke-Check $diff
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'Foo.cs:41  \[TODO without an issue key\]'
        }

        It 'reports that it could not check when the base ref has no merge base' {
            $out = & $script:ScriptUnderTest -BaseRef 'refs/heads/no-such-branch-for-this-test' *>&1 | Out-String
            $LASTEXITCODE | Should -Be 2
            $out | Should -Match 'NOTHING WAS CHECKED'
        }
    }

    It 'is registered as a blocking C10 gate of the dotnet pack' {
        (Get-Content (Join-Path $PSScriptRoot '..' 'gates.json') -Raw) | Should -Match '"script": "scripts/Check-CommentHygiene.ps1", "clause": "C10", "mode": "Blocking"'
    }
}
