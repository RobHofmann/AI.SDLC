#requires -Version 7.4

BeforeDiscovery {
    $script:LanguageSkills = @(
        @{ Package = 'core'; Skill = 'powershell-conventions'; Pages = @('references/house-style.md', 'references/not-decided.md') }
        @{ Package = 'core'; Skill = 'yaml-conventions'; Pages = @('references/yaml.md') }
    )
}

Describe 'The language skill <Skill> of <Package>' -ForEach $script:LanguageSkills {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:PackageRoot = if ($Package -eq 'core') { Join-Path $script:RepoRoot 'core' } else { Join-Path $script:RepoRoot "packs/$Package" }
        $script:SkillRoot = Join-Path $script:PackageRoot ".apm/skills/$Skill"
        $script:SkillText = Get-Content -LiteralPath (Join-Path $script:SkillRoot 'SKILL.md') -Raw
        $script:AllText = (Get-ChildItem -LiteralPath $script:SkillRoot -Recurse -File -Filter '*.md' |
                ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
    }

    It 'ships SKILL.md with the name <Skill>' {
        $script:SkillText | Should -Match "(?m)^name: $([regex]::Escape($Skill))\s*$"
    }

    It 'ships each of its pages' {
        foreach ($page in $Pages) {
            Test-Path -LiteralPath (Join-Path $script:SkillRoot $page) | Should -BeTrue -Because "$Skill must ship $page"
        }
    }

    It 'states the comment rule of clause C10, not a ban on every comment' {
        $script:SkillText | Should -Match 'C10'
        $script:AllText | Should -Not -Match '(?i)adds no comment'
        $script:AllText | Should -Not -Match 'C15'
    }

    It 'names no pull request number and no research page' {
        $script:AllText | Should -Not -Match '(?i)\bPRs? \d{3,}'
        $script:AllText | Should -Not -Match '(?i)research:'
    }

    It 'is listed in the skill catalog and the sync manifest' {
        $catalog = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'core/.apm/skills/ai-sdlc-gates/skill-catalog.json') -Raw
        $manifest = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'core/.apm/skills/ai-sdlc-gates/sync-manifest.json') -Raw
        $catalog | Should -Match ('"' + [regex]::Escape($Skill) + '"')
        $manifest | Should -Match ([regex]::Escape(".claude/skills/$Skill/SKILL.md"))
    }

    It 'has a row in the skills-by-file-type table of code-conventions' {
        $table = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'core/.apm/skills/code-conventions/references/skills-by-file-type.md') -Raw
        $table | Should -Match ('`' + [regex]::Escape($Skill) + '`')
    }
}

Describe 'The YAML rules of github-actions-conventions' {
    It 'links yaml-conventions for the general YAML rules' {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $text = Get-Content -LiteralPath (Join-Path $repoRoot 'packs/github/.apm/skills/github-actions-conventions/SKILL.md') -Raw
        $text | Should -Match ([regex]::Escape('/.claude/skills/yaml-conventions/SKILL.md'))
    }
}
