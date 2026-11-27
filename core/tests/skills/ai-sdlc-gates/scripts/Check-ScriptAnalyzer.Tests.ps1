#requires -Version 7.4

BeforeAll {
    $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm'
    $script:SavedEnvironment = @{}
    foreach ($name in 'PR_TARGET_BRANCH', 'CHANGED_FILES', 'AISDLC_CHANGE_BASE') {
        $script:SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $null)
    }
    $script:ScriptUnderTest = Join-Path -Path $script:ScriptFolder -ChildPath 'Check-ScriptAnalyzer.ps1'
    $script:SavedModulePath = $env:PSModulePath

    function New-FakeAnalyzer {
        param([string]$Version)
        $root = Join-Path $TestDrive ('modules-' + [guid]::NewGuid().ToString('n'))
        $folder = Join-Path $root "PSScriptAnalyzer/$Version"
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $folder 'PSScriptAnalyzer.psd1') -Value @(
            '@{'
            "    ModuleVersion = '$Version'"
            "    RootModule = 'PSScriptAnalyzer.psm1'"
            "    FunctionsToExport = @('Invoke-ScriptAnalyzer')"
            '}'
        )
        Set-Content -LiteralPath (Join-Path $folder 'PSScriptAnalyzer.psm1') -Value @(
            'function Invoke-ScriptAnalyzer {'
            '    [CmdletBinding()]'
            '    param([Parameter(Mandatory)][string]$Path, [object]$Settings, [string[]]$IncludeRule, [string[]]$ExcludeRule, [string[]]$Severity)'
            '    $global:FakeAnalyzerParameters = @($PSBoundParameters.Keys | Where-Object { $_ -notin ''ErrorAction'', ''ErrorVariable'' } | Sort-Object)'
            '    $global:FakeAnalyzerSettings = $Settings'
            '    if ((Get-Content -LiteralPath $Path -Raw) -match ''ANALYZER-CRASH'') { Write-Error ''Object reference not set to an instance of an object.'' }'
            '    $number = 0'
            '    foreach ($text in Get-Content -LiteralPath $Path) {'
            '        $number++'
            '        if ($text -match ''\bgci\b'') {'
            '            [pscustomobject]@{ RuleName = ''PSAvoidUsingCmdletAliases''; Severity = ''Warning''; Line = $number; Message = ''gci is an alias of Get-ChildItem.''; ScriptPath = $Path }'
            '        }'
            '    }'
            '}'
        )
        return $root
    }

    function Use-ModulePath {
        param([string]$Folder)
        $env:PSModulePath = $Folder + [System.IO.Path]::PathSeparator + (Join-Path $PSHOME 'Modules')
    }

    function Invoke-Check {
        param([Parameter(Mandatory)][string[]]$Body, [string]$Path = 'tools/Run.ps1')
        $repo = Join-Path $TestDrive ('plain-' + [guid]::NewGuid().ToString('n'))
        $full = Join-Path $repo $Path
        New-Item -ItemType Directory -Path (Split-Path $full) -Force | Out-Null
        Set-Content -LiteralPath $full -Value $Body
        $out = & $script:ScriptUnderTest -RepoRoot $repo -ChangedFiles $Path *>&1 | Out-String
        [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
    }

    function New-GitRepo {
        param([string[]]$Body, [string[]]$Lock)
        $PSNativeCommandUseErrorActionPreference = $true
        $repo = Join-Path $TestDrive ('repo-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path (Join-Path $repo 'tools') -Force | Out-Null
        git -C $repo init --quiet -b work
        git -C $repo config user.email probe@example.invalid
        git -C $repo config user.name probe
        git -C $repo config core.autocrlf false
        Set-Content -LiteralPath (Join-Path $repo 'tools/Run.ps1') -Value $Body
        if ($Lock) {
            $lines = @("lockfile_version: '1'", 'dependencies:', '- repo_url: _local/core', '  name: ai-sdlc-core', '  deployed_files:') + @($Lock | ForEach-Object { "  - $_" }) + @('  package_type: apm_package')
            Set-Content -LiteralPath (Join-Path $repo 'apm.lock.yaml') -Value $lines
        }
        git -C $repo add -A
        git -C $repo commit --quiet --no-verify -m base
        git -C $repo update-ref refs/remotes/origin/main HEAD
        return $repo
    }

    function Save-Commit {
        param([string]$Repo)
        $PSNativeCommandUseErrorActionPreference = $true
        git -C $Repo add -A
        git -C $Repo commit --quiet --no-verify -m change
    }
}

AfterAll {
    $env:PSModulePath = $script:SavedModulePath
    foreach ($name in $script:SavedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $script:SavedEnvironment[$name]) }
}

