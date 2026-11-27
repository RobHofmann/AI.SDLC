#requires -Version 7.4

BeforeAll {
    $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm'
    $harnessFolder = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
    if (-not (Test-Path -LiteralPath $harnessFolder)) { $harnessFolder = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' 'tests' 'skills' 'ai-sdlc-gates' 'scripts' }
    Import-Module (Join-Path $harnessFolder 'DocToolTestHarness.psm1') -Force
    $script:SavedChangedFiles = $env:CHANGED_FILES
}

AfterAll { $env:CHANGED_FILES = $script:SavedChangedFiles }

Describe 'Check-ProjectLayerOrder' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $script:ScriptFolder -ChildPath 'Check-ProjectLayerOrder.ps1'

        function Invoke-Gate {
            param([string[]]$Changed, [switch]$All, [string]$From, [string]$To, [string]$BaseRef)
            $arguments = @{ RepoRoot = $script:Root }
            if ($Changed) { $arguments.ChangedFiles = $Changed }
            if ($All) { $arguments.All = $true }
            if ($PSBoundParameters.ContainsKey('From')) { $arguments.From = $From }
            if ($PSBoundParameters.ContainsKey('To')) { $arguments.To = $To }
            if ($PSBoundParameters.ContainsKey('BaseRef')) { $arguments.BaseRef = $BaseRef }
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
            param([string]$Path, [string[]]$Reference = @(), [string]$Attributes = '')
            $folder = Split-Path -Parent (Join-Path $script:Root $Path)
            $lines = @('<Project Sdk="Microsoft.NET.Sdk">', '  <ItemGroup>')
            foreach ($target in $Reference) {
                $include = if ($target.Contains('$(')) { $target } else { [IO.Path]::GetRelativePath($folder, (Join-Path $script:Root $target)).Replace('/', '\') }
                $lines += "    <ProjectReference Include=`"$include`"$Attributes />"
            }
            $lines += '  </ItemGroup>'
            $lines += '</Project>'
            Add-File -Path $Path -Text ($lines -join "`n")
        }

        function Write-LayerSetting {
            param([object]$Layers)
            $file = Join-Path $script:Root 'aisdlc.json'
            $config = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
            if ($config['dotnet'] -isnot [System.Collections.IDictionary]) { $config['dotnet'] = @{} }
            $config['dotnet']['layers'] = $Layers
            Set-Content -LiteralPath $file -Value ($config | ConvertTo-Json -Depth 6) -Encoding utf8
        }

        function Write-DotnetSetting {
            param([object]$Value, [switch]$Remove)
            $file = Join-Path $script:Root 'aisdlc.json'
            $config = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
            if ($Remove) { $config.Remove('dotnet') } else { $config['dotnet'] = $Value }
            Set-Content -LiteralPath $file -Value ($config | ConvertTo-Json -Depth 6) -Encoding utf8
        }

        function Clear-LayerKey {
            $file = Join-Path $script:Root 'aisdlc.json'
            $config = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
            if ($config['dotnet'] -is [System.Collections.IDictionary]) { $config['dotnet'].Remove('layers') }
            Set-Content -LiteralPath $file -Value ($config | ConvertTo-Json -Depth 6) -Encoding utf8
        }

        function Write-StandardLayer {
            Write-LayerSetting -Layers @(
                @{ name = 'Kernel'; projects = @('src/Kernel/*.csproj') }
                @{ name = 'Domain'; projects = @('src/Domain*/*.csproj') }
                @{ name = 'Hosts'; projects = @('src/*.Api/*.csproj') }
                @{ name = 'Tests'; projects = @('tests/**/*.csproj') }
            )
        }

        $script:Kernel = 'src/Kernel/Kernel.csproj'
        $script:Domain = 'src/Domain/Domain.csproj'
        $script:Api = 'src/Shop.Api/Shop.Api.csproj'
        $script:UnitTests = 'tests/Unit/Shop.Tests/Shop.Tests.csproj'

        $script:GitTemplate = Join-Path -Path $TestDrive -ChildPath ('git-template-' + [System.Guid]::NewGuid().ToString('N'))
        & git init --quiet --template= -b main $script:GitTemplate
        if ($LASTEXITCODE -ne 0) { throw 'git failed in the test setup' }
        & git -C $script:GitTemplate config user.name Test
        if ($LASTEXITCODE -ne 0) { throw 'git failed in the test setup' }
        & git -C $script:GitTemplate config user.email test@example.invalid
        if ($LASTEXITCODE -ne 0) { throw 'git failed in the test setup' }

        function Initialize-GitBase {
            Copy-Item -LiteralPath (Join-Path $script:GitTemplate '.git') -Destination (Join-Path $script:Root '.git') -Recurse
            & git -C $script:Root add -A 2>$null
            if ($LASTEXITCODE -ne 0) { throw 'git failed in the test setup' }
            & git -C $script:Root commit --quiet -m base
            if ($LASTEXITCODE -ne 0) { throw 'git failed in the test setup' }
            & git -C $script:Root update-ref refs/remotes/origin/main HEAD
            if ($LASTEXITCODE -ne 0) { throw 'git failed in the test setup' }
        }

        function Save-Change {
            & git -C $script:Root add -A 2>$null
            if ($LASTEXITCODE -ne 0) { throw 'git failed in the test setup' }
            & git -C $script:Root commit --quiet -m change
            if ($LASTEXITCODE -ne 0) { throw 'git failed in the test setup' }
        }
    }

    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        Set-AiSdlcTestConfig -Root $script:Root
        Write-StandardLayer
        $env:CHANGED_FILES = $null
    }

    Context 'a reference against the order' {
        It 'names both projects, both layers and a FIX line, and exits 1' -Tag '#82' {
            Add-Project -Path $script:Api
            Add-Project -Path $script:Domain -Reference $script:Api

            $r = Invoke-Gate -Changed @($script:Domain)

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match ([regex]::Escape("src/Domain/Domain.csproj -> src/Shop.Api/Shop.Api.csproj : from layer 'Domain' (1) to layer 'Hosts' (2), which is not a lower layer"))
            $r.Output | Should -Match '(?m)^FIX: '
        }

        It 'treats a reference inside one layer as a finding' -Tag '#82' {
            Add-Project -Path 'src/Domain.Extras/Domain.Extras.csproj'
            Add-Project -Path $script:Domain -Reference 'src/Domain.Extras/Domain.Extras.csproj'

            $r = Invoke-Gate -Changed @($script:Domain)

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match "from layer 'Domain' \(1\) to layer 'Domain' \(1\), which is not a lower layer"
        }

        It 'judges a reference with ReferenceOutputAssembly false or OutputItemType Analyzer too' -Tag '#82' -ForEach @(
            @{ Attributes = ' ReferenceOutputAssembly="false"' }
            @{ Attributes = ' OutputItemType="Analyzer"' }
        ) {
            Add-Project -Path $script:Api
            Add-Project -Path $script:Domain -Reference $script:Api -Attributes $Attributes

            (Invoke-Gate -Changed @($script:Domain)).ExitCode | Should -Be 1
        }

        It 'exits 0 and counts the references when each one points to a lower layer' -Tag '#82' {
            Add-Project -Path $script:Kernel
            Add-Project -Path $script:Domain -Reference $script:Kernel
            Add-Project -Path $script:Api -Reference $script:Domain, $script:Kernel

            $r = Invoke-Gate -Changed @($script:Domain, $script:Api)

            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'OK: 3 project reference'
        }

        It 'exits 0 for a test project in the top layer that references a lower layer' -Tag '#82' {
            Add-Project -Path $script:Api
            Add-Project -Path $script:UnitTests -Reference $script:Api

            (Invoke-Gate -Changed @($script:UnitTests)).ExitCode | Should -Be 0
        }

        It 'exits 3 and says nothing applies when the change adds no project reference' -Tag '#82' {
            Add-Project -Path $script:Kernel
            Add-File -Path 'src/Kernel/Thing.cs' -Text 'class Thing { }'

            $r = Invoke-Gate -Changed @('src/Kernel/Thing.cs')

            $r.ExitCode | Should -Be 3
            $r.Output | Should -Match 'Not applicable'
        }
    }

    Context 'only the references that the change adds' {
        It 'does not name an old reference against the order in a changed project, when the change adds another line' -Tag '#82' {
            Add-Project -Path $script:Kernel
            Add-Project -Path $script:Api
            Add-Project -Path $script:Domain -Reference $script:Api
            Initialize-GitBase
            Add-Project -Path $script:Domain -Reference $script:Api, $script:Kernel
            Save-Change

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 0
            $r.Output | Should -Not -Match 'Shop\.Api'
        }

        It 'does not name a reference against the order in a project that the change did not touch' -Tag '#82' {
            Add-Project -Path $script:Kernel
            Add-Project -Path $script:Api
            Add-Project -Path $script:Domain -Reference $script:Api
            Initialize-GitBase
            Add-Project -Path $script:UnitTests -Reference $script:Kernel
            Save-Change

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 0
            $r.Output | Should -Not -Match 'Domain\.csproj'
        }

        It 'names the reference line that the change adds against the order' -Tag '#82' {
            Add-Project -Path $script:Kernel
            Add-Project -Path $script:Api
            Add-Project -Path $script:Domain -Reference $script:Kernel
            Initialize-GitBase
            Add-Project -Path $script:Domain -Reference $script:Kernel, $script:Api
            Save-Change

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'src/Domain/Domain\.csproj -> src/Shop\.Api/Shop\.Api\.csproj'
            $r.Output | Should -Not -Match 'Kernel\.csproj :'
        }

        It 'reads the changed files from CHANGED_FILES and the lines from git' -Tag '#82' {
            Add-Project -Path $script:Api
            Initialize-GitBase
            Add-Project -Path $script:Domain -Reference $script:Api
            Save-Change
            try {
                $env:CHANGED_FILES = $script:Domain

                $out = & $script:ScriptUnderTest -RepoRoot $script:Root *>&1 | Out-String

                $LASTEXITCODE | Should -Be 1
                $out | Should -Match 'src/Domain/Domain\.csproj -> src/Shop\.Api/Shop\.Api\.csproj'
            }
            finally { $env:CHANGED_FILES = $null }
        }
    }

    Context 'a project that no layer holds' {
        It 'names the project and exits 2 with no layer finding, when the target is in no layer' -Tag '#82' {
            Add-Project -Path 'tools/Gen/Gen.csproj'
            Add-Project -Path $script:Domain -Reference 'tools/Gen/Gen.csproj'

            $r = Invoke-Gate -Changed @($script:Domain)

            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match 'tools/Gen/Gen\.csproj : no layer of dotnet\.layers holds this project, so src/Domain/Domain\.csproj -> tools/Gen/Gen\.csproj is not judged'
            $r.Output | Should -Not -Match 'does not point to a lower layer'
            $r.Output | Should -Match '(?m)^FIX: '
        }

        It 'names both projects when neither the source nor the target is in a layer' -Tag '#82' {
            Add-Project -Path 'tools/Gen/Gen.csproj'
            Add-Project -Path 'tools/App/App.csproj' -Reference 'tools/Gen/Gen.csproj'

            $r = Invoke-Gate -Changed @('tools/App/App.csproj')

            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match 'tools/App/App\.csproj : no layer of dotnet\.layers holds this project'
            $r.Output | Should -Match 'tools/Gen/Gen\.csproj : no layer of dotnet\.layers holds this project'
        }

        It 'names a test project that no layer holds in the same way' -Tag '#82' {
            Add-Project -Path $script:Domain
            Add-Project -Path 'specs/Shop.Specs/Shop.Specs.csproj' -Reference $script:Domain

            $r = Invoke-Gate -Changed @('specs/Shop.Specs/Shop.Specs.csproj')

            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match 'specs/Shop\.Specs/Shop\.Specs\.csproj : no layer of dotnet\.layers holds this project'
        }

        It 'lists the project that no layer holds next to a finding, and exits 1' -Tag '#82' {
            Add-Project -Path 'tools/Gen/Gen.csproj'
            Add-Project -Path $script:Domain
            Add-Project -Path $script:Kernel -Reference $script:Domain
            Add-Project -Path 'src/Domain.Extras/Domain.Extras.csproj' -Reference 'tools/Gen/Gen.csproj'

            $r = Invoke-Gate -Changed @($script:Kernel, 'src/Domain.Extras/Domain.Extras.csproj')

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'src/Kernel/Kernel\.csproj -> src/Domain/Domain\.csproj : from layer'
            $r.Output | Should -Match 'Could not check:'
            $r.Output | Should -Match 'tools/Gen/Gen\.csproj : no layer of dotnet\.layers holds this project'
        }
    }

    Context 'a setting with the wrong shape' {
        It 'names a project that two layers hold and exits 2, and does not judge its references' -Tag '#82' {
            Write-LayerSetting -Layers @(
                @{ name = 'Low'; projects = @('src/Lib/*.csproj') }
                @{ name = 'High'; projects = @('src/*/*.csproj') }
            )
            Add-Project -Path 'src/Lib/Lib.csproj'
            Add-Project -Path 'src/App/App.csproj' -Reference 'src/Lib/Lib.csproj'

            $r = Invoke-Gate -Changed @('src/App/App.csproj')

            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match "src/Lib/Lib\.csproj : layers 'Low' and 'High' of dotnet\.layers both hold this project"
            $r.Output | Should -Not -Match 'does not point to a lower layer'
            $r.Output | Should -Match '(?m)^FIX: '
        }

        It 'names a project that three layers hold with all three names' -Tag '#82' {
            Write-LayerSetting -Layers @(
                @{ name = 'A'; projects = @('src/Lib/*.csproj') }
                @{ name = 'B'; projects = @('src/*/*.csproj') }
                @{ name = 'C'; projects = @('src/**/*.csproj') }
            )
            Add-Project -Path 'src/Lib/Lib.csproj'

            $r = Invoke-Gate -All

            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match "src/Lib/Lib\.csproj : layers 'A', 'B' and 'C' of dotnet\.layers all hold this project"
        }

        It 'names a project that two layers hold also when the change cannot be listed' -Tag '#82' {
            Write-LayerSetting -Layers @(
                @{ name = 'Low'; projects = @('src/Lib/*.csproj') }
                @{ name = 'High'; projects = @('src/*/*.csproj') }
            )
            Add-Project -Path 'src/Lib/Lib.csproj'

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match "layers 'Low' and 'High' of dotnet\.layers both hold this project"
            $r.Output | Should -Match '(?m)^FIX: '
        }

        It 'names a project that two layers hold also when the change adds no reference' -Tag '#82' {
            Write-LayerSetting -Layers @(
                @{ name = 'Low'; projects = @('src/Lib/*.csproj') }
                @{ name = 'High'; projects = @('src/*/*.csproj') }
            )
            Add-Project -Path 'src/Lib/Lib.csproj'
            Add-File -Path 'src/Lib/Thing.cs' -Text 'class Thing { }'

            $r = Invoke-Gate -Changed @('src/Lib/Thing.cs')

            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match "layers 'Low' and 'High'"
        }

        It 'names the setting and exits 2 when <Case>' -Tag '#82' -ForEach @(
            @{ Case = 'layers is a string'; Layers = 'Kernel'; Text = 'dotnet\.layers must be a list' }
            @{ Case = 'layers is an object'; Layers = @{ name = 'A'; projects = @('src/*.csproj') }; Text = 'dotnet\.layers must be a list' }
            @{ Case = 'a layer is not an object'; Layers = @('Kernel'); Text = 'dotnet\.layers\[0\] must be an object' }
            @{ Case = 'a layer has no name'; Layers = @(@{ projects = @('src/*.csproj') }); Text = 'dotnet\.layers\[0\]\.name' }
            @{ Case = 'a name is not a string'; Layers = @(@{ name = 5; projects = @('src/*.csproj') }); Text = 'dotnet\.layers\[0\]\.name' }
            @{ Case = 'a name is blank'; Layers = @(@{ name = '  '; projects = @('src/*.csproj') }); Text = 'dotnet\.layers\[0\]\.name' }
            @{ Case = 'two layers have one name'; Layers = @(@{ name = 'A'; projects = @('src/a/*.csproj') }, @{ name = 'A'; projects = @('src/b/*.csproj') }); Text = "dotnet\.layers\[1\]\.name 'A' is already used" }
            @{ Case = 'projects is empty'; Layers = @(@{ name = 'A'; projects = @() }); Text = 'dotnet\.layers\[0\]\.projects' }
            @{ Case = 'projects is missing'; Layers = @(@{ name = 'A' }); Text = 'dotnet\.layers\[0\]\.projects' }
            @{ Case = 'projects is a string'; Layers = @(@{ name = 'A'; projects = 'src/*.csproj' }); Text = 'dotnet\.layers\[0\]\.projects' }
            @{ Case = 'a glob is a number'; Layers = @(@{ name = 'A'; projects = @(7) }); Text = 'dotnet\.layers\[0\]\.projects\[0\]' }
            @{ Case = 'a glob is blank'; Layers = @(@{ name = 'A'; projects = @('src/*.csproj', ' ') }); Text = 'dotnet\.layers\[0\]\.projects\[1\]' }
        ) {
            Write-LayerSetting -Layers $Layers
            Add-Project -Path $script:Kernel
            Add-Project -Path $script:Domain -Reference $script:Kernel

            $r = Invoke-Gate -Changed @($script:Domain)

            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match "aisdlc\.json : $Text"
            $r.Output | Should -Match '(?m)^FIX: '
            $r.Output | Should -Not -Match 'does not point to a lower layer'
        }

        It 'names the setting and exits 2 when dotnet is not an object' -Tag '#82' {
            Write-DotnetSetting -Value 'layers'
            Add-Project -Path $script:Kernel

            $r = Invoke-Gate -Changed @($script:Kernel)

            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match 'aisdlc\.json : dotnet\.layers'
        }

        It 'reads a list of one layer as valid' -Tag '#82' {
            Write-LayerSetting -Layers @(, @{ name = 'All'; projects = @('src/**/*.csproj') })
            Add-Project -Path $script:Kernel
            Add-Project -Path $script:Domain -Reference $script:Kernel

            $r = Invoke-Gate -Changed @($script:Domain)

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match "from layer 'All' \(0\) to layer 'All' \(0\), which is not a lower layer"
        }
    }

    Context 'when there is nothing to check' {
        It 'exits 3 when dotnet is not set' -Tag '#82' {
            Write-DotnetSetting -Remove
            Add-Project -Path $script:Domain -Reference $script:Api
            Add-Project -Path $script:Api

            $r = Invoke-Gate -Changed @($script:Domain)

            $r.ExitCode | Should -Be 3
            $r.Output | Should -Match 'Not applicable: aisdlc\.json sets no dotnet\.layers\.'
        }

        It 'exits 3 when layers is <Case>' -Tag '#82' -ForEach @(
            @{ Case = 'empty'; Layers = @() }
            @{ Case = 'null'; Layers = $null }
        ) {
            Write-LayerSetting -Layers $Layers
            Add-Project -Path $script:Api
            Add-Project -Path $script:Domain -Reference $script:Api

            $r = Invoke-Gate -Changed @($script:Domain)

            $r.ExitCode | Should -Be 3
            $r.Output | Should -Match 'Not applicable: aisdlc\.json sets no dotnet\.layers\.'
        }

        It 'exits 3 when the layers key is missing' -Tag '#82' {
            Clear-LayerKey
            Add-Project -Path $script:Domain

            (Invoke-Gate -Changed @($script:Domain)).ExitCode | Should -Be 3
        }

        It 'exits 3 when layers are set and the repository holds no project file' -Tag '#82' {
            Add-File -Path 'src/Thing.cs' -Text 'class Thing { }'

            $r = Invoke-Gate -Changed @('src/Thing.cs')

            $r.ExitCode | Should -Be 3
            $r.Output | Should -Match 'Not applicable'
        }
    }

    Context 'how a project path meets a glob' {
        It 'puts test projects at different depths in a layer with a double star' -Tag '#82' {
            Add-Project -Path $script:Kernel
            Add-Project -Path 'tests/Api.Tests/Api.Tests.csproj' -Reference $script:Kernel
            Add-Project -Path 'tests/Unit/Deep/Core.Tests/Core.Tests.csproj' -Reference $script:Kernel

            $r = Invoke-Gate -Changed @('tests/Api.Tests/Api.Tests.csproj', 'tests/Unit/Deep/Core.Tests/Core.Tests.csproj')

            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'OK: 2 project reference'
        }

        It 'does not match a project in a sub folder with a glob that has no folder level' -Tag '#82' {
            Write-LayerSetting -Layers @(
                @{ name = 'Flat'; projects = @('src/*.csproj') }
            )
            Add-Project -Path 'src/Lib/Lib.csproj'
            Add-Project -Path 'src/App/App.csproj' -Reference 'src/Lib/Lib.csproj'

            $r = Invoke-Gate -Changed @('src/App/App.csproj')

            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match 'src/Lib/Lib\.csproj : no layer of dotnet\.layers holds this project'
        }

        It 'changes nothing when a glob matches no project' -Tag '#82' {
            Write-LayerSetting -Layers @(
                @{ name = 'Ghost'; projects = @('nothing/**/*.csproj') }
                @{ name = 'Kernel'; projects = @('src/Kernel/*.csproj') }
                @{ name = 'Domain'; projects = @('src/Domain/*.csproj') }
            )
            Add-Project -Path $script:Kernel
            Add-Project -Path $script:Domain -Reference $script:Kernel

            $r = Invoke-Gate -Changed @($script:Domain)

            $r.ExitCode | Should -Be 0
            $r.Output | Should -Not -Match 'Ghost'
        }

        It 'ignores the case of a glob on Windows' -Tag '#82' -Skip:(-not $IsWindows) {
            Write-LayerSetting -Layers @(
                @{ name = 'Low'; projects = @('SRC/KERNEL/*.csproj') }
                @{ name = 'High'; projects = @('src/domain/*.csproj') }
            )
            Add-Project -Path $script:Kernel
            Add-Project -Path $script:Domain -Reference $script:Kernel

            (Invoke-Gate -Changed @($script:Domain)).ExitCode | Should -Be 0
        }

        It 'respects the case of a glob where paths are case-sensitive' -Tag '#82' -Skip:$IsWindows {
            Write-LayerSetting -Layers @(
                @{ name = 'Low'; projects = @('SRC/KERNEL/*.csproj') }
                @{ name = 'High'; projects = @('src/domain/*.csproj') }
            )
            Add-Project -Path $script:Kernel
            Add-Project -Path $script:Domain -Reference $script:Kernel

            (Invoke-Gate -Changed @($script:Domain)).ExitCode | Should -Be 2
        }

        It 'puts a target that is not a .csproj file in a layer by its path' -Tag '#82' {
            Write-LayerSetting -Layers @(
                @{ name = 'Data'; projects = @('src/Db/*.sqlproj') }
                @{ name = 'Domain'; projects = @('src/Domain/*.csproj') }
            )
            Add-File -Path 'src/Db/Db.sqlproj' -Text '<Project />'
            Add-Project -Path $script:Domain -Reference 'src/Db/Db.sqlproj'

            $r = Invoke-Gate -Changed @($script:Domain)

            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'OK: 1 project reference'
        }

        It 'names a target that is not a .csproj file and that no layer holds' -Tag '#82' {
            Write-LayerSetting -Layers @(
                @{ name = 'Domain'; projects = @('src/Domain/*.csproj') }
            )
            Add-File -Path 'src/Db/Db.sqlproj' -Text '<Project />'
            Add-Project -Path $script:Domain -Reference 'src/Db/Db.sqlproj'

            $r = Invoke-Gate -Changed @($script:Domain)

            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match 'src/Db/Db\.sqlproj : no layer of dotnet\.layers holds this project'
        }
    }

    Context 'what it cannot judge' {
        It 'names a reference that cannot be followed and exits 2, for <Include>' -Tag '#82' -ForEach @(
            @{ Include = '$(SharedProject)' }
            @{ Include = '..\Gone\Gone.csproj' }
        ) {
            Add-File -Path $script:Domain -Text "<Project Sdk=`"Microsoft.NET.Sdk`"><ItemGroup><ProjectReference Include=`"$Include`" /></ItemGroup></Project>"

            $r = Invoke-Gate -Changed @($script:Domain)

            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match ([regex]::Escape($Include))
            $r.Output | Should -Match 'cannot be followed'
            $r.Output | Should -Match '(?m)^FIX: '
        }

        It 'names a changed project file that cannot be read and exits 2' -Tag '#82' {
            Add-Project -Path $script:Kernel
            Add-File -Path $script:Domain -Text '<Project><ItemGroup><ProjectReference Include="..\Kernel\Kernel.csproj" />'

            $r = Invoke-Gate -Changed @($script:Domain)

            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match 'src/Domain/Domain\.csproj cannot be read'
            $r.Output | Should -Match '(?m)^FIX: '
        }

        It 'exits 2 when there is no base and no list of changed files' -Tag '#82' {
            Add-Project -Path $script:Kernel
            Add-Project -Path $script:Domain -Reference $script:Kernel

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match '(?m)^FIX: '
        }
    }

    Context 'a planned reference' {
        BeforeAll {
            function Get-VerdictLine {
                param([string]$Output)
                return @($Output -split "`r?`n" | Where-Object { $_ -match '^  \S' })
            }
        }

        It 'gives the same result as a reference that a change adds, for <Name>' -Tag '#82' -ForEach @(
            @{ Name = 'a lower layer'; From = 'src/Domain/Domain.csproj'; To = 'src/Kernel/Kernel.csproj'; Expected = 0 }
            @{ Name = 'a higher layer'; From = 'src/Domain/Domain.csproj'; To = 'src/Shop.Api/Shop.Api.csproj'; Expected = 1 }
            @{ Name = 'the same layer'; From = 'src/Domain/Domain.csproj'; To = 'src/Domain.Extras/Domain.Extras.csproj'; Expected = 1 }
            @{ Name = 'a target in no layer'; From = 'src/Domain/Domain.csproj'; To = 'tools/Gen/Gen.csproj'; Expected = 2 }
            @{ Name = 'a source in no layer'; From = 'tools/App/App.csproj'; To = 'src/Domain/Domain.csproj'; Expected = 2 }
        ) {
            Add-Project -Path $To
            Add-Project -Path $From -Reference $To

            $change = Invoke-Gate -Changed @($From)
            $planned = Invoke-Gate -From $From -To $To

            $change.ExitCode | Should -Be $Expected
            $planned.ExitCode | Should -Be $change.ExitCode
            Get-VerdictLine -Output $planned.Output | Should -Be (Get-VerdictLine -Output $change.Output)
        }

        It 'gives the same result as a reference that a change adds, when two layers hold the target' -Tag '#82' {
            Write-LayerSetting -Layers @(
                @{ name = 'Low'; projects = @('src/Lib/*.csproj') }
                @{ name = 'High'; projects = @('src/*/*.csproj') }
            )
            Add-Project -Path 'src/Lib/Lib.csproj'
            Add-Project -Path 'src/App/App.csproj' -Reference 'src/Lib/Lib.csproj'

            $change = Invoke-Gate -Changed @('src/App/App.csproj')
            $planned = Invoke-Gate -From 'src/App/App.csproj' -To 'src/Lib/Lib.csproj'

            $change.ExitCode | Should -Be 2
            $planned.ExitCode | Should -Be 2
            (Get-VerdictLine -Output $planned.Output).Count | Should -BeGreaterThan 0
            Get-VerdictLine -Output $planned.Output | Should -Be (Get-VerdictLine -Output $change.Output)
        }

        It 'exits 0 and names both projects and both layers, with no project file and no git' -Tag '#82' {
            $r = Invoke-Gate -From $script:Domain -To $script:Kernel

            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match ([regex]::Escape("src/Domain/Domain.csproj -> src/Kernel/Kernel.csproj : from layer 'Domain' (1) to layer 'Kernel' (0)"))
        }

        It 'exits 1 with the finding text of a change, with no project file and no git' -Tag '#82' {
            $r = Invoke-Gate -From $script:Domain -To $script:Api

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match ([regex]::Escape("src/Domain/Domain.csproj -> src/Shop.Api/Shop.Api.csproj : from layer 'Domain' (1) to layer 'Hosts' (2), which is not a lower layer"))
            $r.Output | Should -Match '(?m)^FIX: '
        }

        It 'exits 2 and names the target when no layer holds it, with no project file' -Tag '#82' {
            $r = Invoke-Gate -From $script:Domain -To 'tools/Gen/Gen.csproj'

            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match 'no layer of dotnet\.layers holds this project'
            $r.Output | Should -Match '(?m)^FIX: '
        }

        It 'exits 3 when dotnet.layers is not set' -Tag '#82' {
            Clear-LayerKey

            $r = Invoke-Gate -From $script:Domain -To $script:Kernel

            $r.ExitCode | Should -Be 3
            $r.Output | Should -Match 'Not applicable: aisdlc\.json sets no dotnet\.layers\.'
        }

        It 'reads <Name> as the same path as the plain form' -Tag '#82' -ForEach @(
            @{ Name = 'backslashes'; From = 'src\Domain\Domain.csproj'; To = 'src\Shop.Api\Shop.Api.csproj' }
            @{ Name = 'a leading ./'; From = './src/Domain/Domain.csproj'; To = './src/Shop.Api/Shop.Api.csproj' }
            @{ Name = 'a leading slash'; From = '/src/Domain/Domain.csproj'; To = '/src/Shop.Api/Shop.Api.csproj' }
            @{ Name = 'spaces around the path'; From = ' src/Domain/Domain.csproj '; To = ' src/Shop.Api/Shop.Api.csproj ' }
        ) {
            $plain = Invoke-Gate -From $script:Domain -To $script:Api

            $r = Invoke-Gate -From $From -To $To

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Be $plain.Output
        }

        It 'exits 2 when -<Name> is <Case>' -Tag '#82' -ForEach @(
            @{ Name = 'From'; Case = 'a rooted path'; From = 'C:/src/Domain/Domain.csproj'; To = 'src/Kernel/Kernel.csproj' }
            @{ Name = 'To'; Case = 'a path with a .. part'; From = 'src/Domain/Domain.csproj'; To = 'src/../src/Kernel/Kernel.csproj' }
            @{ Name = 'From'; Case = 'a path that starts with ..'; From = '..\src\Domain\Domain.csproj'; To = 'src/Kernel/Kernel.csproj' }
            @{ Name = 'To'; Case = 'blank'; From = 'src/Domain/Domain.csproj'; To = ' ' }
        ) {
            $r = Invoke-Gate -From $From -To $To

            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match 'Could not check:'
            $r.Output | Should -Match "-$Name "
            $r.Output | Should -Match '(?m)^FIX: '
        }

        It 'exits 2 when only -<Given> is passed' -Tag '#82' -ForEach @(
            @{ Given = 'From' }
            @{ Given = 'To' }
        ) {
            $r = if ($Given -eq 'From') { Invoke-Gate -From $script:Domain } else { Invoke-Gate -To $script:Kernel }

            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match 'Could not check:'
            $r.Output | Should -Match '(?m)^FIX: '
        }

        It 'exits 2 when -From and -To are passed with <Other>' -Tag '#82' -ForEach @(
            @{ Other = '-All'; Which = 'All' }
            @{ Other = '-ChangedFiles'; Which = 'Changed' }
            @{ Other = '-BaseRef'; Which = 'BaseRef' }
        ) {
            $r = switch ($Which) {
                'All' { Invoke-Gate -From $script:Domain -To $script:Kernel -All }
                'Changed' { Invoke-Gate -From $script:Domain -To $script:Kernel -Changed @($script:Domain) }
                'BaseRef' { Invoke-Gate -From $script:Domain -To $script:Kernel -BaseRef 'origin/main' }
            }

            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match ([regex]::Escape($Other))
            $r.Output | Should -Match '(?m)^FIX: '
        }
    }

    Context 'the -All switch' {
        It 'judges a project that the change did not touch, with no git' -Tag '#82' {
            Add-Project -Path $script:Api
            Add-Project -Path $script:Domain -Reference $script:Api
            Add-Project -Path $script:Kernel

            $r = Invoke-Gate -All

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'src/Domain/Domain\.csproj -> src/Shop\.Api/Shop\.Api\.csproj'
        }

        It 'exits 0 when every reference points to a lower layer' -Tag '#82' {
            Add-Project -Path $script:Kernel
            Add-Project -Path $script:Domain -Reference $script:Kernel

            $r = Invoke-Gate -All

            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'OK'
        }

        It 'names a project file that cannot be read and exits 2' -Tag '#82' {
            Add-File -Path $script:Domain -Text '<Project'

            $r = Invoke-Gate -All

            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match 'src/Domain/Domain\.csproj cannot be read'
        }

        It 'exits 3 when the repository holds no project reference' -Tag '#82' {
            Add-Project -Path $script:Kernel

            (Invoke-Gate -All).ExitCode | Should -Be 3
        }
    }
}
