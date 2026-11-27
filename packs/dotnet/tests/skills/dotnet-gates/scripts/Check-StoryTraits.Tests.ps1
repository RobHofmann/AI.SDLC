#requires -Version 7.4

BeforeAll { $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm' }

Describe 'Check-StoryTraits' {
    BeforeAll {
        $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
        if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' 'tests' 'skills' 'ai-sdlc-gates' 'scripts' }
        Import-Module (Join-Path $aiSdlcGates 'DocToolTestHarness.psm1') -Force
        $script:ScriptUnderTest = Join-Path -Path $script:ScriptFolder -ChildPath 'Check-StoryTraits.ps1'

        function Save-Change {
            param([Parameter(Mandatory)][string]$RepoRoot, [switch]$AsBase)
            git -C $RepoRoot add -A
            git -C $RepoRoot commit --quiet -m change --no-verify --allow-empty
            if ($AsBase) { git -C $RepoRoot update-ref refs/remotes/origin/main HEAD }
        }

        function Invoke-Gate {
            param(
                [Parameter(Mandatory)][string]$RepoRoot,
                [switch]$Strict
            )
            # The gate judges the committed change since origin/main, so commit what the test wrote.
            Save-Change -RepoRoot $RepoRoot
            if ($Strict) {
                $out = & $script:ScriptUnderTest -RepoRoot $RepoRoot -Strict *>&1 | Out-String
            }
            else {
                $out = & $script:ScriptUnderTest -RepoRoot $RepoRoot *>&1 | Out-String
            }
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }

        function New-TestFile {
            param(
                [Parameter(Mandatory)][string]$RepoRoot,
                [Parameter(Mandatory)][string]$Name,
                [Parameter(Mandatory)][string]$Content
            )
            $testsDir = Join-Path -Path $RepoRoot -ChildPath 'Demo' | Join-Path -ChildPath 'tests'
            New-Item -ItemType Directory -Path $testsDir -Force | Out-Null
            $path = Join-Path -Path $testsDir -ChildPath $Name
            Set-Content -LiteralPath $path -Value $Content -Encoding UTF8
            return $path
        }

        function New-EmptyTestsDir {
            param(
                [Parameter(Mandatory)][string]$RepoRoot
            )
            $testsDir = Join-Path -Path $RepoRoot -ChildPath 'Demo' | Join-Path -ChildPath 'tests'
            New-Item -ItemType Directory -Path $testsDir -Force | Out-Null
            return $testsDir
        }
    }

    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        Set-AiSdlcTestConfig -Root $script:Root
        git -C $script:Root init --quiet -b main
        git -C $script:Root config user.email probe@example.invalid
        git -C $script:Root config user.name probe
        git -C $script:Root config core.autocrlf false
        Save-Change -RepoRoot $script:Root -AsBase
        $env:CHANGED_FILES = $null
    }

    AfterEach { $env:CHANGED_FILES = $null }

    It 'passes a clean fixture with a valid Story trait (exit 0)' {
        $cs = @'
using Xunit;

public class CleanTests
{
    [Fact]
    [Trait("Story", "#42")]
    public void DoesSomething()
    {
        Assert.True(true);
    }
}
'@
        New-TestFile -RepoRoot $script:Root -Name 'CleanTests.cs' -Content $cs | Out-Null

        $result = Invoke-Gate -RepoRoot $script:Root

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'All test classes carry a Story trait\.'
    }

    It 'fails on a malformed Story key regardless of Strict (exit 1)' {
        $cs = @'
using Xunit;

public class MalformedKeyTests
{
    [Fact]
    [Trait("Story", "bad-key")]
    public void DoesSomething()
    {
        Assert.True(true);
    }
}
'@
        New-TestFile -RepoRoot $script:Root -Name 'MalformedKeyTests.cs' -Content $cs | Out-Null

        $result = Invoke-Gate -RepoRoot $script:Root

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'malformed Story key'
    }

    It 'is report-only for an untagged test class without Strict (exit 0)' {
        # Advisory for untagged classes: missing Story traits do NOT fail the build unless
        # -Strict is passed. A malformed key, by contrast, always fails.
        $cs = @'
using Xunit;

public class UntaggedTests
{
    [Fact]
    public void DoesSomething()
    {
        Assert.True(true);
    }
}
'@
        New-TestFile -RepoRoot $script:Root -Name 'UntaggedTests.cs' -Content $cs | Out-Null

        $result = Invoke-Gate -RepoRoot $script:Root

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Report-only: missing Story traits do not fail the build\.'
    }

    It 'fails on an untagged test class in Strict mode (exit 1)' {
        $cs = @'
using Xunit;

public class UntaggedTests
{
    [Fact]
    public void DoesSomething()
    {
        Assert.True(true);
    }
}
'@
        New-TestFile -RepoRoot $script:Root -Name 'UntaggedTests.cs' -Content $cs | Out-Null

        $result = Invoke-Gate -RepoRoot $script:Root -Strict

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'Strict mode:.*missing a Story trait; failing\.'
    }

    It 'fails on a malformed Story key in Strict mode, reported as malformed (exit 1)' {
        # Malformed-key failure takes precedence over the strict-untagged failure: the script
        # exits in the malformed block before the strict block, so the message stays "malformed".
        $cs = @'
using Xunit;

public class MalformedKeyStrictTests
{
    [Fact]
    [Trait("Story", "bad-key")]
    public void DoesSomething()
    {
        Assert.True(true);
    }
}
'@
        New-TestFile -RepoRoot $script:Root -Name 'MalformedKeyStrictTests.cs' -Content $cs | Out-Null

        $result = Invoke-Gate -RepoRoot $script:Root -Strict

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'malformed Story key'
    }

    It 'exits 0 when no tests directory exists at all' {
        # $script:Root has no Demo/tests subtree; the script reports nothing to check.
        $result = Invoke-Gate -RepoRoot $script:Root

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'No tests directory found'
        $result.Output | Should -Match 'nothing to check\.'
    }

    It 'exits 0 when the tests directory exists but contains no test files' {
        New-EmptyTestsDir -RepoRoot $script:Root | Out-Null

        $result = Invoke-Gate -RepoRoot $script:Root

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Test classes found : 0'
        $result.Output | Should -Match 'All test classes carry a Story trait\.'
    }

    It 'counts a class-level Story trait placed above the class declaration: <Key> (exit 0)' -TestCases @(
        @{ Key = '#2001'; ClassName = 'ClassLevelStoryTests' }
    ) {
        # A [Trait("Story",...)] on the line above the class declaration is deferred to that class, so
        # the class counts as covered (matching the script's documented "class-level attribute" rule).
        # LEGACY-0 does not cover a class the change adds; the contexts below cover it on older code.
        $cs = @"
using Xunit;

[Trait("Story", "$Key")]
public class $ClassName
{
    [Fact]
    public void DoesSomething()
    {
        Assert.True(true);
    }
}
"@
        New-TestFile -RepoRoot $script:Root -Name "$ClassName.cs" -Content $cs | Out-Null

        $result = Invoke-Gate -RepoRoot $script:Root -Strict

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'With Story trait   : 1'
        $result.Output | Should -Match 'Malformed keys     : 0'
        $result.Output | Should -Match 'All test classes carry a Story trait\.'
    }

    It 'does not leak a class-level Story trait to the next, untagged class (Strict exit 1)' {
        # The deferred trait must be consumed by the first class only: a following untagged class
        # stays untagged. With -Strict that untagged class fails the build.
        $cs = @'
using Xunit;

[Trait("Story", "#2001")]
public class TaggedAboveTests
{
    [Fact]
    public void A()
    {
        Assert.True(true);
    }
}

public class UntaggedAfterTests
{
    [Fact]
    public void B()
    {
        Assert.True(true);
    }
}
'@
        New-TestFile -RepoRoot $script:Root -Name 'AttributionTests.cs' -Content $cs | Out-Null

        $result = Invoke-Gate -RepoRoot $script:Root -Strict

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'With Story trait   : 1'
        $result.Output | Should -Match 'Missing Story trait: 1'
    }

    It 'ignores a non-test class with no Fact or Theory even in Strict mode (exit 0)' {
        # A class only counts as a test class when its body contains a [Fact]/[Theory].
        # Helper, fixture, and mock types with no test methods are not reported.
        $cs = @'
using Xunit;

public class PlainHelper
{
    public int Add(int a, int b)
    {
        return a + b;
    }
}
'@
        New-TestFile -RepoRoot $script:Root -Name 'PlainHelper.cs' -Content $cs | Out-Null

        $result = Invoke-Gate -RepoRoot $script:Root -Strict

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Test classes found : 0'
        $result.Output | Should -Match 'All test classes carry a Story trait\.'
    }

    It 'accepts a cross-repository key owner/repo#42 (exit 0)' {
        # The story pattern takes an optional owner/repo before the number.
        $cs = @'
using Xunit;

public class OtherPrefixTests
{
    [Fact]
    [Trait("Story", "contoso/portal#99")]
    public void DoesSomething()
    {
        Assert.True(true);
    }
}
'@
        New-TestFile -RepoRoot $script:Root -Name 'OtherPrefixTests.cs' -Content $cs | Out-Null

        $result = Invoke-Gate -RepoRoot $script:Root

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Malformed keys     : 0'
        $result.Output | Should -Match 'All test classes carry a Story trait\.'
    }

    It 'fails on a bare number without the hash (exit 1)' {
        # A story key is #42; a bare 42 does not match the story pattern.
        $cs = @'
using Xunit;

public class DigitPrefixTests
{
    [Fact]
    [Trait("Story", "42")]
    public void DoesSomething()
    {
        Assert.True(true);
    }
}
'@
        New-TestFile -RepoRoot $script:Root -Name 'DigitPrefixTests.cs' -Content $cs | Out-Null

        $result = Invoke-Gate -RepoRoot $script:Root

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'Malformed keys     : 1'
        $result.Output | Should -Match 'malformed Story key'
    }

    It 'fails on a key with text after the number (exit 1)' {
        # The whole value must be the key: #42 followed by more text is malformed.
        $cs = @'
using Xunit;

public class LowercasePrefixTests
{
    [Fact]
    [Trait("Story", "#42 login")]
    public void DoesSomething()
    {
        Assert.True(true);
    }
}
'@
        New-TestFile -RepoRoot $script:Root -Name 'LowercasePrefixTests.cs' -Content $cs | Out-Null

        $result = Invoke-Gate -RepoRoot $script:Root

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'malformed Story key'
    }

    Context 'it judges only the test classes and methods the change adds' {
        BeforeAll {
            function New-LegacyClass {
                param([string]$Body = '        Assert.True(true);', [string]$Extra = '')
                return @"
using Xunit;

[Trait("Story", "LEGACY-0")]
public class OldTests
{
    [Fact]
    public void Existing()
    {
$Body
    }
$Extra}
"@
            }
        }

        It 'fails a test class that the change adds with no Story trait' -Tag '#80' {
            New-TestFile -RepoRoot $script:Root -Name 'OldTests.cs' -Content (New-LegacyClass) | Out-Null
            Save-Change -RepoRoot $script:Root -AsBase
            $cs = "using Xunit;`n`npublic class NewTests`n{`n    [Fact]`n    public void Fresh()`n    {`n        Assert.True(true);`n    }`n}`n"
            New-TestFile -RepoRoot $script:Root -Name 'NewTests.cs' -Content $cs | Out-Null

            $result = Invoke-Gate -RepoRoot $script:Root -Strict

            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'NewTests'
            $result.Output | Should -Match 'Missing Story trait: 1'
        }

        It 'passes an edit inside a LEGACY-0 class' -Tag '#80' {
            New-TestFile -RepoRoot $script:Root -Name 'OldTests.cs' -Content (New-LegacyClass) | Out-Null
            Save-Change -RepoRoot $script:Root -AsBase
            New-TestFile -RepoRoot $script:Root -Name 'OldTests.cs' -Content (New-LegacyClass -Body '        Assert.False(false);') | Out-Null

            $result = Invoke-Gate -RepoRoot $script:Root -Strict

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'Missing Story trait: 0'
        }

        It 'does not read a file that the change did not touch' -Tag '#80' {
            $cs = "using Xunit;`n`npublic class UntouchedTests`n{`n    [Fact]`n    public void Old()`n    {`n    }`n}`n"
            New-TestFile -RepoRoot $script:Root -Name 'UntouchedTests.cs' -Content $cs | Out-Null
            Save-Change -RepoRoot $script:Root -AsBase
            $tagged = "using Xunit;`n`n[Trait(`"Story`", `"#80`")]`npublic class TaggedTests`n{`n    [Fact]`n    public void Fresh()`n    {`n    }`n}`n"
            New-TestFile -RepoRoot $script:Root -Name 'TaggedTests.cs' -Content $tagged | Out-Null

            $result = Invoke-Gate -RepoRoot $script:Root -Strict

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Not -Match 'UntouchedTests'
        }

        It 'passes an edit inside an old class that has no Story trait at all' -Tag '#80' {
            $cs = "using Xunit;`n`npublic class PlainOldTests`n{`n    [Fact]`n    public void Old()`n    {`n        Assert.True(true);`n    }`n}`n"
            New-TestFile -RepoRoot $script:Root -Name 'PlainOldTests.cs' -Content $cs | Out-Null
            Save-Change -RepoRoot $script:Root -AsBase
            New-TestFile -RepoRoot $script:Root -Name 'PlainOldTests.cs' -Content $cs.Replace('Assert.True(true)', 'Assert.False(false)') | Out-Null

            $result = Invoke-Gate -RepoRoot $script:Root -Strict

            $result.ExitCode | Should -Be 0
        }

        It 'does not accept LEGACY-0 on a class that the change adds' -Tag '#80' {
            New-TestFile -RepoRoot $script:Root -Name 'OldTests.cs' -Content (New-LegacyClass) | Out-Null

            $result = Invoke-Gate -RepoRoot $script:Root -Strict

            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'LEGACY-0 is not allowed'
        }

        It 'fails a test method that the change adds to a LEGACY-0 class with no key of its own' -Tag '#80' {
            New-TestFile -RepoRoot $script:Root -Name 'OldTests.cs' -Content (New-LegacyClass) | Out-Null
            Save-Change -RepoRoot $script:Root -AsBase
            $extra = "`n    [Fact]`n    public void Added()`n    {`n    }`n"
            New-TestFile -RepoRoot $script:Root -Name 'OldTests.cs' -Content (New-LegacyClass -Extra $extra) | Out-Null

            $result = Invoke-Gate -RepoRoot $script:Root -Strict

            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'method Added'
        }

        It 'passes a test method that the change adds to a LEGACY-0 class with a real key' -Tag '#80' {
            New-TestFile -RepoRoot $script:Root -Name 'OldTests.cs' -Content (New-LegacyClass) | Out-Null
            Save-Change -RepoRoot $script:Root -AsBase
            $extra = "`n    [Fact]`n    [Trait(`"Story`", `"#80`")]`n    public void Added()`n    {`n    }`n"
            New-TestFile -RepoRoot $script:Root -Name 'OldTests.cs' -Content (New-LegacyClass -Extra $extra) | Out-Null

            $result = Invoke-Gate -RepoRoot $script:Root -Strict

            $result.ExitCode | Should -Be 0
        }

        It 'fails a malformed key on a line the change adds, and ignores one on an older line' -Tag '#80' {
            $old = "using Xunit;`n`npublic class BadOldTests`n{`n    [Fact]`n    [Trait(`"Story`", `"bad-key`")]`n    public void Old()`n    {`n    }`n}`n"
            New-TestFile -RepoRoot $script:Root -Name 'BadOldTests.cs' -Content $old | Out-Null
            Save-Change -RepoRoot $script:Root -AsBase
            New-TestFile -RepoRoot $script:Root -Name 'BadOldTests.cs' -Content $old.Replace("    {`n    }", "    {`n        Assert.True(true);`n    }") | Out-Null

            $older = Invoke-Gate -RepoRoot $script:Root -Strict

            $older.ExitCode | Should -Be 0
            $older.Output | Should -Match 'Malformed keys     : 0'

            $added = "using Xunit;`n`npublic class BadNewTests`n{`n    [Fact]`n    [Trait(`"Story`", `"bad-key`")]`n    public void Fresh()`n    {`n    }`n}`n"
            New-TestFile -RepoRoot $script:Root -Name 'BadNewTests.cs' -Content $added | Out-Null

            $result = Invoke-Gate -RepoRoot $script:Root

            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'BadNewTests.cs'
            $result.Output | Should -Not -Match 'BadOldTests.cs'
        }

        It 'reads an NUnit Property and an MSTest TestProperty as a Story trait: <Case>' -Tag '#80' -TestCases @(
            @{ Case = 'NUnit with a real key'; Attribute = '[Test]'; Trait = '[Property("Story", "#80")]'; Exit = 0 }
            @{ Case = 'NUnit with a malformed key'; Attribute = '[Test]'; Trait = '[Property("Story", "bad-key")]'; Exit = 1 }
            @{ Case = 'NUnit with no trait'; Attribute = '[TestCase(1)]'; Trait = ''; Exit = 1 }
            @{ Case = 'MSTest with a real key'; Attribute = '[TestMethod]'; Trait = '[TestProperty("Story", "#80")]'; Exit = 0 }
            @{ Case = 'MSTest with a malformed key'; Attribute = '[DataTestMethod]'; Trait = '[TestProperty("Story", "bad-key")]'; Exit = 1 }
        ) {
            $cs = "public class FrameworkTests`n{`n    $Attribute`n    $Trait`n    public void Works()`n    {`n    }`n}`n"
            New-TestFile -RepoRoot $script:Root -Name 'FrameworkTests.cs' -Content $cs | Out-Null

            $result = Invoke-Gate -RepoRoot $script:Root -Strict

            $result.ExitCode | Should -Be $Exit
        }

        It 'exits 2 with a FIX line when CHANGED_FILES is set and there is no merge base' -Tag '#80' {
            git -C $script:Root update-ref -d refs/remotes/origin/main
            $cs = "using Xunit;`n`npublic class NewTests`n{`n    [Fact]`n    public void Fresh()`n    {`n    }`n}`n"
            New-TestFile -RepoRoot $script:Root -Name 'NewTests.cs' -Content $cs | Out-Null
            $env:CHANGED_FILES = 'Demo/tests/NewTests.cs'

            $result = Invoke-Gate -RepoRoot $script:Root -Strict

            $result.ExitCode | Should -Be 2
            $result.Output | Should -Match '(?m)^FIX: '
            $result.Output | Should -Not -Match 'Missing Story trait'
        }

        It 'exits 2 with a FIX line in a local run with no merge base, and does not judge whole files' -Tag '#80' {
            git -C $script:Root update-ref -d refs/remotes/origin/main
            $cs = "using Xunit;`n`npublic class NewTests`n{`n    [Fact]`n    public void Fresh()`n    {`n    }`n}`n"
            New-TestFile -RepoRoot $script:Root -Name 'NewTests.cs' -Content $cs | Out-Null

            $result = Invoke-Gate -RepoRoot $script:Root -Strict

            $result.ExitCode | Should -Be 2
            $result.Output | Should -Match '(?m)^FIX: '
            $result.Output | Should -Not -Match 'Missing Story trait'
        }
    }

    Context 'it finds a test class inside a namespace' {
        BeforeAll {
            $script:Untagged = "    public class InsideTests`n    {`n        [Fact]`n        public void DoesSomething()`n        {`n        }`n    }`n"
        }

        It 'sees an untagged class in a block namespace with the brace on the same line (Strict exit 1)' {
            $cs = "using Xunit;`n`nnamespace Contoso.Tests {`n$($script:Untagged)}`n"
            New-TestFile -RepoRoot $script:Root -Name 'SameLine.cs' -Content $cs | Out-Null

            $result = Invoke-Gate -RepoRoot $script:Root -Strict

            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'class InsideTests'
        }

        It 'sees an untagged class in a block namespace with the brace on the next line (Strict exit 1)' {
            $cs = "using Xunit;`n`nnamespace Contoso.Tests`n{`n$($script:Untagged)}`n"
            New-TestFile -RepoRoot $script:Root -Name 'NextLine.cs' -Content $cs | Out-Null

            $result = Invoke-Gate -RepoRoot $script:Root -Strict

            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'class InsideTests'
        }

        It 'sees an untagged class in nested block namespaces (Strict exit 1)' {
            $cs = "using Xunit;`n`nnamespace Contoso`n{`n    namespace Tests`n    {`n$($script:Untagged)    }`n}`n"
            New-TestFile -RepoRoot $script:Root -Name 'Nested.cs' -Content $cs | Out-Null

            $result = Invoke-Gate -RepoRoot $script:Root -Strict

            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'Test classes found : 1'
        }

        It 'sees an untagged class in a file-scoped namespace (Strict exit 1)' {
            $cs = "using Xunit;`n`nnamespace Contoso.Tests;`n`npublic class InsideTests`n{`n    [Fact]`n    public void DoesSomething()`n    {`n    }`n}`n"
            New-TestFile -RepoRoot $script:Root -Name 'FileScoped.cs' -Content $cs | Out-Null

            $result = Invoke-Gate -RepoRoot $script:Root -Strict

            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'class InsideTests'
        }

        It 'passes a tagged class in a block namespace (exit 0)' {
            $cs = "using Xunit;`n`nnamespace Contoso.Tests`n{`n    [Trait(`"Story`", `"#42`")]`n$($script:Untagged)}`n"
            New-TestFile -RepoRoot $script:Root -Name 'Tagged.cs' -Content $cs | Out-Null

            $result = Invoke-Gate -RepoRoot $script:Root -Strict

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'Test classes found : 1'
        }

        It 'does not count a class nested in a test class as a top-level class (Strict exit 0)' {
            $cs = @'
using Xunit;

namespace Contoso.Tests
{
    [Trait("Story", "#42")]
    public class OuterTests
    {
        [Fact]
        public void DoesSomething()
        {
        }

        public class InnerTests
        {
            [Fact]
            public void Nested()
            {
            }
        }
    }
}
'@
            New-TestFile -RepoRoot $script:Root -Name 'Inner.cs' -Content $cs | Out-Null

            $result = Invoke-Gate -RepoRoot $script:Root -Strict

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'Test classes found : 1'
        }
    }
}