Describe 'Check-ScriptAnalyzer' {
    BeforeEach {
        Use-ModulePath -Folder (New-FakeAnalyzer -Version '1.25.0')
        $global:FakeAnalyzerParameters = $null
    }

    AfterEach {
        Remove-Module -Name PSScriptAnalyzer -Force -ErrorAction Ignore
        $env:PSModulePath = $script:SavedModulePath
        Remove-Variable -Name FakeAnalyzerParameters, FakeAnalyzerSettings -Scope Global -ErrorAction Ignore
    }

    Context 'a finding on an added line is a warning (AC-8)' {
        It 'reports the file, the line, the rule and a FIX line, and exits 1' -Tag '#72' {
            $r = Invoke-Check @('$folder = ''.''', 'gci -Path $folder')

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'tools/Run\.ps1:2  PSAvoidUsingCmdletAliases \(Warning\)'
            $r.Output | Should -Match 'never stops a push'
            $r.Output | Should -Match 'FIX: '
        }

        It 'runs the analyzer with settings the gate owns, which keep the default rules but Write-Host and load no custom rule' -Tag '#72' {
            $r = Invoke-Check @('$folder = ''.''', 'Get-ChildItem -Path $folder')

            $r.ExitCode | Should -Be 0 -Because $r.Output
            $global:FakeAnalyzerParameters | Should -Be @('Path', 'Settings')
            $global:FakeAnalyzerSettings | Should -BeOfType [hashtable]
            $global:FakeAnalyzerSettings['IncludeDefaultRules'] | Should -BeTrue
            $global:FakeAnalyzerSettings['Severity'] | Should -Be @('Error', 'Warning', 'Information')
            $global:FakeAnalyzerSettings['ExcludeRules'] | Should -Be @('PSAvoidUsingWriteHost')
            @($global:FakeAnalyzerSettings.Keys | Sort-Object) | Should -Be @('ExcludeRules', 'IncludeDefaultRules', 'Severity')
        }

        It 'passes its own settings also when the repository holds a PSScriptAnalyzerSettings.psd1, so that file is never read' -Tag '#72' {
            $repo = Join-Path $TestDrive ('plain-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path (Join-Path $repo 'tools') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $repo 'PSScriptAnalyzerSettings.psd1') -Value @('@{ CustomRulePath = ''./evil''; ExcludeRules = @(''*'') }')
            Set-Content -LiteralPath (Join-Path $repo 'tools/PSScriptAnalyzerSettings.psd1') -Value @('@{ ExcludeRules = @(''*'') }')
            Set-Content -LiteralPath (Join-Path $repo 'tools/Run.ps1') -Value @('gci -Path .')

            $out = & $script:ScriptUnderTest -RepoRoot $repo -ChangedFiles 'tools/Run.ps1' *>&1 | Out-String

            $LASTEXITCODE | Should -Be 1 -Because $out
            $global:FakeAnalyzerSettings | Should -BeOfType [hashtable]
            $global:FakeAnalyzerSettings.ContainsKey('CustomRulePath') | Should -BeFalse
            $global:FakeAnalyzerSettings['ExcludeRules'] | Should -Be @('PSAvoidUsingWriteHost')
        }

        It 'passes a file with no finding and names the analyzer version' -Tag '#72' {
            $r = Invoke-Check @('$folder = ''.''', 'Get-ChildItem -Path $folder')

            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match 'Script analyzer OK: PSScriptAnalyzer 1\.25\.0 read 1 PowerShell file'
        }
    }

    Context 'what the change covers' {
        It 'reports only the lines the change adds, so an older finding in a touched file is not reported' -Tag '#72' {
            $repo = New-GitRepo -Body @('gci -Path .', '$a = 1')
            Add-Content -LiteralPath (Join-Path $repo 'tools/Run.ps1') -Value @('$b = 2', 'gci -Path $b')
            Save-Commit -Repo $repo

            $out = & $script:ScriptUnderTest -RepoRoot $repo *>&1 | Out-String

            $LASTEXITCODE | Should -Be 1 -Because $out
            $out | Should -Match 'Run\.ps1:4  PSAvoidUsingCmdletAliases'
            $out | Should -Not -Match 'Run\.ps1:1  '
        }

        It 'passes a touched file whose only finding sits on an older line' -Tag '#72' {
            $repo = New-GitRepo -Body @('gci -Path .', '$a = 1')
            Add-Content -LiteralPath (Join-Path $repo 'tools/Run.ps1') -Value @('$b = 2')
            Save-Commit -Repo $repo

            $out = & $script:ScriptUnderTest -RepoRoot $repo *>&1 | Out-String

            $LASTEXITCODE | Should -Be 0 -Because $out
        }

        It 'skips the files that apm.lock.yaml at the base lists as installed' -Tag '#72' {
            $repo = New-GitRepo -Body @('$a = 1') -Lock '.claude/skills/demo/scripts/Shared.ps1'
            New-Item -ItemType Directory -Path (Join-Path $repo '.claude/skills/demo/scripts') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $repo '.claude/skills/demo/scripts/Shared.ps1') -Value @('gci -Path .')
            Set-Content -LiteralPath (Join-Path $repo '.claude/skills/demo/scripts/Own.ps1') -Value @('gci -Path .')
            Save-Commit -Repo $repo

            $out = & $script:ScriptUnderTest -RepoRoot $repo *>&1 | Out-String

            $LASTEXITCODE | Should -Be 1 -Because $out
            $out | Should -Match 'Own\.ps1:1'
            $out | Should -Not -Match 'Shared\.ps1'
        }

        It 'skips a .claude/ script that the same change installs and adds to apm.lock.yaml' -Tag '#72' {
            $repo = New-GitRepo -Body @('$a = 1') -Lock '.claude/skills/demo/scripts/Shared.ps1'
            New-Item -ItemType Directory -Path (Join-Path $repo '.claude/skills/demo/scripts') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $repo '.claude/skills/demo/scripts/Fresh.ps1') -Value @('gci -Path .')
            $sha = (Get-FileHash -LiteralPath (Join-Path $repo '.claude/skills/demo/scripts/Fresh.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()
            $lines = @("lockfile_version: '1'", 'dependencies:', '- repo_url: _local/core', '  name: ai-sdlc-core', '  deployed_files:', '  - .claude/skills/demo/scripts/Shared.ps1', '  - .claude/skills/demo/scripts/Fresh.ps1', '  deployed_file_hashes:', "    .claude/skills/demo/scripts/Fresh.ps1: sha256:$sha", '  package_type: apm_package')
            Set-Content -LiteralPath (Join-Path $repo 'apm.lock.yaml') -Value $lines
            Set-Content -LiteralPath (Join-Path $repo 'tools/Own.ps1') -Value @('gci -Path .')
            Save-Commit -Repo $repo

            $out = & $script:ScriptUnderTest -RepoRoot $repo *>&1 | Out-String

            $LASTEXITCODE | Should -Be 1 -Because $out
            $out | Should -Match 'Own\.ps1:1'
            $out | Should -Not -Match 'Fresh\.ps1'
        }

        It 'exits 3 when the change touches no .ps1 or .psm1 file' -Tag '#72' {
            $r = Invoke-Check -Path 'pipelines/build.yml' -Body @('steps:', '- pwsh: gci')

            $r.ExitCode | Should -Be 3 -Because $r.Output
            $r.Output | Should -Match 'Not applicable'
        }
    }

    Context 'it fails closed when it cannot check' {
        It 'exits 2 and says nothing was checked when PSScriptAnalyzer is not installed' -Tag '#72' {
            Use-ModulePath -Folder (Join-Path $TestDrive ('empty-' + [guid]::NewGuid().ToString('n')))

            $r = Invoke-Check @('gci -Path .')

            $r.ExitCode | Should -Be 2 -Because $r.Output
            $r.Output | Should -Match 'PSScriptAnalyzer module at version 1\.21\.0 or newer is not installed, so NOTHING WAS CHECKED'
            $r.Output | Should -Match 'FIX: Install the module'
        }

        It 'exits 2 when the installed PSScriptAnalyzer is older than the pinned minimum' -Tag '#72' {
            Use-ModulePath -Folder (New-FakeAnalyzer -Version '1.20.0')

            $r = Invoke-Check @('gci -Path .')

            $r.ExitCode | Should -Be 2 -Because $r.Output
            $r.Output | Should -Match 'NOTHING WAS CHECKED'
        }

        It 'exits 3, not 2, when there is no PowerShell change and no module either' -Tag '#72' {
            Use-ModulePath -Folder (Join-Path $TestDrive ('empty-' + [guid]::NewGuid().ToString('n')))

            $r = Invoke-Check -Path 'docs/page.md' -Body @('# Page')

            $r.ExitCode | Should -Be 3 -Because $r.Output
        }

        It 'reports a script that does not parse as not checked, never as clean' -Tag '#72' {
            $r = Invoke-Check @('function Get-Count {', '    gci -Path .')

            $r.ExitCode | Should -Be 2 -Because $r.Output
            $r.Output | Should -Match 'tools/Run\.ps1 : the file does not parse'
            $r.Output | Should -Match 'FIX: '
        }

        It 'names a file on which the analyzer fails as not checked, never as clean' -Tag '#72' {
            $r = Invoke-Check @('# ANALYZER-CRASH', '$a = 1')

            $r.ExitCode | Should -Be 2 -Because $r.Output
            $r.Output | Should -Match 'tools/Run\.ps1 : PSScriptAnalyzer failed on the file'
            $r.Output | Should -Match 'FIX: '
        }

        It 'exits 2 when there is no merge base, so the change could not be read' -Tag '#72' {
            $repo = New-GitRepo -Body @('$a = 1')

            $out = & $script:ScriptUnderTest -RepoRoot $repo -BaseRef 'origin/no-such-branch' *>&1 | Out-String

            $LASTEXITCODE | Should -Be 2 -Because $out
            $out | Should -Match 'NOTHING WAS CHECKED'
        }

        It 'names a script reached through a link to a folder outside the repository as not checked' -Tag '#72' {
            $repo = Join-Path $TestDrive ('plain-' + [guid]::NewGuid().ToString('n'))
            $outside = Join-Path $TestDrive ('outside-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $repo, $outside -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $outside 'Far.ps1') -Value @('gci -Path .')
            $kind = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
            try { New-Item -ItemType $kind -Path (Join-Path $repo 'linked') -Target $outside -ErrorAction Stop | Out-Null }
            catch { Set-ItResult -Skipped -Because "this machine cannot create a $kind"; return }

            $out = & $script:ScriptUnderTest -RepoRoot $repo -ChangedFiles 'linked/Far.ps1' *>&1 | Out-String

            $LASTEXITCODE | Should -Be 2 -Because $out
            $out | Should -Match 'linked/Far\.ps1 : the path goes through a symbolic link or junction'
        }

        It 'names a path outside the repository as not checked' -Tag '#72' {
            $repo = Join-Path $TestDrive ('plain-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $repo -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $TestDrive 'Outside.ps1') -Value @('gci -Path .')

            $out = & $script:ScriptUnderTest -RepoRoot $repo -ChangedFiles '../Outside.ps1' *>&1 | Out-String

            $LASTEXITCODE | Should -Be 2 -Because $out
            $out | Should -Match 'Outside\.ps1 : the path is outside the repository'
        }

        It 'names a <Case> as outside the repository, before it is joined to the repository root' -Tag '#72' -ForEach @(
            @{ Case = 'rooted path'; Listed = { Join-Path $TestDrive 'Rooted.ps1' } }
            @{ Case = 'UNC path'; Listed = { '\\server\share\Far.ps1' } }
            @{ Case = 'forward-slash UNC path'; Listed = { '//server/share/Far.ps1' } }
            @{ Case = 'path that goes up and back in'; Listed = { 'tools/../tools/Run.ps1' } }
        ) {
            $repo = Join-Path $TestDrive ('plain-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path (Join-Path $repo 'tools') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $repo 'tools/Run.ps1') -Value @('gci -Path .')
            Set-Content -LiteralPath (Join-Path $TestDrive 'Rooted.ps1') -Value @('gci -Path .')
            $path = & $Listed

            $out = & $script:ScriptUnderTest -RepoRoot $repo -ChangedFiles $path *>&1 | Out-String

            $LASTEXITCODE | Should -Be 2 -Because $out
            $out | Should -Match 'the path is outside the repository'
            $global:FakeAnalyzerParameters | Should -BeNullOrEmpty
        }
    }
}
