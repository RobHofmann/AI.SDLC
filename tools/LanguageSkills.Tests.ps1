#requires -Version 7.4

BeforeDiscovery {
    $script:LanguageSkills = @(
        @{ Package = 'core'; Skill = 'powershell-conventions'; Pages = @('references/house-style.md', 'references/not-decided.md') }
        @{ Package = 'core'; Skill = 'yaml-conventions'; Pages = @('references/yaml.md') }
        @{ Package = 'blazor'; Skill = 'razor-conventions'; Pages = @('references/razor.md') }
        @{ Package = 'css'; Skill = 'css-conventions'; Pages = @('references/css.md', 'references/not-decided.md') }
        @{ Package = 'javascript'; Skill = 'javascript-conventions'; Pages = @('references/javascript.md') }
        @{ Package = 'dotnet'; Skill = 'csharp-conventions'; Pages = @('references/house-style.md', 'references/not-decided.md', 'references/csharp.md') }
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

Describe 'The split of the Blazor rules' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    }

    It 'leaves no blazor-conventions skill in the blazor pack' {
        Test-Path -LiteralPath (Join-Path $script:RepoRoot 'packs/blazor/.apm/skills/blazor-conventions') | Should -BeFalse
    }

    It 'lists the css and javascript packs as APM dependencies of the blazor pack' {
        $apm = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'packs/blazor/apm.yml') -Raw
        $apm | Should -Match '(?m)^\s*-\s+\.\./css\s*$'
        $apm | Should -Match '(?m)^\s*-\s+\.\./javascript\s*$'
    }

    It 'gives the css and javascript packs one skill each' -ForEach @('css', 'javascript') {
        $skills = @(Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot "packs/$_/.apm/skills") -Directory)
        $skills.Count | Should -Be 1
        $skills[0].Name | Should -Be "$_-conventions"
    }

    It 'records the dependencies of the blazor pack in the sync manifest' {
        $manifest = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'core/.apm/skills/ai-sdlc-gates/sync-manifest.json') -Raw | ConvertFrom-Json -AsHashtable
        @($manifest.packages.blazor.dependencies) | Should -Be @('css', 'javascript')
    }

    It 'has a test consumer with only the <_> pack' -ForEach @('blazor', 'javascript') {
        $apm = Get-Content -LiteralPath (Join-Path $script:RepoRoot "test-consumers/$_-only/apm.yml") -Raw
        $packs = @([regex]::Matches($apm, 'packs/([a-z-]+)') | ForEach-Object { $_.Groups[1].Value })
        $packs | Should -Be @($_)
    }
}

Describe 'The house style of csharp-conventions' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:Skill = Join-Path $script:RepoRoot 'packs/dotnet/.apm/skills/csharp-conventions'
    }

    It 'gives each house rule a code example or an inline example, and at least two public links' {
        $text = Get-Content -LiteralPath (Join-Path $script:Skill 'references/house-style.md') -Raw
        $sections = @([regex]::Split($text, '(?m)^## ') | Select-Object -Skip 1 | Where-Object { $_ -notmatch '^(Related|The folder of a new type)' })
        $sections.Count | Should -BeGreaterThan 5
        foreach ($section in $sections) {
            $title = ($section -split "`n")[0]
            $section | Should -Match '`' -Because "$title needs an example"
            ([regex]::Matches($section, '\]\(https://')).Count | Should -BeGreaterOrEqual 2 -Because "$title needs two public sources"
        }
    }

    It 'says on not-decided.md that a change follows the file it edits' {
        $text = Get-Content -LiteralPath (Join-Path $script:Skill 'references/not-decided.md') -Raw
        $text | Should -Match 'A change follows the form of the file or class it edits'
    }

    It 'reads the folders of a new type from dotnet.folders' {
        $text = Get-Content -LiteralPath (Join-Path $script:Skill 'references/house-style.md') -Raw
        foreach ($key in 'contracts', 'exceptions', 'options') { $text | Should -Match "dotnet\.folders\.$key" }
    }

    It 'leaves out the app settings rule and a fixed default folder name' {
        $all = (Get-ChildItem -LiteralPath $script:Skill -Recurse -File -Filter '*.md' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
        $all | Should -Not -Match 'App Configuration'
        $all | Should -Not -Match 'Configs/Options'
    }
}
