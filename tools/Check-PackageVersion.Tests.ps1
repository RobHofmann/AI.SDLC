#requires -Version 7.4

Describe 'Check-PackageVersion' {
    BeforeAll {
        $script:Tool = Join-Path $PSScriptRoot 'Check-PackageVersion.ps1'
        Import-Module (Join-Path $PSScriptRoot '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' 'DocToolTestHarness.psm1') -Force

        function New-Repo {
            param([string]$Changelog = "# Changelog`n`n## v2.0.0 - 2026-10-20`n`nStory: #1.`n`n## v1.5.0 - 2026-10-19`n", [hashtable]$Versions = @{ core = '"2.0.0"'; 'packs/github-issues' = '"2.0.0"' })
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('package-version-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            if ($null -ne $Changelog) { Set-Content -LiteralPath (Join-Path $root 'CHANGELOG.md') -Value $Changelog }
            foreach ($package in $Versions.Keys) {
                $folder = Join-Path $root $package
                New-Item -ItemType Directory -Path $folder -Force | Out-Null
                $lines = @("name: ai-sdlc-$(Split-Path $package -Leaf)")
                if ($Versions[$package]) { $lines += "version: $($Versions[$package])" }
                $lines += 'description: A package.'
                Set-Content -LiteralPath (Join-Path $folder 'apm.yml') -Value $lines
            }
            return $root
        }

        function Set-Lock {
            param([string]$Root, [hashtable]$Locked)
            $lines = @("lockfile_version: '1'", 'apm_version: 0.31.0', 'dependencies:')
            foreach ($package in $Locked.Keys) {
                $lines += "- repo_url: _local/$(Split-Path $package -Leaf)"
                $lines += "  name: ai-sdlc-$(Split-Path $package -Leaf)"
                if ($Locked[$package]) { $lines += "  version: $($Locked[$package])" }
                $lines += '  deployed_file_hashes:'
                $lines += "    .claude/skills/$(Split-Path $package -Leaf)/SKILL.md: sha256:00"
                $lines += '  source: local'
                $lines += "  local_path: ./$package"
            }
            $lines += '- repo_url: example.org/other'
            $lines += '  version: 9.9.9'
            $lines += 'mcp_servers: []'
            Set-Content -LiteralPath (Join-Path $Root 'apm.lock.yaml') -Value $lines
            return $Root
        }

        function Invoke-Gate {
            param([string]$Root)
            $run = Invoke-ScriptInProcess -Path $script:Tool -Arguments @('-RepoRoot', $Root)
            [pscustomobject]@{ Code = $run.ExitCode; Output = $run.Output }
        }
    }

    AfterAll {
        Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'package-version-*' -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'passes when every apm.yml names the version of the newest CHANGELOG heading' {
        $r = Invoke-Gate (New-Repo)
        $r.Code | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match '2 package\(s\) at 2\.0\.0'
    }

    It 'reads a version without quotes too' {
        $r = Invoke-Gate (New-Repo -Versions @{ core = '2.0.0'; 'packs/github-issues' = "'2.0.0'" })
        $r.Code | Should -Be 0 -Because $r.Output
    }

    It 'fails on an apm.yml whose version differs, names it, and says how to fix it' {
        $r = Invoke-Gate (New-Repo -Versions @{ core = '"2.0.0"'; 'packs/github-issues' = '"1.5.0"' })
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'packs/github-issues/apm\.yml: version 1\.5\.0'
        $r.Output | Should -Match '(?m)^FIX: '
        $r.Output | Should -Not -Match '  core/apm\.yml'
    }

    It 'fails on an apm.yml with no version' {
        $r = Invoke-Gate (New-Repo -Versions @{ core = '"2.0.0"'; 'packs/github-issues' = '' })
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'packs/github-issues/apm\.yml: no version'
    }

    It 'takes the first heading as the newest, also for a release candidate' {
        $r = Invoke-Gate (New-Repo -Changelog "# Changelog`n`n## v3.0.0-rc.1 - 2026-11-01`n`n## v2.0.0 - 2026-10-20`n" -Versions @{ core = '"3.0.0-rc.1"' })
        $r.Code | Should -Be 0 -Because $r.Output
    }

    It 'passes when apm.lock.yaml records the version of each local apm.yml, and skips a remote package' {
        $r = Invoke-Gate (Set-Lock -Root (New-Repo) -Locked @{ core = '2.0.0'; 'packs/github-issues' = "'2.0.0'" })
        $r.Code | Should -Be 0 -Because $r.Output
    }

    It 'fails on a local package whose version in apm.lock.yaml is stale, and says to run apm install again' {
        $r = Invoke-Gate (Set-Lock -Root (New-Repo) -Locked @{ core = '2.0.0'; 'packs/github-issues' = '1.5.0' })
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'apm\.lock\.yaml: \./packs/github-issues has version 1\.5\.0, packs/github-issues/apm\.yml says 2\.0\.0'
        $r.Output | Should -Not -Match '\./core has'
        $r.Output | Should -Match '(?m)^FIX: Run apm install again'
    }

    It 'skips the lock check with a clear line when there is no apm.lock.yaml' {
        $r = Invoke-Gate (New-Repo)
        $r.Code | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'Lock check skipped: there is no apm\.lock\.yaml'
    }

    It 'says nothing about a skipped lock check when apm.lock.yaml is there' {
        $r = Invoke-Gate (Set-Lock -Root (New-Repo) -Locked @{ core = '2.0.0'; 'packs/github-issues' = '2.0.0' })
        $r.Output | Should -Not -Match 'Lock check skipped'
    }

    It 'fails on a local package with no version in apm.lock.yaml' {
        $r = Invoke-Gate (Set-Lock -Root (New-Repo) -Locked @{ core = ''; 'packs/github-issues' = '2.0.0' })
        $r.Code | Should -Be 1
        $r.Output | Should -Match '\./core has no version'
    }

    It 'cannot check without a version heading in CHANGELOG.md (exit 2)' {
        $r = Invoke-Gate (New-Repo -Changelog "# Changelog`n`nNothing yet.`n")
        $r.Code | Should -Be 2
    }

    It 'passes on this repository' {
        $r = Invoke-Gate (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $r.Code | Should -Be 0 -Because $r.Output
    }
}
