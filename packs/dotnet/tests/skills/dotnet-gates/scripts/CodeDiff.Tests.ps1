#requires -Version 7.4

Describe 'CodeDiff' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'CodeDiff.psm1') -Force
    }

    AfterAll {
        Remove-Module CodeDiff -Force -ErrorAction SilentlyContinue
    }

    It 'splits a diff into added and context lines with the line numbers of the new file' {
        $diff = "diff --git a/src/Foo.cs b/src/Foo.cs`n--- a/src/Foo.cs`n+++ b/src/Foo.cs`n@@ -10,2 +10,3 @@`n var a = 1;`n+var b = 2;`n-var old = 0;`n var c = 3;"
        $lines = @(Get-CodeDiffLine -Diff $diff)
        $lines.Count | Should -Be 3
        $lines[1].Line | Should -Be 11
        $lines[1].IsAdded | Should -BeTrue
        $lines[2].IsAdded | Should -BeFalse
        $lines[2].Line | Should -Be 12
    }

    It 'skips a deleted file' {
        $diff = "--- a/src/Foo.cs`n+++ /dev/null`n@@ -1,1 +0,0 @@`n-var a = 1;"
        @(Get-CodeDiffLine -Diff $diff).Count | Should -Be 0
    }

    It 'reads <Path> as <Expected>' -ForEach @(
        @{ Path = 'src/Api/Foo.cs'; Expected = $true }
        @{ Path = 'src\Portal\Pages\Foo.razor'; Expected = $true }
        @{ Path = 'src/Api/Foo.Designer.cs'; Expected = $false }
        @{ Path = 'src/Api/Foo.g.cs'; Expected = $false }
        @{ Path = 'src/Api/obj/Debug/Foo.cs'; Expected = $false }
        @{ Path = 'tools/Foo.ps1'; Expected = $false }
    ) {
        Test-CodeDiffPath -Path $Path | Should -Be $Expected
    }

    It 'takes only the extensions it is given' {
        Test-CodeDiffPath -Path 'src/Portal/Pages/Foo.razor' -Extension '.cs' | Should -BeFalse
    }

    It 'names the problem when there is no merge base' {
        $result = Get-CodeDiffText -RepoRoot $PSScriptRoot -BaseRef 'refs/heads/no-such-branch-for-this-test'
        $result.Problem | Should -Match 'no merge base'
        $result.Text | Should -Be ''
    }
}
