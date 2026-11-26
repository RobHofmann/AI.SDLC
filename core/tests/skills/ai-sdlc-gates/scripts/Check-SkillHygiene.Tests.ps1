#requires -Version 7.4

Describe 'Check-SkillHygiene' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Check-SkillHygiene.ps1'

        function New-SkillFixture {
            param(
                [Parameter(Mandatory)][string]$Root,
                [Parameter(Mandatory)][string]$Folder,
                [string]$Name = $Folder,
                [string]$Description = 'Do a thing. Use when the user says "do the thing".',
                [string]$Body = "Invoked as ``/{0}``. Usable by any persona.`n`n## Next steps`n- none`n",
                [string]$Phase = 'cross-cutting',
                [string]$Persona = 'any',
                [string]$Kind = 'workflow',
                [switch]$NoKind,
                [switch]$NoPhase,
                [switch]$NoPersona,
                [switch]$NoSkillMd,
                [switch]$NoStandingRules,
                [switch]$NoAutolearnPointer
            )
            $dir = Join-Path $Root $Folder
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            if ($NoSkillMd) { return $dir }
            $resolvedBody = $Body -f $Folder
            if (-not $NoStandingRules -and $resolvedBody -notmatch '(?m)^##\s*Standing rules') {
                $standing = "## Standing rules`n`n- Language: [language conventions](../ai-sdlc-handbook/references/language.md).`n"
                if (-not $NoAutolearnPointer) { $standing += "- Autolearn: [autolearn](../ai-sdlc-handbook/references/autolearn.md).`n" }
                $resolvedBody = "$standing`n$resolvedBody"
            }
            $fm = "name: $Name"
            if (-not $NoKind) { $fm += "`nkind: $Kind" }
            if (-not $NoPhase) { $fm += "`nphase: $Phase" }
            if (-not $NoPersona) { $fm += "`npersona: $Persona" }
            $content = "---`n$fm`ndescription: >`n  $Description`n---`n`n# Title`n`n$resolvedBody"
            Set-Content -LiteralPath (Join-Path $dir 'SKILL.md') -Value $content -NoNewline
            return $dir
        }

        function New-KnowledgeFixture {
            param(
                [Parameter(Mandatory)][string]$Root,
                [string]$Folder = 'how-we-do-x',
                [string]$Frontmatter = "user-invocable: false",
                [string]$Sources = "## Sources`n`n- [the rule](../../rule.md)`n",
                [string]$Extra = '',
                [switch]$NoRulePage
            )
            $dir = Join-Path $Root $Folder
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            if (-not $NoRulePage) { Set-Content -LiteralPath (Join-Path (Split-Path $Root -Parent) 'rule.md') -Value '# Rule' }
            $standing = "## Standing rules`n`n- Language: [language conventions](../ai-sdlc-handbook/references/language.md).`n- Autolearn: [autolearn](../ai-sdlc-handbook/references/autolearn.md).`n"
            $content = "---`nname: $Folder`nkind: knowledge`n$Frontmatter`ndescription: >`n  How we do X here. Use when a change touches X.`n---`n`n# How we do X`n`n- check one`n$Extra`n$Sources`n$standing"
            Set-Content -LiteralPath (Join-Path $dir 'SKILL.md') -Value $content -NoNewline
            return $dir
        }

        function Invoke-Hygiene {
            param([Parameter(Mandatory)][string]$SkillsRoot, [switch]$Strict, [string]$CatalogPath = (Join-Path $TestDrive 'no-catalog.json'))
            $out = if ($Strict) { & $script:ScriptUnderTest -SkillsRoot $SkillsRoot -CatalogPath $CatalogPath -Strict *>&1 | Out-String }
            else { & $script:ScriptUnderTest -SkillsRoot $SkillsRoot -CatalogPath $CatalogPath *>&1 | Out-String }
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }
    }

    BeforeEach {
        $script:Skills = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Skills | Out-Null
    }

    It 'passes a well-formed skill (exit 0)' {
        New-SkillFixture -Root $script:Skills -Folder 'do-thing' | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Skill hygiene OK'
    }

    It 'fails when frontmatter name does not match the folder' {
        New-SkillFixture -Root $script:Skills -Folder 'do-thing' -Name 'other-thing' | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'name=folder'
    }

    It 'fails a phase-prefixed skill name (not a bare functional name)' {
        New-SkillFixture -Root $script:Skills -Folder 'governance-do-thing' | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'bare-name'
    }

    It 'fails a phase-token-prefixed skill name' {
        New-SkillFixture -Root $script:Skills -Folder 'discovery-do-thing' | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'bare-name'
    }

    It 'fails when the description lacks triggering language' {
        New-SkillFixture -Root $script:Skills -Folder 'do-thing' -Description 'Just does a thing with no trigger phrasing.' | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'trigger-rich-desc'
    }

    It 'fails a description over 1024 characters, which GitHub Copilot refuses to load' {
        $long = 'Use when the user says "do the thing". ' + ('word ' * 200)
        New-SkillFixture -Root $script:Skills -Folder 'do-thing' -Description $long.Trim() | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match '\[description-length\]'
        $r.Output | Should -Match 'has 1038 characters'
    }

    It 'counts every line of a plain description that goes on over several lines' {
        $dir = New-SkillFixture -Root $script:Skills -Folder 'do-thing'
        $path = Join-Path $dir 'SKILL.md'
        $more = (1..30 | ForEach-Object { '  Use when the user says "do the thing" in one more way.' }) -join "`n"
        $text = (Get-Content -LiteralPath $path -Raw) -replace '(?s)description: >\n  [^\n]*', "description: Do a thing.`n$more"
        Set-Content -LiteralPath $path -Value $text -NoNewline
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.Output | Should -Match '\[description-length\]'
    }

    It 'passes a description of exactly 1024 characters' {
        $start = 'Use when the user says "do the thing". '
        New-SkillFixture -Root $script:Skills -Folder 'do-thing' -Description ($start + ('x' * (1024 - $start.Length))) | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 0 -Because $r.Output
    }

    It 'counts a folded description the way YAML reads it, one space where a line breaks' {
        $line = 'x' * 99
        $folded = (@('Use when the user says it.') + @(1..10 | ForEach-Object { $line })) -join "`n  "
        New-SkillFixture -Root $script:Skills -Folder 'do-thing' -Description $folded | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'has 1026 characters' -Because '26 + 10 lines of 99 + 10 joining spaces'
    }

    It 'fails a name the Agent Skills specification refuses: <Folder>' -ForEach @(
        @{ Folder = 'Do-Thing' }
        @{ Folder = 'do--thing' }
        @{ Folder = 'do-thing-' }
    ) {
        New-SkillFixture -Root $script:Skills -Folder $Folder | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match '\[name-spec\]'
    }

    It 'fails when there is no persona line' {
        New-SkillFixture -Root $script:Skills -Folder 'do-thing' -Body "Plain body.`n`n## Next steps`n- none`n" | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'persona-line'
    }

    It 'fails when the Next steps section is missing' {
        New-SkillFixture -Root $script:Skills -Folder 'do-thing' -Body "Invoked as ``/do-thing``. Usable by any persona.`n" | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'next-steps'
    }

    It 'fails when the Standing rules section is missing' {
        New-SkillFixture -Root $script:Skills -Folder 'do-thing' -NoStandingRules | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'standing-rules'
    }

    It 'fails when Standing rules does not point at the autolearn loop' {
        New-SkillFixture -Root $script:Skills -Folder 'do-thing' -NoAutolearnPointer | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'does not link: autolearn\.md'
    }

    It 'fails when the links sit outside the Standing rules section' {
        $body = "Invoked as ``/do-thing``. Usable by any persona.`n`n## Standing rules`n`n- Follow the standing rules.`n`n## References`n`n- [language](../ai-sdlc-handbook/references/language.md)`n- [autolearn](../ai-sdlc-handbook/references/autolearn.md)`n`n## Next steps`n- none`n"
        New-SkillFixture -Root $script:Skills -Folder 'do-thing' -Body $body | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'standing-rules'
    }

    It 'fails on an em-dash' {
        $emDash = [char]0x2014
        New-SkillFixture -Root $script:Skills -Folder 'do-thing' -Description "Do a thing $emDash quickly. Use when asked." | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'em-dash'
    }

    It 'fails on a source line-number citation' {
        New-SkillFixture -Root $script:Skills -Folder 'do-thing' -Body "Invoked as ``/do-thing``. Usable by any persona. See Program.cs:42.`n`n## Next steps`n- none`n" | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'line-citation'
    }

    It 'fails on an unresolved cross-reference' {
        New-SkillFixture -Root $script:Skills -Folder 'do-thing' -Body "Invoked as ``/do-thing``. Usable by any persona. Then run /does-not-exist.`n`n## Next steps`n- none`n" | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'cross-ref'
    }

    It 'resolves a cross-reference to a sibling skill that exists' {
        New-SkillFixture -Root $script:Skills -Folder 'alpha-skill' | Out-Null
        New-SkillFixture -Root $script:Skills -Folder 'beta-skill' -Body "Invoked as ``/beta-skill``. Usable by any persona. Then run /alpha-skill.`n`n## Next steps`n- none`n" | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 0
    }

    It 'passes Standing rules links to language.md and autolearn.md at any relative path' {
        $body = "Invoked as ``/do-thing``. Usable by any persona.`n`n## Standing rules`n`n- [language](../../somewhere/else/language.md)`n- [autolearn](autolearn.md#why-it-exists)`n`n## Next steps`n- none`n"
        New-SkillFixture -Root $script:Skills -Folder 'do-thing' -Body $body | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 0 -Because $r.Output
    }

    It 'fails Standing rules that name a file which is not language.md, such as old-language.md' {
        $body = "Invoked as ``/do-thing``. Usable by any persona.`n`n## Standing rules`n`n- [language](../x/old-language.md)`n- [autolearn](../x/autolearn.md)`n`n## Next steps`n- none`n"
        New-SkillFixture -Root $script:Skills -Folder 'do-thing' -Body $body | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'does not link: language\.md'
    }

    It 'resolves a cross-reference to a skill that the catalog lists for a pack this repository did not install' {
        $catalog = Join-Path $TestDrive 'skill-catalog.json'
        Set-Content -LiteralPath $catalog -Value '{ "skills": { "core": [ "do-thing" ], "github-issues": [ "pack-only-skill" ] }, "agents": {} }'
        New-SkillFixture -Root $script:Skills -Folder 'do-thing' -Body "Invoked as ``/do-thing``. Usable by any persona. Then ``/pack-only-skill``.`n`n## Next steps`n- none`n" | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills -CatalogPath $catalog
        $r.ExitCode | Should -Be 0 -Because $r.Output
    }

    It 'still fails a cross-reference that neither the skills folder nor the catalog knows' {
        $catalog = Join-Path $TestDrive 'skill-catalog.json'
        Set-Content -LiteralPath $catalog -Value '{ "skills": { "core": [ "do-thing" ], "github-issues": [ "pack-only-skill" ] }, "agents": {} }'
        New-SkillFixture -Root $script:Skills -Folder 'do-thing' -Body "Invoked as ``/do-thing``. Usable by any persona. Then ``/no-such-skill``.`n`n## Next steps`n- none`n" | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills -CatalogPath $catalog
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'unresolved skill reference\(s\): no-such-skill'
    }

    It 'fails when a skill folder has no SKILL.md' {
        New-SkillFixture -Root $script:Skills -Folder 'empty-skill' -NoSkillMd | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'skill-md'
    }

    It 'fails when the skills directory does not exist' {
        $missing = Join-Path $script:Skills 'nope'
        $r = Invoke-Hygiene -SkillsRoot $missing
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'not found'
    }

    It 'reports an advisory (non-failing) when the recommended sections are missing' {
        New-SkillFixture -Root $script:Skills -Folder 'do-thing' | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'advisories'
        $r.Output | Should -Match 'failure-modes'
        $r.Output | Should -Match 'observable-signal'
        $r.Output | Should -Match 'Skill hygiene OK'
    }

    It 'fails under -Strict when a recommended section is missing (exit 1)' {
        New-SkillFixture -Root $script:Skills -Folder 'do-thing' | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills -Strict
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Strict mode'
        $r.Output | Should -Match 'failure-modes'
    }

    It 'passes under -Strict when the recommended sections are present (exit 0)' {
        $body = "Invoked as ``/do-thing``. Usable by any persona.`n`n## Failure modes`n- a`n`n## Observable signal`n- b`n`n## Next steps`n- none`n"
        New-SkillFixture -Root $script:Skills -Folder 'do-thing' -Body $body | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills -Strict
        $r.ExitCode | Should -Be 0
    }

    It 'does not advise when both recommended sections are present' {
        $body = "Invoked as ``/do-thing``. Usable by any persona.`n`n## Failure modes`n- a`n`n## Observable signal`n- b`n`n## Next steps`n- none`n"
        New-SkillFixture -Root $script:Skills -Folder 'do-thing' -Body $body | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Not -Match 'failure-modes'
        $r.Output | Should -Not -Match 'observable-signal'
    }

    It 'does not flag a relative markdown doc link as a missing skill cross-reference' {
        $body = "Invoked as ``/do-thing``. Usable by any persona. See [the workaround](./azure-devops-cli-conditional-access.md) and [pattern](../ai-sdlc/pattern.md).`n`n## Next steps`n- none`n"
        New-SkillFixture -Root $script:Skills -Folder 'do-thing' -Body $body | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 0
    }

    It 'resolves a multi-segment bare cross-reference to a sibling skill that exists' {
        New-SkillFixture -Root $script:Skills -Folder 'walk-substrate' | Out-Null
        New-SkillFixture -Root $script:Skills -Folder 'make-thing' -Body "Invoked as ``/make-thing``. Usable by any persona. First run /walk-substrate.`n`n## Next steps`n- none`n" | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 0
    }

    It 'fails when the phase frontmatter is missing' {
        New-SkillFixture -Root $script:Skills -Folder 'do-thing' -NoPhase | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'phase'
    }

    It 'fails when the phase is not a known value' {
        New-SkillFixture -Root $script:Skills -Folder 'do-thing' -Phase 'bogus' | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'phase'
    }

    It 'fails when the persona frontmatter is missing' {
        New-SkillFixture -Root $script:Skills -Folder 'do-thing' -NoPersona | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'persona'
    }

    It 'fails when the kind frontmatter is missing' {
        New-SkillFixture -Root $script:Skills -Folder 'do-thing' -NoKind | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match '\[kind\]'
    }

    It 'fails when the kind is not a known value' {
        New-SkillFixture -Root $script:Skills -Folder 'do-thing' -Kind 'command' | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match "kind 'command'"
    }

    It 'fails a plugin-style skill reference that nobody else has' {
        New-SkillFixture -Root $script:Skills -Folder 'do-thing' -Body "Invoked as ``/do-thing``. Usable by any persona. Use ``superpowers:test-driven-development``.`n`n## Next steps`n- none`n" | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'plugin-ref'
        $r.Output | Should -Match 'superpowers:test-driven-development'
    }

    It 'fails a slash reference to a personal plugin command that used to be allowlisted' {
        New-SkillFixture -Root $script:Skills -Folder 'do-thing' -Body "Invoked as ``/do-thing``. Usable by any persona. Then run /go-review.`n`n## Next steps`n- none`n" | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'cross-ref'
    }

    It 'counts workflow and knowledge skills separately when both pass' {
        New-SkillFixture -Root $script:Skills -Folder 'do-thing' | Out-Null
        New-KnowledgeFixture -Root $script:Skills | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match '1 workflow and 1 knowledge'
    }

    It 'passes a well-formed knowledge skill under -Strict, since the pattern.md sections are for workflow skills' {
        New-KnowledgeFixture -Root $script:Skills | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills -Strict
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Not -Match 'failure-modes'
    }

    It 'fails a knowledge skill that can be typed as a slash command' {
        New-KnowledgeFixture -Root $script:Skills -Frontmatter 'user-invocable: true' | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'user-invocable: false'
    }

    It 'fails a knowledge skill that carries a phase or a persona' {
        New-KnowledgeFixture -Root $script:Skills -Frontmatter "user-invocable: false`nphase: create`npersona: Developer" | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'has no phase'
        $r.Output | Should -Match 'has no persona'
    }

    It 'fails a knowledge skill with a Next steps section' {
        New-KnowledgeFixture -Root $script:Skills -Extra "`n## Next steps`n- none`n" | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'knowledge-shape'
    }

    It 'fails a knowledge skill without a Sources section' {
        New-KnowledgeFixture -Root $script:Skills -Sources '' | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match '\[sources\]'
    }

    It 'fails a knowledge skill whose Sources section links only outside the repository' {
        New-KnowledgeFixture -Root $script:Skills -Sources "## Sources`n`n- [upstream](https://example.com/rule)`n" | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'links no repository page'
    }

    It 'fails a knowledge skill whose Sources link does not resolve' {
        New-KnowledgeFixture -Root $script:Skills -Sources "## Sources`n`n- [gone](../../no-such-page.md)`n" | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'no-such-page.md'
    }

    It 'fails a knowledge skill that grows past the line limit' {
        $filler = (1..130 | ForEach-Object { "- line $_" }) -join "`n"
        New-KnowledgeFixture -Root $script:Skills -Extra $filler | Out-Null
        $r = Invoke-Hygiene -SkillsRoot $script:Skills
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'knowledge-size'
    }


    It 'resolves a Sources link that starts with / from the repository root, the form APM leaves as it is' {
        $repo = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N'))
        $skills = Join-Path $repo '.claude' 'skills'
        New-Item -ItemType Directory -Path (Join-Path $repo 'docs') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'docs' 'rule.md') -Value '# Rule'
        New-KnowledgeFixture -Root $skills -Sources "## Sources`n`n- [the rule](/docs/rule.md)`n" -NoRulePage | Out-Null

        $r = Invoke-Hygiene -SkillsRoot $skills

        $r.ExitCode | Should -Be 0
    }

    It 'fails a Sources link that starts with / when the file is not at the repository root' {
        $repo = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N'))
        $skills = Join-Path $repo '.claude' 'skills'
        New-KnowledgeFixture -Root $skills -Sources "## Sources`n`n- [the rule](/docs/missing.md)`n" -NoRulePage | Out-Null

        $r = Invoke-Hygiene -SkillsRoot $skills

        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match '/docs/missing\.md'
    }
}
