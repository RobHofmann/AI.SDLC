#requires -Version 7.4

Describe 'Update-SkillCatalog' {
    BeforeAll {
        $script:Tool = Join-Path $PSScriptRoot 'Update-SkillCatalog.ps1'
        Import-Module (Join-Path $PSScriptRoot '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' 'DocToolTestHarness.psm1') -Force

        function New-PackageRepo {
            param([string[]]$Skills, [string[]]$Agents = @())
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('usc-' + [guid]::NewGuid().ToString('n'))
            foreach ($entry in $Skills) {
                $package, $skill = $entry -split ':'
                $base = if ($package -eq 'core') { Join-Path $root 'core' } else { Join-Path $root 'packs' $package }
                New-Item -ItemType Directory -Path (Join-Path $base '.apm' 'skills' $skill) -Force | Out-Null
            }
            foreach ($entry in $Agents) {
                $package, $agent = $entry -split ':'
                $base = if ($package -eq 'core') { Join-Path $root 'core' } else { Join-Path $root 'packs' $package }
                New-Item -ItemType Directory -Path (Join-Path $base '.apm' 'agents') -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $base '.apm' 'agents' "$agent.agent.md") -Value 'x'
            }
            New-Item -ItemType Directory -Path (Join-Path $root 'packs') -Force | Out-Null
            return $root
        }

        function Invoke-Tool {
            param([string]$Root, [switch]$Check)
            $extra = @()
            if ($Check) { $extra += '-Check' }
            $run = Invoke-ScriptInProcess -Path $script:Tool -Arguments (@('-RepoRoot', $Root) + $extra)
            return [pscustomobject]@{ Code = $run.ExitCode; Output = $run.Output }
        }
    }

    It 'lists each skill and agent under the package that ships it' {
        $root = New-PackageRepo -Skills @('core:guide-me', 'core:ai-sdlc-gates', 'dotnet:test-first-dotnet') -Agents @('core:architect', 'dotnet:code-reviewer')

        Invoke-Tool -Root $root | Out-Null
        $catalog = Get-Content (Join-Path $root 'core/.apm/skills/ai-sdlc-gates/skill-catalog.json') -Raw | ConvertFrom-Json

        $catalog.skills.core | Should -Be @('ai-sdlc-gates', 'guide-me')
        $catalog.skills.dotnet | Should -Be @('test-first-dotnet')
        $catalog.agents.dotnet | Should -Be @('code-reviewer')
    }

    It 'passes the check right after a write' {
        $root = New-PackageRepo -Skills @('core:ai-sdlc-gates', 'bicep:bicep-conventions')
        Invoke-Tool -Root $root | Out-Null

        (Invoke-Tool -Root $root -Check).Code | Should -Be 0
    }

    It 'fails the check when a skill was added after the write, and names the fix' {
        $root = New-PackageRepo -Skills @('core:ai-sdlc-gates')
        Invoke-Tool -Root $root | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'packs/github-issues/.apm/skills/write-story') -Force | Out-Null

        $result = Invoke-Tool -Root $root -Check

        $result.Code | Should -Be 1
        $result.Output | Should -Match 'FIX: Run pwsh tools/Update-SkillCatalog\.ps1'
    }

    It 'fails when two packages ship a skill with the same name' {
        $root = New-PackageRepo -Skills @('core:ai-sdlc-gates', 'core:same', 'github-issues:same')

        $result = Invoke-Tool -Root $root

        $result.Code | Should -Be 1
        $result.Output | Should -Match 'more than one package: same'
    }
}
