#requires -Version 7.4

BeforeAll { $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm' }

Describe 'Find-RetiredSkillNames' {
    BeforeAll {
        $script:Source = Join-Path $script:ScriptFolder 'Find-RetiredSkillNames.ps1'
        Import-Module (Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts' 'DocToolTestHarness.psm1') -Force
        # A manifest whose core package delivers .claude/skills/x/SKILL.md, the one installed file.
        $script:InstalledX = '{ "retired": { "old-skill": "new-skill" }, "packages": { "core": { "files": { ".claude/skills/x/SKILL.md": "0" } } } }'

        function Write-LfFile {
            param([string]$Path, [string]$Content)
            New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
            [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
        }

        function New-ConsumerRepo {
            param([hashtable]$Files, [string]$Manifest = '{ "retired": { "old-skill": "new-skill", "old-agent": "new-agent" }, "packages": {} }')
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            git -C $root init --quiet
            Write-LfFile -Path "$root.manifest.json" -Content $Manifest
            foreach ($rel in $Files.Keys) { Write-LfFile -Path (Join-Path $root $rel) -Content $Files[$rel] }
            git -C $root add -A
            return $root
        }

        function Invoke-Finder {
            param([string]$Root)
            $run = Invoke-ScriptInProcess -Path $script:Source -Arguments @('-RepoRoot', $Root, '-ManifestPath', "$Root.manifest.json")
            return [pscustomobject]@{ Code = $run.ExitCode; Output = $run.Output }
        }
    }

    It 'lists each line of the repository that uses an old name, with the new name' {
        $root = New-ConsumerRepo -Files @{
            'AGENTS.md'          = "# Agents`nRoute product code through the ``old-skill`` skill.`n"
            'docs/onboarding.md' = "Type /old-skill to start, then ask old-agent.`n"
        }
        $r = Invoke-Finder -Root $root
        $r.Code | Should -Be 0
        $r.Output | Should -Match 'AGENTS\.md:2  old-skill -> new-skill'
        $r.Output | Should -Match 'docs/onboarding\.md:1  old-skill -> new-skill'
        $r.Output | Should -Match 'docs/onboarding\.md:1  old-agent -> new-agent'
    }

    It 'says when the new name is an internal step, and names the command a person types' {
        $manifest = '{ "retired": { "old-ask": "ask-step", "old-note": "note-step", "old-skill": "new-skill" }, "packages": {} }'
        $root = New-ConsumerRepo -Manifest $manifest -Files @{
            '.claude/skills/ask-step/SKILL.md'  = "---`nname: ask-step`nuser-invocable: false`n---`n# Ask`nIt is an internal step: a person types ``/ask-me``.`n"
            '.claude/skills/note-step/SKILL.md' = "---`nname: note-step`nuser-invocable: false`n---`n# Note`n"
            '.claude/skills/new-skill/SKILL.md' = "---`nname: new-skill`n---`n# New`n"
            'CLAUDE.md'                         = "Type /old-ask, then /old-note, then /old-skill.`n"
        }
        $r = Invoke-Finder -Root $root
        $r.Code | Should -Be 0
        $r.Output | Should -Match 'CLAUDE\.md:1  old-ask -> ask-step \(an internal step: skills call it; a person types /ask-me\)'
        $r.Output | Should -Match 'CLAUDE\.md:1  old-note -> note-step \(an internal step: skills call it, a person does not type it\)'
        $r.Output | Should -Match 'CLAUDE\.md:1  old-skill -> new-skill\r?\n'
    }

    It 'leaves out the step line of an ADR, the installed files and a longer name' {
        $root = New-ConsumerRepo -Manifest $script:InstalledX -Files @{
            'docs/adrs/0001-x.md'               = "---`nstory: `"#1`"`nstep: old-skill`n---`n# ADR 0001`n"
            '.claude/skills/x/SKILL.md'         = "Calls ``old-skill``.`n"
            'README.md'                         = "The old-skill-extra and pre-old-skill names are other names.`n"
        }
        $r = Invoke-Finder -Root $root
        $r.Code | Should -Be 0
        $r.Output | Should -Match 'no file of the repository uses an old skill name'
    }

    It 'leaves out every line of an ADR in the default ADR folder, and still lists a normal page' {
        $root = New-ConsumerRepo -Files @{
            'docs/adrs/0014-x.md' = "# ADR 0014`n`nWe call ``old-skill`` here.`n"
            'docs/guide.md'       = "Run ``old-skill`` first.`n"
        }
        $r = Invoke-Finder -Root $root
        $r.Code | Should -Be 0
        $r.Output | Should -Match ([regex]::Escape('docs/guide.md:1  old-skill -> new-skill'))
        $r.Output | Should -Not -Match 'docs/adrs/'
    }

    It 'leaves out the ADR folder that aisdlc.json names, and reads docs/adrs there like any folder' {
        $root = New-ConsumerRepo -Files @{
            'aisdlc.json'                = '{ "paths": { "adrFolder": "./architecture/decisions/" } }'
            'architecture/decisions/a.md' = "Uses ``old-skill``.`n"
            'docs/adrs/b.md'             = "Uses ``old-skill``.`n"
        }
        $r = Invoke-Finder -Root $root
        $r.Code | Should -Be 0
        $r.Output | Should -Not -Match 'architecture/decisions/'
        $r.Output | Should -Match ([regex]::Escape('docs/adrs/b.md:1  old-skill -> new-skill'))
    }

    It 'falls back to docs/adrs and still exits 0 when aisdlc.json is not valid JSON' {
        $root = New-ConsumerRepo -Files @{
            'aisdlc.json'    = '{ not json'
            'docs/adrs/a.md' = "Uses ``old-skill``.`n"
            'README.md'      = "Uses ``old-skill``.`n"
        }
        $r = Invoke-Finder -Root $root
        $r.Code | Should -Be 0
        $r.Output | Should -Match ([regex]::Escape('README.md:1  old-skill -> new-skill'))
        $r.Output | Should -Not -Match 'docs/adrs/'
    }

    It 'leaves out a folder, a single file and a glob of paths.historyPaths, and still lists a file that does not match' {
        $root = New-ConsumerRepo -Files @{
            'aisdlc.json'                          = '{ "paths": { "historyPaths": ["./notes/old/", "docs\\roadmap.md", "courses/*/docs/course_changes_*.md"] } }'
            'notes/old/a.md'                       = "Uses ``old-skill``.`n"
            'notes/old/deep/b.md'                  = "Uses ``old-skill``.`n"
            'docs/roadmap.md'                      = "Uses ``old-skill``.`n"
            'courses/ai/docs/course_changes_v1.md' = "Was ``old-skill``, now ``new-skill``.`nAsk old-agent.`n"
            'courses/ai/docs/course.md'            = "Uses ``old-skill``.`n"
            'docs/roadmap-next.md'                 = "Uses ``old-skill``.`n"
        }
        $r = Invoke-Finder -Root $root
        $r.Code | Should -Be 0
        $r.Output | Should -Not -Match 'notes/old/'
        $r.Output | Should -Not -Match 'docs/roadmap\.md:'
        $r.Output | Should -Not -Match 'course_changes_v1\.md:'
        $r.Output | Should -Match ([regex]::Escape('courses/ai/docs/course.md:1  old-skill -> new-skill'))
        $r.Output | Should -Match ([regex]::Escape('docs/roadmap-next.md:1  old-skill -> new-skill'))
    }

    It 'says in one line how many places the history paths left out' {
        $root = New-ConsumerRepo -Files @{
            'aisdlc.json'       = '{ "paths": { "historyPaths": ["changes/**/*.md"] } }'
            'changes/v1.md'     = "Was ``old-skill``.`n"
            'changes/v2/all.md' = "Was ``old-skill`` and old-agent.`n"
        }
        $r = Invoke-Finder -Root $root
        $r.Code | Should -Be 0
        $r.Output | Should -Match 'no file of the repository uses an old skill name'
        $r.Output | Should -Match ([regex]::Escape('3 place(s) in files marked as history in aisdlc.json (paths.historyPaths) are left out.'))

        Write-LfFile -Path (Join-Path $root 'README.md') -Content "Uses ``old-skill``.`n"
        git -C $root add -A
        $r = Invoke-Finder -Root $root
        $r.Output | Should -Match ([regex]::Escape('README.md:1  old-skill -> new-skill'))
        $r.Output | Should -Match ([regex]::Escape('3 place(s) in files marked as history'))
    }

    It 'prints no history line when the history paths hold no old name' {
        $root = New-ConsumerRepo -Files @{
            'aisdlc.json'   = '{ "paths": { "historyPaths": ["changes"] } }'
            'changes/v1.md' = "Nothing old here.`n"
        }
        $r = Invoke-Finder -Root $root
        $r.Output | Should -Not -Match 'marked as history'
    }

    It 'keeps the ADR folder left out when historyPaths is set too' {
        $root = New-ConsumerRepo -Files @{
            'aisdlc.json'         = '{ "paths": { "historyPaths": ["changes"] } }'
            'docs/adrs/0001-x.md' = "We call ``old-skill`` here.`n"
            'changes/v1.md'       = "Was ``old-skill``.`n"
            'docs/guide.md'       = "Run ``old-skill`` first.`n"
        }
        $r = Invoke-Finder -Root $root
        $r.Code | Should -Be 0
        $r.Output | Should -Not -Match 'docs/adrs/'
        $r.Output | Should -Not -Match 'changes/v1\.md:'
        $r.Output | Should -Match ([regex]::Escape('docs/guide.md:1  old-skill -> new-skill'))
        $r.Output | Should -Match ([regex]::Escape('1 place(s) in files marked as history'))
    }

    It 'warns for a history pattern that matches no file, and does not fail' {
        $root = New-ConsumerRepo -Files @{
            'aisdlc.json'   = '{ "paths": { "historyPaths": ["changes", "chnages/*.md"] } }'
            'changes/v1.md' = "Was ``old-skill``.`n"
        }
        $r = Invoke-Finder -Root $root
        $r.Code | Should -Be 0
        $r.Output | Should -Match ([regex]::Escape("'chnages/*.md' matches no file"))
        $r.Output | Should -Not -Match "'changes' matches no file"
    }

    It 'lists a skill or an agent of the repository itself, next to the installed ones' {
        $root = New-ConsumerRepo -Manifest $script:InstalledX -Files @{
            '.claude/skills/x/SKILL.md'   = "Calls ``old-skill``.`n"
            '.claude/skills/own/SKILL.md' = "# Own`nCalls ``old-skill``.`n"
            '.claude/agents/own-agent.md' = "Ask old-skill first.`n"
        }
        $r = Invoke-Finder -Root $root
        $r.Code | Should -Be 0
        $r.Output | Should -Match '\.claude/skills/own/SKILL\.md:2  old-skill -> new-skill'
        $r.Output | Should -Match '\.claude/agents/own-agent\.md:1  old-skill -> new-skill'
        $r.Output | Should -Not -Match '\.claude/skills/x/'
    }

    It 'leaves out the installed manifest itself' {
        $root = New-ConsumerRepo -Files @{
            '.claude/skills/ai-sdlc-gates/sync-manifest.json' = '{ "retired": { "old-skill": "new-skill" } }'
        }
        $r = Invoke-Finder -Root $root
        $r.Code | Should -Be 0
        $r.Output | Should -Match 'no file of the repository uses an old skill name'
    }

    Context 'a decision record' {
        BeforeAll {
            $script:AdrNote = ' (a path in a decision record: change the path, not the decision)'
            $script:SkillPath = '.claude/skills/old-skill/references/clean-code.md'
            $script:AdrLines = @(
                '---'
                'story: "#1"'
                'step: old-skill'
                'relates:'
                "  smells: ../../$script:SkillPath"
                'because: the old-skill rules'
                '---'
                'We call old-skill here.'
                ''
                'A [old-skill](../guide.md) link.'
                ''
                'See `[x](../../.claude/skills/old-skill/SKILL.md)` in code.'
                'Text old-agent only.'
                "A [rules](../../$script:SkillPath) link."
                'More old-skill text.'
                ''
                '[smells]: ../../.claude/skills/old-skill/SKILL.md'
            ) -join "`n"
        }

        It 'lists only a path of an ADR: a link target, a definition and a relates entry' -Tag '#105' {
            $root = New-ConsumerRepo -Files @{ 'docs/adrs/0001-x.md' = "$script:AdrLines`n" }
            $r = Invoke-Finder -Root $root
            $r.Code | Should -Be 0
            foreach ($line in 5, 14, 17) {
                $r.Output | Should -Match ("docs/adrs/0001-x\.md:$line  old-skill -> new-skill" + [regex]::Escape($script:AdrNote))
            }
            foreach ($line in 3, 6, 8, 10, 12, 13, 15) {
                $r.Output | Should -Not -Match "docs/adrs/0001-x\.md:$line  "
            }
        }

        It 'lists intent.hypothesis but not intent.assumption' -Tag '#105' {
            $root = New-ConsumerRepo -Files @{
                'docs/adrs/0002-x.md' = "---`nintent:`n  assumption: the old-skill stays`n  hypothesis: .claude/skills/old-skill/a.md`n---`n# ADR`n"
            }
            $r = Invoke-Finder -Root $root
            $r.Output | Should -Match ([regex]::Escape('docs/adrs/0002-x.md:4  old-skill -> new-skill'))
            $r.Output | Should -Not -Match 'docs/adrs/0002-x\.md:3  '
        }

        It 'reports one finding on the right line: <Name>' -Tag '#105' -ForEach @(
            @{ Name = 'a relates list entry'; Line = 3; Text = "---`nrelates:`n  - ../../.claude/skills/old-skill/SKILL.md`n---`n# ADR`n" }
            @{ Name = 'a relates list entry with a key'; Line = 3; Text = "---`nrelates:`n  - spec: ../../.claude/skills/old-skill/SKILL.md`n---`n# ADR`n" }
            @{ Name = 'a link whose text wraps to the next line'; Line = 4; Text = "# ADR`n`nSee [the old`nrules](../../.claude/skills/old-skill/SKILL.md) now.`n" }
            @{ Name = 'a link in an ADR without front matter'; Line = 3; Text = "# ADR`n`nSee [rules](../../.claude/skills/old-skill/SKILL.md).`n" }
        ) {
            $root = New-ConsumerRepo -Files @{ 'docs/adrs/0003-x.md' = $Text }
            $r = Invoke-Finder -Root $root
            ([regex]::Matches($r.Output, 'docs/adrs/0003-x\.md:')).Count | Should -Be 1
            $r.Output | Should -Match "docs/adrs/0003-x\.md:$Line  old-skill -> new-skill"
        }

        It 'does not list a link inside a code fence of an ADR' -Tag '#105' -ForEach @('```', '~~~') {
            $text = "# ADR`n`n$_`n[x](../../.claude/skills/old-skill/SKILL.md)`n$_`n"
            $root = New-ConsumerRepo -Files @{ 'docs/adrs/0004-x.md' = $text }
            $r = Invoke-Finder -Root $root
            $r.Output | Should -Match 'no file of the repository uses an old skill name'
        }
    }

    Context 'a docs index' {
        BeforeAll {
            $builder = Join-Path $script:ScriptFolder '..' '..' 'ai-sdlc-gates' 'scripts' 'Build-DocsIndex.ps1'
            $header = [regex]::Match((Get-Content -LiteralPath $builder -Raw), '(?m)^\$generatedHeader = ''(?<h>[^'']+)''').Groups['h'].Value
            $script:IndexHeader = "<!-- $header -->"
        }

        It 'skips a generated docs index and still lists a page with the same text' -Tag '#105' {
            $root = New-ConsumerRepo -Files @{
                'docs/index.md' = "$script:IndexHeader`n# Index`n`nRun ``old-skill`` first.`n"
                'docs/guide.md' = "# Guide`n`nRun ``old-skill`` first.`n"
            }
            $r = Invoke-Finder -Root $root
            $r.Output | Should -Match ([regex]::Escape('docs/guide.md:3  old-skill -> new-skill'))
            $r.Output | Should -Not -Match 'docs/index\.md'
        }

        It 'reads an index.md written by hand' -Tag '#105' {
            $root = New-ConsumerRepo -Files @{ 'docs/index.md' = "# Index`n`nRun ``old-skill`` first.`n" }
            $r = Invoke-Finder -Root $root
            $r.Output | Should -Match ([regex]::Escape('docs/index.md:3  old-skill -> new-skill'))
        }
    }

    It 'changes no file' {
        $root = New-ConsumerRepo -Files @{ 'CLAUDE.md' = "Use ``old-skill``.`n" }
        Invoke-Finder -Root $root | Out-Null
        Get-Content -LiteralPath (Join-Path $root 'CLAUDE.md') -Raw | Should -Be "Use ``old-skill``.`n"
    }

    It 'says nothing and exits 0 when the manifest has no retired names, or is missing' {
        $root = New-ConsumerRepo -Files @{ 'CLAUDE.md' = "Use ``old-skill``.`n" } -Manifest '{ "packages": {} }'
        $r = Invoke-Finder -Root $root
        $r.Code | Should -Be 0
        $r.Output.Trim() | Should -BeNullOrEmpty

        Remove-Item -LiteralPath "$root.manifest.json"
        $r = Invoke-Finder -Root $root
        $r.Code | Should -Be 0
        $r.Output | Should -Match 'not checked'
    }
}
