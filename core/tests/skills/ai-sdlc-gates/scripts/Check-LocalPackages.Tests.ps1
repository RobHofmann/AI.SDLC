#requires -Version 7.4

Describe 'Check-LocalPackages' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
        Import-Module (Join-Path $PSScriptRoot 'DocToolTestHarness.psm1') -Force
        $script:ScriptUnderTest = Join-Path $PSScriptRoot 'Check-LocalPackages.ps1'

        function Invoke-Gate {
            param([Parameter(Mandatory)][string]$RepoRoot)
            $out = & $script:ScriptUnderTest -RepoRoot $RepoRoot *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }

        function Write-LfFile {
            param([string]$Path, [string]$Content)
            New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
            [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
        }

        function Set-ApmFile {
            param([string[]]$Local = @())
            $lines = @('name: consumer', 'targets:', '  - claude', 'dependencies:', '  apm:',
                '    - git: https://example.invalid/_git/AI.SDLC', '      path: core', '      ref: v1.0.0')
            $lines += @($Local | ForEach-Object { "    - $_" })
            Write-LfFile -Path (Join-Path $script:Root 'apm.yml') -Content (($lines -join "`n") + "`n")
        }

        function Set-LockFile {
            param([string]$LocalPath, [string]$Name = 'video-course')
            Write-LfFile -Path (Join-Path $script:Root 'apm.lock.yaml') -Content @"
lockfile_version: '1'
apm_version: 0.31.0
dependencies:
- repo_url: _local/$Name
  name: $Name
  version: 1.0.0
  package_type: apm_package
  deployed_files:
  - .claude/skills/course-site
  source: local
  local_path: $LocalPath
- repo_url: org/project/AI.SDLC
  name: ai-sdlc-core
  virtual_path: core
  deployed_files:
  - .claude/skills/add-gate
"@
        }

        function Add-TrackedPackage {
            param([string]$Folder)
            Write-LfFile -Path (Join-Path $script:Root $Folder 'apm.yml') -Content "name: own`n"
            git -C $script:Root add -- $Folder
            git -C $script:Root commit --quiet -m 'add package' | Out-Null
        }
    }

    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        git -C $script:Root init --quiet
        git -C $script:Root config user.email test@example.invalid
        git -C $script:Root config user.name test
        Set-AiSdlcTestConfig -Root $script:Root
    }

    It 'passes a repository with no local package' {
        Set-ApmFile

        $r = Invoke-Gate -RepoRoot $script:Root

        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'Local packages OK: 0 local package path\(s\)'
    }

    It 'passes a local package whose folder git tracks, in apm.yml and in the lock' {
        Add-TrackedPackage -Folder 'packs/own'
        Set-ApmFile -Local './packs/own'
        Set-LockFile -LocalPath './packs/own' -Name 'own'

        $r = Invoke-Gate -RepoRoot $script:Root

        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'Local packages OK: 2 local package path\(s\) are in git'
    }

    It 'fails on a local package in apm.yml whose path does not exist, and names the package and the fix' {
        Set-ApmFile -Local './packs/gone'

        $r = Invoke-Gate -RepoRoot $script:Root

        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'apm\.yml names local package \./packs/gone at \./packs/gone, and that path does not exist'
        $r.Output | Should -Match 'FIX: Add the folder to git'
        $r.Output | Should -Match 'run apm install'
    }

    It 'fails on a local package whose folder exists but git does not track' {
        Write-LfFile -Path (Join-Path $script:Root 'packs' 'video-course' 'apm.yml') -Content "name: video-course`n"
        Set-ApmFile -Local './packs/video-course'

        $r = Invoke-Gate -RepoRoot $script:Root

        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'local package \./packs/video-course at \./packs/video-course, and git does not track that path'
    }

    It 'fails on a lock entry that apm.yml no longer names, as when the skills moved to the root .apm folder' {
        Set-ApmFile
        Set-LockFile -LocalPath './packs/video-course'

        $r = Invoke-Gate -RepoRoot $script:Root

        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'apm\.lock\.yaml names local package video-course at \./packs/video-course, and that path does not exist'
        $r.Output | Should -Match 'its dependency from apm\.lock\.yaml'
    }

    It 'does not check a local path outside the repository, the form of a local AI.SDLC clone' {
        Set-ApmFile -Local '../AI.SDLC/packs/github-issues'

        $r = Invoke-Gate -RepoRoot $script:Root

        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match '1 path\(s\) outside the repository are not checked'
    }

    It 'does not check a full path outside the repository, in apm.yml or in the lock' {
        $clone = (Join-Path $TestDrive 'clone' 'core').Replace('\', '/')
        New-Item -ItemType Directory -Path $clone -Force | Out-Null
        Set-ApmFile -Local $clone
        Set-LockFile -LocalPath $clone -Name 'ai-sdlc-core'

        $r = Invoke-Gate -RepoRoot $script:Root

        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match '2 path\(s\) outside the repository are not checked'
    }

    It 'says it could not check when apm.yml is missing' {
        Remove-Item -LiteralPath (Join-Path $script:Root 'apm.yml') -ErrorAction SilentlyContinue

        $r = Invoke-Gate -RepoRoot $script:Root

        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'could not be checked'
    }
}
