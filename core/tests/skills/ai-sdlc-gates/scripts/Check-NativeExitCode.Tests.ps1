#requires -Version 7.4

BeforeAll {
    $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm'
    $script:SavedEnvironment = @{}
    foreach ($name in 'PR_TARGET_BRANCH', 'CHANGED_FILES', 'AISDLC_CHANGE_BASE') {
        $script:SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $null)
    }
    $script:ScriptUnderTest = Join-Path -Path $script:ScriptFolder -ChildPath 'Check-NativeExitCode.ps1'

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
        if ($Lock) { Set-LockFile -Repo $repo -Deployed $Lock }
        git -C $repo add -A
        git -C $repo commit --quiet --no-verify -m base
        git -C $repo update-ref refs/remotes/origin/main HEAD
        return $repo
    }

    function Set-LockFile {
        param([string]$Repo, [string[]]$Deployed, [hashtable]$Hash = @{})
        $lines = @("lockfile_version: '1'", 'dependencies:', '- repo_url: _local/core', '  name: ai-sdlc-core', '  deployed_files:') + @($Deployed | ForEach-Object { "  - $_" }) + $(if ($Hash.Count -gt 0) { @('  deployed_file_hashes:') + @($Hash.Keys | ForEach-Object { "    $($_): sha256:$($Hash[$_])" }) }) + @('  package_type: apm_package')
        Set-Content -LiteralPath (Join-Path $Repo 'apm.lock.yaml') -Value $lines
    }

    function Save-Commit {
        param([string]$Repo)
        $PSNativeCommandUseErrorActionPreference = $true
        git -C $Repo add -A
        git -C $Repo commit --quiet --no-verify -m change
    }
}

AfterAll {
    foreach ($name in $script:SavedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $script:SavedEnvironment[$name]) }
}

