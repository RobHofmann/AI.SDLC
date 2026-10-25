#requires -Version 7.4

Describe 'Check-StoryTraits' {
    BeforeAll {
        $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
        if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
        Import-Module (Join-Path $aiSdlcGates 'DocToolTestHarness.psm1') -Force
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Check-StoryTraits.ps1'

        function Invoke-Gate {
            param(
                [Parameter(Mandatory)][string]$RepoRoot,
                [switch]$Strict
            )
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
    }

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
        @{ Key = 'LEGACY-0'; ClassName = 'PredatesTheConventionTests' }
    ) {
        # A [Trait("Story",...)] on the line above the class declaration is deferred to that class, so
        # the class counts as covered (matching the script's documented "class-level attribute" rule).
        # LEGACY-0 is the placeholder for a class that predates the convention; it passes without
        # naming a real issue.
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
}
