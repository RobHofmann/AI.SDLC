#requires -Version 7.4
Describe 'AiSdlcSetup' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'AiSdlcSetup.ps1')
        function gh { }
    }

    Context 'Test-GitHubLogin' {
        It 'returns nothing when gh auth status passes' {
            Mock Get-Command { [pscustomobject]@{ Name = 'gh' } } -ParameterFilter { $Name -eq 'gh' }
            Mock gh { $global:LASTEXITCODE = 0 }

            Test-GitHubLogin | Should -BeNullOrEmpty

            Should -Invoke gh -Times 1 -Exactly -ParameterFilter { ($args -join ' ') -eq 'auth status' }
        }

        It 'returns the login fix when gh has no valid login' {
            Mock Get-Command { [pscustomobject]@{ Name = 'gh' } } -ParameterFilter { $Name -eq 'gh' }
            Mock gh { $global:LASTEXITCODE = 1 }

            Test-GitHubLogin | Should -Match 'gh auth login'
        }

        It 'says gh is missing when the GitHub CLI is not installed' {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'gh' }

            Test-GitHubLogin | Should -Match 'is missing'
        }
    }

    Context 'Get-KnowledgeFolderHint' {
        BeforeEach {
            $script:Repo = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $script:Repo -Force | Out-Null
        }

        It 'returns nothing when the knowledge folder exists' {
            Set-Content -LiteralPath (Join-Path $script:Repo 'aisdlc.json') -Value '{ "paths": { "knowledgeRoot": "Knowledge" } }'
            New-Item -ItemType Directory -Path (Join-Path $script:Repo 'Knowledge') | Out-Null

            Get-KnowledgeFolderHint -RepoRoot $script:Repo | Should -BeNullOrEmpty
        }

        It 'names the clone command when the folder is missing and knowledge.repository is set' {
            Set-Content -LiteralPath (Join-Path $script:Repo 'aisdlc.json') -Value '{ "paths": { "knowledgeRoot": "../Knowledge" }, "knowledge": { "repository": "contoso/knowledge" } }'

            Get-KnowledgeFolderHint -RepoRoot $script:Repo | Should -Match 'gh repo clone contoso/knowledge \.\./Knowledge'
        }

        It 'says how to name the repository when knowledge.repository is empty' {
            Set-Content -LiteralPath (Join-Path $script:Repo 'aisdlc.json') -Value '{ "paths": { "knowledgeRoot": "missing-folder" } }'

            Get-KnowledgeFolderHint -RepoRoot $script:Repo | Should -Match 'knowledge\.repository'
        }
    }

    Context 'Get-ApmInstallFailureHint' {
        It 'names the exit code, the login and the long-path fix' {
            $hint = Get-ApmInstallFailureHint -ExitCode 5

            $hint | Should -Match 'exit code 5'
            $hint | Should -Match 'GITHUB_APM_PAT'
            $hint | Should -Match 'WinError 206'
            $hint | Should -Match 'LongPathsEnabled'
        }
    }

    Context 'Set-GitHookExecutable' {
        BeforeEach {
            $script:Repo = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
            $hooks = Join-Path $script:Repo '.claude' 'skills' 'ai-sdlc-hooks' 'githooks'
            New-Item -ItemType Directory -Path $hooks -Force | Out-Null
            git -C $script:Repo init --quiet
            Set-Content -LiteralPath (Join-Path $hooks 'pre-push') -Value '#!/bin/sh'
            Set-Content -LiteralPath (Join-Path $hooks 'post-merge') -Value '#!/bin/sh'
        }

        It 'marks every tracked hook executable in the git index' {
            git -C $script:Repo add -A

            $marked = @(Set-GitHookExecutable -RepoRoot $script:Repo)

            $marked | Should -HaveCount 2
            $modes = @(git -C $script:Repo ls-files --stage -- '.claude/skills/ai-sdlc-hooks/githooks' | ForEach-Object { ($_ -split '\s+')[0] })
            $modes | Should -Be @('100755', '100755')
        }

        It 'leaves out a hook that git does not track yet' {
            git -C $script:Repo add -- '.claude/skills/ai-sdlc-hooks/githooks/pre-push'

            $marked = @(Set-GitHookExecutable -RepoRoot $script:Repo)

            $marked | Should -Be @('.claude/skills/ai-sdlc-hooks/githooks/pre-push')
        }

        It 'does nothing when the repository has no hook folder' {
            $empty = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $empty | Out-Null
            git -C $empty init --quiet

            @(Set-GitHookExecutable -RepoRoot $empty) | Should -HaveCount 0
        }

        It 'changes nothing with -WhatIf' {
            git -C $script:Repo add -A

            Set-GitHookExecutable -RepoRoot $script:Repo -WhatIf | Out-Null

            $modes = @(git -C $script:Repo ls-files --stage -- '.claude/skills/ai-sdlc-hooks/githooks' | ForEach-Object { ($_ -split '\s+')[0] })
            $modes | Should -Be @('100644', '100644')
        }
    }

    Context 'Get-AiSdlcPin' {
        BeforeAll {
            function New-ApmRepo([string]$Apm) {
                $root = Join-Path ([IO.Path]::GetTempPath()) ('aisdlc-pin-' + [guid]::NewGuid().ToString('n'))
                New-Item -ItemType Directory -Path $root -Force | Out-Null
                [IO.File]::WriteAllText((Join-Path $root 'apm.yml'), $Apm)
                return $root
            }
        }

        It 'reads the source from the core dependency and the refs of every dependency on that source' {
            $root = New-ApmRepo "dependencies:`n  apm:`n    - git: https://github.com/contoso/AI.SDLC`n      path: core`n      ref: v1.0.0`n    - git: https://github.com/contoso/other`n      path: skills/x`n      ref: v9.9.9`n    - git: https://github.com/contoso/AI.SDLC`n      path: packs/bicep`n      ref: v1.0.0   # note`n"
            $pin = Get-AiSdlcPin -RepoRoot $root

            $pin.Url | Should -Be 'https://github.com/contoso/AI.SDLC'
            $pin.Current | Should -Be @('v1.0.0')
            $pin.AllPinned | Should -BeTrue
            $pin.Newline | Should -Be "`n"
        }

        It 'says a dependency of the source without a ref is not pinned' {
            $root = New-ApmRepo "dependencies:`n  apm:`n    - git: https://github.com/contoso/AI.SDLC`n      path: core`n      ref: v1.0.0`n    - git: https://github.com/contoso/AI.SDLC`n      path: packs/bicep`n"
            (Get-AiSdlcPin -RepoRoot $root).AllPinned | Should -BeFalse
        }

        It 'throws when apm.yml has no core dependency, or no apm.yml at all' {
            { Get-AiSdlcPin -RepoRoot (New-ApmRepo "dependencies:`n  apm: []`n") } | Should -Throw '*path: core*'
            { Get-AiSdlcPin -RepoRoot (Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))) } | Should -Throw '*No apm.yml*'
        }
    }

    Context 'Get-AiSdlcReleaseTag' {
        BeforeAll {
            $script:Source = Join-Path ([IO.Path]::GetTempPath()) ('aisdlc-tags-' + [guid]::NewGuid().ToString('n'))
            git init --quiet -b main $script:Source
            git -C $script:Source -c user.email=probe@example.invalid -c user.name=probe commit --quiet --allow-empty -m init
            foreach ($tag in 'v1.2.0', 'v1.10.0', 'v1.11.0-rc.1', 'not-a-release') { git -C $script:Source tag $tag }
        }

        It 'returns the newest release by version, not by text, and skips a pre-release' {
            Get-AiSdlcReleaseTag -Url $script:Source | Should -Be 'v1.10.0'
        }

        It 'takes a pre-release with -IncludePreRelease' {
            Get-AiSdlcReleaseTag -Url $script:Source -IncludePreRelease | Should -Be 'v1.11.0-rc.1'
        }

        It 'throws when the source has no release tag' {
            $empty = Join-Path ([IO.Path]::GetTempPath()) ('aisdlc-tags-' + [guid]::NewGuid().ToString('n'))
            git init --quiet $empty
            { Get-AiSdlcReleaseTag -Url $empty } | Should -Throw '*No release tag*'
        }
    }
}
