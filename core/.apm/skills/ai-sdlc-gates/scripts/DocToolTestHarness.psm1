#Requires -Version 7
<#
.SYNOPSIS
    The throwaway-repository fixture the documentation tool tests share.

.DESCRIPTION
    Check-DocDrift, Check-DocGraphClaims, Invoke-DocGraphLink and Update-DocFromGraph all need the
    same thing to test against: a temporary directory holding a handful of files at chosen relative
    paths, sometimes with a git repository initialised over it because the tool under test asks git
    which files are tracked. That fixture existed four times, once per test file, and the copies had
    already started to differ in ways that had nothing to do with what each file was testing.

    This is the same move DocSurface.psm1 makes for the rules the three checks share, applied to the
    test fixture rather than the production code.

    The shared gates read the folders of a repository from aisdlc.json. A fixture therefore gets a
    test aisdlc.json by default, with the two doc layers, the source and test roots and the data model
    patterns the tests were written against. Story keys use the default pattern (#42). Set-AiSdlcTestConfig writes the same file into a fixture that a
    test builds by hand.

.PARAMETER Files
    Relative path to file content. Parent directories are created as needed.

.PARAMETER Prefix
    Short prefix for the temporary directory name, so a leftover directory says which suite made it.

.PARAMETER InitialiseGit
    Initialise a git repository and commit the files. Needed only by the tools that ask git for the
    tracked file list; the graph-reading tools read the working tree directly and do not care.

.PARAMETER NoConfig
    Leave out the test aisdlc.json. Files that already hold an aisdlc.json keep their own.

.PARAMETER Root
    For Set-AiSdlcTestConfig: the fixture folder to write aisdlc.json into.

.PARAMETER Paths
    For Set-AiSdlcTestConfig: path values that replace the test defaults, for example
    @{ docsRoots = @('docs') }.

.EXAMPLE
    $root = New-DocToolRepo -Prefix 'ddr' -InitialiseGit -Files @{ 'docs/libraries/thing.md' = '# Thing' }

.PARAMETER Name
    For Find-AiSdlcSkillFolder: the skill to find, for example dotnet-gates.

.PARAMETER From
    For Find-AiSdlcSkillFolder and Get-AiSdlcHookSettings: the scripts folder of the calling test,
    usually $PSScriptRoot.

.EXAMPLE
    Set-AiSdlcTestConfig -Root $root -Paths @{ docsRoots = @('docs') }

.EXAMPLE
    Set-AiSdlcTestPack -Root $root -Packs dotnet, bicep
    Writes apm.yml with core and the two packs, which is where AiSdlcConfig.psm1 reads the packs from.
    No packs writes apm.yml with core only.

.EXAMPLE
    Find-AiSdlcSkillFolder -Name dotnet-gates -From $PSScriptRoot
    Finds a sibling skill in an installed repository (.claude/skills/<name>) and in the AI.SDLC source
    layout (core/.apm/skills/<name> or packs/<pack>/.apm/skills/<name>). Returns nothing when the
    skill is in neither, for example a pack the repository did not install.

.EXAMPLE
    (Get-AiSdlcHookSettings -From $PSScriptRoot).hooks.Stop
    Reads the hook entries: from the hooks/*.json files of the package in the AI.SDLC source layout,
    or from .claude/settings.json of the repository where the packages are installed.
#>

$script:TestPacks = @('dotnet', 'blazor', 'github-issues', 'github')

$script:TestConfig = [ordered]@{
    repository = 'Fixture'
    paths      = [ordered]@{
        docsRoots         = @('docs', 'docs-functional')
        technicalDocs     = 'docs'
        functionalDocs    = 'docs-functional'
        solution          = 'Demo/Demo.sln'
        sourceRoot        = 'Demo/src'
        testRoot          = 'Demo/tests'
        runSettings       = 'Demo/Demo.runsettings'
        coverageBaseline  = 'Demo/coverage-baseline.json'
        readingLevelRoots = @('docs', 'docs-functional', '.claude/skills', '.github', 'Demo')
        sectionRefRoots   = @('docs', 'docs-functional', '.claude/skills', 'Demo/tools', 'Demo/pipelines')
        sourceExtensions  = @('.cs', '.razor')
    }
    tracker    = [ordered]@{
        dataModelPatterns = @('Shared.Demo\.(Domain|Data)/.*/Models?/', 'Shared.Demo\.Domain/.*Entit')
    }
    dotnet     = [ordered]@{
        externalContractPaths  = @('Demo/src/Shared.Network/', 'Demo/src/Shared.Ledger/')
        wireNameAllowlist      = @(
            [ordered]@{
                name   = 'userId'
                file   = 'Demo/src/Shared.Demo.Domain/Common/Models/Core/Notification.cs'
                reason = 'Cosmos partition key path /userId. A partition key path is fixed for the life of the container.'
            }
        )
        portalAppComponent     = 'Demo/src/Portal.Demo/Components/App.razor'
    }
}

