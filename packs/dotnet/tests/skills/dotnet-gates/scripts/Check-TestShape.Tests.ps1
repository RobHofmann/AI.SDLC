#requires -Version 7.4

BeforeAll { $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm' }

Describe 'Check-TestShape' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $script:ScriptFolder -ChildPath 'Check-TestShape.ps1'
        $script:TestPath = 'Demo/tests/Api.Demo.Tests/OrderServiceTests.cs'

        function New-Repo {
            param([string]$TargetBranch = 'main', [string]$OldPath, [string[]]$Old)
            $repo = Join-Path $TestDrive ('repo-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $repo -Force | Out-Null
            git -C $repo init --quiet --template= -b work
            git -C $repo config user.email probe@example.invalid
            git -C $repo config user.name probe
            Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value 'base'
            if ($OldPath) {
                $file = Join-Path $repo $OldPath
                New-Item -ItemType Directory -Path (Split-Path $file) -Force | Out-Null
                Set-Content -LiteralPath $file -Value $Old
            }
            git -C $repo add -A
            git -C $repo commit --quiet -m base --no-verify
            git -C $repo update-ref "refs/remotes/origin/$TargetBranch" HEAD
            return $repo
        }

        function Write-TestFile {
            param([string]$Repo, [string]$Path = $script:TestPath, [string[]]$Lines)
            $file = Join-Path $Repo $Path
            New-Item -ItemType Directory -Path (Split-Path $file) -Force | Out-Null
            Set-Content -LiteralPath $file -Value $Lines
        }

        function Invoke-Gate {
            param([string]$Repo, [hashtable]$Params = @{})
            $out = & $script:ScriptUnderTest -RepoRoot $Repo @Params *>&1 | Out-String
            [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }

        # The test file is new (untracked), so the gate counts every line as added.
        function Invoke-OnNew {
            param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines, [string]$Path = $script:TestPath)
            $repo = New-Repo
            Write-TestFile -Repo $repo -Path $Path -Lines $Lines
            Invoke-Gate -Repo $repo
        }

        # The test file exists at the base, and the working tree holds the edit.
        function Invoke-OnEdit {
            param([Parameter(Mandatory)][string[]]$Old, [Parameter(Mandatory)][string[]]$New)
            $repo = New-Repo -OldPath $script:TestPath -Old $Old
            Write-TestFile -Repo $repo -Lines $New
            Invoke-Gate -Repo $repo
        }

        function New-TestClass {
            param([Parameter(Mandatory)][string[]]$Body, [string]$Name = 'Total_IsSum')
            @(
                'public class OrderServiceTests',
                '{',
                '    [Fact]',
                "    public void $Name()",
                '    {'
            ) + ($Body | ForEach-Object { "        $_" }) + @(
                '    }',
                '}'
            )
        }
    }

    BeforeEach {
        $script:Saved = @{ Target = $env:PR_TARGET_BRANCH; Changed = $env:CHANGED_FILES }
        $env:PR_TARGET_BRANCH = $null
        $env:CHANGED_FILES = $null
    }

    AfterEach {
        $env:PR_TARGET_BRANCH = $script:Saved.Target
        $env:CHANGED_FILES = $script:Saved.Changed
    }

    Context 'a test method the change adds' {
        It 'reads a test file with a line of 50,000 quotes within 10 seconds, and still checks its markers' -Tag '#79' {
            $hostile = 'var s = ' + ('"' * 50000) + '"x;'
            $lines = New-TestClass @('// Arrange', $hostile, '// Act', 'var t = s.Total();', '// Assert', 'Assert.Equal(0, t);', '// Act', 's.Add(1);')
            $clock = [Diagnostics.Stopwatch]::StartNew()

            $r = Invoke-OnNew $lines

            $clock.Elapsed.TotalSeconds | Should -BeLessThan 10
            $r.Output | Should -Match 'Act appears 2 times'
        }

        It 'fails a repeated marker and names the file and the method' -Tag '#79' {
            $r = Invoke-OnNew (New-TestClass @('// Arrange', 'var s = new OrderService();', '// Act', 'var t = s.Total();', '// Assert', 'Assert.Equal(0, t);', '// Act', 's.Add(1);', '// Assert', 'Assert.Equal(1, s.Total());'))

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match ([regex]::Escape($script:TestPath) + '.*Total_IsSum')
            $r.Output | Should -Match 'Act appears 2 times'
            $r.Output | Should -Match '(?m)^FIX: '
        }

        It 'fails markers that are out of order' -Tag '#79' {
            $r = Invoke-OnNew (New-TestClass @('// Act', 'var t = 1;', '// Arrange', 'var s = 2;', '// Assert', 'Assert.Equal(1, t);'))

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'out of order'
        }

        It 'fails an Act that no Assert follows' -Tag '#79' {
            $r = Invoke-OnNew (New-TestClass @('// Arrange', 'var s = 2;', '// Act', 's.Add(1);'))

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'no // Assert follows'
        }

        It 'passes each marker once and in order' -Tag '#79' {
            $r = Invoke-OnNew (New-TestClass @('// Arrange', 'var s = new OrderService();', '// Act', 'var t = s.Total();', '// Assert', 'Assert.Equal(0, t);'))

            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match 'Test shape OK: 1 changed test method'
        }

        It 'fails a method with no markers at all, and names each missing one' -Tag '#79' {
            $r = Invoke-OnNew (New-TestClass @('Assert.Equal(0, new OrderService().Total());'))

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'Total_IsSum: the // Arrange marker is missing'
            $r.Output | Should -Match 'Total_IsSum: the // Act marker is missing'
            $r.Output | Should -Match 'Total_IsSum: the // Assert marker is missing'
        }

        It 'fails a method that misses only the Arrange marker' -Tag '#79' {
            $r = Invoke-OnNew (New-TestClass @('// Act', 'var t = new OrderService().Total();', '// Assert', 'Assert.Equal(0, t);'))

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'the // Arrange marker is missing'
            $r.Output | Should -Not -Match 'Act marker is missing|Assert marker is missing'
        }

        It 'reads a marker that carries more text as its part' -Tag '#79' {
            $r = Invoke-OnNew (New-TestClass @('// Arrange', 'var s = new OrderService();', '// Act', 's.Clear();', '// Assert - no exception means success', 'Assert.True(true);'))

            $r.ExitCode | Should -Be 0 -Because $r.Output
        }
    }

    Context 'merged markers' {
        It 'counts <Name> as both parts' -Tag '#79' -ForEach @(
            @{ Name = 'Arrange & Act'; Body = @('// Arrange & Act', 'var t = new OrderService().Total();', '// Assert', 'Assert.Equal(0, t);') }
            @{ Name = 'Act & Assert'; Body = @('// Arrange', 'var s = new OrderService();', '// Act & Assert', 'Assert.Throws<ArgumentException>(() => s.Add(-1));') }
            @{ Name = 'Arrange & Act & Assert'; Body = @('// Arrange & Act & Assert', 'Assert.Equal(0, new OrderService().Total());') }
        ) {
            $r = Invoke-OnNew (New-TestClass $Body)

            $r.ExitCode | Should -Be 0 -Because $r.Output
        }

        It 'still fails a merged marker that repeats a part' -Tag '#79' {
            $r = Invoke-OnNew (New-TestClass @('// Arrange & Act', 'var t = 1;', '// Act & Assert', 'Assert.Equal(1, t);'))

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'Act appears 2 times'
        }
    }

    Context 'text that is not a marker' -Tag '#79' {
        It 'does not count braces inside a string as the end of the method' {
            $r = Invoke-OnNew (New-TestClass @('// Arrange', 'var json = "{ }}";', '// Act', 'var t = Parse(json);', '// Assert', 'Assert.NotNull(t);', '// Assert', 'Assert.True(t.Ok);'))

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'Assert appears 2 times'
        }

        It 'does not count a marker line inside a raw or verbatim string over several lines' {
            $r = Invoke-OnNew (New-TestClass @('// Arrange', 'var text = """', '    // Assert {', '    """;', 'var v = @"', '// Act }', '";', '// Act', 'var t = Parse(text, v);', '// Assert', 'Assert.NotNull(t);'))

            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match 'Test shape OK: 1 changed test method'
        }

        It 'does not let a marker in a string stand in for a missing marker' {
            $r = Invoke-OnNew (New-TestClass @('var text = "// Arrange";', '// Act', 'var t = Parse(text);', '// Assert', 'Assert.NotNull(t);'))

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'the // Arrange marker is missing'
        }

        It 'does not count a marker or a brace inside a block comment' {
            $r = Invoke-OnNew (New-TestClass @('// Arrange', '/*', '// Act }', '*/', 'var s = new OrderService(); /* { */', '// Act', 's.Add(1);', '// Assert', 'Assert.Equal(1, s.Total());'))

            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match 'Test shape OK: 1 changed test method'
        }

        It 'does not let a marker in a block comment stand in for a missing marker' {
            $r = Invoke-OnNew (New-TestClass @('/* // Arrange */', '// Act', 'var t = 1;', '// Assert', 'Assert.Equal(1, t);'))

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'the // Arrange marker is missing'
        }

        It 'does not count a brace in a line comment as the start of a block' {
            $lines = @('public class OrderServiceTests', '{', '    [Fact]', '    public void First()', '    {', '        // Arrange {', '        var a = 1;', '        // Act', '        a++;', '        // Assert', '        Assert.Equal(2, a);', '    }',
                '    [Fact]', '    public void Second()', '    {', '        // Act', '        var b = 1;', '        // Act', '        b++;', '        // Assert', '        Assert.Equal(2, b);', '    }', '}')

            $r = Invoke-OnNew $lines

            $r.Output | Should -Match 'Second: Act appears 2 times'
            $r.Output | Should -Not -Match 'First:'
        }

        It 'does not read a string opener in a line comment as the start of a string' {
            $r = Invoke-OnNew (New-TestClass @('// Arrange', 'var u = "a"; // Act on x@" the input', '// Act', 'var t = u.Length;', '// Assert', 'Assert.Equal(1, t);', '// Assert', 'Assert.True(t > 0);'))

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'Assert appears 2 times'
        }

        It 'reads a block comment opener inside a verbatim string as string text' {
            $r = Invoke-OnNew (New-TestClass @('// Arrange', 'var text = @"prefix /*', 'body";', '// Act', 'a();', '// Act', 'b();', '// Assert', 'Assert.True(true);'))

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'Act appears 2 times'
        }
    }

    Context 'which methods the gate finds' -Tag '#79' {
        It 'reads the body of a theory whose data attribute holds braces' {
            $r = Invoke-OnNew @('public class OrderServiceTests', '{', '    [Theory]', '    [InlineData(new[] { 1, 2 })]', '    public void Add_Counts(int[] n)', '    {',
                '        // Act', '        var a = 1;', '        // Act', '        var b = 2;', '        // Assert', '        Assert.Equal(1, a);', '    }', '}')

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'Add_Counts: Act appears 2 times'
        }

        It 'reads the body of a theory whose data attribute spans several lines' {
            $r = Invoke-OnNew @('public class OrderServiceTests', '{', '    [Theory]', '    [InlineData(', '        new[] { 1, 2 })]', '    public void Add_Counts(int[] n)', '    {',
                '        // Act', '        var a = 1;', '        // Act', '        var b = 2;', '        // Assert', '        Assert.Equal(1, a);', '    }', '}')

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'Add_Counts: Act appears 2 times'
        }

        It 'skips a test method with no body and names the next one right' {
            $r = Invoke-OnNew @('public abstract class OrderServiceTests', '{', '    [Fact]', '    public abstract void Base();', '    [Fact]', '    public async Task Real()', '    {',
                '        // Act', '        var a = 1;', '        // Act', '        var b = 2;', '        // Assert', '        Assert.Equal(1, a);', '    }', '}')

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match ':5  Real: Act appears 2 times'
            $r.Output | Should -Not -Match 'Base:'
        }

        It 'names a test method whose attribute shares its line' {
            $r = Invoke-OnNew @('public class OrderServiceTests', '{', '    [Fact] public void Inline()', '    {', '        // Act', '        var a = 1;', '    }', '}')

            $r.Output | Should -Match 'Inline: no // Assert follows'
        }

        It 'checks a test written as an expression body' {
            $r = Invoke-OnNew @('public class OrderServiceTests', '{', '    [Fact]', '    public void Throws() =>', '        // Act', '        Run(', '            1);', '}')

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'Throws: no // Assert follows'
        }

        It 'reports a test method whose body runs to the end of the file without failing itself' {
            $r = Invoke-OnNew @('public class OrderServiceTests', '{', '    [Fact]', '    public void Open()', '    {', '        // Act', '        var a = 1;', '        // Act', '        var b = 2;')

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'Open: Act appears 2 times'
        }

        It 'finds a test whose Fact follows another attribute on the same line' -ForEach @(
            @{ Line = '    [Trait("Story", "PROJ-1")][Fact] public void Works()' }
            @{ Line = '    [Trait("Story", "PROJ-1"), Fact] public void Works()' }
        ) {
            $r = Invoke-OnNew @('public class OrderServiceTests', '{', $Line, '    {', '        // Act', '        var a = 1;', '        // Act', '        var b = 2;', '        // Assert', '        Assert.Equal(1, a);', '    }', '}')

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'Works: Act appears 2 times'
        }

        It 'finds a test with the attribute <Attr>' -ForEach @(
            @{ Attr = '[Xunit.Fact]' }
            @{ Attr = '[FactAttribute]' }
            @{ Attr = '[global::Xunit.TheoryAttribute]' }
        ) {
            $r = Invoke-OnNew @('public class OrderServiceTests', '{', "    $Attr", '    public void Works()', '    {', '        // Act', '        var a = 1;', '        // Act', '        var b = 2;', '        // Assert', '        Assert.Equal(1, a);', '    }', '}')

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'Works: Act appears 2 times'
        }

        It 'finds a test whose attribute list runs over two lines before Fact' {
            $r = Invoke-OnNew @('public class OrderServiceTests', '{', '    [Trait("Story", "PROJ-1"),', '     Fact]', '    public void Works()', '    {', '        // Act', '        var a = 1;', '        // Act', '        var b = 2;', '        // Assert', '        Assert.Equal(1, a);', '    }', '}')

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'Works: Act appears 2 times'
        }

        It 'reads a test file whose path holds a space' {
            $r = Invoke-OnNew -Path 'tests/My Project/OrderTests.cs' -Lines (New-TestClass @('// Act', 'var a = 1;', '// Act', 'var b = 2;', '// Assert', 'Assert.Equal(1, a);'))

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'Total_IsSum: Act appears 2 times'
        }

        It 'skips the generated or build file <Path>' -ForEach @(
            @{ Path = 'tests/Api.Tests/Orders.Designer.cs' }
            @{ Path = 'tests/Api.Tests/Orders.g.cs' }
            @{ Path = 'tests/Api.Tests/Orders.g.i.cs' }
            @{ Path = 'tests/Api.Tests/obj/Debug/Orders.cs' }
            @{ Path = 'tests/Api.Tests/bin/Debug/Orders.cs' }
        ) {
            $r = Invoke-OnNew -Path $Path -Lines (New-TestClass @('Assert.True(true);'))

            $r.ExitCode | Should -Be 3 -Because $r.Output
        }

        It 'does not read an NUnit test' {
            $r = Invoke-OnNew @('public class OrderTests', '{', '    [Test]', '    public void Works()', '    {', '        Assert.That(1, Is.EqualTo(1));', '    }', '}')

            $r.ExitCode | Should -Be 3
        }
    }

    Context 'an older test method' {
        It 'does not report a broken test method that the change does not touch' -Tag '#79' {
            $broken = New-TestClass @('// Act', 'var t = 1;', '// Act', 'var u = 2;', '// Assert', 'Assert.Equal(1, t);')
            $old = ($broken | Select-Object -SkipLast 1) + @(
                '    [Fact]', '    public void Add_Counts()', '    {', '        // Arrange', '        var s = new OrderService();', '        // Act', '        s.Add(1);', '        // Assert', '        Assert.Equal(1, s.Total());', '    }', '}'
            )
            $new = $old.Clone()
            $new[18] = '        s.Add(2);'

            $r = Invoke-OnEdit -Old $old -New $new

            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -Not -Match 'Total_IsSum'
        }

        It 'does not check an older test without markers that the change does not touch' -Tag '#79' {
            $old = (New-TestClass @('Assert.Equal(0, new OrderService().Total());') | Select-Object -SkipLast 1) +
            @('    [Fact]', '    public void Add_Counts()', '    {', '        // Arrange', '        var s = new OrderService();', '        // Act', '        s.Add(1);', '        // Assert', '        Assert.Equal(1, s.Total());', '    }', '}')
            $new = $old.Clone()
            $new[13] = '        var s = new OrderService(1);'

            $r = Invoke-OnEdit -Old $old -New $new

            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match 'Test shape OK: 1 changed test method'
        }

        It 'does not fail an older test without markers when the change edits one line of its body' -Tag '#79' {
            $old = New-TestClass @('var s = 1;', 'Assert.Equal(1, s);')
            $new = $old.Clone()
            $new[5] = '        var s = 2;'

            $r = Invoke-OnEdit -Old $old -New $new

            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match 'Test shape OK: 1 changed test method'
        }

        It 'does not fail an older test whose markers are out of order when the change edits another line' -Tag '#79' {
            $old = New-TestClass @('// Act', 'var t = 1;', '// Arrange', 'var s = 2;', '// Assert', 'Assert.Equal(1, t);')
            $new = $old.Clone()
            $new[6] = '        var t = 3;'

            (Invoke-OnEdit -Old $old -New $new).ExitCode | Should -Be 0
        }

        It 'does not fail an older test with a repeated marker when the change edits another line' -Tag '#79' {
            $old = New-TestClass @('// Arrange', 'var s = 1;', '// Act', 's++;', '// Act', 's++;', '// Assert', 'Assert.Equal(3, s);')
            $new = $old.Clone()
            $new[7] = '        s += 1;'

            (Invoke-OnEdit -Old $old -New $new).ExitCode | Should -Be 0
        }

        It 'does not fail an older test without markers when the change only deletes a line of its body' -Tag '#79' {
            $old = New-TestClass @('var s = 1;', 's++;', 'Assert.Equal(1, s);')
            $new = $old | Where-Object { $_ -notmatch 's\+\+' }

            $r = Invoke-OnEdit -Old $old -New $new

            $r.ExitCode | Should -Be 0 -Because $r.Output
        }

        It 'fails an older test when the change adds a second Act marker' -Tag '#79' {
            $old = New-TestClass @('// Arrange', 'var s = 1;', '// Act', 's++;', '// Assert', 'Assert.Equal(2, s);')
            $new = New-TestClass @('// Arrange', 'var s = 1;', '// Act', 's++;', '// Act', 's++;', '// Assert', 'Assert.Equal(3, s);')

            $r = Invoke-OnEdit -Old $old -New $new

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'Total_IsSum: Act appears 2 times'
        }

        It 'fails an older test when an added marker puts the markers out of order' -Tag '#79' {
            $old = New-TestClass @('// Act', 'var t = 1;', '// Assert', 'Assert.Equal(1, t);')
            $new = New-TestClass @('// Act', 'var t = 1;', '// Assert', 'Assert.Equal(1, t);', '// Arrange', 'var s = 2;')

            $r = Invoke-OnEdit -Old $old -New $new

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'Total_IsSum: the markers are out of order'
        }

        It 'fails only the new test of a file, and not the older one beside it' -Tag '#79' {
            $old = New-TestClass @('var t = 1;', 'Assert.Equal(1, t);')
            $new = ($old | Select-Object -SkipLast 1) + @('    [Fact]', '    public void Added()', '    {', '        Assert.True(true);', '    }', '}')

            $r = Invoke-OnEdit -Old $old -New $new

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'Added: the // Arrange marker is missing'
            $r.Output | Should -Not -Match 'Total_IsSum'
        }

        It 'treats a test whose signature line the change adds as a new test, and wants every marker' -Tag '#79' {
            $old = @('public class OrderServiceTests', '{', '    [Fact]', '    public void Old_Name()', '    {', '        var s = 1;', '        Assert.Equal(1, s);', '    }', '}')
            $new = $old.Clone()
            $new[3] = '    public void Total_IsSum()'

            $r = Invoke-OnEdit -Old $old -New $new

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'Total_IsSum: the // Arrange marker is missing'
        }

        It 'fails an older test from which the change removed the Assert marker' -Tag '#79' {
            $old = New-TestClass @('// Arrange', 'var s = 1;', '// Act', 's++;', '// Assert', 'Assert.Equal(2, s);')
            $new = New-TestClass @('// Arrange', 'var s = 1;', '// Act', 's++;')

            $r = Invoke-OnEdit -Old $old -New $new

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'Total_IsSum: no // Assert follows the // Act'
        }

        It 'fails an older test whose Arrange marker the change replaced with plain text' -Tag '#79' {
            $old = New-TestClass @('// Arrange', 'var s = 1;', '// Act', 's++;', '// Assert', 'Assert.Equal(2, s);')
            $new = $old.Clone()
            $new[5] = '        // set up'

            $r = Invoke-OnEdit -Old $old -New $new

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'Total_IsSum: the // Arrange marker is missing'
        }
    }

    Context 'exit 3, nothing to check' {
        It 'exits 3 when the change only deleted a line just before a test' -Tag '#79' {
            $old = @('public class OrderServiceTests', '{', '    // old note', '    [Fact]', '    public void Total_IsSum()', '    {', '        // Act', '        var a = 1;', '        // Act', '        var b = 2;', '        // Assert', '        Assert.Equal(1, a);', '    }', '}')
            $new = $old | Where-Object { $_ -ne '    // old note' }

            $r = Invoke-OnEdit -Old $old -New $new

            $r.ExitCode | Should -Be 3 -Because $r.Output
            $r.Output | Should -Not -Match 'Total_IsSum'
        }

        It 'exits 3 with one Not applicable line for a change outside C# files' -Tag '#79' {
            $repo = New-Repo
            Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value '// Act'

            $r = Invoke-Gate -Repo $repo

            $r.ExitCode | Should -Be 3
            @($r.Output -split '\r?\n' | Where-Object { $_ -match 'Not applicable:' }) | Should -HaveCount 1
            $r.Output | Should -Not -Match 'Test shape OK'
        }

        It 'exits 3 with one Not applicable line for an empty change' -Tag '#79' {
            $r = Invoke-Gate -Repo (New-Repo)

            $r.ExitCode | Should -Be 3
            @($r.Output -split '\r?\n' | Where-Object { $_ -match 'Not applicable:' }) | Should -HaveCount 1
            $r.Output | Should -Not -Match '0 changed test method'
        }

        It 'exits 3 when a changed C# file holds no test method' -Tag '#79' {
            $r = Invoke-OnNew @('public class Helper', '{', '    public int One() => 1;', '}')

            $r.ExitCode | Should -Be 3
            $r.Output | Should -Match 'Not applicable:'
        }

        It 'does not print Not applicable when it checked a test method' -Tag '#79' {
            $r = Invoke-OnNew (New-TestClass @('// Arrange & Act', 'var t = new OrderService().Total();', '// Assert', 'Assert.Equal(0, t);'))

            $r.ExitCode | Should -Be 0
            $r.Output | Should -Not -Match 'Not applicable'
        }
    }
}

