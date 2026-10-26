#requires -Version 7.4
Describe 'Install-AiSdlc' {
    BeforeAll {
        $script:Source = Join-Path -Path $PSScriptRoot -ChildPath 'Install-AiSdlc.ps1'

        function apm { }
        function gh { }
        function winget { }
        function sh { }

        function New-TempRepo {
            param([int]$CoreExitCode = 0, [switch]$NoCore, [switch]$WithLock, [string]$PinnedVersion)
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ("install-aisdlc-" + [guid]::NewGuid().ToString('n'))
            $coreDir = Join-Path $root '.claude' 'skills' 'ai-sdlc-hooks' 'scripts'
            $gatesDir = Join-Path $root '.claude' 'skills' 'ai-sdlc-gates' 'scripts'
            New-Item -ItemType Directory -Path $coreDir, $gatesDir -Force | Out-Null
            git -C $root init --quiet
            Copy-Item -LiteralPath $script:Source, (Join-Path $PSScriptRoot 'WindowsLongPaths.ps1'), (Join-Path $PSScriptRoot 'AiSdlcSetup.ps1') -Destination $coreDir
            Set-Content -LiteralPath (Join-Path $gatesDir 'Install-Apm.ps1') -Value @(
                'param([switch]$AddToPath)'
                '$global:InstallAiSdlcTest.InstallerCalls++'
                'if ($global:InstallAiSdlcTest.InstallerThrows) { throw "the SHA-256 did not match" }'
                'Write-Output "fake installer ran"'
            )
            if ($WithLock) { Set-Content -LiteralPath (Join-Path $root 'apm.lock.yaml') -Value 'lockfile_version: "1"' }
            if ($PinnedVersion) { Set-Content -LiteralPath (Join-Path $gatesDir 'apm-version.json') -Value (@{ version = $PinnedVersion } | ConvertTo-Json) }
            if (-not $NoCore) {
                $record = Join-Path $root 'core-args.json'
                $body = @(
                    '[CmdletBinding(SupportsShouldProcess)]'
                    'param([switch]$Minimal, [switch]$SkipRestore, [switch]$SkipGraphify, [switch]$SkipGlobalGitConfig)'
                    '$bound = @($PSBoundParameters.Keys)'
                    'if ($WhatIfPreference) { $bound += ''WhatIf'' }'
                    "ConvertTo-Json -InputObject @(`$bound) | Set-Content -LiteralPath '$record' -WhatIf:`$false"
                    "exit $CoreExitCode"
                )
                Set-Content -LiteralPath (Join-Path $coreDir 'Initialize-AiSdlc.ps1') -Value $body
            }
            return $root
        }

        function Get-CoreArgs {
            param([string]$Root)
            $path = Join-Path $Root 'core-args.json'
            if (-not (Test-Path -LiteralPath $path)) { return $null }
            return @(Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
        }
    }

    BeforeEach {
        $global:InstallAiSdlcTest = @{ ApmCalls = [System.Collections.Generic.List[string]]::new(); ApmExit = 0; GhExit = 0; InstallerCalls = 0; InstallerThrows = $false; ApmVersion = 'apm, version 0.31.0' }
        Mock Get-ItemProperty { [pscustomobject]@{ LongPathsEnabled = 1 } }
        Mock gh { $global:LASTEXITCODE = $global:InstallAiSdlcTest.GhExit }
        Mock apm {
            if ($args[0] -eq '--version') { $global:LASTEXITCODE = 0; return $global:InstallAiSdlcTest.ApmVersion }
            $global:InstallAiSdlcTest.ApmCalls.Add(($args -join ' ')); $global:LASTEXITCODE = $global:InstallAiSdlcTest.ApmExit
        }
        Mock winget { $global:LASTEXITCODE = 0 }
        Mock sh { $global:LASTEXITCODE = 0 }
        Mock Start-Process { }
        Mock Set-ItemProperty { }
        $script:SavedCi = @{ GITHUB_ACTIONS = $env:GITHUB_ACTIONS; CI = $env:CI }
        $env:GITHUB_ACTIONS = $null
        $env:CI = $null
    }

    AfterEach {
        $env:GITHUB_ACTIONS = $script:SavedCi.GITHUB_ACTIONS
        $env:CI = $script:SavedCi.CI
    }

    AfterAll {
        Remove-Variable -Name InstallAiSdlcTest -Scope Global -ErrorAction SilentlyContinue
        Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'install-aisdlc-*' -Directory -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'sits next to Initialize-AiSdlc.ps1, the core setup it hands over to' {
        Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Initialize-AiSdlc.ps1') | Should -BeTrue
    }

    It 'installs from the committed lock with apm install --frozen, then runs the installed core' {
        $root = New-TempRepo -WithLock
        & (Join-Path $root '.claude' 'skills' 'ai-sdlc-hooks' 'scripts' 'Install-AiSdlc.ps1') *> $null
        $LASTEXITCODE | Should -Be 0
        $global:InstallAiSdlcTest.ApmCalls | Should -Be @('install --frozen')
        Get-CoreArgs -Root $root | Should -HaveCount 0
        Test-Path -LiteralPath (Join-Path $root 'core-args.json') | Should -BeTrue
    }

    It 'runs a plain apm install, which writes the lock, when the repository has no apm.lock.yaml yet' {
        $root = New-TempRepo
        $out = & (Join-Path $root '.claude' 'skills' 'ai-sdlc-hooks' 'scripts' 'Install-AiSdlc.ps1') *>&1 | Out-String
        $global:InstallAiSdlcTest.ApmCalls | Should -Be @('install')
        $out | Should -Match 'No apm\.lock\.yaml yet'
    }

    It 'names the lock mismatch when apm install --frozen fails' {
        $global:InstallAiSdlcTest.ApmExit = 1
        $root = New-TempRepo -WithLock
        { & (Join-Path $root '.claude' 'skills' 'ai-sdlc-hooks' 'scripts' 'Install-AiSdlc.ps1') *> $null } | Should -Throw '*exit code 1*does not match apm.yml*'
    }

    It 'passes -Minimal, -SkipRestore, -SkipGraphify and -SkipGlobalGitConfig through to the core' {
        $root = New-TempRepo
        & (Join-Path $root '.claude' 'skills' 'ai-sdlc-hooks' 'scripts' 'Install-AiSdlc.ps1') -Minimal -SkipRestore -SkipGraphify -SkipGlobalGitConfig *> $null
        $passed = Get-CoreArgs -Root $root
        $passed | Should -Contain 'Minimal'
        $passed | Should -Contain 'SkipRestore'
        $passed | Should -Contain 'SkipGraphify'
        $passed | Should -Contain 'SkipGlobalGitConfig'
    }

    It 'warns with both versions and the Install-Apm.ps1 fix when the installed APM is not the pinned one, and still installs' {
        $global:InstallAiSdlcTest.ApmVersion = 'apm, version 0.29.2'
        $root = New-TempRepo -WithLock -PinnedVersion 'v0.31.0'
        $out = & (Join-Path $root '.claude' 'skills' 'ai-sdlc-hooks' 'scripts' 'Install-AiSdlc.ps1') *>&1 | Out-String
        $out | Should -Match 'APM 0\.29\.2 is on the PATH, but apm-version\.json pins APM 0\.31\.0'
        $out | Should -Match 'Install-Apm\.ps1 -AddToPath'
        $global:InstallAiSdlcTest.ApmCalls | Should -Be @('install --frozen')
    }

    It 'gives no version warning when the installed APM is the pinned one' {
        $root = New-TempRepo -WithLock -PinnedVersion 'v0.31.0'
        $out = & (Join-Path $root '.claude' 'skills' 'ai-sdlc-hooks' 'scripts' 'Install-AiSdlc.ps1') *>&1 | Out-String
        $out | Should -Not -Match 'pins APM'
        $out | Should -Not -Match 'gave no version'
    }

    It 'warns when apm --version names no version it can compare with the pin' {
        $global:InstallAiSdlcTest.ApmVersion = 'unknown'
        $root = New-TempRepo -WithLock -PinnedVersion 'v0.31.0'
        $out = & (Join-Path $root '.claude' 'skills' 'ai-sdlc-hooks' 'scripts' 'Install-AiSdlc.ps1') *>&1 | Out-String
        $out | Should -Match 'apm --version gave no version.*0\.31\.0'
    }

    It 'leaves APM alone with -SkipApm' {
        $root = New-TempRepo
        & (Join-Path $root '.claude' 'skills' 'ai-sdlc-hooks' 'scripts' 'Install-AiSdlc.ps1') -SkipApm *> $null
        $global:InstallAiSdlcTest.ApmCalls | Should -HaveCount 0
        $global:InstallAiSdlcTest.InstallerCalls | Should -Be 0
        Test-Path -LiteralPath (Join-Path $root 'core-args.json') | Should -BeTrue
    }

    It 'advises the GitHub CLI login when it is missing, and still runs apm install and the core' {
        Mock Get-Command { [pscustomobject]@{ Name = 'gh' } } -ParameterFilter { $Name -eq 'gh' }
        $global:InstallAiSdlcTest.GhExit = 1
        $root = New-TempRepo -WithLock
        $out = & (Join-Path $root '.claude' 'skills' 'ai-sdlc-hooks' 'scripts' 'Install-AiSdlc.ps1') *>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'Setup advice: .*gh auth login'
        $global:InstallAiSdlcTest.ApmCalls | Should -Be @('install --frozen')
        Test-Path -LiteralPath (Join-Path $root 'core-args.json') | Should -BeTrue
    }

    It 'advises the clone command when the knowledge folder is missing, and still installs' {
        $root = New-TempRepo -WithLock
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts' 'AiSdlcConfig.psm1') -Destination (Join-Path $root '.claude' 'skills' 'ai-sdlc-gates' 'scripts')
        Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value '{ "paths": { "knowledgeRoot": "Knowledge" }, "knowledge": { "repository": "contoso/knowledge" } }'
        $out = & (Join-Path $root '.claude' 'skills' 'ai-sdlc-hooks' 'scripts' 'Install-AiSdlc.ps1') *>&1 | Out-String
        $out | Should -Match 'Setup advice: .*gh repo clone contoso/knowledge Knowledge'
        $global:InstallAiSdlcTest.ApmCalls | Should -Be @('install --frozen')
    }

    It 'says apm install did not run and exits 1 when a setup check failed, though the core passed' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'apm' }
        $global:InstallAiSdlcTest.InstallerThrows = $true
        $root = New-TempRepo
        $out = & (Join-Path $root '.claude' 'skills' 'ai-sdlc-hooks' 'scripts' 'Install-AiSdlc.ps1') *>&1 | Out-String
        $exit = $LASTEXITCODE
        $out | Should -Match 'apm install did not run'
        $exit | Should -Be 1
    }

    It 'switches long paths on by default, with one administrator prompt, and then installs' -Skip:(-not $IsWindows) {
        $global:InstallAiSdlcTest.LongPathReads = 0
        Mock Get-ItemProperty { $global:InstallAiSdlcTest.LongPathReads++; [pscustomobject]@{ LongPathsEnabled = [int]($global:InstallAiSdlcTest.LongPathReads -gt 1) } }
        $root = New-TempRepo

        $out = & (Join-Path $root '.claude' 'skills' 'ai-sdlc-hooks' 'scripts' 'Install-AiSdlc.ps1') *>&1 | Out-String

        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $Verb -eq 'RunAs' -and ($ArgumentList -join ' ') -match 'LongPathsEnabled -Value 1' }
        $out | Should -Match 'long paths are on now'
        $out | Should -Not -Match 'long paths are off'
        $global:InstallAiSdlcTest.ApmCalls | Should -HaveCount 1
    }

    It 'still accepts -EnableLongPaths from older instructions' -Skip:(-not $IsWindows) {
        $root = New-TempRepo
        & (Join-Path $root '.claude' 'skills' 'ai-sdlc-hooks' 'scripts' 'Install-AiSdlc.ps1') -EnableLongPaths *> $null
        $LASTEXITCODE | Should -Be 0
    }

    It 'warns, names the fix and skips apm install when the prompt was declined' -Skip:(-not $IsWindows) {
        Mock Get-ItemProperty { [pscustomobject]@{ LongPathsEnabled = 0 } }
        Mock Start-Process { throw 'The operation was canceled by the user.' }
        $root = New-TempRepo

        $out = & (Join-Path $root '.claude' 'skills' 'ai-sdlc-hooks' 'scripts' 'Install-AiSdlc.ps1') *>&1 | Out-String

        $out | Should -Match 'did not run: The operation was canceled'
        $out | Should -Match 'long paths are off'
        $out | Should -Match 'LongPathsEnabled to 1'
        $global:InstallAiSdlcTest.ApmCalls | Should -HaveCount 0
        Test-Path -LiteralPath (Join-Path $root 'core-args.json') | Should -BeTrue
    }

    It 'leaves long paths alone with -SkipLongPaths' -Skip:(-not $IsWindows) {
        Mock Get-ItemProperty { [pscustomobject]@{ LongPathsEnabled = 0 } }
        $root = New-TempRepo

        & (Join-Path $root '.claude' 'skills' 'ai-sdlc-hooks' 'scripts' 'Install-AiSdlc.ps1') -SkipLongPaths *>&1 | Out-Null

        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It 'never asks for administrator approval in CI' -Skip:(-not $IsWindows) {
        Mock Get-ItemProperty { [pscustomobject]@{ LongPathsEnabled = 0 } }
        $env:GITHUB_ACTIONS = 'true'
        $root = New-TempRepo

        & (Join-Path $root '.claude' 'skills' 'ai-sdlc-hooks' 'scripts' 'Install-AiSdlc.ps1') *>&1 | Out-Null

        Should -Invoke Start-Process -Times 0 -Exactly
        Should -Invoke Set-ItemProperty -Times 0 -Exactly
    }

    It 'installs the pinned APM through Install-Apm.ps1 when APM is missing, then runs apm install' {
        $global:InstallAiSdlcTest.ApmLookups = 0
        Mock Get-Command { $global:InstallAiSdlcTest.ApmLookups++; if ($global:InstallAiSdlcTest.ApmLookups -gt 1) { [pscustomobject]@{ Name = 'apm' } } } -ParameterFilter { $Name -eq 'apm' }
        $root = New-TempRepo -WithLock

        $out = & (Join-Path $root '.claude' 'skills' 'ai-sdlc-hooks' 'scripts' 'Install-AiSdlc.ps1') *>&1 | Out-String

        $global:InstallAiSdlcTest.InstallerCalls | Should -Be 1
        $out | Should -Match 'APM is installed\.'
        $global:InstallAiSdlcTest.ApmCalls | Should -Be @('install --frozen')
        Should -Invoke winget -Times 0 -Exactly
        Should -Invoke sh -Times 0 -Exactly
    }

    It 'never says APM is installed when the installer failed, and skips apm install' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'apm' }
        $global:InstallAiSdlcTest.InstallerThrows = $true
        $root = New-TempRepo -WithLock

        $out = & (Join-Path $root '.claude' 'skills' 'ai-sdlc-hooks' 'scripts' 'Install-AiSdlc.ps1') *>&1 | Out-String

        $out | Should -Match 'could not be installed: the SHA-256 did not match'
        $out | Should -Not -Match 'APM is installed\.'
        $global:InstallAiSdlcTest.ApmCalls | Should -HaveCount 0
        Test-Path -LiteralPath (Join-Path $root 'core-args.json') | Should -BeTrue
    }

    It 'reports APM still missing when the installer ran but apm is not on the PATH' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'apm' }
        $root = New-TempRepo

        $out = & (Join-Path $root '.claude' 'skills' 'ai-sdlc-hooks' 'scripts' 'Install-AiSdlc.ps1') *>&1 | Out-String

        $global:InstallAiSdlcTest.InstallerCalls | Should -Be 1
        $out | Should -Match 'still not found on the PATH'
        $out | Should -Not -Match 'APM is installed\.'
        $global:InstallAiSdlcTest.ApmCalls | Should -HaveCount 0
    }

    It 'fails when apm install fails' {
        $global:InstallAiSdlcTest.ApmExit = 3
        $root = New-TempRepo
        { & (Join-Path $root '.claude' 'skills' 'ai-sdlc-hooks' 'scripts' 'Install-AiSdlc.ps1') *> $null } | Should -Throw '*apm install failed with exit code 3*'
    }

    It 'fails with a clear message when the installed core is missing' {
        $root = New-TempRepo -NoCore
        { & (Join-Path $root '.claude' 'skills' 'ai-sdlc-hooks' 'scripts' 'Install-AiSdlc.ps1') -SkipApm *> $null } | Should -Throw '*installed core is missing*'
    }

    It 'returns the exit code of the core, so a failed step fails the command' {
        $root = New-TempRepo -CoreExitCode 1
        & (Join-Path $root '.claude' 'skills' 'ai-sdlc-hooks' 'scripts' 'Install-AiSdlc.ps1') -SkipApm *> $null
        $LASTEXITCODE | Should -Be 1
    }

    It 'runs nothing with -WhatIf and passes -WhatIf to the core' {
        $root = New-TempRepo
        & (Join-Path $root '.claude' 'skills' 'ai-sdlc-hooks' 'scripts' 'Install-AiSdlc.ps1') -WhatIf *> $null
        $global:InstallAiSdlcTest.ApmCalls | Should -HaveCount 0
        Get-CoreArgs -Root $root | Should -Contain 'WhatIf'
    }
}
