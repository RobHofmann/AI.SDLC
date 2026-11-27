#requires -Version 7.4

BeforeAll { $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm' }

Describe 'Check-CommentHygiene' {
    BeforeAll {
        Import-Module (Join-Path $script:ScriptFolder 'AiSdlcConfig.psm1') -Force
        $script:ScriptUnderTest = Join-Path -Path $script:ScriptFolder -ChildPath 'Check-CommentHygiene.ps1'

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

    It 'is registered as a blocking C10 gate of the core package' {
        (Get-Content (Join-Path $script:ScriptFolder '..' 'gates.json') -Raw) | Should -Match '"script": "scripts/Check-CommentHygiene.ps1", "clause": "C10", "mode": "Blocking"'
    }
}

Describe 'Check-CommentHygiene for YAML and PowerShell' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $script:ScriptFolder -ChildPath 'Check-CommentHygiene.ps1'

        function New-Diff {
            param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Added, [int]$Start = 10, [string[]]$Context = @())
            $lines = @("diff --git a/$Path b/$Path", "--- a/$Path", "+++ b/$Path", "@@ -$Start,$($Context.Count) +$Start,$($Context.Count + $Added.Count) @@")
            $lines += $Context | ForEach-Object { " $_" }
            $lines += $Added | ForEach-Object { "+$_" }
            $lines -join "`n"
        }

        function Invoke-Check {
            param([Parameter(Mandatory)][AllowEmptyString()][string]$Diff)
            $out = & $script:ScriptUnderTest -Language YamlPowerShell -DiffText $Diff *>&1 | Out-String
            [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }
    }

    Context 'a comment that breaks clause C10 is a finding' {
        It 'reports commented-out PowerShell code and names the file and the line' -Tag '#73' -ForEach @(
            @{ Code = '# $count = 1' }
            @{ Code = '# Get-ChildItem -Path $root' }
            @{ Code = '# if ($ok) {' }
            @{ Code = '# }' }
            @{ Code = '# foreach ($item in $items) {' }
            @{ Code = '# return $null' }
            @{ Code = '$a = 1 # $b = 2' }
        ) {
            $r = Invoke-Check (New-Diff 'tools/Run.ps1' @('$x = 1', $Code) -Start 20)

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'tools/Run\.ps1:21  \[commented-out code\]'
            $r.Output | Should -Match 'FIX: '
        }

        It 'reports commented-out YAML code' -Tag '#73' -ForEach @(
            @{ Code = '# - uses: actions/checkout@v4' }
            @{ Code = '# runs-on: ubuntu-latest' }
            @{ Code = '#   timeout-minutes: 10' }
            @{ Code = '  # name: "Build"' }
        ) {
            $r = Invoke-Check (New-Diff '.github/workflows/ci.yml' @('on: push', $Code) -Start 1)

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'ci\.yml:2  \[commented-out code\]'
        }

        It 'reports a TODO without an issue key in <Path> and passes one that has a key' -Tag '#73' -ForEach @(
            @{ Path = 'tools/Run.ps1' }
            @{ Path = 'ci/build.yml' }
        ) {
            $bad = Invoke-Check (New-Diff $Path @('# TODO drop this after the move'))
            $good = Invoke-Check (New-Diff $Path @('# TODO #42: drop this after the move'))

            $bad.ExitCode | Should -Be 1 -Because $bad.Output
            $bad.Output | Should -Match '\[TODO without an issue key\]'
            $good.ExitCode | Should -Be 0 -Because $good.Output
        }

        It 'reports a comment that names an AI tool in <Path>' -Tag '#73' -ForEach @(
            @{ Path = 'tools/Run.ps1'; Code = '# written by Copilot' }
            @{ Path = 'ci/build.yml'; Code = 'key: value # generated by a tool' }
        ) {
            $r = Invoke-Check (New-Diff $Path @($Code))

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match '\[names an AI tool\]'
        }

        It 'reports a bare TODO inside the help block, but not a code-like help line' -Tag '#73' {
            $diff = New-Diff 'tools/Run.ps1' @('<#', '.SYNOPSIS', '    Runs the build.', '.EXAMPLE', '    $x = 1', '    TODO later', '#>', 'param()') -Start 1

            $r = Invoke-Check $diff

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'Run\.ps1:6  \[TODO without an issue key\]'
            $r.Output | Should -Not -Match 'Run\.ps1:5'
        }

        It 'reports commented-out code inside a block comment that is not a help block' -Tag '#73' {
            $r = Invoke-Check (New-Diff 'tools/Run.ps1' @('<#', '$a = 1', '#>', '$b = 2') -Start 1)

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'Run\.ps1:2  \[commented-out code\]'
        }

        It 'reads a comment in <Path>' -Tag '#73' -ForEach @(
            @{ Path = 'tools/Mod.psm1' }
            @{ Path = 'tools/Mod.psd1' }
        ) {
            $r = Invoke-Check (New-Diff $Path @('# $a = 1'))

            $r.ExitCode | Should -Be 1 -Because $r.Output
        }

        It 'reads a comment line inside a YAML block scalar' -Tag '#73' {
            $r = Invoke-Check (New-Diff 'ci/build.yml' @('run: |', '  # $a = 1', '  echo hi') -Start 1)

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'build\.yml:2  \[commented-out code\]'
        }
    }

    Context 'what passes' {
        It 'passes a comment that says why: <Code>' -Tag '#73' -ForEach @(
            @{ Path = 'tools/Run.ps1'; Code = '# The API rejects a batch over 500 rows, see #12.' }
            @{ Path = 'tools/Run.ps1'; Code = '# return early when the cache is empty' }
            @{ Path = 'tools/Run.ps1'; Code = '# Get-AiSdlcChange reads the committed change only.' }
            @{ Path = 'ci/build.yml'; Code = '# Pin the action to a full SHA, see #12.' }
            @{ Path = 'ci/build.yml'; Code = '# Note: the cache key holds the lock hash' }
        ) {
            $r = Invoke-Check (New-Diff $Path @($Code))

            $r.ExitCode | Should -Be 0 -Because $r.Output
        }

        It 'passes the comment-based help block' -Tag '#73' {
            $r = Invoke-Check (New-Diff 'tools/Run.ps1' @('<#', '.SYNOPSIS', '    Runs the build.', '.PARAMETER Path', '    The folder.', '.EXAMPLE', '    pwsh tools/Run.ps1', '#>', 'param([string]$Path)') -Start 1)

            $r.ExitCode | Should -Be 0 -Because $r.Output
        }

        It 'passes a help block that names the tools a gate looks for, and a comment that names a .claude path' -Tag '#73' {
            $help = Invoke-Check (New-Diff 'tools/Run.ps1' @('<#', '.SYNOPSIS', '    Reports a comment that names Copilot.', '#>', 'param()') -Start 1)
            $path = Invoke-Check (New-Diff 'tools/Run.ps1' @('# The hook runs from .claude/hooks/ and reads the change.') -Start 1)

            $help.ExitCode | Should -Be 0 -Because $help.Output
            $path.ExitCode | Should -Be 0 -Because $path.Output
        }

        It 'passes #Requires, #region, #endregion and a shebang' -Tag '#73' {
            $r = Invoke-Check (New-Diff 'tools/Run.ps1' @('#!/usr/bin/env pwsh', '#Requires -Version 7', '#region Setup', '$count = 1', '#endregion') -Start 1)

            $r.ExitCode | Should -Be 0 -Because $r.Output
        }

        It 'passes the ai-sdlc marker lines in <Path>' -Tag '#73' -ForEach @(
            @{ Path = 'tools/Run.ps1' }
            @{ Path = 'ci/build.yml' }
        ) {
            $r = Invoke-Check (New-Diff $Path @('# ai-sdlc:core:start', 'a: 1', '# ai-sdlc:core:end') -Start 1)

            $r.ExitCode | Should -Be 0 -Because $r.Output
        }

        It 'does not read a # inside a quoted YAML string or a PowerShell string as a comment' -Tag '#73' {
            $yaml = Invoke-Check (New-Diff 'ci/build.yml' @('a: "x # $b = 1"', "b: 'TODO # fix'", 'c: http://host/#anchor') -Start 1)
            $ps = Invoke-Check (New-Diff 'tools/Run.ps1' @("`$a = '# `$b = 1'", "`$c = @'", '# TODO in a here-string', "'@") -Start 1)

            $yaml.ExitCode | Should -Be 0 -Because $yaml.Output
            $ps.ExitCode | Should -Be 0 -Because $ps.Output
        }

        It 'does not fail an older comment that sits next to an added line' -Tag '#73' {
            $r = Invoke-Check (New-Diff 'tools/Run.ps1' -Context @('# $old = 1') -Added @('$new = 2'))

            $r.ExitCode | Should -Be 0 -Because $r.Output
        }

        It 'exits 3 when the change adds no PowerShell or YAML line' -Tag '#73' {
            $r = Invoke-Check (New-Diff 'Demo/src/Foo.cs' @('// var a = 1;'))

            $r.ExitCode | Should -Be 3
            $r.Output | Should -Match 'Not applicable: the change adds no PowerShell or YAML line'
        }

        It 'leaves a PowerShell comment alone in the default C# mode' -Tag '#73' {
            $out = & $script:ScriptUnderTest -DiffText (New-Diff 'tools/Run.ps1' @('# $a = 1')) *>&1 | Out-String

            $LASTEXITCODE | Should -Be 0 -Because $out
        }
    }

    Context 'a change read through git' {
        BeforeAll {
            function New-ScriptRepo {
                $PSNativeCommandUseErrorActionPreference = $true
                $repo = Join-Path $TestDrive ('repo-' + [guid]::NewGuid().ToString('n'))
                New-Item -ItemType Directory -Path (Join-Path $repo 'tools') -Force | Out-Null
                git -C $repo init --quiet -b work
                git -C $repo config user.email probe@example.invalid
                git -C $repo config user.name probe
                git -C $repo config core.autocrlf false
                $body = @("`$text = @'") + (1..40 | ForEach-Object { "line $_" }) + @("'@", 'Write-Output $text')
                Set-Content -LiteralPath (Join-Path $repo 'tools/Run.ps1') -Value $body
                git -C $repo add -A
                git -C $repo commit --quiet --no-verify -m base
                git -C $repo update-ref refs/remotes/origin/main HEAD
                return $repo
            }

            function Invoke-RepoCheck {
                param([string]$Repo)
                $out = & $script:ScriptUnderTest -Language YamlPowerShell -RepoRoot $Repo -BaseRef origin/main *>&1 | Out-String
                [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
            }
        }

        BeforeEach {
            $script:SavedEnv = @{ T = $env:PR_TARGET_BRANCH; C = $env:CHANGED_FILES }
            $env:PR_TARGET_BRANCH = $null
            $env:CHANGED_FILES = $null
        }

        AfterEach {
            $env:PR_TARGET_BRANCH = $script:SavedEnv.T
            $env:CHANGED_FILES = $script:SavedEnv.C
        }

        It 'reads the whole PowerShell file, so a line added deep inside a here-string is not a comment' -Tag '#73' {
            $repo = New-ScriptRepo
            $path = Join-Path $repo 'tools/Run.ps1'
            $lines = [System.Collections.Generic.List[string]]@(Get-Content -LiteralPath $path)
            $lines.Insert(40, '# $inside = 1')
            Set-Content -LiteralPath $path -Value $lines

            $r = Invoke-RepoCheck $repo

            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match 'Comment hygiene OK: 1 added'
        }

        It 'reports commented-out code in an untracked YAML file' -Tag '#73' {
            $repo = New-ScriptRepo
            Set-Content -LiteralPath (Join-Path $repo 'build.yml') -Value @('trigger: none', '# - uses: actions/checkout@v4')

            $r = Invoke-RepoCheck $repo

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'build\.yml:2  \[commented-out code\]'
        }

        It 'names a PowerShell file that does not parse as not checked, never as clean' -Tag '#73' {
            $repo = New-ScriptRepo
            Set-Content -LiteralPath (Join-Path $repo 'tools/Broken.ps1') -Value @('function Get-Count {', '    1')

            $r = Invoke-RepoCheck $repo

            $r.ExitCode | Should -Be 2 -Because $r.Output
            $r.Output | Should -Match 'NOTHING WAS CHECKED'
            $r.Output | Should -Match 'tools/Broken\.ps1'
            $r.Output | Should -Match 'FIX: '
        }

        It 'skips a file that apm.lock.yaml at the base lists as installed' -Tag '#73' {
            $PSNativeCommandUseErrorActionPreference = $true
            $repo = New-ScriptRepo
            Set-Content -LiteralPath (Join-Path $repo 'apm.lock.yaml') -Value @("lockfile_version: '1'", 'dependencies:', '- repo_url: _local/core', '  name: ai-sdlc-core', '  deployed_files:', '  - .claude/skills/demo/scripts/Shared.ps1', '  package_type: apm_package')
            git -C $repo add -A
            git -C $repo commit --quiet --no-verify -m lock
            git -C $repo update-ref refs/remotes/origin/main HEAD
            New-Item -ItemType Directory -Path (Join-Path $repo '.claude/skills/demo/scripts') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $repo '.claude/skills/demo/scripts/Shared.ps1') -Value @('# $a = 1', '$a = 1')
            Set-Content -LiteralPath (Join-Path $repo '.claude/skills/demo/scripts/Own.ps1') -Value @('# $b = 2', '$b = 2')

            $r = Invoke-RepoCheck $repo

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'Own\.ps1:1'
            $r.Output | Should -Not -Match 'Shared\.ps1'
        }

        It 'does not skip a file that the same change adds to apm.lock.yaml' -Tag '#73' {
            $repo = New-ScriptRepo
            Set-Content -LiteralPath (Join-Path $repo 'apm.lock.yaml') -Value @("lockfile_version: '1'", 'dependencies:', '- repo_url: _local/core', '  name: ai-sdlc-core', '  deployed_files:', '  - tools/Own.ps1', '  package_type: apm_package')
            Set-Content -LiteralPath (Join-Path $repo 'tools/Own.ps1') -Value @('# $b = 2', '$b = 2')

            $r = Invoke-RepoCheck $repo

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'tools/Own\.ps1:1'
        }

        It 'exits 2 and says nothing was checked when the base ref has no merge base' -Tag '#73' {
            $repo = New-ScriptRepo

            $out = & $script:ScriptUnderTest -Language YamlPowerShell -RepoRoot $repo -BaseRef 'refs/heads/no-such-branch' *>&1 | Out-String

            $LASTEXITCODE | Should -Be 2
            $out | Should -Match 'NOTHING WAS CHECKED'
            $out | Should -Match 'FIX: '
        }

        It 'exits 3 when the change touches no PowerShell or YAML file' -Tag '#73' {
            $repo = New-ScriptRepo
            Set-Content -LiteralPath (Join-Path $repo 'notes.md') -Value '# a heading'

            $r = Invoke-RepoCheck $repo

            $r.ExitCode | Should -Be 3 -Because $r.Output
        }
    }
}
