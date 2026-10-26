#requires -Version 7.4

Describe 'Check-SyncManifest' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
        Import-Module (Join-Path $PSScriptRoot 'DocToolTestHarness.psm1') -Force
        $script:ScriptUnderTest = Join-Path $PSScriptRoot 'Check-SyncManifest.ps1'

        function Invoke-Gate {
            param([Parameter(Mandatory)][string]$RepoRoot)
            $out = & $script:ScriptUnderTest -RepoRoot $RepoRoot -ManifestPath (Join-Path $RepoRoot 'manifest.json') *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }

        function Write-LfFile {
            param([string]$Path, [string]$Content)
            New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
            [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
        }

        function Get-BlobHash {
            param([string]$Content)
            $path = Join-Path $TestDrive ('blob-' + [guid]::NewGuid().ToString('n'))
            Write-LfFile -Path $path -Content $Content
            return (git hash-object $path).Trim()
        }
    }

    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        git -C $script:Root init --quiet
        Set-AiSdlcTestConfig -Root $script:Root
        Write-LfFile -Path (Join-Path $script:Root 'apm.yml') -Content "dependencies:`n  apm:`n    - git: https://github.com/contoso/AI.SDLC`n      path: core`n      ref: v1.0.0`n    - ../../packs/github-issues`n"
        Write-LfFile -Path (Join-Path $script:Root '.claude/skills/core-skill/SKILL.md') -Content "core`n"
        Write-LfFile -Path (Join-Path $script:Root '.claude/agents/reviewer.md') -Content "agent`n"
        Write-LfFile -Path (Join-Path $script:Root '.claude/skills/issue-skill/SKILL.md') -Content "issues`n"
        Write-LfFile -Path (Join-Path $script:Root '.claude/settings.json') -Content '{ "hooks": { "Stop": [ { "matcher": "*", "hooks": [ { "type": "command", "command": "pwsh -File stop.ps1" } ] } ] } }'
        $script:Manifest = [ordered]@{
            retired  = [ordered]@{ 'old-skill' = 'core-skill'; 'old-agent' = 'reviewer' }
            packages = [ordered]@{
                core = [ordered]@{
                    files = [ordered]@{ '.claude/skills/core-skill/SKILL.md' = (Get-BlobHash "core`n"); '.claude/agents/reviewer.md' = (Get-BlobHash "agent`n") }
                    hooks = @([ordered]@{ event = 'Stop'; matcher = ''; if = ''; command = 'pwsh -File stop.ps1' })
                }
                'github-issues' = [ordered]@{ files = [ordered]@{ '.claude/skills/issue-skill/SKILL.md' = (Get-BlobHash "issues`n") }; hooks = @() }
                dotnet = [ordered]@{ files = [ordered]@{ '.claude/skills/dotnet-skill/SKILL.md' = (Get-BlobHash "dotnet`n") }; hooks = @() }
            }
        }
        function Save-Manifest { Write-LfFile -Path (Join-Path $script:Root 'manifest.json') -Content ($script:Manifest | ConvertTo-Json -Depth 6) }
        Save-Manifest
    }

    It 'passes when every file and hook of the installed packages is there, and ignores packages that are not installed' {
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'AI.SDLC sync OK: 3 file\(s\) and 1 hook\(s\) of 2 package\(s\)'
    }

    It 'treats a CRLF working copy as unchanged' {
        Write-LfFile -Path (Join-Path $script:Root '.claude/skills/core-skill/SKILL.md') -Content "core`r`n"
        git -C $script:Root config core.autocrlf true
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 0
    }

    It 'fails on a file that APM did not deliver' {
        Remove-Item -LiteralPath (Join-Path $script:Root '.claude/skills/issue-skill/SKILL.md')
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'missing: \.claude/skills/issue-skill/SKILL\.md'
    }

    It 'fails on a file whose content differs from the release' {
        Write-LfFile -Path (Join-Path $script:Root '.claude/agents/reviewer.md') -Content "edited by hand`n"
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'changed: \.claude/agents/reviewer\.md'
    }

    It 'fails on a stale file in the folder of an installed skill' {
        Write-LfFile -Path (Join-Path $script:Root '.claude/skills/core-skill/old.md') -Content "removed upstream`n"
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'not in this AI.SDLC version: \.claude/skills/core-skill/old\.md'
    }

    It 'fails on a skill folder whose name a release retired, and says how to fix it' {
        Write-LfFile -Path (Join-Path $script:Root '.claude/skills/old-skill/SKILL.md') -Content "renamed upstream`n"
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'retired, now core-skill: \.claude/skills/old-skill/'
        $r.Output | Should -Match 'FIX: Delete'
    }

    It 'fails on an agent file whose name a release retired' {
        Write-LfFile -Path (Join-Path $script:Root '.claude/agents/old-agent.md') -Content "renamed upstream`n"
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'retired, now reviewer: \.claude/agents/old-agent\.md'
    }

    It 'fails on the skill folder of a package that apm.yml no longer installs' {
        Write-LfFile -Path (Join-Path $script:Root '.claude/skills/dotnet-skill/SKILL.md') -Content "dotnet`n"
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'package dotnet, which apm\.yml does not install: \.claude/skills/dotnet-skill/'
    }

    It 'leaves a skill and an agent of the repository alone, with no list to keep' {
        Write-LfFile -Path (Join-Path $script:Root '.claude/skills/own-skill/SKILL.md') -Content "ours`n"
        Write-LfFile -Path (Join-Path $script:Root '.claude/agents/own-agent.md') -Content "ours`n"
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 0 -Because $r.Output
    }

    It 'passes with a manifest of an older version that has no retired list' {
        $script:Manifest.Remove('retired')
        Save-Manifest
        Write-LfFile -Path (Join-Path $script:Root '.claude/skills/old-skill/SKILL.md') -Content "renamed upstream`n"
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 0 -Because $r.Output
    }

    It 'fails on a hook that is missing from settings.json' {
        Write-LfFile -Path (Join-Path $script:Root '.claude/settings.json') -Content '{ "hooks": {} }'
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'missing hook in \.claude/settings\.json: Stop'
    }

    It 'fails on a package in apm.yml that the manifest does not know' {
        $script:Manifest.packages.Remove('github-issues')
        Save-Manifest
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'package github-issues is in apm\.yml but not in the manifest'
    }

    It 'says it could not check when the manifest is missing' {
        Remove-Item -LiteralPath (Join-Path $script:Root 'manifest.json')
        $r = Invoke-Gate -RepoRoot $script:Root
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'could not be checked'
    }

    Context 'a repository that installs the core from its own tree' {
        BeforeEach {
            Write-LfFile -Path (Join-Path $script:Root 'apm.yml') -Content "dependencies:`n  apm:`n    - ./core`n    - ./packs/github-issues`n"
            $script:SourceManifest = Join-Path $script:Root 'core/.apm/skills/ai-sdlc-gates/sync-manifest.json'
            Write-LfFile -Path $script:SourceManifest -Content ($script:Manifest | ConvertTo-Json -Depth 6)
        }

        It 'checks against the source manifest of that core, and says so' {
            $out = & $script:ScriptUnderTest -RepoRoot $script:Root *>&1 | Out-String
            $LASTEXITCODE | Should -Be 0
            $out | Should -Match 'match the source manifest core/\.apm/skills/ai-sdlc-gates/sync-manifest\.json'
        }

        It 'fails when the source changed and .claude/ was not installed again, and names the file' {
            $script:Manifest.packages['github-issues'].files['.claude/skills/issue-skill/SKILL.md'] = Get-BlobHash "issues, changed in the source`n"
            Write-LfFile -Path $script:SourceManifest -Content ($script:Manifest | ConvertTo-Json -Depth 6)
            $out = & $script:ScriptUnderTest -RepoRoot $script:Root *>&1 | Out-String
            $LASTEXITCODE | Should -Be 1
            $out | Should -Match 'changed: \.claude/skills/issue-skill/SKILL\.md'
            $out | Should -Match 'FIX: The packages are installed from this repository'
        }

        It 'still uses the manifest it is given' {
            Remove-Item -LiteralPath $script:SourceManifest
            $r = Invoke-Gate -RepoRoot $script:Root
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'match the manifest\.'
        }
    }
}