Describe 'Check-NativeExitCode' {
    Context 'a native call with no exit-code check is a finding (AC-1)' {
        It 'reports a call to <Tool> and names the file and the line' -Tag '#71' -ForEach @(
            @{ Tool = 'az'; Call = 'az group list --output json' }
            @{ Tool = 'git'; Call = 'git fetch origin' }
            @{ Tool = 'dotnet'; Call = 'dotnet build --configuration Release' }
            @{ Tool = 'bicep'; Call = 'bicep build main.bicep' }
        ) {
            $r = Invoke-Check @('$a = 1', $Call, 'Write-Output $a')

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match ("tools/Run\.ps1:2  " + [regex]::Escape($Call))
            $r.Output | Should -Match 'FIX: '
        }

        It 'reports a call through the & operator, with .exe, and with a folder in front' -Tag '#71' {
            $r = Invoke-Check @('& git status', '& ''git.exe'' status', '& "C:\tools\az.cmd" login', 'Write-Output done')

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'Run\.ps1:1  '
            $r.Output | Should -Match 'Run\.ps1:2  '
            $r.Output | Should -Match 'Run\.ps1:3  '
        }

        It 'reports a call whose check comes two statements later' -Tag '#71' {
            $r = Invoke-Check @('git fetch origin', '$a = 1', 'if ($LASTEXITCODE -ne 0) { throw "fetch failed" }')

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'Run\.ps1:1  git fetch origin'
        }

        It 'reports a call that is the last statement of its block' -Tag '#71' {
            $r = Invoke-Check @('function Update-Remote {', '    git fetch origin', '}', 'Update-Remote', 'if ($LASTEXITCODE -ne 0) { throw "fetch failed" }')

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'Run\.ps1:2  git fetch origin'
        }

        It 'reports a call when $LASTEXITCODE sits only in a string or a comment of the next statement' -Tag '#71' {
            $r = Invoke-Check @('git fetch origin', 'Write-Host "exit code $LASTEXITCODE"', 'dotnet build', '# $LASTEXITCODE', '$b = 2')

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'Run\.ps1:1  git fetch origin'
            $r.Output | Should -Match 'Run\.ps1:3  dotnet build'
        }

        It 'reports a call whose next statement reads $LASTEXITCODE but does not test it: <Case>' -Tag '#71' -ForEach @(
            @{ Case = 'only printed'; Body = @('git fetch origin', 'Write-Output $LASTEXITCODE') }
            @{ Case = 'only inside a loop body'; Body = @('git fetch origin', 'foreach ($i in 1..2) { if ($LASTEXITCODE -ne 0) { throw "x" } }') }
            @{ Case = 'only inside the body of an if'; Body = @('git fetch origin', 'if ($a) { $code = $LASTEXITCODE }') }
            @{ Case = 'only inside a function definition'; Body = @('git fetch origin', 'function Test-Code { if ($LASTEXITCODE -ne 0) { throw "x" } }') }
            @{ Case = 'only inside a script block on the right side'; Body = @('git fetch origin', '$later = { $LASTEXITCODE }') }
        ) {
            $r = Invoke-Check $Body

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'Run\.ps1:1  git fetch origin'
        }
    }

    Context 'a call with a check is not a finding (AC-2)' {
        It 'passes a call followed by <Case>' -Tag '#71' -ForEach @(
            @{ Case = 'an if on $LASTEXITCODE'; Body = @('$json = az group list --output json', 'if ($LASTEXITCODE -ne 0) {', '    throw "az group list failed with exit code $LASTEXITCODE"', '}') }
            @{ Case = 'a check on the same line'; Body = @('git fetch origin; $ok = $LASTEXITCODE -eq 0', 'Write-Output $ok') }
            @{ Case = 'a || chain'; Body = @('dotnet build || throw "build failed"') }
            @{ Case = 'a && chain'; Body = @('git fetch origin && Write-Output fetched') }
            @{ Case = 'a check after a call inside @( )'; Body = @('$files = @(git ls-files)', 'if ($LASTEXITCODE -ne 0) { throw "git ls-files failed" }') }
            @{ Case = 'a check in the same if statement'; Body = @('if ((git diff --quiet) -or $LASTEXITCODE -ne 0) { Write-Output changed }') }
            @{ Case = 'a scoped $global:LASTEXITCODE'; Body = @('bicep build main.bicep', 'exit $global:LASTEXITCODE') }
        ) {
            $r = Invoke-Check $Body

            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match 'Native exit code OK: 1 PowerShell file'
        }
    }

    Context 'a script that stops on a failed native call is not a finding (AC-3)' {
        It 'passes the calls after $PSNativeCommandUseErrorActionPreference = $true, also inside a function' -Tag '#71' {
            $r = Invoke-Check @('$PSNativeCommandUseErrorActionPreference = $true', 'git fetch origin', 'function Get-Head {', '    git rev-parse HEAD', '}', 'Get-Head')

            $r.ExitCode | Should -Be 0 -Because $r.Output
        }

        It 'reports the calls when the preference is <Case>' -Tag '#71' -ForEach @(
            @{ Case = 'false'; Body = @('$PSNativeCommandUseErrorActionPreference = $false', 'git fetch origin', '$a = 1') }
            @{ Case = 'only in a string'; Body = @('$note = ''$PSNativeCommandUseErrorActionPreference = $true''', 'git fetch origin', '$a = 1') }
            @{ Case = 'set after the call'; Body = @('git fetch origin', '$PSNativeCommandUseErrorActionPreference = $true') }
            @{ Case = 'set inside an if'; Body = @('if ($ci) { $PSNativeCommandUseErrorActionPreference = $true }', 'git fetch origin', '$a = 1') }
            @{ Case = 'set inside a loop'; Body = @('foreach ($i in 1) { $PSNativeCommandUseErrorActionPreference = $true }', 'git fetch origin', '$a = 1') }
            @{ Case = 'set inside a try'; Body = @('try { $PSNativeCommandUseErrorActionPreference = $true } catch { }', 'git fetch origin', '$a = 1') }
            @{ Case = 'set inside a switch'; Body = @('switch ($mode) { ''ci'' { $PSNativeCommandUseErrorActionPreference = $true } }', 'git fetch origin', '$a = 1') }
            @{ Case = 'set inside another function'; Body = @('function Set-Strict { $PSNativeCommandUseErrorActionPreference = $true }', 'git fetch origin', '$a = 1') }
            @{ Case = 'set back to false after true'; Body = @('$PSNativeCommandUseErrorActionPreference = $true', '$PSNativeCommandUseErrorActionPreference = $false', 'git fetch origin', '$a = 1') }
        ) {
            $r = Invoke-Check $Body

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'git fetch origin'
        }
    }

    Context 'a cmdlet is not a native call (AC-4)' {
        It 'passes Get-ChildItem, and a native name that is only an argument' -Tag '#71' {
            $r = Invoke-Check @('$items = Get-ChildItem -Path .', 'Get-Command git', '$tool = ''az''', 'Write-Output "git $tool"')

            $r.ExitCode | Should -Be 0 -Because $r.Output
        }
    }

    Context 'what the change covers, and when it cannot check' {
        It 'reads only the lines the change adds, so an older call in a touched file is not reported' -Tag '#71' {
            $repo = New-GitRepo -Body @('git fetch origin', '$a = 1')
            Add-Content -LiteralPath (Join-Path $repo 'tools/Run.ps1') -Value @('dotnet build', '$b = 2')
            Save-Commit -Repo $repo

            $out = & $script:ScriptUnderTest -RepoRoot $repo *>&1 | Out-String

            $LASTEXITCODE | Should -Be 1 -Because $out
            $out | Should -Match 'Run\.ps1:3  dotnet build'
            $out | Should -Not -Match 'git fetch origin'
        }

        It 'reports a script that does not parse as not checked, never as clean' -Tag '#71' {
            $r = Invoke-Check @('function Get-Count {', '    git rev-parse HEAD')

            $r.ExitCode | Should -Be 2 -Because $r.Output
            $r.Output | Should -Match 'NOTHING WAS CHECKED'
            $r.Output | Should -Match 'tools/Run\.ps1 : the file does not parse'
            $r.Output | Should -Match 'FIX: '
        }

        It 'exits 2 when there is no merge base, so the change could not be read' -Tag '#71' {
            $repo = New-GitRepo -Body @('$a = 1')

            $out = & $script:ScriptUnderTest -RepoRoot $repo -BaseRef 'origin/no-such-branch' *>&1 | Out-String

            $LASTEXITCODE | Should -Be 2 -Because $out
            $out | Should -Match 'NOTHING WAS CHECKED'
            $out | Should -Match 'FIX: '
        }

        It 'exits 3 when the change touches no .ps1 or .psm1 file' -Tag '#71' {
            $r = Invoke-Check -Path 'pipelines/build.yml' -Body @('steps:', '- pwsh: git fetch origin')

            $r.ExitCode | Should -Be 3 -Because $r.Output
            $r.Output | Should -Match 'Not applicable'
        }

        It 'skips the files that apm.lock.yaml at the base lists as installed, which a consumer must not edit' -Tag '#71' {
            $repo = New-GitRepo -Body @('$a = 1') -Lock '.claude/skills/demo/scripts/Shared.ps1'
            New-Item -ItemType Directory -Path (Join-Path $repo '.claude/skills/demo/scripts') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $repo '.claude/skills/demo/scripts/Shared.ps1') -Value @('git fetch origin', '$a = 1')
            Set-Content -LiteralPath (Join-Path $repo '.claude/skills/demo/scripts/Own.ps1') -Value @('git fetch origin', '$b = 2')
            Save-Commit -Repo $repo

            $out = & $script:ScriptUnderTest -RepoRoot $repo *>&1 | Out-String

            $LASTEXITCODE | Should -Be 1 -Because $out
            $out | Should -Match 'Own\.ps1:1'
            $out | Should -Not -Match 'Shared\.ps1'
        }

        It 'skips a .claude/ script that the same change installs and adds to apm.lock.yaml' -Tag '#71' {
            $repo = New-GitRepo -Body @('$a = 1') -Lock '.claude/skills/demo/scripts/Shared.ps1'
            New-Item -ItemType Directory -Path (Join-Path $repo '.claude/skills/demo/scripts') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $repo '.claude/skills/demo/scripts/Fresh.ps1') -Value @('git fetch origin', '$a = 1')
            $sha = (Get-FileHash -LiteralPath (Join-Path $repo '.claude/skills/demo/scripts/Fresh.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()
            Set-LockFile -Repo $repo -Deployed '.claude/skills/demo/scripts/Shared.ps1', '.claude/skills/demo/scripts/Fresh.ps1' -Hash @{ '.claude/skills/demo/scripts/Fresh.ps1' = $sha }
            Set-Content -LiteralPath (Join-Path $repo 'tools/Own.ps1') -Value @('git fetch origin', '$b = 2')
            Save-Commit -Repo $repo

            $out = & $script:ScriptUnderTest -RepoRoot $repo *>&1 | Out-String

            $LASTEXITCODE | Should -Be 1 -Because $out
            $out | Should -Match 'tools/Own\.ps1:1'
            $out | Should -Not -Match 'Fresh\.ps1'
        }

        It 'does not skip a script that the same change adds to apm.lock.yaml' -Tag '#71' {
            $repo = New-GitRepo -Body @('$a = 1') -Lock '.claude/skills/demo/scripts/Shared.ps1'
            Set-LockFile -Repo $repo -Deployed '.claude/skills/demo/scripts/Shared.ps1', 'tools/Own.ps1'
            Set-Content -LiteralPath (Join-Path $repo 'tools/Own.ps1') -Value @('git fetch origin', '$b = 2')
            Save-Commit -Repo $repo

            $out = & $script:ScriptUnderTest -RepoRoot $repo *>&1 | Out-String

            $LASTEXITCODE | Should -Be 1 -Because $out
            $out | Should -Match 'tools/Own\.ps1:1'
        }
        It 'names a path outside the repository as not checked, also in a folder whose name starts with the repository name' -Tag '#71' {
            $name = 'plain-' + [guid]::NewGuid().ToString('n')
            $repo = Join-Path $TestDrive $name
            New-Item -ItemType Directory -Path $repo, (Join-Path $TestDrive "$name-other") -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $TestDrive 'Outside.ps1') -Value @('git fetch origin', '$a = 1')
            Set-Content -LiteralPath (Join-Path $TestDrive "$name-other" 'Next.ps1') -Value @('git fetch origin', '$a = 1')

            $out = & $script:ScriptUnderTest -RepoRoot $repo -ChangedFiles '../Outside.ps1', "../$name-other/Next.ps1" *>&1 | Out-String

            $LASTEXITCODE | Should -Be 2 -Because $out
            $out | Should -Match 'Outside\.ps1 : the path is outside the repository'
            $out | Should -Match 'Next\.ps1 : the path is outside the repository'
        }

        It 'names a path in a folder that differs from the repository only in case as outside, where paths are case-sensitive' -Tag '#71' -Skip:$IsWindows {
            $name = 'Case-' + [guid]::NewGuid().ToString('n')
            $repo = Join-Path $TestDrive $name
            $other = Join-Path $TestDrive $name.ToLowerInvariant()
            New-Item -ItemType Directory -Path $repo, $other -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $other 'Next.ps1') -Value @('git fetch origin', '$a = 1')

            $out = & $script:ScriptUnderTest -RepoRoot $repo -ChangedFiles "../$($name.ToLowerInvariant())/Next.ps1" *>&1 | Out-String

            $LASTEXITCODE | Should -Be 2 -Because $out
            $out | Should -Match 'Next\.ps1 : the path is outside the repository'
        }

        It 'names a script reached through a link to a folder outside the repository as not checked' -Tag '#71' {
            $repo = Join-Path $TestDrive ('plain-' + [guid]::NewGuid().ToString('n'))
            $outside = Join-Path $TestDrive ('outside-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $repo, $outside -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $outside 'Far.ps1') -Value @('git fetch origin', '$a = 1')
            $kind = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
            try { New-Item -ItemType $kind -Path (Join-Path $repo 'linked') -Target $outside -ErrorAction Stop | Out-Null }
            catch { Set-ItResult -Skipped -Because "this machine cannot create a $kind"; return }

            $out = & $script:ScriptUnderTest -RepoRoot $repo -ChangedFiles 'linked/Far.ps1' *>&1 | Out-String

            $LASTEXITCODE | Should -Be 2 -Because $out
            $out | Should -Match 'linked/Far\.ps1 : the path goes through a symbolic link or junction'
        }
        It 'names a listed script that is not on disk as not checked' -Tag '#71' {
            $repo = Join-Path $TestDrive ('plain-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $repo -Force | Out-Null

            $out = & $script:ScriptUnderTest -RepoRoot $repo -ChangedFiles 'tools/Gone.ps1' *>&1 | Out-String

            $LASTEXITCODE | Should -Be 2 -Because $out
            $out | Should -Match 'tools/Gone\.ps1 : the file is not on disk'
        }
    }
}
