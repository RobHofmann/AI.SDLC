#requires -Version 7.4

Describe 'Invoke-DotnetPostEdit' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-DotnetPostEdit.ps1'

        $script:FailingBuild = Join-Path -Path $TestDrive -ChildPath 'build-fail.ps1'
        Set-Content -Path $script:FailingBuild -Value @'
Write-Output "Sub/Thing.cs(3,5): error CS1002: ; expected [$($args[1])]"
Write-Output "Build FAILED."
exit 1
'@

        $script:CleanBuild = Join-Path -Path $TestDrive -ChildPath 'build-clean.ps1'
        Set-Content -Path $script:CleanBuild -Value @'
Write-Output 'Build succeeded.'
exit 0
'@

        $script:CountingBuild = Join-Path -Path $TestDrive -ChildPath 'build-count.ps1'
        Set-Content -Path $script:CountingBuild -Value @'
Add-Content -LiteralPath (Join-Path $PSScriptRoot 'builds.log') -Value $args[1]
Write-Output "error CS1002: ; expected [$([IO.Path]::GetFileName($args[1]))]"
exit 1
'@

        function Invoke-Step {
            param([string[]]$File, [string]$BuildTool = $script:CleanBuild)
            $relative = @($File | ForEach-Object { [IO.Path]::GetRelativePath($script:Root, $_).Replace('\', '/') })
            $out = & $script:ScriptUnderTest -File $File -Relative $relative -RepoRoot $script:Root -BuildTool $BuildTool *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }
    }

    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'Demo/src/Proj/Sub') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Root 'Demo/src/Proj/Proj.csproj') -Value '<Project />'
        Set-Content -LiteralPath (Join-Path $script:Root 'Demo/src/Proj/Sub/Thing.cs') -Value 'class Thing {}'
    }

    It 'builds the project that owns the file and returns the errors when the build fails' {
        $r = Invoke-Step -File (Join-Path $script:Root 'Demo/src/Proj/Sub/Thing.cs') -BuildTool $script:FailingBuild

        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Proj.csproj no longer builds after the edit to Demo/src/Proj/Sub/Thing.cs'
        $r.Output | Should -Match 'error CS1002'
        $r.Output | Should -Not -Match 'Build FAILED'
    }

    It 'stays silent when the build passes' {
        $r = Invoke-Step -File (Join-Path $script:Root 'Demo/src/Proj/Sub/Thing.cs')
        $r.Output.Trim() | Should -BeNullOrEmpty
    }

    It 'treats a Razor file the same as a C# file' {
        $razor = Join-Path $script:Root 'Demo/src/Proj/Sub/Page.razor'
        Set-Content -LiteralPath $razor -Value '<h1>Page</h1>'
        $r = Invoke-Step -File $razor -BuildTool $script:FailingBuild
        $r.Output | Should -Match 'Proj.csproj no longer builds'
    }

    It 'builds a project once for many of its files, and each project of the edit once' {
        $log = Join-Path $TestDrive 'builds.log'
        if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log }
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'Demo/src/Other') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Root 'Demo/src/Other/Other.csproj') -Value '<Project />'
        $files = @('Demo/src/Proj/Sub/Thing.cs', 'Demo/src/Proj/Sub/More.cs', 'Demo/src/Proj/Page.razor', 'Demo/src/Other/A.cs') |
            ForEach-Object { $path = Join-Path $script:Root $_; Set-Content -LiteralPath $path -Value 'x'; $path }

        $r = Invoke-Step -File $files -BuildTool $script:CountingBuild

        @(Get-Content -LiteralPath $log) | Should -HaveCount 2
        ([regex]::Matches($r.Output, 'Proj.csproj no longer builds')).Count | Should -Be 1
        $r.Output | Should -Match 'Proj.csproj no longer builds after the edit to Demo/src/Proj/Sub/Thing.cs, Demo/src/Proj/Sub/More.cs, Demo/src/Proj/Page.razor'
        $r.Output | Should -Match 'Other.csproj no longer builds after the edit to Demo/src/Other/A.cs'
    }

    It 'stays silent on a C# file with no project above it' {
        $loose = Join-Path $script:Root 'Loose.cs'
        Set-Content -LiteralPath $loose -Value 'class Loose {}'
        $r = Invoke-Step -File $loose -BuildTool $script:FailingBuild
        $r.Output.Trim() | Should -BeNullOrEmpty
    }
}