function Set-AiSdlcTestPack {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [string[]]$Packs = @()
    )

    $lines = @('name: fixture', 'version: "0.0.0"', 'dependencies:', '  apm:', '    - ../AI.SDLC/core') +
        @($Packs | Where-Object { $_ } | ForEach-Object { "    - ../AI.SDLC/packs/$_" })
    Set-Content -LiteralPath (Join-Path $Root 'apm.yml') -Value ($lines -join "`n") -Encoding utf8
}

function Set-AiSdlcTestConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [hashtable]$Paths
    )

    $config = $script:TestConfig | ConvertTo-Json -Depth 6 | ConvertFrom-Json -AsHashtable
    if ($Paths) { foreach ($key in $Paths.Keys) { $config.paths[$key] = $Paths[$key] } }
    Set-Content -LiteralPath (Join-Path $Root 'aisdlc.json') -Value ($config | ConvertTo-Json -Depth 6) -Encoding utf8
    Set-AiSdlcTestPack -Root $Root -Packs $script:TestPacks
}

function New-DocToolRepo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Files,
        [string]$Prefix = 'doctool',
        [switch]$InitialiseGit,
        [switch]$NoConfig
    )

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("$Prefix-" + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null

    if ($InitialiseGit) {
        git -C $root init --quiet
        git -C $root config user.email t@t.local
        git -C $root config user.name t
    }

    foreach ($rel in $Files.Keys) {
        $full = Join-Path $root $rel
        New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
        Set-Content -LiteralPath $full -Value $Files[$rel] -Encoding utf8
    }

    if (-not $NoConfig -and -not $Files.ContainsKey('aisdlc.json')) { Set-AiSdlcTestConfig -Root $root }

    if ($InitialiseGit) {
        git -C $root add -A *> $null
        git -C $root commit -m init --quiet *> $null
    }

    return $root
}

function Get-AiSdlcSkillsFolder {
    param([Parameter(Mandatory)][string]$From)
    $folder = (Resolve-Path -LiteralPath $From).Path
    if ((Split-Path $folder -Leaf) -eq 'scripts') { $folder = Split-Path $folder -Parent }
    return Split-Path $folder -Parent
}

function Find-AiSdlcSkillFolder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$From
    )

    $skills = Get-AiSdlcSkillsFolder -From $From
    $sibling = Join-Path $skills $Name
    if (Test-Path -LiteralPath $sibling -PathType Container) { return (Resolve-Path -LiteralPath $sibling).Path }

    $dir = $skills
    while ($dir) {
        if (Test-Path -LiteralPath (Join-Path $dir 'core' '.apm' 'skills') -PathType Container) {
            $candidates = @(Join-Path $dir 'core' '.apm' 'skills' $Name) +
                @(Get-ChildItem -LiteralPath (Join-Path $dir 'packs') -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName '.apm' 'skills' $Name })
            foreach ($candidate in $candidates) {
                if (Test-Path -LiteralPath $candidate -PathType Container) { return (Resolve-Path -LiteralPath $candidate).Path }
            }
            return $null
        }
        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

function Get-AiSdlcHookSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$From)

    $skills = Get-AiSdlcSkillsFolder -From $From
    $apm = Split-Path $skills -Parent
    if ((Split-Path $apm -Leaf) -eq '.apm') {
        $merged = [ordered]@{}
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $apm 'hooks') -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $data = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable
            foreach ($event in $data.hooks.Keys) {
                if (-not $merged.Contains($event)) { $merged[$event] = [System.Collections.Generic.List[object]]::new() }
                foreach ($entry in $data.hooks[$event]) { $merged[$event].Add($entry) }
            }
        }
        return ([ordered]@{ hooks = $merged } | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
    }

    $repo = Split-Path (Split-Path $skills -Parent) -Parent
    $settings = Join-Path $repo '.claude' 'settings.json'
    if (-not (Test-Path -LiteralPath $settings -PathType Leaf)) { return $null }
    return Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
}

function ConvertTo-ParameterTable {
    <#
    .SYNOPSIS
        Turns a command-line argument list (-Name value -Switch) into a hashtable for splatting.
    .DESCRIPTION
        Splatting an array into a script binds every item by position, so '-Name' would become a
        value. A token that starts with '-' names a parameter. The next token is its value, unless that
        token names a parameter too or the list ends; then the parameter is a switch.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Arguments = @())

    $table = [ordered]@{}
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $token = $Arguments[$i]
        if (-not ($token -is [string] -and $token -match '^-([A-Za-z]\w*)(:(.*))?$')) {
            throw "Argument '$token' at position $i does not name a parameter."
        }
        $name = $matches[1]
        if ($matches[2]) { $table[$name] = $matches[3]; continue }
        $next = if ($i + 1 -lt $Arguments.Count) { $Arguments[$i + 1] } else { $null }
        if ($null -eq $next -or ($next -is [string] -and $next -match '^-[A-Za-z]\w*(:.*)?$')) { $table[$name] = $true; continue }
        $table[$name] = $next
        $i++
    }
    return $table
}

