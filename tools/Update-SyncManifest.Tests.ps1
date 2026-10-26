#requires -Version 7.4

Describe 'Update-SyncManifest' {
    BeforeAll {
        $script:Source = Join-Path $PSScriptRoot 'Update-SyncManifest.ps1'
        Import-Module (Join-Path $PSScriptRoot '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' 'DocToolTestHarness.psm1') -Force

        function Write-LfFile {
            param([string]$Path, [string]$Content)
            New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
            [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
        }

        function Invoke-Tool {
            param([string]$Root, [switch]$Check)
            $extra = @(if ($Check) { '-Check' })
            $run = Invoke-ScriptInProcess -Path $script:Source -Arguments (@('-RepoRoot', $Root) + $extra)
            return [pscustomobject]@{ Code = $run.ExitCode; Output = $run.Output }
        }

        function Get-Manifest {
            param([string]$Root)
            Get-Content -LiteralPath (Join-Path $Root 'core/.apm/skills/ai-sdlc-gates/sync-manifest.json') -Raw | ConvertFrom-Json -AsHashtable
        }
    }

    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        git init --quiet $script:Root
        Write-LfFile -Path (Join-Path $script:Root 'core/.apm/skills/ai-sdlc-gates/SKILL.md') -Content "gates`n"
        Write-LfFile -Path (Join-Path $script:Root 'core/.apm/agents/reviewer.agent.md') -Content "agent`n"
        Write-LfFile -Path (Join-Path $script:Root 'core/.apm/hooks/core-hooks.json') -Content '{ "hooks": { "PreToolUse": [ { "matcher": "Edit|Write", "hooks": [ { "type": "command", "if": "Edit(*)", "command": "pwsh -File guard.ps1" } ] } ] } }'
        Write-LfFile -Path (Join-Path $script:Root 'core/apm.yml') -Content "name: core`n"
        Write-LfFile -Path (Join-Path $script:Root 'packs/github-issues/.apm/skills/issue-skill/SKILL.md') -Content "issue`n"
    }

    It 'maps each kind of file to where APM deploys it, with its git blob hash' {
        (Invoke-Tool -Root $script:Root).Code | Should -Be 0
        $m = Get-Manifest -Root $script:Root
        $m.packages.Keys | Should -Be @('core', 'github-issues')
        $expectedHash = (git -C $script:Root hash-object 'core/.apm/skills/ai-sdlc-gates/SKILL.md').Trim()
        $m.packages.core.files['.claude/skills/ai-sdlc-gates/SKILL.md'] | Should -Be $expectedHash
        $m.packages.core.files.Keys | Should -Contain '.claude/agents/reviewer.md'
        $m.packages.'github-issues'.files.Keys | Should -Contain '.claude/skills/issue-skill/SKILL.md'
        $m.packages.core.hooks[0].event | Should -Be 'PreToolUse'
        $m.packages.core.hooks[0].matcher | Should -Be 'Edit|Write'
        $m.packages.core.hooks[0].command | Should -Be 'pwsh -File guard.ps1'
    }

    It 'leaves out itself and the apm.yml of a package, which APM does not deploy' {
        Invoke-Tool -Root $script:Root | Out-Null
        (Invoke-Tool -Root $script:Root).Code | Should -Be 0
        $m = Get-Manifest -Root $script:Root
        $m.packages.core.files.Keys | Should -Not -Contain '.claude/skills/ai-sdlc-gates/sync-manifest.json'
        @($m.packages.core.files.Keys | Where-Object { $_ -match 'apm\.yml' }).Count | Should -Be 0
    }

    It 'writes the retired skill names from config/retired-skill-names.txt, each with its new name' {
        Write-LfFile -Path (Join-Path $script:Root 'config/retired-skill-names.txt') -Content "# v9.0.0`nold-skill new-skill`n`nother-old other-new`n"
        (Invoke-Tool -Root $script:Root).Code | Should -Be 0
        $m = Get-Manifest -Root $script:Root
        @($m.retired.Keys) | Should -Be @('old-skill', 'other-old')
        $m.retired['old-skill'] | Should -Be 'new-skill'
    }

    It 'writes an empty retired list when the repository has no retired names' {
        (Invoke-Tool -Root $script:Root).Code | Should -Be 0
        (Get-Manifest -Root $script:Root).retired.Count | Should -Be 0
    }

    It 'passes -Check when the manifest is current, and fails it after a file changes' {
        Invoke-Tool -Root $script:Root | Out-Null
        (Invoke-Tool -Root $script:Root -Check).Code | Should -Be 0
        Write-LfFile -Path (Join-Path $script:Root 'packs/github-issues/.apm/skills/issue-skill/SKILL.md') -Content "issue, changed`n"
        $r = Invoke-Tool -Root $script:Root -Check
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'Run pwsh tools/Update-SyncManifest\.ps1'
    }

    It 'stops on a kind of file it does not know how APM deploys' {
        Write-LfFile -Path (Join-Path $script:Root 'packs/github-issues/.apm/prompts/new.prompt.md') -Content "prompt`n"
        $r = Invoke-Tool -Root $script:Root
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'packs/github-issues/\.apm/prompts/new\.prompt\.md'
        Test-Path -LiteralPath (Join-Path $script:Root 'core/.apm/skills/ai-sdlc-gates/sync-manifest.json') | Should -BeFalse
    }
}
