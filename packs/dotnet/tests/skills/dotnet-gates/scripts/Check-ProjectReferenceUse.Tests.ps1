#requires -Version 7.4

BeforeAll {
    $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm'
    $harnessFolder = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
    if (-not (Test-Path -LiteralPath $harnessFolder)) { $harnessFolder = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' 'tests' 'skills' 'ai-sdlc-gates' 'scripts' }
    Import-Module (Join-Path $harnessFolder 'DocToolTestHarness.psm1') -Force
    $script:SavedChangedFiles = $env:CHANGED_FILES
}

AfterAll { $env:CHANGED_FILES = $script:SavedChangedFiles }

Describe 'Check-ProjectReferenceUse' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $script:ScriptFolder -ChildPath 'Check-ProjectReferenceUse.ps1'

        function Invoke-Gate {
            param([string[]]$Changed, [switch]$All)
            $arguments = @{ RepoRoot = $script:Root }
            if ($Changed) { $arguments.ChangedFiles = $Changed }
            if ($All) { $arguments.All = $true }
            $out = & $script:ScriptUnderTest @arguments *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }

        function Add-File {
            param([string]$Path, [string]$Text)
            $full = Join-Path $script:Root $Path
            New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
            Set-Content -LiteralPath $full -Value $Text -Encoding utf8
        }

        function Add-Project {
            param([string]$Path, [string[]]$Reference = @(), [string]$Extra = '')
            $lines = @('<Project Sdk="Microsoft.NET.Sdk">', '  <ItemGroup>')
            foreach ($item in $Reference) { $lines += "    <ProjectReference Include=`"$item`" />" }
            $lines += '  </ItemGroup>'
            if ($Extra) { $lines += $Extra }
            $lines += '</Project>'
            Add-File -Path $Path -Text ($lines -join "`n")
        }

        function Add-Library {
            param([string]$Name = 'Lib', [string]$Namespace = $Name)
            Add-Project -Path "src/$Name/$Name.csproj"
            Add-File -Path "src/$Name/Service.cs" -Text "namespace $Namespace;`npublic class Service { }"
        }

        function Add-App {
            param([string[]]$Reference = @('..\Lib\Lib.csproj'), [string]$Code = "namespace App;`npublic class Handler { }", [string]$Extra = '')
            Add-Project -Path 'src/App/App.csproj' -Reference $Reference -Extra $Extra
            Add-File -Path 'src/App/Handler.cs' -Text $Code
        }

        $script:GitTemplate = Join-Path -Path $TestDrive -ChildPath ('git-template-' + [System.Guid]::NewGuid().ToString('N'))
        & git init --quiet --template= -b main $script:GitTemplate
        if ($LASTEXITCODE -ne 0) { throw 'git failed in the test setup' }
        & git -C $script:GitTemplate config user.name Test
        if ($LASTEXITCODE -ne 0) { throw 'git failed in the test setup' }
        & git -C $script:GitTemplate config user.email test@example.invalid
        if ($LASTEXITCODE -ne 0) { throw 'git failed in the test setup' }

        function Initialize-GitBase {
            Copy-Item -LiteralPath (Join-Path $script:GitTemplate '.git') -Destination (Join-Path $script:Root '.git') -Recurse
            & git -C $script:Root add -A
            if ($LASTEXITCODE -ne 0) { throw 'git failed in the test setup' }
            & git -C $script:Root commit --quiet -m base
            if ($LASTEXITCODE -ne 0) { throw 'git failed in the test setup' }
            & git -C $script:Root update-ref refs/remotes/origin/main HEAD
            if ($LASTEXITCODE -ne 0) { throw 'git failed in the test setup' }
        }

        function Save-Change {
            & git -C $script:Root add -A
            if ($LASTEXITCODE -ne 0) { throw 'git failed in the test setup' }
            & git -C $script:Root commit --quiet -m change
            if ($LASTEXITCODE -ne 0) { throw 'git failed in the test setup' }
        }
    }

    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        Set-AiSdlcTestConfig -Root $script:Root
        $env:CHANGED_FILES = $null
    }

    Context 'a reference that no code uses' {
        It 'names both projects and a FIX line, and exits 1' -Tag '#82' {
            Add-Library
            Add-App

            $r = Invoke-Gate -Changed @('src/App/App.csproj')

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'src/App/App\.csproj -> src/Lib/Lib\.csproj : no namespace use in code'
            $r.Output | Should -Match '(?m)^FIX: '
        }

        It 'sees a type found through a qualified name with no using' -Tag '#82' {
            Add-Library
            Add-App -Code "namespace App;`npublic class Handler { private Lib.Service _s; }"

            (Invoke-Gate -Changed @('src/App/App.csproj')).ExitCode | Should -Be 0
        }

        It 'sees a using of a single-segment namespace' -Tag '#82' {
            Add-Library
            Add-App -Code "using Lib;`nnamespace App;`npublic class Handler { }"

            (Invoke-Gate -Changed @('src/App/App.csproj')).ExitCode | Should -Be 0
        }

        It 'sees a using static, a global using and an alias of a namespace' -Tag '#82' -ForEach @(
            @{ Line = 'using static Lib.Service;' }
            @{ Line = 'global using Lib;' }
            @{ Line = 'using L = Lib;' }
        ) {
            Add-Library
            Add-App -Code "$Line`nnamespace App;`npublic class Handler { }"

            (Invoke-Gate -Changed @('src/App/App.csproj')).ExitCode | Should -Be 0
        }

        It 'sees an @using in _Imports.razor' -Tag '#82' {
            Add-Library
            Add-Project -Path 'src/App/App.csproj' -Reference '..\Lib\Lib.csproj'
            Add-File -Path 'src/App/_Imports.razor' -Text '@using Lib'
            Add-File -Path 'src/App/Page.razor' -Text '<p />'

            (Invoke-Gate -Changed @('src/App/App.csproj')).ExitCode | Should -Be 0
        }

        It 'sees a Razor library that declares no namespace in C# through its implicit namespace' -Tag '#82' {
            Add-Project -Path 'src/RazorLib/RazorLib.csproj'
            Add-File -Path 'src/RazorLib/Components/Button.razor' -Text '<button />'
            Add-Project -Path 'src/App/App.csproj' -Reference '..\RazorLib\RazorLib.csproj'
            Add-File -Path 'src/App/_Imports.razor' -Text '@using RazorLib.Components'

            (Invoke-Gate -Changed @('src/App/App.csproj')).ExitCode | Should -Be 0
        }

        It 'reports a Razor library whose implicit namespace nothing uses' -Tag '#82' {
            Add-Project -Path 'src/RazorLib/RazorLib.csproj'
            Add-File -Path 'src/RazorLib/Components/Button.razor' -Text '<button />'
            Add-Project -Path 'src/App/App.csproj' -Reference '..\RazorLib\RazorLib.csproj'
            Add-File -Path 'src/App/_Imports.razor' -Text '@using System'

            $r = Invoke-Gate -Changed @('src/App/App.csproj')

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'src/RazorLib/RazorLib\.csproj : no namespace use in code'
        }

        It 'uses the @namespace of a Razor file as a declared namespace' -Tag '#82' {
            Add-Project -Path 'src/RazorLib/RazorLib.csproj'
            Add-File -Path 'src/RazorLib/Button.razor' -Text "@namespace Kit.Controls`n<button />"
            Add-Project -Path 'src/App/App.csproj' -Reference '..\RazorLib\RazorLib.csproj'
            Add-File -Path 'src/App/Page.razor' -Text "@using Kit.Controls`n<Button />"

            (Invoke-Gate -Changed @('src/App/App.csproj')).ExitCode | Should -Be 0
        }

        It 'sees a Using item in the project file' -Tag '#82' {
            Add-Library
            Add-App -Extra '  <ItemGroup><Using Include="Lib" /></ItemGroup>'

            (Invoke-Gate -Changed @('src/App/App.csproj')).ExitCode | Should -Be 0
        }

        It 'sees a Using item of Directory.Build.props, and not a Using Remove' -Tag '#82' {
            Add-Library
            Add-App
            Add-File -Path 'Directory.Build.props' -Text '<Project><ItemGroup><Using Include="Lib" /></ItemGroup></Project>'

            (Invoke-Gate -Changed @('src/App/App.csproj')).ExitCode | Should -Be 0

            Add-File -Path 'Directory.Build.props' -Text '<Project><ItemGroup><Using Remove="Lib" /></ItemGroup></Project>'

            (Invoke-Gate -Changed @('src/App/App.csproj')).ExitCode | Should -Be 1
        }

        It 'sees WebApplicationFactory<Program> of a project with top-level statements' -Tag '#82' {
            Add-Project -Path 'src/Api/Api.csproj'
            Add-File -Path 'src/Api/Program.cs' -Text "using System;`n`nvar builder = WebApplication.CreateBuilder(args);`nbuilder.Build().Run();"
            Add-Project -Path 'tests/Api.Tests/Api.Tests.csproj' -Reference '..\..\src\Api\Api.csproj'
            Add-File -Path 'tests/Api.Tests/ApiTests.cs' -Text "namespace Api.Tests;`npublic class ApiTests { private WebApplicationFactory<Program> _f; }"

            (Invoke-Gate -Changed @('tests/Api.Tests/Api.Tests.csproj')).ExitCode | Should -Be 0
        }

        It 'sees WebApplicationFactory<Program> of a project with an explicit partial Program' -Tag '#82' {
            Add-Project -Path 'src/Api/Api.csproj'
            Add-File -Path 'src/Api/Program.cs' -Text "[Obsolete]`npublic partial class Program { }"
            Add-Project -Path 'tests/Api.Tests/Api.Tests.csproj' -Reference '..\..\src\Api\Api.csproj'
            Add-File -Path 'tests/Api.Tests/ApiTests.cs' -Text "namespace Api.Tests;`npublic class ApiTests { private WebApplicationFactory<Program> _f; }"

            (Invoke-Gate -Changed @('tests/Api.Tests/Api.Tests.csproj')).ExitCode | Should -Be 0
        }

        It 'reports a project with top-level statements that its referrer never names' -Tag '#82' {
            Add-Project -Path 'src/Api/Api.csproj'
            Add-File -Path 'src/Api/Program.cs' -Text "var builder = WebApplication.CreateBuilder(args);"
            Add-Project -Path 'tests/Api.Tests/Api.Tests.csproj' -Reference '..\..\src\Api\Api.csproj'
            Add-File -Path 'tests/Api.Tests/ApiTests.cs' -Text "namespace Api.Tests;`npublic class ApiTests { }"

            (Invoke-Gate -Changed @('tests/Api.Tests/Api.Tests.csproj')).ExitCode | Should -Be 1
        }

        It 'resolves a name to the longest declared namespace, so the project that declares only the shorter one is reported' -Tag '#82' {
            Add-Library -Name 'Lib'
            Add-Project -Path 'src/LibData/LibData.csproj'
            Add-File -Path 'src/LibData/Repo.cs' -Text "namespace Lib.Data;`npublic class Repo { }"
            Add-App -Reference '..\Lib\Lib.csproj', '..\LibData\LibData.csproj' -Code "using Lib.Data;`nnamespace App;`npublic class Handler { }"

            $r = Invoke-Gate -Changed @('src/App/App.csproj')

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'src/Lib/Lib\.csproj : no namespace use in code'
            $r.Output | Should -Not -Match 'LibData\.csproj : no namespace use'
        }

        It 'counts a namespace that two projects declare as used for both' -Tag '#82' {
            Add-Library -Name 'One' -Namespace 'Shared'
            Add-Library -Name 'Two' -Namespace 'Shared'
            Add-App -Reference '..\One\One.csproj', '..\Two\Two.csproj' -Code "using Shared;`nnamespace App;`npublic class Handler { }"

            (Invoke-Gate -Changed @('src/App/App.csproj')).ExitCode | Should -Be 0
        }

        It 'counts the enclosing namespace of a test project as used, so unqualified types of the library need no using' -Tag '#82' {
            Add-Library
            Add-Project -Path 'tests/Lib.Tests/Lib.Tests.csproj' -Reference '..\..\src\Lib\Lib.csproj'
            Add-File -Path 'tests/Lib.Tests/ServiceTests.cs' -Text "namespace Lib.Tests;`npublic class ServiceTests { private Service _s; }"

            (Invoke-Gate -Changed @('tests/Lib.Tests/Lib.Tests.csproj')).ExitCode | Should -Be 0
        }

        It 'does not count a file of a nested project for the parent project' -Tag '#82' {
            Add-Project -Path 'src/Lib/Lib.csproj'
            Add-Project -Path 'src/Lib/Inner/Inner.csproj'
            Add-File -Path 'src/Lib/Inner/Thing.cs' -Text "namespace Shared;`npublic class Thing { }"
            Add-App -Reference '..\Lib\Lib.csproj' -Code "using Shared;`nnamespace App;`npublic class Handler { }"

            $r = Invoke-Gate -Changed @('src/App/App.csproj')

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'src/Lib/Lib\.csproj : no namespace use in code'
        }
    }

    Context 'a reference the gate leaves alone' {
        It 'skips a reference with ReferenceOutputAssembly set to <Case>, so nothing is checked' -Tag '#82' -ForEach @(
            @{ Case = 'false as an attribute'; Reference = '<ProjectReference Include="..\Lib\Lib.csproj" ReferenceOutputAssembly="false" />' }
            @{ Case = 'False as a child element'; Reference = '<ProjectReference Include="..\Lib\Lib.csproj"><ReferenceOutputAssembly>False</ReferenceOutputAssembly></ProjectReference>' }
            @{ Case = 'false in other case'; Reference = '<ProjectReference Include="..\Lib\Lib.csproj" ReferenceOutputAssembly="FALSE" />' }
        ) {
            Add-Library
            Add-File -Path 'src/App/App.csproj' -Text "<Project Sdk=`"Microsoft.NET.Sdk`"><ItemGroup>$Reference</ItemGroup></Project>"
            Add-File -Path 'src/App/Handler.cs' -Text "namespace App;`npublic class Handler { }"

            $r = Invoke-Gate -Changed @('src/App/App.csproj')

            $r.ExitCode | Should -Be 3
            $r.Output | Should -Not -Match 'no namespace use'
        }

        It 'skips an analyzer reference given as <Case>' -Tag '#82' -ForEach @(
            @{ Case = 'an attribute'; Reference = '<ProjectReference Include="..\Lib\Lib.csproj" OutputItemType="Analyzer" />' }
            @{ Case = 'a child element'; Reference = '<ProjectReference Include="..\Lib\Lib.csproj"><OutputItemType>analyzer</OutputItemType></ProjectReference>' }
        ) {
            Add-Library
            Add-File -Path 'src/App/App.csproj' -Text "<Project Sdk=`"Microsoft.NET.Sdk`"><ItemGroup>$Reference</ItemGroup></Project>"
            Add-File -Path 'src/App/Handler.cs' -Text "namespace App;`npublic class Handler { }"

            $r = Invoke-Gate -Changed @('src/App/App.csproj')

            $r.ExitCode | Should -Be 3
            $r.Output | Should -Not -Match 'no namespace use'
        }
    }

    Context 'what it cannot check' {
        It 'names a reference that cannot be followed and exits 2 with a FIX line, for <Include>' -Tag '#82' -ForEach @(
            @{ Include = '$(SharedProject)' }
            @{ Include = '..\Gone\Gone.csproj' }
        ) {
            Add-App -Reference $Include

            $r = Invoke-Gate -Changed @('src/App/App.csproj')

            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match ([regex]::Escape($Include))
            $r.Output | Should -Match 'cannot be followed'
            $r.Output | Should -Match '(?m)^FIX: '
        }

        It 'lists a reference that cannot be followed together with a finding, and exits 1' -Tag '#82' {
            Add-Library
            Add-App -Reference '$(SharedProject)', '..\Lib\Lib.csproj'

            $r = Invoke-Gate -Changed @('src/App/App.csproj')

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'src/Lib/Lib\.csproj : no namespace use in code'
            $r.Output | Should -Match ([regex]::Escape('$(SharedProject)'))
        }

        It 'names a changed project file that cannot be read, and exits 2' -Tag '#82' {
            Add-Library
            Add-File -Path 'src/App/App.csproj' -Text '<Project><ItemGroup><ProjectReference Include="..\Lib\Lib.csproj" />'

            $r = Invoke-Gate -Changed @('src/App/App.csproj')

            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match 'src/App/App\.csproj cannot be read'
            $r.Output | Should -Match '(?m)^FIX: '
        }

        It 'names a target project file that cannot be read, and exits 2' -Tag '#82' {
            Add-File -Path 'src/Lib/Lib.csproj' -Text '<Project'
            Add-App

            $r = Invoke-Gate -Changed @('src/App/App.csproj')

            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match 'src/Lib/Lib\.csproj cannot be read'
        }

        It 'names a Directory.Build.props that cannot be read, and exits 2 when nothing else is found' -Tag '#82' {
            Add-Library
            Add-App -Code "using Lib;`nnamespace App;`npublic class Handler { }"
            Add-File -Path 'Directory.Build.props' -Text '<Project'

            $r = Invoke-Gate -Changed @('src/App/App.csproj')

            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match 'Directory\.Build\.props cannot be read'
        }

        It 'exits 2 with a FIX line when there is no base and no list, instead of judging every file' -Tag '#82' {
            Add-Library
            Add-App

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match 'Could not check'
            $r.Output | Should -Match '(?m)^FIX: '
        }
    }

    Context 'when there is nothing to check' {
        It 'exits 3 when the repository holds no project file' -Tag '#82' {
            Add-File -Path 'src/Lib/Service.cs' -Text "namespace Lib;`npublic class Service { }"

            $r = Invoke-Gate -Changed @('src/Lib/Service.cs')

            $r.ExitCode | Should -Be 3
            $r.Output | Should -Match 'Not applicable'
        }

        It 'exits 3 when a changed project file adds no project reference' -Tag '#82' {
            Add-Project -Path 'src/Lib/Lib.csproj'

            $r = Invoke-Gate -Changed @('src/Lib/Lib.csproj')

            $r.ExitCode | Should -Be 3
        }

        It 'exits 3 for a project file that the change deleted' -Tag '#82' {
            Add-Library

            $r = Invoke-Gate -Changed @('src/Gone/Gone.csproj')

            $r.ExitCode | Should -Be 3
        }
    }

    Context 'the lines the change adds' {
        It 'does not name an unused reference of a project that the change did not touch' -Tag '#82' {
            Add-Library
            Add-Project -Path 'src/Other/Other.csproj' -Reference '..\Lib\Lib.csproj'
            Add-File -Path 'src/Other/Thing.cs' -Text "namespace Other;`npublic class Thing { }"
            Initialize-GitBase
            Add-App
            Save-Change

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'src/App/App\.csproj -> src/Lib/Lib\.csproj'
            $r.Output | Should -Not -Match 'Other\.csproj'
        }

        It 'does not name an old unused reference in a changed project, and exits 3 when the change adds no reference line' -Tag '#82' {
            Add-Library
            Add-App
            Initialize-GitBase
            Add-App -Extra '  <PropertyGroup><Nullable>enable</Nullable></PropertyGroup>'
            Save-Change

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 3
            $r.Output | Should -Not -Match 'no namespace use'
        }

        It 'names only the reference line that the change adds to a project that holds an older unused one' -Tag '#82' {
            Add-Library -Name 'Old'
            Add-Library -Name 'Fresh'
            Add-App -Reference '..\Old\Old.csproj'
            Initialize-GitBase
            Add-App -Reference '..\Old\Old.csproj', '..\Fresh\Fresh.csproj'
            Save-Change

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'src/Fresh/Fresh\.csproj : no namespace use'
            $r.Output | Should -Not -Match 'Old\.csproj'
        }

        It 'exits 3 when the change touches only a C# file' -Tag '#82' {
            Add-Library
            Add-App
            Initialize-GitBase
            Add-File -Path 'src/App/Other.cs' -Text "namespace App;`npublic class Other { }"
            Save-Change

            (Invoke-Gate).ExitCode | Should -Be 3
        }

        It 'reads the changed files from CHANGED_FILES and the lines from git' -Tag '#82' {
            Add-Library
            Initialize-GitBase
            Add-App
            Save-Change
            try {
                $env:CHANGED_FILES = 'src/App/App.csproj'

                $out = & $script:ScriptUnderTest -RepoRoot $script:Root *>&1 | Out-String

                $LASTEXITCODE | Should -Be 1
                $out | Should -Match 'src/App/App\.csproj -> src/Lib/Lib\.csproj'
            }
            finally { $env:CHANGED_FILES = $null }
        }
    }

    Context 'how names are read' {
        It 'does not count a namespace that only a comment names: <Comment>' -Tag '#82' -ForEach @(
            @{ Comment = '// see Lib.Service' }
            @{ Comment = '/* Lib.Service */' }
            @{ Comment = '// using Lib;' }
        ) {
            Add-Library
            Add-App -Code "namespace App;`n$Comment`npublic class Handler { }"

            (Invoke-Gate -Changed @('src/App/App.csproj')).ExitCode | Should -Be 1
        }

        It 'resolves a partly qualified name inside the namespace of the referencing project' -Tag '#82' {
            Add-Library -Name 'Domain' -Namespace 'Company.Product.Domain'
            Add-App -Reference '..\Domain\Domain.csproj' -Code "namespace Company.Product.Web;`npublic class Handler { private Domain.Service _s; }"

            (Invoke-Gate -Changed @('src/App/App.csproj')).ExitCode | Should -Be 0
        }

        It 'sees a using with global:: in front: <Line>' -Tag '#82' -ForEach @(
            @{ Line = 'using L = global::Lib;' }
            @{ Line = 'using global::Lib;' }
        ) {
            Add-Library
            Add-App -Code "$Line`nnamespace App;`npublic class Handler { }"

            (Invoke-Gate -Changed @('src/App/App.csproj')).ExitCode | Should -Be 0
        }

        It 'sees an @using with global:: in front' -Tag '#82' {
            Add-Library
            Add-Project -Path 'src/App/App.csproj' -Reference '..\Lib\Lib.csproj'
            Add-File -Path 'src/App/_Imports.razor' -Text '@using global::Lib'

            (Invoke-Gate -Changed @('src/App/App.csproj')).ExitCode | Should -Be 0
        }

        It 'reads <File> of the referencing project for use' -Tag '#82' -ForEach @(
            @{ File = 'src/App/Views/_ViewImports.cshtml'; Text = '@using Lib' }
            @{ File = 'src/App/Views/Home/Index.cshtml'; Text = '@inject Lib.Service Service' }
            @{ File = 'src/App/Views/Home/Index.cshtml'; Text = '@model Lib.Service' }
        ) {
            Add-Library
            Add-App
            Add-File -Path $File -Text $Text

            (Invoke-Gate -Changed @('src/App/App.csproj')).ExitCode | Should -Be 0
        }

        It 'does not read a .cshtml file of the target for declarations' -Tag '#82' {
            Add-Project -Path 'src/Lib/Lib.csproj'
            Add-File -Path 'src/Lib/Views/Index.cshtml' -Text "@namespace Lib`n<p />"
            Add-App -Code "using Lib;`nnamespace App;`npublic class Handler { }"

            (Invoke-Gate -Changed @('src/App/App.csproj')).ExitCode | Should -Be 1
        }

        It 'splits a Using item that lists several namespaces' -Tag '#82' {
            Add-Library
            Add-App -Extra '  <ItemGroup><Using Include="System;Lib; ;Other" /></ItemGroup>'

            (Invoke-Gate -Changed @('src/App/App.csproj')).ExitCode | Should -Be 0
        }
    }

    Context 'what the review asked for' {
        It 'names a changed project file that cannot be read, whatever its added lines hold, and exits 2' -Tag '#82' {
            Add-Library
            Add-File -Path 'src/Bad/Bad.csproj' -Text '<Project'

            $r = Invoke-Gate -Changed @('src/Bad/Bad.csproj')

            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match 'src/Bad/Bad\.csproj cannot be read'
        }

        It 'lists an unreadable changed project file together with a finding, and exits 1' -Tag '#82' {
            Add-Library
            Add-App
            Add-File -Path 'src/Bad/Bad.csproj' -Text '<Project'

            $r = Invoke-Gate -Changed @('src/App/App.csproj', 'src/Bad/Bad.csproj')

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'src/App/App\.csproj -> src/Lib/Lib\.csproj'
            $r.Output | Should -Match 'src/Bad/Bad\.csproj cannot be read'
        }

        It 'names a reference to a project that is not a C# project and exits 2 when nothing else is found' -Tag '#82' {
            Add-File -Path 'src/Db/Db.sqlproj' -Text '<Project />'
            Add-App -Reference '..\Db\Db.sqlproj'

            $r = Invoke-Gate -Changed @('src/App/App.csproj')

            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match 'src/Db/Db\.sqlproj'
            $r.Output | Should -Match 'not checked: not a C# project'
            $r.Output | Should -Match '(?m)^FIX: '
        }

        It 'lists a reference to a project that is not a C# project together with a finding, and exits 1' -Tag '#82' {
            Add-Library
            Add-File -Path 'src/Db/Db.sqlproj' -Text '<Project />'
            Add-App -Reference '..\Lib\Lib.csproj', '..\Db\Db.sqlproj'

            $r = Invoke-Gate -Changed @('src/App/App.csproj')

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'not checked: not a C# project'
        }
    }

    Context 'what the pull request review found' {
        It 'does not count a name that only a Razor or HTML comment holds: <Text>' -Tag '#82' -ForEach @(
            @{ File = 'src/App/Page.razor'; Text = "@* Lib.Service *@" }
            @{ File = 'src/App/Page.razor'; Text = "@*`n  @using Lib`n  Lib.Service`n*@" }
            @{ File = 'src/App/Views/Index.cshtml'; Text = '<!-- Lib.Service -->' }
            @{ File = 'src/App/Views/Index.cshtml'; Text = "<!--`n@using Lib`n-->" }
        ) {
            Add-Library
            Add-App
            Add-File -Path $File -Text $Text

            (Invoke-Gate -Changed @('src/App/App.csproj')).ExitCode | Should -Be 1
        }

        It 'reads code that follows a string with two slashes: <Code>' -Tag '#82' -ForEach @(
            @{ Code = 'var url = "https://host"; Lib.Service.Use();' }
            @{ Code = 'var path = @"C:\x // y"; Lib.Service.Use();' }
            @{ Code = 'var text = $"a // {b}"; Lib.Service.Use();' }
            @{ Code = 'var raw = """a // b"""; Lib.Service.Use();' }
            @{ Code = "var c = '/'; var url = `"a\`"//b`"; Lib.Service.Use();" }
        ) {
            Add-Library
            Add-App -Code "namespace App;`npublic class Handler { void Run() { $Code } }"

            (Invoke-Gate -Changed @('src/App/App.csproj')).ExitCode | Should -Be 0
        }

        It 'still removes a comment that follows a string' -Tag '#82' {
            Add-Library
            Add-App -Code "namespace App;`npublic class Handler { string S = `"x`"; // Lib.Service`n}"

            (Invoke-Gate -Changed @('src/App/App.csproj')).ExitCode | Should -Be 1
        }

        It 'does not take the Include of an item that is not a ProjectReference as an added reference' -Tag '#82' {
            Add-Library
            Add-App
            Initialize-GitBase
            Add-App -Extra '  <ItemGroup><None Include="..\Lib\Lib.csproj" /></ItemGroup>'
            Save-Change

            (Invoke-Gate).ExitCode | Should -Be 3
        }

        It 'reads a ProjectReference whose Include sits on a line after the element name' -Tag '#82' {
            Add-Library
            Add-File -Path 'src/App/App.csproj' -Text "<Project Sdk=`"Microsoft.NET.Sdk`">`n  <ItemGroup>`n    <ProjectReference`n      Include=`"..\Lib\Lib.csproj`" />`n  </ItemGroup>`n</Project>"
            Add-File -Path 'src/App/Handler.cs' -Text "namespace App;`npublic class Handler { }"

            (Invoke-Gate -Changed @('src/App/App.csproj')).ExitCode | Should -Be 1
        }

        It 'removes only the namespace declaration from a line, not the code after it' -Tag '#82' {
            Add-Library
            Add-App -Code 'namespace App; public class Handler { Lib.Service Value; }'

            (Invoke-Gate -Changed @('src/App/App.csproj')).ExitCode | Should -Be 0
        }

        It 'removes only a block namespace declaration from a line' -Tag '#82' {
            Add-Library
            Add-App -Code 'namespace App { public class Handler { Lib.Service Value; } }'

            (Invoke-Gate -Changed @('src/App/App.csproj')).ExitCode | Should -Be 0
        }

        It 'does not read a Directory.Build.props above one that does not import it' -Tag '#82' {
            Add-Library
            Add-App
            Add-File -Path 'Directory.Build.props' -Text '<Project><ItemGroup><Using Include="Lib" /></ItemGroup></Project>'
            Add-File -Path 'src/Directory.Build.props' -Text '<Project />'

            (Invoke-Gate -Changed @('src/App/App.csproj')).ExitCode | Should -Be 1
        }

        It 'reads a Directory.Build.props above one that imports it' -Tag '#82' {
            Add-Library
            Add-App
            Add-File -Path 'Directory.Build.props' -Text '<Project><ItemGroup><Using Include="Lib" /></ItemGroup></Project>'
            Add-File -Path 'src/Directory.Build.props' -Text '<Project><Import Project="$([MSBuild]::GetPathOfFileAbove(''directory.build.props'', ''$(MSBuildThisFileDirectory)../''))" /></Project>'

            (Invoke-Gate -Changed @('src/App/App.csproj')).ExitCode | Should -Be 0
        }
    }

    Context 'global types and top-level statements in odd files (#82)' {
        It 'sees a global type that sits before a block namespace in the same file' -Tag '#82' {
            Add-Project -Path 'src/Lib/Lib.csproj'
            Add-File -Path 'src/Lib/Types.cs' -Text "public class GlobalThing { }`nnamespace Lib`n{`n    class Inner { }`n}"
            Add-App -Reference '..\Lib\Lib.csproj' -Code "namespace App;`npublic class Handler { GlobalThing T; }"

            (Invoke-Gate -Changed @('src/App/App.csproj')).ExitCode | Should -Be 0
        }

        It 'does not take a type inside a namespace block as a global type' -Tag '#82' {
            Add-Project -Path 'src/Lib/Lib.csproj'
            Add-File -Path 'src/Lib/Types.cs' -Text "public class GlobalThing { }`nnamespace Lib`n{`n    class Inner { }`n}"
            Add-App -Reference '..\Lib\Lib.csproj' -Code "namespace App;`npublic class Handler { Inner T; }"

            (Invoke-Gate -Changed @('src/App/App.csproj')).ExitCode | Should -Be 1
        }

        It 'does not take a type after a file-scoped namespace as a global type' -Tag '#82' {
            Add-Project -Path 'src/Lib/Lib.csproj'
            Add-File -Path 'src/Lib/Types.cs' -Text "namespace Lib;`nclass Inner { }"
            Add-App -Reference '..\Lib\Lib.csproj' -Code "namespace App;`npublic class Handler { Inner T; }"

            (Invoke-Gate -Changed @('src/App/App.csproj')).ExitCode | Should -Be 1
        }

        It 'sees Program of a file with a using and top-level code on one line' -Tag '#82' {
            Add-Project -Path 'src/Api/Api.csproj'
            Add-File -Path 'src/Api/Program.cs' -Text 'using System; WebApplication.CreateBuilder(args);'
            Add-Project -Path 'tests/Api.Tests/Api.Tests.csproj' -Reference '..\..\src\Api\Api.csproj'
            Add-File -Path 'tests/Api.Tests/ApiTests.cs' -Text "namespace Api.Tests;`npublic class ApiTests { private WebApplicationFactory<Program> _f; }"

            (Invoke-Gate -Changed @('tests/Api.Tests/Api.Tests.csproj')).ExitCode | Should -Be 0
        }
    }

    Context 'round three of the review (#82)' {
        It 'does not count a name that only a C# comment holds inside <Block> of a Razor file' -Tag '#82' -ForEach @(
            @{ Block = '@code'; Text = "@code {`n    // Lib.Service`n}" }
            @{ Block = '@functions'; Text = "@functions {`n    /* Lib.Service */`n    void Run() { }`n}" }
            @{ Block = '@{'; Text = "@{`n    var x = 1; // Lib.Service`n}" }
        ) {
            Add-Library
            Add-App
            Add-File -Path 'src/App/Page.razor' -Text $Text

            (Invoke-Gate -Changed @('src/App/App.csproj')).ExitCode | Should -Be 1
        }

        It 'still counts code in a Razor code block that has a comment after it' -Tag '#82' {
            Add-Library
            Add-App
            Add-File -Path 'src/App/Page.razor' -Text "@code {`n    Lib.Service S; // note`n}"

            (Invoke-Gate -Changed @('src/App/App.csproj')).ExitCode | Should -Be 0
        }

        It 'reads a URL in Razor markup as before, with no comment' -Tag '#82' {
            Add-Library
            Add-App
            Add-File -Path 'src/App/Page.razor' -Text '<a href="https://x/Lib.Service">link</a>'

            (Invoke-Gate -Changed @('src/App/App.csproj')).ExitCode | Should -Be 0
        }

        It 'sees Program of a file that starts with an assembly or module attribute: <Text>' -Tag '#82' -ForEach @(
            @{ Text = "[assembly: CLSCompliant(false)]`nvar app = WebApplication.Create();" }
            @{ Text = "using System;`n[module: SkipLocalsInit]`n[assembly: CLSCompliant(false)] var app = WebApplication.Create();" }
        ) {
            Add-Project -Path 'src/Api/Api.csproj'
            Add-File -Path 'src/Api/Program.cs' -Text $Text
            Add-Project -Path 'tests/Api.Tests/Api.Tests.csproj' -Reference '..\..\src\Api\Api.csproj'
            Add-File -Path 'tests/Api.Tests/ApiTests.cs' -Text "namespace Api.Tests;`npublic class ApiTests { private WebApplicationFactory<Program> _f; }"

            (Invoke-Gate -Changed @('tests/Api.Tests/Api.Tests.csproj')).ExitCode | Should -Be 0
        }

        It 'counts a file for each of two projects that share its folder' -Tag '#82' {
            Add-Project -Path 'src/Shared/A.csproj'
            Add-Project -Path 'src/Shared/B.csproj'
            Add-File -Path 'src/Shared/Thing.cs' -Text "namespace Shared;`npublic class Thing { }"
            Add-App -Reference '..\Shared\B.csproj' -Code "using Shared;`nnamespace App;`npublic class Handler { }"

            (Invoke-Gate -Changed @('src/App/App.csproj')).ExitCode | Should -Be 0
        }
    }

    Context 'the -All switch' {
        It 'reports an untouched project too, with no git' -Tag '#82' {
            Add-Library
            Add-Project -Path 'src/Other/Other.csproj' -Reference '..\Lib\Lib.csproj'
            Add-File -Path 'src/Other/Thing.cs' -Text "namespace Other;`npublic class Thing { }"
            Add-App

            $r = Invoke-Gate -All

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'src/App/App\.csproj -> src/Lib/Lib\.csproj'
            $r.Output | Should -Match 'src/Other/Other\.csproj -> src/Lib/Lib\.csproj'
        }

        It 'exits 0 when every reference has namespace use' -Tag '#82' {
            Add-Library
            Add-App -Code "using Lib;`nnamespace App;`npublic class Handler { }"

            $r = Invoke-Gate -All

            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'OK'
        }
    }
}
