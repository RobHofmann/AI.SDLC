#requires -Version 7.4

BeforeAll {
    $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm'
    Import-Module (Join-Path $script:ScriptFolder 'CSharpCodeView.psm1') -Force
}

Describe 'Get-CodeView' {
    It 'gives one output line for each input line' -Tag '#79' {
        $lines = @('var a = 1;', '/* one', 'two */ var b = 2;', 'var c = @"x', 'y";', 'var d = 3;')

        $view = @(Get-CodeView -Lines $lines)

        $view.Count | Should -Be 6
    }

    It 'reads a line of <Count> <Name> within 3 seconds, as one empty code line' -Tag '#79' -ForEach @(
        @{ Name = 'quotes'; Text = '"'; Count = 50000 }
        @{ Name = 'dollar signs before a quote'; Text = '$'; Count = 50000 }
    ) {
        $hostile = ($Text * $Count) + '"x'
        $clock = [Diagnostics.Stopwatch]::StartNew()

        $view = @(Get-CodeView -Lines @('var a = 1;', $hostile, 'var b = 2;'))

        $clock.Elapsed.TotalSeconds | Should -BeLessThan 3
        $view.Count | Should -Be 3
        $view[1] | Should -Be ''
        $view[2] | Should -Be 'var b = 2;'
    }

    It 'still reads a long line that is under the cap' -Tag '#79' {
        $line = 'var s = "' + ('a' * 3000) + '"; var h = new HttpClient();'

        $view = @(Get-CodeView -Lines @($line))

        $view[0] | Should -Be 'var s = ""; var h = new HttpClient();'
    }

    It 'replaces the text of a string with an empty string' -Tag '#79' {
        $view = @(Get-CodeView -Lines @('var s = "new HttpClient()";'))

        $view[0] | Should -Be 'var s = "";'
    }

    It 'replaces an interpolated string and a character' -Tag '#79' {
        $view = @(Get-CodeView -Lines @('var s = $"a {b} c"; var c = ''x'';'))

        $view[0] | Should -Be 'var s = ""; var c = "";'
    }

    It 'blanks the lines of a verbatim string over several lines' -Tag '#79' {
        $view = @(Get-CodeView -Lines @('var s = @"first', 'new HttpClient()', 'last"; var t = 1;'))

        $view[0] | Should -Be 'var s = '
        $view[1] | Should -Be ''
        $view[2] | Should -Be '; var t = 1;'
    }

    It 'blanks the lines of a raw string over several lines' -Tag '#79' {
        $view = @(Get-CodeView -Lines @('var s = """', 'new HttpClient()', '""";'))

        $view[0] | Should -Be 'var s = '
        $view[1] | Should -Be ''
        $view[2] | Should -Be ';'
    }

    It 'blanks the lines of a block comment over several lines' -Tag '#79' {
        $view = @(Get-CodeView -Lines @('var a = 1; /* start', 'new HttpClient()', 'end */ var b = 2;'))

        $view[0] | Should -Be 'var a = 1; '
        $view[1] | Should -Be ''
        $view[2] | Should -Be ' var b = 2;'
    }

    It 'turns a block comment on one line into a space' -Tag '#79' {
        $view = @(Get-CodeView -Lines @('var a = /* new HttpClient() */ 1;'))

        $view[0] | Should -Be 'var a =   1;'
    }

    It 'keeps a line comment' -Tag '#79' {
        $view = @(Get-CodeView -Lines @('var a = 1; // new HttpClient()'))

        $view[0] | Should -Be 'var a = 1; // new HttpClient()'
    }

    It 'reads <Name>' -Tag '#79' -ForEach @(
        @{ Name = 'a url in a string, which is no comment'; Lines = @('var u = "http://x"; var a = 1;', 'var b = 2;'); Expected = @('var u = ""; var a = 1;', 'var b = 2;') }
        @{ Name = 'a string that holds a block comment start'; Lines = @('var s = "/*"; var t = 1;', 'var b = 2;'); Expected = @('var s = ""; var t = 1;', 'var b = 2;') }
        @{ Name = 'a character that is a double quote'; Lines = @('var c = ''"''; var d = 1;', 'var b = 2;'); Expected = @('var c = ""; var d = 1;', 'var b = 2;') }
        @{ Name = 'an interpolated string with nested quotes'; Lines = @('var s = $"a {x["k"]} b"; var t = 1;', 'var b = 2;'); Expected = @('var s = ""; var t = 1;', 'var b = 2;') }
        @{ Name = 'a raw string that holds doubled quotes'; Lines = @('var s = """a "" b"""; var t = 1;', 'var b = 2;'); Expected = @('var s = ""; var t = 1;', 'var b = 2;') }
        @{ Name = 'a block comment that opens after a closed string'; Lines = @('var s = "x"; /* start', 'end */ var t = 1;'); Expected = @('var s = ""; ', ' var t = 1;') }
        @{ Name = 'a double quote inside a line comment'; Lines = @('var a = 1; // say "hi', 'var b = 2;'); Expected = @('var a = 1; // say "hi', 'var b = 2;') }
    ) {
        $view = @(Get-CodeView -Lines $Lines)

        $view | Should -Be $Expected
    }
}

Describe 'Test-CheckedPath' {
    It 'accepts a C# file and rejects other files and generated files' -Tag '#79' -ForEach @(
        @{ Path = 'src/Orders/OrderService.cs'; Expected = $true }
        @{ Path = 'src/Orders/readme.md'; Expected = $false }
        @{ Path = 'src/Orders/Form.Designer.cs'; Expected = $false }
        @{ Path = 'src/Orders/Api.g.cs'; Expected = $false }
        @{ Path = 'src/Orders/Api.g.i.cs'; Expected = $false }
        @{ Path = 'src/Orders/obj/Debug/Info.cs'; Expected = $false }
        @{ Path = 'src/Orders/bin/Release/Info.cs'; Expected = $false }
        @{ Path = 'src/Orders/OBJ/Debug/Info.cs'; Expected = $false }
        @{ Path = 'src/Orders/Bin/Release/Info.cs'; Expected = $false }
        @{ Path = 'src\Orders\obj\Info.cs'; Expected = $true }
    ) {
        Test-CheckedPath -Path $Path | Should -Be $Expected
    }
}
