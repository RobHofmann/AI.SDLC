#requires -Version 7.4
Describe 'Update-AiSdlc' {
    BeforeAll {
        $script:Source = Join-Path -Path $PSScriptRoot -ChildPath 'Update-AiSdlc.ps1'

        function apm { }

        function New-ConsumerRepo {
            param([int]$GatesExit = 0, [string]$Ref = 'v1.0.0')
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('update-aisdlc-' + [guid]::NewGuid().ToString('n'))
            $hooks = Join-Path $root '.claude' 'skills' 'ai-sdlc-hooks' 'scripts'
            $gates = Join-Path $root '.claude' 'skills' 'ai-sdlc-gates' 'scripts'
            New-Item -ItemType Directory -Path $hooks, $gates -Force | Out-Null
            git -C $root init --quiet
            git -C $root config user.email probe@example.invalid
            git -C $root config user.name probe
            Copy-Item -LiteralPath $script:Source, (Join-Path $PSScriptRoot 'WindowsLongPaths.ps1'), (Join-Path $PSScriptRoot 'AiSdlcSetup.ps1') -Destination $hooks
            Set-Content -LiteralPath (Join-Path $root 'apm.yml') -Value @"
name: consumer
dependencies:
  apm:
    - git: https://github.com/contoso/AI.SDLC
      path: core
      ref: $Ref
    - git: https://github.com/contoso/other-skills
      path: skills/review
      ref: v0.3.1
    - git: https://github.com/contoso/AI.SDLC
      path: packs/bicep
      ref: $Ref   # the templates
"@
            Set-Content -LiteralPath (Join-Path $root 'AGENTS.md') -Value '# AGENTS'
            Set-Content -LiteralPath (Join-Path $gates 'Sync-AgentsFile.ps1') -Value "Add-Content -LiteralPath '$root/AGENTS.md' -Value 'synced'; exit 0"
            Set-Content -LiteralPath (Join-Path $gates 'Invoke-LocalGates.ps1') -Value "exit $GatesExit"
            git -C $root add -A
            git -C $root commit --quiet -m init --no-verify
            return $root
        }

        function Invoke-Update {
            param([string]$Root, [hashtable]$Extra = @{})
            & (Join-Path $Root '.claude' 'skills' 'ai-sdlc-hooks' 'scripts' 'Update-AiSdlc.ps1') -RepoRoot $Root @Extra *>&1 | Out-String
        }
    }

    BeforeEach {
        $global:UpdateAiSdlcTest = @{ ApmCalls = [System.Collections.Generic.List[string]]::new(); ApmExit = 0; AuditExit = 0 }
        Mock apm {
            $global:UpdateAiSdlcTest.ApmCalls.Add(($args -join ' '))
            $global:LASTEXITCODE = if ($args[0] -eq 'audit') { $global:UpdateAiSdlcTest.AuditExit } else { $global:UpdateAiSdlcTest.ApmExit }
        }
        Mock Get-ItemProperty { [pscustomobject]@{ LongPathsEnabled = 1 } }
        Mock Start-Process { }
        Mock Set-ItemProperty { }
    }

    It 'switches long paths on before the install when they are off' -Skip:(-not $IsWindows) {
        $global:UpdateAiSdlcTest.LongPathReads = 0
        Mock Get-ItemProperty { $global:UpdateAiSdlcTest.LongPathReads++; [pscustomobject]@{ LongPathsEnabled = [int]($global:UpdateAiSdlcTest.LongPathReads -gt 1) } }
        $root = New-ConsumerRepo
        Invoke-Update -Root $root -Extra @{ Ref = 'v1.2.0'; NoGates = $true } | Out-Null

        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $Verb -eq 'RunAs' }
        $global:UpdateAiSdlcTest.ApmCalls | Should -Be @('install', 'audit --ci')
    }

    It 'stops before the install when long paths stay off' -Skip:(-not $IsWindows) {
        Mock Get-ItemProperty { [pscustomobject]@{ LongPathsEnabled = 0 } }
        Mock Start-Process { throw 'The operation was canceled by the user.' }
        $root = New-ConsumerRepo
        { & (Join-Path $root '.claude' 'skills' 'ai-sdlc-hooks' 'scripts' 'Update-AiSdlc.ps1') -RepoRoot $root -Ref v1.2.0 *> $null } | Should -Throw '*long paths are off*'
        $global:UpdateAiSdlcTest.ApmCalls | Should -HaveCount 0
    }

    AfterAll {
        Remove-Variable -Name UpdateAiSdlcTest -Scope Global -ErrorAction SilentlyContinue
        Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'update-aisdlc-*' -Directory -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'sets the AI.SDLC refs in apm.yml to the new tag, installs, syncs AGENTS.md and stages the result' {
        $root = New-ConsumerRepo
        $out = Invoke-Update -Root $root -Extra @{ Ref = 'v1.2.0' }

        $LASTEXITCODE | Should -Be 0 -Because $out
        $global:UpdateAiSdlcTest.ApmCalls | Should -Be @('install', 'audit --ci')
        $refs = @(Select-String -LiteralPath (Join-Path $root 'apm.yml') -Pattern '^\s+ref:\s*(\S+)' | ForEach-Object { $_.Matches[0].Groups[1].Value })
        $refs | Should -Be @('v1.2.0', 'v0.3.1', 'v1.2.0')
        Get-Content (Join-Path $root 'AGENTS.md') -Raw | Should -Match 'synced'
        $staged = @(git -C $root diff --cached --name-only)
        $staged | Should -Contain 'apm.yml'
        $staged | Should -Contain 'AGENTS.md'
    }

    It 'writes the allow rules of the installed packages and stages .claude/settings.json' {
        $root = New-ConsumerRepo
        $gates = Join-Path $root '.claude' 'skills' 'ai-sdlc-gates' 'scripts'
        Set-Content -LiteralPath (Join-Path $gates 'Sync-AllowRules.ps1') -Value "Set-Content -LiteralPath '$root/.claude/settings.json' -Value '{ ""permissions"": { ""allow"": [ ""Bash(git status *)"" ] } }'; exit 0"
        $out = Invoke-Update -Root $root -Extra @{ Ref = 'v1.2.0' }

        $LASTEXITCODE | Should -Be 0 -Because $out
        Get-Content (Join-Path $root '.claude' 'settings.json') -Raw | Should -Match 'git status'
        @(git -C $root diff --cached --name-only) | Should -Contain '.claude/settings.json'
    }

    It 'keeps the ref of a dependency from another source, and the comment after a moved ref' {
        $root = New-ConsumerRepo
        Invoke-Update -Root $root -Extra @{ Ref = 'v1.2.0'; NoGates = $true } | Out-Null

        $text = Get-Content (Join-Path $root 'apm.yml') -Raw
        $text | Should -Match '(?s)other-skills\s+path: skills/review\s+ref: v0\.3\.1'
        $text | Should -Match 'ref: v1\.2\.0   # the templates'
    }

    It 'takes the AI.SDLC source from the dependency with path: core, wherever it is in the list' {
        $root = New-ConsumerRepo
        Set-Content -LiteralPath (Join-Path $root 'apm.yml') -Value @"
name: consumer
dependencies:
  apm:
    - git: https://github.com/contoso/other-skills
      path: skills/review
      ref: v0.3.1
    - git: https://github.com/contoso/AI.SDLC
      path: core
      ref: v1.0.0
"@
        Invoke-Update -Root $root -Extra @{ Ref = 'v1.2.0'; NoGates = $true } | Out-Null

        $refs = @(Select-String -LiteralPath (Join-Path $root 'apm.yml') -Pattern '^\s+ref:\s*(\S+)' | ForEach-Object { $_.Matches[0].Groups[1].Value })
        $refs | Should -Be @('v0.3.1', 'v1.2.0')
    }

    It 'stops and changes nothing when no dependency has path: core' {
        $root = New-ConsumerRepo
        Set-Content -LiteralPath (Join-Path $root 'apm.yml') -Value "dependencies:`n  apm:`n    - git: https://github.com/contoso/other-skills`n      path: skills/review`n      ref: v0.3.1"

        { & (Join-Path $root '.claude' 'skills' 'ai-sdlc-hooks' 'scripts' 'Update-AiSdlc.ps1') -RepoRoot $root -Ref v1.2.0 *> $null } | Should -Throw '*path: core*'
        Get-Content (Join-Path $root 'apm.yml') -Raw | Should -Match 'ref: v0\.3\.1'
        $global:UpdateAiSdlcTest.ApmCalls | Should -HaveCount 0
    }

    It 'fails and stages nothing when apm audit --ci finds drift after the install' {
        $global:UpdateAiSdlcTest.AuditExit = 1
        $root = New-ConsumerRepo

        { & (Join-Path $root '.claude' 'skills' 'ai-sdlc-hooks' 'scripts' 'Update-AiSdlc.ps1') -RepoRoot $root -Ref v1.2.0 *> $null } | Should -Throw '*apm audit --ci failed*'
        $global:UpdateAiSdlcTest.ApmCalls | Should -Be @('install', 'audit --ci')
        @(git -C $root diff --cached --name-only) | Should -HaveCount 0
    }

    It 'does nothing when the repository is already on the tag' {
        $root = New-ConsumerRepo -Ref 'v1.2.0'
        $out = Invoke-Update -Root $root -Extra @{ Ref = 'v1.2.0' }

        $out | Should -Match 'Already on v1\.2\.0'
        $global:UpdateAiSdlcTest.ApmCalls | Should -HaveCount 0
    }

    It 'stops before it changes a file when apm is not on the PATH, and names the fix' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'apm' }
        $root = New-ConsumerRepo
        $before = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } |
            ForEach-Object { '{0} {1}' -f [IO.Path]::GetRelativePath($root, $_.FullName), (Get-FileHash -LiteralPath $_.FullName).Hash })

        { & (Join-Path $root '.claude' 'skills' 'ai-sdlc-hooks' 'scripts' 'Update-AiSdlc.ps1') -RepoRoot $root -Ref v1.2.0 *> $null } |
            Should -Throw '*pwsh .claude/skills/ai-sdlc-gates/scripts/Install-Apm.ps1 -AddToPath*'
        $after = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } |
            ForEach-Object { '{0} {1}' -f [IO.Path]::GetRelativePath($root, $_.FullName), (Get-FileHash -LiteralPath $_.FullName).Hash })
        $after | Should -Be $before
        @(git -C $root status --porcelain) | Should -HaveCount 0
        $global:UpdateAiSdlcTest.ApmCalls | Should -HaveCount 0
    }

    It 'fails with the likely causes when apm install fails' {
        $global:UpdateAiSdlcTest.ApmExit = 5
        $root = New-ConsumerRepo
        { & (Join-Path $root '.claude' 'skills' 'ai-sdlc-hooks' 'scripts' 'Update-AiSdlc.ps1') -RepoRoot $root -Ref v1.2.0 *> $null } | Should -Throw '*apm install failed with exit code 5*long paths*'
    }

    It 'exits 1 and says so when a blocking gate fails on the new version' {
        $root = New-ConsumerRepo -GatesExit 1
        $out = Invoke-Update -Root $root -Extra @{ Ref = 'v1.2.0' }

        $LASTEXITCODE | Should -Be 1
        $out | Should -Match 'blocking gate failed'
    }

    It 'skips the gates with -NoGates' {
        $root = New-ConsumerRepo -GatesExit 1
        Invoke-Update -Root $root -Extra @{ Ref = 'v1.2.0'; NoGates = $true } | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    It 'lists the lines of the repository that still use a retired skill name, and changes none of them' {
        $root = New-ConsumerRepo
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Find-RetiredSkillNames.ps1') -Destination (Join-Path $root '.claude' 'skills' 'ai-sdlc-hooks' 'scripts')
        Set-Content -LiteralPath (Join-Path $root '.claude' 'skills' 'ai-sdlc-gates' 'sync-manifest.json') -Value '{ "retired": { "old-skill": "new-skill" }, "packages": {} }'
        Set-Content -LiteralPath (Join-Path $root 'CLAUDE.md') -Value "Build every change with the ``old-skill`` skill."
        git -C $root add -A

        $out = Invoke-Update -Root $root -Extra @{ Ref = 'v1.2.0'; NoGates = $true }

        $LASTEXITCODE | Should -Be 0 -Because $out
        $out | Should -Match 'CLAUDE\.md:1  old-skill -> new-skill'
        Get-Content -LiteralPath (Join-Path $root 'CLAUDE.md') -Raw | Should -Match 'old-skill'
    }
}