function Invoke-ScriptInProcess {
    <#
    .SYNOPSIS
        Runs a script in this process the way a test used to run it in a child pwsh, and returns its
        output and exit code.
    .DESCRIPTION
        The coverage of the Pester runs measures only the test process, so a script that a test starts
        in a child pwsh counts as not covered. This runs it with & instead. A terminating error becomes
        exit code 1 with the message in the output, as pwsh -File would give. The location and the
        environment variables are put back afterwards, so the next test starts clean.

        One difference remains. A script that ends without exit, right after a native command that
        failed, returns the exit code of that command here; pwsh -File gives 0. The helper cannot tell
        that code from a real exit. A test of such a script sets LASTEXITCODE to 0 at its end itself.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyCollection()][object[]]$Arguments = @(),
        [hashtable]$Parameters = @{}
    )

    $splat = ConvertTo-ParameterTable -Arguments $Arguments
    foreach ($key in $Parameters.Keys) { $splat[$key] = $Parameters[$key] }
    $location = Get-Location
    $environment = @{}
    foreach ($item in Get-ChildItem Env:) { $environment[$item.Name] = $item.Value }
    $buffer = [System.Collections.Generic.List[object]]::new()
    $global:LASTEXITCODE = 0
    $code = 0
    try {
        & $Path @splat *>&1 | ForEach-Object { $buffer.Add($_) }
        $code = $global:LASTEXITCODE
    }
    catch {
        $buffer.Add($_)
        $code = 1
    }
    finally {
        Set-Location -LiteralPath $location.Path
        foreach ($item in @(Get-ChildItem Env:)) {
            if (-not $environment.ContainsKey($item.Name)) { Remove-Item -LiteralPath "Env:$($item.Name)" -ErrorAction SilentlyContinue }
        }
        foreach ($name in $environment.Keys) {
            if ([Environment]::GetEnvironmentVariable($name) -cne $environment[$name]) { [Environment]::SetEnvironmentVariable($name, $environment[$name]) }
        }
    }
    $global:LASTEXITCODE = $code
    return [pscustomobject]@{ Output = ($buffer | Out-String); Lines = @($buffer | ForEach-Object { "$_" }); ExitCode = $code }
}

function Invoke-WithInProcessCommand {
    <#
    .SYNOPSIS
        Runs a script block in which pwsh -File, and each command named in -Script, run in this process.
    .DESCRIPTION
        A test of a tool that starts small stand-in scripts in a child pwsh pays about half a second for
        each start. Inside the script block, a call of pwsh with -File runs that script through
        Invoke-ScriptInProcess instead, with the same output lines and exit code. Any other pwsh call,
        such as pwsh -Command, still starts the real pwsh. Each name in -Script, such as apm, runs the
        script it maps to with the same arguments, in place of a shim on the PATH that starts pwsh.
        The stand-ins are global functions, because a function wins over a program of the same name,
        and they are removed afterwards. A global function that had the same name before comes back.
        A test that must cross the process boundary does not use this.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [hashtable]$Script = @{}
    )

    $names = [System.Collections.Generic.List[string]]::new()
    $pwshStandIn = {
        $list = @($args)
        $at = -1
        for ($i = 0; $i -lt $list.Count; $i++) { if ("$($list[$i])" -ieq '-File') { $at = $i; break } }
        if ($at -lt 0 -or $at + 1 -ge $list.Count) {
            $real = Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1
            & $real.Source @list
            return
        }
        $run = Invoke-ScriptInProcess -Path ([string]$list[$at + 1]) -Arguments @($list | Select-Object -Skip ($at + 2))
        $run.Lines
        $global:LASTEXITCODE = $run.ExitCode
    }
    $before = @{}
    $standIns = [ordered]@{ pwsh = $pwshStandIn }
    foreach ($name in $Script.Keys) {
        $path = [string]$Script[$name]
        $standIns[$name] = { $global:LASTEXITCODE = 0; & $path @args }.GetNewClosure()
    }
    try {
        foreach ($name in $standIns.Keys) {
            $existing = Get-Item -LiteralPath "function:\$name" -ErrorAction SilentlyContinue
            if ($existing) { $before[$name] = $existing.ScriptBlock }
            Set-Item -Path "function:global:$name" -Value $standIns[$name]
            $names.Add($name)
        }
        & $ScriptBlock
    }
    finally {
        foreach ($name in $names) {
            Remove-Item -LiteralPath "function:\$name" -ErrorAction SilentlyContinue
            if ($before.ContainsKey($name)) { Set-Item -Path "function:global:$name" -Value $before[$name] }
        }
    }
}

Export-ModuleMember -Function New-DocToolRepo, Set-AiSdlcTestConfig, Set-AiSdlcTestPack, Find-AiSdlcSkillFolder, Get-AiSdlcHookSettings, ConvertTo-ParameterTable, Invoke-ScriptInProcess, Invoke-WithInProcessCommand
