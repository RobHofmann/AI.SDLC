#requires -Version 7.4

BeforeAll { $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm' }

Describe 'DotnetTestScope' -Tag '#81' {
    BeforeAll {
        Import-Module (Join-Path $script:ScriptFolder 'DotnetTestScope.psm1') -Force

        function New-Project {
            param([string]$Root, [string]$Path, [string[]]$References = @(), [string]$Body = '')
            $full = Join-Path $Root $Path
            New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
            $refs = ($References | ForEach-Object { "<ProjectReference Include=`"$_`" />" }) -join ''
            Set-Content -LiteralPath $full -Value "<Project Sdk=`"Microsoft.NET.Sdk`"><ItemGroup>$refs</ItemGroup>$Body</Project>"
        }

        $script:Root = Join-Path $TestDrive 'repo'
        New-Project -Root $script:Root -Path 'src/Lib/Lib.csproj'
        New-Project -Root $script:Root -Path 'src/Lib/Inner/Inner.csproj'
        New-Project -Root $script:Root -Path 'src/App/App.csproj' -References '..\Lib\Lib.csproj'
        New-Project -Root $script:Root -Path 'src/Tool/Tool.csproj'
        New-Project -Root $script:Root -Path 'tests/Lib.Tests/Lib.Tests.csproj' -References '..\..\src\Lib\Lib.csproj'
        New-Project -Root $script:Root -Path 'tests/App.Checks/App.Checks.csproj' -References '..\..\src\App\App.csproj' -Body '<ItemGroup><PackageReference Include="xunit" /></ItemGroup>'
        New-Project -Root $script:Root -Path 'tests/Inner.Spec/Inner.Spec.csproj' -References '..\..\src\Lib\Inner\Inner.csproj' -Body '<PropertyGroup><IsTestProject>true</IsTestProject></PropertyGroup>'
        New-Project -Root $script:Root -Path '.claude/worktrees/copy/src/Lib/Lib.csproj'
        New-Project -Root $script:Root -Path 'src/App/bin/Release/App.csproj'
        $script:Graph = @(Get-DotnetProjectGraph -RepoRoot $script:Root)
    }

    It 'reads every project outside .claude, bin and obj, with its references' {
        $script:Graph.Path | Sort-Object | Should -Be @('src/App/App.csproj', 'src/Lib/Inner/Inner.csproj', 'src/Lib/Lib.csproj', 'src/Tool/Tool.csproj', 'tests/App.Checks/App.Checks.csproj', 'tests/Inner.Spec/Inner.Spec.csproj', 'tests/Lib.Tests/Lib.Tests.csproj')
        @($script:Graph | Where-Object Path -eq 'src/App/App.csproj').References | Should -Be @('src/Lib/Lib.csproj')
    }

    It 'knows a test project by its name, a test package or IsTestProject' {
        @($script:Graph | Where-Object IsTest).Path | Sort-Object | Should -Be @('tests/App.Checks/App.Checks.csproj', 'tests/Inner.Spec/Inner.Spec.csproj', 'tests/Lib.Tests/Lib.Tests.csproj')
    }

    It 'runs the tests of a changed project and of every project that references it, also through another project' {
        $scope = Get-DotnetTestScope -RepoRoot $script:Root -Files 'src/Lib/Service.cs' -Projects $script:Graph

        $scope.All | Should -BeFalse
        $scope.Projects | Should -Be @('src/Lib/Lib.csproj')
        $scope.TestProjects | Should -Be @('tests/App.Checks/App.Checks.csproj', 'tests/Lib.Tests/Lib.Tests.csproj')
    }

    It 'gives a file to the deepest project folder that holds it' {
        $scope = Get-DotnetTestScope -RepoRoot $script:Root -Files 'src/Lib/Inner/Deep.cs' -Projects $script:Graph

        $scope.Projects | Should -Be @('src/Lib/Inner/Inner.csproj')
        $scope.TestProjects | Should -Be @('tests/Inner.Spec/Inner.Spec.csproj')
    }

    It 'runs the test project itself when only a test changes' {
        $scope = Get-DotnetTestScope -RepoRoot $script:Root -Files 'tests\Lib.Tests\LibTests.cs' -Projects $script:Graph

        $scope.TestProjects | Should -Be @('tests/Lib.Tests/Lib.Tests.csproj')
    }

    It 'touches a project and runs no test when no test project reaches it' {
        $scope = Get-DotnetTestScope -RepoRoot $script:Root -Files 'src/Tool/Program.cs' -Projects $script:Graph

        $scope.Projects | Should -Be @('src/Tool/Tool.csproj')
        $scope.TestProjects | Should -BeNullOrEmpty
    }

    It 'touches no project for <Files>' -ForEach @(
        @{ Files = @('docs/guide.md') }
        @{ Files = @('src/Lib/README.md') }
        @{ Files = @('docs-functional/area/page.png') }
        @{ Files = @('infra/main.bicep', 'pipelines/build.yml') }
        @{ Files = @() }
    ) {
        $scope = Get-DotnetTestScope -RepoRoot $script:Root -Files $Files -Projects $script:Graph

        $scope.All | Should -BeFalse
        $scope.Projects | Should -BeNullOrEmpty
        $scope.TestProjects | Should -BeNullOrEmpty
    }

    It 'runs everything for <File>, because <Why>' -ForEach @(
        @{ File = 'Directory.Packages.props'; Why = 'every project reads it' }
        @{ File = 'src/Directory.Build.props'; Why = 'every project below it reads it' }
        @{ File = 'global.json'; Why = 'it picks the SDK' }
        @{ File = 'App.sln'; Why = 'it lists the projects' }
        @{ File = 'App.runsettings'; Why = 'it sets up every test run' }
        @{ File = 'analyzers/App.globalconfig'; Why = 'it sets the analyzer rules of every project' }
        @{ File = 'shared/Common.cs'; Why = 'it is a .NET file outside every project' }
    ) {
        $scope = Get-DotnetTestScope -RepoRoot $script:Root -Files @('src/Lib/Service.cs', $File) -Projects $script:Graph

        $scope.All | Should -BeTrue
        $scope.Reason | Should -Match ([regex]::Escape($File))
    }

    It 'runs everything when a project file cannot be read' {
        $root = Join-Path $TestDrive 'broken'
        New-Item -ItemType Directory -Path (Join-Path $root 'src' 'Bad') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'src' 'Bad' 'Bad.csproj') -Value '<Project'

        $scope = Get-DotnetTestScope -RepoRoot $root -Files 'src/Bad/A.cs'

        $scope.All | Should -BeTrue
        $scope.Reason | Should -Match 'src/Bad/Bad.csproj'
    }

    It 'runs everything when the project reference <Include> cannot be followed' -ForEach @(
        @{ Include = '$(SharedProject)' }
        @{ Include = '..\Shared\*.csproj' }
        @{ Include = '..\Gone\Gone.csproj' }
    ) {
        $root = Join-Path $TestDrive "refs-$([guid]::NewGuid().ToString('N'))"
        New-Project -Root $root -Path 'src/Shared/Shared.csproj'
        New-Project -Root $root -Path 'src/App/App.csproj' -References $Include
        New-Project -Root $root -Path 'tests/App.Tests/App.Tests.csproj' -References '..\..\src\App\App.csproj'

        $scope = Get-DotnetTestScope -RepoRoot $root -Files 'src/Shared/Shared.cs'

        $scope.All | Should -BeTrue
        $scope.Reason | Should -Match 'src/App/App.csproj'
        $scope.Reason | Should -Match ([regex]::Escape($Include))
    }

    Context 'what the project reference gate reads (#82)' {
        BeforeAll {
            function Get-RawRoot { Join-Path $TestDrive ('raw-' + [guid]::NewGuid().ToString('N')) }

            function Add-RawFile {
                param([string]$Root, [string]$Path, [string]$Text)
                $full = Join-Path $Root $Path
                New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
                Set-Content -LiteralPath $full -Value $Text
            }

            function Get-OneProject {
                param([string]$Root, [string]$Path)
                @(Get-DotnetProjectGraph -RepoRoot $Root | Where-Object Path -eq $Path)[0]
            }
        }

        It 'gives each reference with ReferenceOutputAssembly and OutputItemType, read as attribute or child element' -Tag '#82' {
            $root = Get-RawRoot
            New-Project -Root $root -Path 'src/Lib/Lib.csproj'
            New-Project -Root $root -Path 'src/Gen/Gen.csproj'
            New-Project -Root $root -Path 'src/Tool/Tool.csproj'
            Add-RawFile -Root $root -Path 'src/App/App.csproj' -Text '<Project Sdk="Microsoft.NET.Sdk"><ItemGroup><ProjectReference Include="..\Lib\Lib.csproj" /><ProjectReference Include="..\Gen\Gen.csproj" ReferenceOutputAssembly="false" OutputItemType="Analyzer" /><ProjectReference Include="..\Tool\Tool.csproj"><ReferenceOutputAssembly>False</ReferenceOutputAssembly><OutputItemType>Content</OutputItemType></ProjectReference></ItemGroup></Project>'

            $items = @((Get-OneProject -Root $root -Path 'src/App/App.csproj').ReferenceItems)

            $items.Count | Should -Be 3
            $lib = $items | Where-Object Include -eq '..\Lib\Lib.csproj'
            $lib.Path | Should -Be 'src/Lib/Lib.csproj'
            $lib.ReferenceOutputAssembly | Should -BeNullOrEmpty
            $lib.OutputItemType | Should -BeNullOrEmpty
            $gen = $items | Where-Object Include -eq '..\Gen\Gen.csproj'
            $gen.Path | Should -Be 'src/Gen/Gen.csproj'
            $gen.ReferenceOutputAssembly | Should -Be 'false'
            $gen.OutputItemType | Should -Be 'Analyzer'
            $tool = $items | Where-Object Include -eq '..\Tool\Tool.csproj'
            $tool.ReferenceOutputAssembly | Should -Be 'False'
            $tool.OutputItemType | Should -Be 'Content'
        }

        It 'gives a null Path for a reference that cannot be followed and leaves References and Error as they were' -Tag '#82' {
            $root = Get-RawRoot
            New-Project -Root $root -Path 'src/Lib/Lib.csproj'
            New-Project -Root $root -Path 'src/App/App.csproj' -References '$(SharedProject)', '..\Gone\Gone.csproj', '..\Lib\Lib.csproj'

            $app = Get-OneProject -Root $root -Path 'src/App/App.csproj'

            @($app.ReferenceItems).Count | Should -Be 3
            @($app.ReferenceItems | Where-Object { $null -eq $_.Path }).Include | Should -Be @('$(SharedProject)', '..\Gone\Gone.csproj')
            @($app.ReferenceItems | Where-Object Path).Path | Should -Be @('src/Lib/Lib.csproj')
            @($app.References) | Should -Be @('src/Lib/Lib.csproj')
            $app.Error | Should -Match 'cannot be followed'
        }

        It 'reads the nearest Directory.Build.props and each one above it that the file below imports, up to the repository root and not above it' -Tag '#82' {
            $outer = Get-RawRoot
            $root = Join-Path $outer 'repo'
            $import = '<Import Project="$([MSBuild]::GetPathOfFileAbove(''Directory.Build.props'', ''$(MSBuildThisFileDirectory)../''))" />'
            Add-RawFile -Root $outer -Path 'Directory.Build.props' -Text "<Project>$import<ItemGroup><Using Include=`"Above`" /></ItemGroup></Project>"
            Add-RawFile -Root $root -Path 'Directory.Build.props' -Text "<Project>$import<ItemGroup><Using Include=`"Root`" /></ItemGroup></Project>"
            Add-RawFile -Root $root -Path 'src/Directory.Build.props' -Text "<Project>$import<ItemGroup><Using Include=`"Src`" /></ItemGroup></Project>"
            Add-RawFile -Root $root -Path 'src/App/App.csproj' -Text '<Project Sdk="Microsoft.NET.Sdk"><ItemGroup><Using Include="Own" /><Using Remove="Gone" /></ItemGroup></Project>'
            Add-RawFile -Root $root -Path 'other/Tool/Tool.csproj' -Text '<Project Sdk="Microsoft.NET.Sdk" />'

            $app = Get-OneProject -Root $root -Path 'src/App/App.csproj'
            $tool = Get-OneProject -Root $root -Path 'other/Tool/Tool.csproj'

            @($app.Usings | Sort-Object) | Should -Be @('Own', 'Root', 'Src')
            @($tool.Usings) | Should -Be @('Root')
            $app.UsingsError | Should -BeNullOrEmpty
        }

        It 'stops at the nearest Directory.Build.props when it does not import the one above, and finds the nearest one above a folder that has none' -Tag '#82' {
            $root = Get-RawRoot
            Add-RawFile -Root $root -Path 'Directory.Build.props' -Text '<Project><ItemGroup><Using Include="Root" /></ItemGroup></Project>'
            Add-RawFile -Root $root -Path 'src/Directory.Build.props' -Text '<Project><ItemGroup><Using Include="Src" /></ItemGroup></Project>'
            Add-RawFile -Root $root -Path 'src/App/Deep/Deep.csproj' -Text '<Project Sdk="Microsoft.NET.Sdk" />'
            Add-RawFile -Root $root -Path 'tools/Tool/Tool.csproj' -Text '<Project Sdk="Microsoft.NET.Sdk" />'

            @((Get-OneProject -Root $root -Path 'src/App/Deep/Deep.csproj').Usings) | Should -Be @('Src')
            @((Get-OneProject -Root $root -Path 'tools/Tool/Tool.csproj').Usings) | Should -Be @('Root')
        }

        It 'splits the Include of a Using item on semicolons, in the project file and in Directory.Build.props' -Tag '#82' {
            $root = Get-RawRoot
            Add-RawFile -Root $root -Path 'Directory.Build.props' -Text '<Project><ItemGroup><Using Include="P1; P2;;" /></ItemGroup></Project>'
            Add-RawFile -Root $root -Path 'src/App/App.csproj' -Text '<Project Sdk="Microsoft.NET.Sdk"><ItemGroup><Using Include="A;B ; " /></ItemGroup></Project>'

            @((Get-OneProject -Root $root -Path 'src/App/App.csproj').Usings | Sort-Object) | Should -Be @('A', 'B', 'P1', 'P2')
        }

        It 'names a Directory.Build.props that cannot be read in UsingsError and does not set Error' -Tag '#82' {
            $root = Get-RawRoot
            Add-RawFile -Root $root -Path 'src/Directory.Build.props' -Text '<Project'
            Add-RawFile -Root $root -Path 'src/App/App.csproj' -Text '<Project Sdk="Microsoft.NET.Sdk"><ItemGroup><Using Include="Own" /></ItemGroup></Project>'

            $app = Get-OneProject -Root $root -Path 'src/App/App.csproj'

            $app.UsingsError | Should -Match 'src/Directory.Build.props'
            $app.Error | Should -BeNullOrEmpty
            @($app.Usings) | Should -Be @('Own')
        }

        It 'gives empty new properties for a project file that cannot be read' -Tag '#82' {
            $root = Get-RawRoot
            Add-RawFile -Root $root -Path 'src/Bad/Bad.csproj' -Text '<Project'

            $bad = Get-OneProject -Root $root -Path 'src/Bad/Bad.csproj'

            $bad.Error | Should -Be 'cannot be read'
            @($bad.ReferenceItems).Count | Should -Be 0
            @($bad.Usings).Count | Should -Be 0
            $bad.RootNamespace | Should -BeNullOrEmpty
            $bad.UsingsError | Should -BeNullOrEmpty
        }

        It 'reads RootNamespace from the element, else from the project file name' -Tag '#82' {
            $root = Get-RawRoot
            Add-RawFile -Root $root -Path 'src/Named/Named.csproj' -Text '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><RootNamespace>Company.Named</RootNamespace></PropertyGroup></Project>'
            Add-RawFile -Root $root -Path 'src/Plain.Lib/Plain.Lib.csproj' -Text '<Project Sdk="Microsoft.NET.Sdk" />'

            (Get-OneProject -Root $root -Path 'src/Named/Named.csproj').RootNamespace | Should -Be 'Company.Named'
            (Get-OneProject -Root $root -Path 'src/Plain.Lib/Plain.Lib.csproj').RootNamespace | Should -Be 'Plain.Lib'
        }

        It 'gives a file to each project when two projects share the deepest folder' -Tag '#82' {
            $root = Get-RawRoot
            Add-RawFile -Root $root -Path 'src/Shared/A.csproj' -Text '<Project Sdk="Microsoft.NET.Sdk" />'
            Add-RawFile -Root $root -Path 'src/Shared/B.csproj' -Text '<Project Sdk="Microsoft.NET.Sdk" />'
            Add-RawFile -Root $root -Path 'src/Shared/Thing.cs' -Text 'class Thing { }'
            $graph = @(Get-DotnetProjectGraph -RepoRoot $root)

            $files = @(Get-DotnetProjectSourceFile -RepoRoot $root -Projects $graph)

            @($files | Where-Object Project -eq 'src/Shared/A.csproj').Files | Should -Be @('src/Shared/Thing.cs')
            @($files | Where-Object Project -eq 'src/Shared/B.csproj').Files | Should -Be @('src/Shared/Thing.cs')
        }

        It 'gives each .cs and .razor file to the deepest project that holds it, and skips bin and obj' -Tag '#82' {
            $root = Get-RawRoot
            Add-RawFile -Root $root -Path 'src/Lib/Lib.csproj' -Text '<Project Sdk="Microsoft.NET.Sdk" />'
            Add-RawFile -Root $root -Path 'src/Lib/Inner/Inner.csproj' -Text '<Project Sdk="Microsoft.NET.Sdk" />'
            Add-RawFile -Root $root -Path 'src/Lib/A.cs' -Text 'class A { }'
            Add-RawFile -Root $root -Path 'src/Lib/View/B.razor' -Text '<p />'
            Add-RawFile -Root $root -Path 'src/Lib/Inner/C.cs' -Text 'class C { }'
            Add-RawFile -Root $root -Path 'src/Lib/Notes.txt' -Text 'text'
            Add-RawFile -Root $root -Path 'src/Lib/obj/Gen.cs' -Text 'class Gen { }'
            Add-RawFile -Root $root -Path 'src/Lib/bin/Out.cs' -Text 'class Out { }'
            Add-RawFile -Root $root -Path 'loose/D.cs' -Text 'class D { }'
            $graph = @(Get-DotnetProjectGraph -RepoRoot $root)

            $files = @(Get-DotnetProjectSourceFile -RepoRoot $root -Projects $graph)

            @($files | Where-Object Project -eq 'src/Lib/Lib.csproj').Files | Sort-Object | Should -Be @('src/Lib/A.cs', 'src/Lib/View/B.razor')
            @($files | Where-Object Project -eq 'src/Lib/Inner/Inner.csproj').Files | Should -Be @('src/Lib/Inner/C.cs')
        }
    }

    Context 'the project references that a change adds (#82)' {
        BeforeAll {
            $script:AddedTemplate = Join-Path -Path $TestDrive -ChildPath ('added-template-' + [guid]::NewGuid().ToString('N'))
            & git init --quiet --template= -b main $script:AddedTemplate
            if ($LASTEXITCODE -ne 0) { throw 'git failed in the test setup' }
            & git -C $script:AddedTemplate config user.name Test
            if ($LASTEXITCODE -ne 0) { throw 'git failed in the test setup' }
            & git -C $script:AddedTemplate config user.email test@example.invalid
            if ($LASTEXITCODE -ne 0) { throw 'git failed in the test setup' }

            function Get-AddedRoot { Join-Path $TestDrive ('added-' + [guid]::NewGuid().ToString('N')) }

            function Write-AddedFile {
                param([string]$Root, [string]$Path, [string]$Text)
                $full = Join-Path $Root $Path
                New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
                Set-Content -LiteralPath $full -Value $Text -Encoding utf8
            }

            function Initialize-AddedBase {
                param([string]$Root)
                Copy-Item -LiteralPath (Join-Path $script:AddedTemplate '.git') -Destination (Join-Path $Root '.git') -Recurse
                & git -C $Root add -A 2>$null
                if ($LASTEXITCODE -ne 0) { throw 'git failed in the test setup' }
                & git -C $Root commit --quiet -m base
                if ($LASTEXITCODE -ne 0) { throw 'git failed in the test setup' }
                $head = & git -C $Root rev-parse HEAD
                if ($LASTEXITCODE -ne 0) { throw 'git failed in the test setup' }
                return $head
            }

            function Save-AddedChange {
                param([string]$Root)
                & git -C $Root add -A 2>$null
                if ($LASTEXITCODE -ne 0) { throw 'git failed in the test setup' }
                & git -C $Root commit --quiet -m change
                if ($LASTEXITCODE -ne 0) { throw 'git failed in the test setup' }
            }

            function Get-Added {
                param([string]$Root, [string[]]$Files, [string]$Base, [switch]$AssumeNew)
                $graph = @(Get-DotnetProjectGraph -RepoRoot $Root)
                $arguments = @{ RepoRoot = $Root; Projects = $graph; Files = $Files }
                if ($Base) { $arguments.Base = $Base }
                if ($AssumeNew) { $arguments.AssumeNew = $true }
                return Get-DotnetAddedProjectReference @arguments
            }

            $script:TwoLibs = @{
                Lib   = '<Project Sdk="Microsoft.NET.Sdk" />'
                Other = '<Project Sdk="Microsoft.NET.Sdk" />'
            }

            function Add-LibraryPair {
                param([string]$Root)
                Write-AddedFile -Root $Root -Path 'src/Lib/Lib.csproj' -Text $script:TwoLibs.Lib
                Write-AddedFile -Root $Root -Path 'src/Other/Other.csproj' -Text $script:TwoLibs.Other
            }
        }

        It 'counts every reference of a listed project file when the list is explicit' -Tag '#82' {
            $root = Get-AddedRoot
            Add-LibraryPair -Root $root
            Write-AddedFile -Root $root -Path 'src/App/App.csproj' -Text '<Project Sdk="Microsoft.NET.Sdk"><ItemGroup><ProjectReference Include="..\Lib\Lib.csproj" /><ProjectReference Include="..\Other\Other.csproj" /></ItemGroup></Project>'

            $answer = Get-Added -Root $root -Files @('src/App/App.csproj') -AssumeNew

            @($answer.References).Count | Should -Be 2
            @($answer.References.Project.Path | Select-Object -Unique) | Should -Be @('src/App/App.csproj')
            @($answer.References | ForEach-Object { $_.Item.Include } | Sort-Object) | Should -Be @('..\Lib\Lib.csproj', '..\Other\Other.csproj')
            @($answer.Unreadable).Count | Should -Be 0
            @($answer.LinesUnknown).Count | Should -Be 0
        }

        It 'counts only the reference on an added line when a git base is given' -Tag '#82' {
            $root = Get-AddedRoot
            Add-LibraryPair -Root $root
            Write-AddedFile -Root $root -Path 'src/App/App.csproj' -Text "<Project Sdk=`"Microsoft.NET.Sdk`">`n  <ItemGroup>`n    <ProjectReference Include=`"..\Lib\Lib.csproj`" />`n  </ItemGroup>`n</Project>"
            $base = Initialize-AddedBase -Root $root
            Write-AddedFile -Root $root -Path 'src/App/App.csproj' -Text "<Project Sdk=`"Microsoft.NET.Sdk`">`n  <ItemGroup>`n    <ProjectReference Include=`"..\Lib\Lib.csproj`" />`n    <ProjectReference Include=`"..\Other\Other.csproj`" />`n  </ItemGroup>`n</Project>"
            Save-AddedChange -Root $root

            $answer = Get-Added -Root $root -Files @('src/App/App.csproj') -Base $base

            @($answer.References).Count | Should -Be 1
            $answer.References[0].Item.Include | Should -Be '..\Other\Other.csproj'
            $answer.References[0].Project.Path | Should -Be 'src/App/App.csproj'
        }

        It 'counts an Include that sits on a line after the ProjectReference tag' -Tag '#82' {
            $root = Get-AddedRoot
            Add-LibraryPair -Root $root
            Write-AddedFile -Root $root -Path 'src/App/App.csproj' -Text "<Project Sdk=`"Microsoft.NET.Sdk`">`n  <ItemGroup>`n    <ProjectReference`n      Include=`"..\Lib\Lib.csproj`" />`n  </ItemGroup>`n</Project>"
            $base = Initialize-AddedBase -Root $root
            Write-AddedFile -Root $root -Path 'src/App/App.csproj' -Text "<Project Sdk=`"Microsoft.NET.Sdk`">`n  <ItemGroup>`n    <ProjectReference`n      Include=`"..\Lib\Lib.csproj`" />`n    <ProjectReference`n      Include=`"..\Other\Other.csproj`" />`n  </ItemGroup>`n</Project>"
            Save-AddedChange -Root $root

            $answer = Get-Added -Root $root -Files @('src/App/App.csproj') -Base $base

            @($answer.References | ForEach-Object { $_.Item.Include }) | Should -Be @('..\Other\Other.csproj')
        }

        It 'does not count an Include of an element that is not a ProjectReference' -Tag '#82' {
            $root = Get-AddedRoot
            Add-LibraryPair -Root $root
            Write-AddedFile -Root $root -Path 'src/App/App.csproj' -Text '<Project Sdk="Microsoft.NET.Sdk"><ItemGroup><None Include="..\Lib\Lib.csproj" /></ItemGroup></Project>'

            $answer = Get-Added -Root $root -Files @('src/App/App.csproj') -AssumeNew

            @($answer.References).Count | Should -Be 0
        }

        It 'gives nothing and no error for a listed project file that was deleted' -Tag '#82' {
            $root = Get-AddedRoot
            Add-LibraryPair -Root $root

            $answer = Get-Added -Root $root -Files @('src/Gone/Gone.csproj') -AssumeNew

            @($answer.References).Count | Should -Be 0
            @($answer.Unreadable).Count | Should -Be 0
            @($answer.LinesUnknown).Count | Should -Be 0
        }

        It 'gives nothing for a project file under bin or .claude, which the graph does not hold' -Tag '#82' {
            $root = Get-AddedRoot
            Add-LibraryPair -Root $root
            Write-AddedFile -Root $root -Path 'src/App/bin/App.csproj' -Text '<Project Sdk="Microsoft.NET.Sdk"><ItemGroup><ProjectReference Include="..\..\Lib\Lib.csproj" /></ItemGroup></Project>'
            Write-AddedFile -Root $root -Path '.claude/copy/Copy.csproj' -Text '<Project Sdk="Microsoft.NET.Sdk"><ItemGroup><ProjectReference Include="..\..\src\Lib\Lib.csproj" /></ItemGroup></Project>'

            $answer = Get-Added -Root $root -Files @('src/App/bin/App.csproj', '.claude/copy/Copy.csproj') -AssumeNew

            @($answer.References).Count | Should -Be 0
            @($answer.Unreadable).Count | Should -Be 0
            @($answer.LinesUnknown).Count | Should -Be 0
        }

        It 'lists a project file that cannot be read as Unreadable and not as LinesUnknown' -Tag '#82' {
            $root = Get-AddedRoot
            Write-AddedFile -Root $root -Path 'src/Bad/Bad.csproj' -Text '<Project'

            $answer = Get-Added -Root $root -Files @('src/Bad/Bad.csproj')

            @($answer.Unreadable) | Should -Be @('src/Bad/Bad.csproj')
            @($answer.LinesUnknown).Count | Should -Be 0
            @($answer.References).Count | Should -Be 0
        }

        It 'lists a project file whose added lines cannot be read as LinesUnknown, when there is no base and the list is not explicit' -Tag '#82' {
            $root = Get-AddedRoot
            Add-LibraryPair -Root $root
            Write-AddedFile -Root $root -Path 'src/App/App.csproj' -Text '<Project Sdk="Microsoft.NET.Sdk"><ItemGroup><ProjectReference Include="..\Lib\Lib.csproj" /></ItemGroup></Project>'

            $answer = Get-Added -Root $root -Files @('src/App/App.csproj')

            @($answer.LinesUnknown) | Should -Be @('src/App/App.csproj')
            @($answer.References).Count | Should -Be 0
        }

        It 'ignores a file that is not a .csproj file' -Tag '#82' {
            $root = Get-AddedRoot
            Add-LibraryPair -Root $root
            Write-AddedFile -Root $root -Path 'src/App/App.cs' -Text 'class App { }'
            Write-AddedFile -Root $root -Path 'src/App/App.sqlproj' -Text '<Project><ItemGroup><ProjectReference Include="..\Lib\Lib.csproj" /></ItemGroup></Project>'

            $answer = Get-Added -Root $root -Files @('src/App/App.cs', 'src/App/App.sqlproj') -AssumeNew

            @($answer.References).Count | Should -Be 0
            @($answer.Unreadable).Count | Should -Be 0
            @($answer.LinesUnknown).Count | Should -Be 0
        }

        It 'returns a reference with ReferenceOutputAssembly false and does not filter it' -Tag '#82' {
            $root = Get-AddedRoot
            Add-LibraryPair -Root $root
            Write-AddedFile -Root $root -Path 'src/App/App.csproj' -Text '<Project Sdk="Microsoft.NET.Sdk"><ItemGroup><ProjectReference Include="..\Lib\Lib.csproj" ReferenceOutputAssembly="false" /><ProjectReference Include="..\Other\Other.csproj" OutputItemType="Analyzer" /></ItemGroup></Project>'

            $answer = Get-Added -Root $root -Files @('src/App/App.csproj') -AssumeNew

            @($answer.References | ForEach-Object { $_.Item.Include } | Sort-Object) | Should -Be @('..\Lib\Lib.csproj', '..\Other\Other.csproj')
        }
    }
}
