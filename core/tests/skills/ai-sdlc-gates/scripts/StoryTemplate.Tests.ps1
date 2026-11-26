#requires -Version 7.4

# These tests read the source of AI.SDLC, so they skip in a consumer, which has no packs folder.
BeforeDiscovery {
    $dir = $PSScriptRoot
    $NoSource = $true
    while ($dir) {
        if ((Test-Path -LiteralPath (Join-Path $dir 'core' '.apm' 'skills')) -and (Test-Path -LiteralPath (Join-Path $dir 'packs' 'github-issues'))) {
            $NoSource = $false
            break
        }
        $dir = Split-Path -Parent $dir
    }
}

BeforeAll {
    $script:SourceRoot = $null
    $dir = $PSScriptRoot
    while ($dir) {
        if ((Test-Path -LiteralPath (Join-Path $dir 'core' '.apm' 'skills')) -and (Test-Path -LiteralPath (Join-Path $dir 'packs' 'github-issues'))) {
            $script:SourceRoot = $dir
            break
        }
        $dir = Split-Path -Parent $dir
    }
    if (-not $script:SourceRoot) { return }

    function Read-Source {
        param([Parameter(Mandatory)][string]$RelativePath)
        $path = Join-Path $script:SourceRoot $RelativePath
        if (-not (Test-Path -LiteralPath $path)) { throw "Missing source file: $RelativePath" }
        return Get-Content -LiteralPath $path -Raw
    }

    $script:Template = Read-Source 'packs/github-issues/.apm/skills/write-story/references/story-template.md'
    $script:Block = [regex]::Match($script:Template, '(?s)## The template\s+```\r?\n(.*?)```').Groups[1].Value
    $script:Conventions = Read-Source 'packs/github-issues/.apm/skills/github-issue-conventions/SKILL.md'
}

Describe 'The story template has six sections with the goal first' -Skip:$NoSource {
    It 'lists the six headings in order' {
        $headings = @(
            "🎯 What's the Goal?"
            '📌 Background'
            "🛠️ How we'll do it"
            '💡 Expected Value'
            '✅ Acceptance Criteria'
            '⚠️ Risks & Blockers'
        )
        $script:Block | Should -Not -BeNullOrEmpty
        $found = @($script:Block -split '\r?\n' | Where-Object { $_ -and $_ -notmatch '^[\s\*\[]' })
        $found | Should -Be $headings
    }

    It 'has no ELI5 and no Technical Implementation section' {
        $script:Block | Should -Not -Match 'ELI5'
        $script:Block | Should -Not -Match 'Technical Implementation'
    }

    It 'gives each section its budget' -ForEach @(
        @{ Section = '📌 Background'; Next = '🛠️'; Budget = 'At most 3' }
        @{ Section = "🛠️ How we'll do it"; Next = '💡'; Budget = 'At most 5' }
        @{ Section = '💡 Expected Value'; Next = '✅'; Budget = 'At most 3' }
        @{ Section = '⚠️ Risks & Blockers'; Next = '$'; Budget = 'At most 3' }
    ) {
        $text = [regex]::Match($script:Block, "(?s)$([regex]::Escape($Section))\s+(.*?)$Next").Groups[1].Value
        $text | Should -Match $Budget
    }

    It 'limits a story, bug or task to 5 criteria' {
        $criteria = [regex]::Match($script:Block, '(?s)✅ Acceptance Criteria\s+(.*?)⚠️').Groups[1].Value
        $criteria | Should -Match 'at most 5'
        $criteria | Should -Not -Match 'at most 8'
    }

    It 'lets no criterion name a file, a class, a setting or a rule ID' {
        $script:Template | Should -Match 'names no\s+file, class, setting or rule ID'
        $script:Template | Should -Not -Match 'may name a symbol'
    }
}

Describe 'The issue conventions state the limits of both forms' -Skip:$NoSource {
    It 'says at most 5 criteria, and 8 in the old form' {
        $script:Conventions | Should -Match 'at most 5 criteria, or 8 in the old form'
    }

    It 'describes the old form with its own criteria heading' {
        $script:Conventions | Should -Match 'criteria heading is `✅ Success Criteria` has the old form'
    }
}

Describe 'A reader finds the criteria under both headings' -Skip:$NoSource {
    It 'names both headings in <File>' -ForEach @(
        @{ File = 'core/.apm/skills/walk-substrate/SKILL.md' }
        @{ File = 'core/.apm/agents/spec-reviewer.agent.md' }
        @{ File = 'packs/github-issues/.apm/agents/draft-reviewer.agent.md' }
        @{ File = 'packs/github-issues/.apm/skills/write-story/SKILL.md' }
        @{ File = 'packs/dotnet/.apm/skills/test-first-dotnet/SKILL.md' }
    ) {
        $text = Read-Source $File
        $text | Should -Match '`✅ Acceptance Criteria`'
        $text | Should -Match '`✅ Success Criteria`'
    }
}

Describe 'The github-issues pack keeps no old section count' -Skip:$NoSource {
    It 'has no seven-section wording left' {
        $hits = Get-ChildItem -LiteralPath (Join-Path $script:SourceRoot 'packs' 'github-issues' '.apm') -Recurse -File -Filter '*.md' |
            Select-String -Pattern 'seven sections|seven house sections|7-section'
        @($hits).Count | Should -Be 0
    }
}

Describe 'The plan names the proof of each criterion' -Skip:$NoSource {
    It 'gives the architect plan a Proof field' {
        $architect = Read-Source 'core/.apm/agents/architect.agent.md'
        $architect | Should -Match '(?m)^Proof:'
    }
}
