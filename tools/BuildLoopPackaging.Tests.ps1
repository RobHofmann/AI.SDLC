#requires -Version 7.4

Describe 'The skills-by-file-type table of code-conventions' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:TablePage = Join-Path $script:RepoRoot 'core/.apm/skills/code-conventions/references/skills-by-file-type.md'

        $script:PackageSkills = @(
            @(Join-Path $script:RepoRoot 'core') + @(Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'packs') -Directory | ForEach-Object FullName) |
                ForEach-Object { Join-Path $_ '.apm' 'skills' } |
                Where-Object { Test-Path -LiteralPath $_ } |
                ForEach-Object { Get-ChildItem -LiteralPath $_ -Directory -Force } |
                Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') } |
                ForEach-Object Name
        )

        $script:TableSkills = @(
            Get-Content -LiteralPath $script:TablePage |
                Where-Object { $_ -match '^\|\s*`' } |
                ForEach-Object { ($_ -split '\|')[2] } |
                ForEach-Object { [regex]::Matches($_, '`([a-z0-9-]+)`') } |
                ForEach-Object { $_.Groups[1].Value } |
                Sort-Object -Unique
        )
    }

    It 'has at least one row' {
        $script:TableSkills.Count | Should -BeGreaterThan 0
    }

    It 'names only skills that a package in core or packs holds' {
        $missing = @($script:TableSkills | Where-Object { $_ -notin $script:PackageSkills })
        $missing | Should -BeNullOrEmpty -Because 'every row must name a skill that exists in core/ or packs/'
    }

    It 'has a code-conventions skill in core' {
        Test-Path -LiteralPath (Join-Path $script:RepoRoot 'core/.apm/skills/code-conventions/SKILL.md') | Should -BeTrue
    }
}