Describe 'Check-TestShape reads the change from git' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $script:ScriptFolder -ChildPath 'Check-TestShape.ps1'
        $script:TestPath = 'Demo/tests/Api.Demo.Tests/OrderServiceTests.cs'
        $script:Clean = @('public class OrderServiceTests', '{', '    [Fact]', '    public void Total_IsSum()', '    {', '        // Arrange & Act', '        var t = 1;', '        // Assert', '        Assert.Equal(1, t);', '    }', '}')
        $script:Broken = @('public class OrderServiceTests', '{', '    [Fact]', '    public void Total_IsSum()', '    {', '        // Arrange & Act', '        var t = 1;', '        // Assert', '        Assert.Equal(1, t);', '    }', '    [Fact]', '    public void Added()', '    {', '        Assert.True(true);', '    }', '}')

        $script:RepoTemplate = Join-Path $TestDrive ('template-' + [guid]::NewGuid().ToString('n'))
        $templateFile = Join-Path $script:RepoTemplate $script:TestPath
        New-Item -ItemType Directory -Path (Split-Path $templateFile) -Force | Out-Null
        git -C $script:RepoTemplate init --quiet --template= -b work
        git -C $script:RepoTemplate config user.email probe@example.invalid
        git -C $script:RepoTemplate config user.name probe
        Set-Content -LiteralPath $templateFile -Value $script:Clean
        git -C $script:RepoTemplate add -A
        git -C $script:RepoTemplate commit --quiet -m base --no-verify

        function New-Repo {
            param([string]$TargetBranch = 'main')
            $repo = Join-Path $TestDrive ('repo-' + [guid]::NewGuid().ToString('n'))
            Copy-Item -LiteralPath $script:RepoTemplate -Destination $repo -Recurse
            git -C $repo update-ref "refs/remotes/origin/$TargetBranch" HEAD
            return $repo
        }

        function Add-BrokenChange {
            param([string]$Repo, [switch]$Commit)
            Set-Content -LiteralPath (Join-Path $Repo $script:TestPath) -Value $script:Broken
            if ($Commit) {
                git -C $Repo add -A
                git -C $Repo commit --quiet -m change --no-verify
            }
        }

        function Invoke-InRepo {
            param([string]$Repo, [hashtable]$Params = @{})
            $out = & $script:ScriptUnderTest -RepoRoot $Repo @Params *>&1 | Out-String
            [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }
    }

    BeforeEach {
        $script:Saved = @{ Target = $env:PR_TARGET_BRANCH; Changed = $env:CHANGED_FILES }
        $env:PR_TARGET_BRANCH = $null
        $env:CHANGED_FILES = $null
    }

    AfterEach {
        $env:PR_TARGET_BRANCH = $script:Saved.Target
        $env:CHANGED_FILES = $script:Saved.Changed
    }

    It 'measures against origin/main when there is no pull request target' -Tag '#79' {
        $repo = New-Repo
        Add-BrokenChange -Repo $repo -Commit

        $r = Invoke-InRepo -Repo $repo

        $r.ExitCode | Should -Be 1 -Because $r.Output
        $r.Output | Should -Match 'Added: the // Arrange marker is missing'
    }

    It 'measures against the pull request target branch when the workflow names one' -Tag '#79' {
        $repo = New-Repo -TargetBranch 'release'
        Add-BrokenChange -Repo $repo -Commit
        $env:PR_TARGET_BRANCH = 'refs/heads/release'

        $r = Invoke-InRepo -Repo $repo

        $r.ExitCode | Should -Be 1 -Because $r.Output
        $r.Output | Should -Match 'Added: the // Arrange marker is missing'
    }

    It 'measures against the trunk that github.trunk names when there is no pull request target' -Tag '#79' {
        $repo = New-Repo -TargetBranch 'trunk'
        Set-Content -LiteralPath (Join-Path $repo 'aisdlc.json') -Value '{ "github": { "trunk": "trunk" } }'
        git -C $repo add -A
        git -C $repo commit --quiet -m config --no-verify
        git -C $repo update-ref refs/remotes/origin/trunk HEAD
        Add-BrokenChange -Repo $repo -Commit

        $r = Invoke-InRepo -Repo $repo

        $r.ExitCode | Should -Be 1 -Because $r.Output
    }

    It 'lets -BaseRef win over the pull request target' -Tag '#79' {
        $repo = New-Repo
        Add-BrokenChange -Repo $repo -Commit
        $env:PR_TARGET_BRANCH = 'does-not-exist'

        $r = Invoke-InRepo -Repo $repo -Params @{ BaseRef = 'origin/main' }

        $r.ExitCode | Should -Be 1 -Because $r.Output
    }

    It 'does not fail an older test without markers when a commit edits one line of it, and fails a new one in the same file' -Tag '#79' {
        $repo = New-Repo
        $file = Join-Path $repo $script:TestPath
        $older = @('public class OrderServiceTests', '{', '    [Fact]', '    public void Total_IsSum()', '    {', '        var t = 1;', '        Assert.Equal(1, t);', '    }', '}')
        Set-Content -LiteralPath $file -Value $older
        git -C $repo commit --quiet -am older --no-verify
        git -C $repo update-ref refs/remotes/origin/main HEAD
        Set-Content -LiteralPath $file -Value ($older -replace 'var t = 1;', 'var t = 2;')
        git -C $repo commit --quiet -am edit --no-verify

        $edited = Invoke-InRepo -Repo $repo
        Set-Content -LiteralPath $file -Value (($older -replace 'var t = 1;', 'var t = 2;')[0..7] + @('    [Fact]', '    public void Added()', '    {', '        Assert.True(true);', '    }', '}'))
        git -C $repo commit --quiet -am add --no-verify
        $added = Invoke-InRepo -Repo $repo

        $edited.ExitCode | Should -Be 0 -Because $edited.Output
        $added.ExitCode | Should -Be 1 -Because $added.Output
        $added.Output | Should -Match 'Added: the // Arrange marker is missing'
        $added.Output | Should -Not -Match 'Total_IsSum'
    }

    It 'still reads an uncommitted edit of a test file' -Tag '#79' {
        $repo = New-Repo
        Add-BrokenChange -Repo $repo

        $r = Invoke-InRepo -Repo $repo

        $r.ExitCode | Should -Be 1 -Because $r.Output
    }

    It 'still reads an untracked test file whole' -Tag '#79' {
        $repo = New-Repo
        Set-Content -LiteralPath (Join-Path $repo 'Demo/tests/Api.Demo.Tests/NewTests.cs') -Value $script:Broken

        $r = Invoke-InRepo -Repo $repo

        $r.ExitCode | Should -Be 1 -Because $r.Output
        $r.Output | Should -Match 'NewTests\.cs'
    }

    It 'exits 3 when the change holds no test method' -Tag '#79' {
        $r = Invoke-InRepo -Repo (New-Repo)

        $r.ExitCode | Should -Be 3 -Because $r.Output
        $r.Output | Should -Match 'Not applicable:'
    }

    It 'exits 2, names the target branch and prints a FIX line when it has no merge base' -Tag '#79' {
        $repo = New-Repo
        $env:PR_TARGET_BRANCH = 'refs/heads/does-not-exist'

        $r = Invoke-InRepo -Repo $repo

        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'origin/does-not-exist'
        $r.Output | Should -Match '(?m)^FIX: \S'
    }

    It 'exits 2 and prints a FIX line when git is not on the PATH' -Tag '#79' {
        $repo = New-Repo
        $empty = Join-Path $TestDrive 'no-git'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        $pwsh = Join-Path $PSHOME ($IsWindows ? 'pwsh.exe' : 'pwsh')
        $savedPath = $env:PATH

        try {
            $env:PATH = $empty
            $out = & $pwsh -NoProfile -File $script:ScriptUnderTest -RepoRoot $repo *>&1 | Out-String
            $code = $LASTEXITCODE
        }
        finally { $env:PATH = $savedPath }

        $code | Should -Be 2 -Because $out
        $out | Should -Match '(?m)^FIX: \S'
    }

    It 'prints a FIX line before every exit 2 in the script' -Tag '#79' {
        $lines = @(Get-Content -LiteralPath $script:ScriptUnderTest)
        $exits = @(0..($lines.Count - 1) | Where-Object { $lines[$_] -match '^\s*exit 2\b' })

        $exits | Should -Not -BeNullOrEmpty
        foreach ($i in $exits) { $lines[$i - 1] | Should -Match 'FIX: ' -Because "line $($i + 1) exits 2" }
    }

    It 'documents the exit code 3 and the default base in its help' -Tag '#79' {
        $help = Get-Content -LiteralPath $script:ScriptUnderTest -Raw
        $help | Should -Match '3 no test method changed'
        $help | Should -Match 'PR_TARGET_BRANCH'
        $help | Should -Match 'github\.trunk'
    }
}
