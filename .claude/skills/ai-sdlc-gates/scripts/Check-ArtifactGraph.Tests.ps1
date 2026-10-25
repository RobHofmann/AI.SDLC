#requires -Version 7.4

Describe 'Check-ArtifactGraph' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'DocToolTestHarness.psm1') -Force
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Check-ArtifactGraph.ps1'

        function Invoke-Gate {
            param([Parameter(Mandatory)][string]$RepoRoot, [switch]$Strict)
            if ($Strict) {
                $out = & $script:ScriptUnderTest -RepoRoot $RepoRoot -Strict *>&1 | Out-String
            }
            else {
                $out = & $script:ScriptUnderTest -RepoRoot $RepoRoot *>&1 | Out-String
            }
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }

        function New-Artifact {
            param(
                [Parameter(Mandatory)][string]$RepoRoot,
                [Parameter(Mandatory)][string]$RelativePath,
                [Parameter(Mandatory)][string]$FrontMatter
            )
            $full = Join-Path -Path $RepoRoot -ChildPath $RelativePath
            $dir = Split-Path -Path $full -Parent
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath $full -Value $FrontMatter -NoNewline
            return $full
        }
    }

    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'docs') -Force | Out-Null
        Set-AiSdlcTestConfig -Root $script:Root
    }

    It 'passes a clean fixture (exit 0)' {
        New-Artifact -RepoRoot $script:Root -RelativePath 'docs/target.md' -FrontMatter @'
---
story: "#1234"
phase: discovery
---

# Target
'@
        New-Artifact -RepoRoot $script:Root -RelativePath 'docs/source.md' -FrontMatter @'
---
story: "#1234"
phase: create
relates:
  spec: docs/target.md
  ticket: https://github.com/contoso/portal/issues/1234
---

# Source
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Artifact graph OK:'
    }

    It 'ignores artifacts without story front-matter (exit 0)' {
        New-Artifact -RepoRoot $script:Root -RelativePath 'docs/plain.md' -FrontMatter @'
---
title: No story here
phase: discovery
---

# Plain
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Artifact graph OK:'
    }

    It 'skips an empty markdown file instead of crashing (exit 0)' {
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/empty.md') -Value '' -NoNewline

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Artifact graph OK:'
    }

    It 'fails on an invalid story key (exit 1)' {
        New-Artifact -RepoRoot $script:Root -RelativePath 'docs/badstory.md' -FrontMatter @'
---
story: not-a-key
phase: discovery
---

# Bad story
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'is not a valid story key'
    }

    It 'accepts an unquoted issue number as the story key (exit 0)' {
        New-Artifact -RepoRoot $script:Root -RelativePath 'docs/number.md' -FrontMatter @'
---
story: 42
phase: discovery
---

# Number
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Artifact graph OK: 1 graph'
    }

    It 'fails on an empty story value and names the fix (exit 1)' {
        New-Artifact -RepoRoot $script:Root -RelativePath 'docs/empty-story.md' -FrontMatter @'
---
story:
phase: discovery
---

# Empty story
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match "'story:' has no value"
        $result.Output | Should -Match 'FIX: Quote the story key'
    }

    It 'fails on an unquoted # key, which YAML reads as a comment (exit 1)' {
        New-Artifact -RepoRoot $script:Root -RelativePath 'docs/comment-story.md' -FrontMatter @'
---
story: #42
phase: discovery
---

# Comment story
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match "'story:' has no value"
    }

    It 'accepts a cross-repository story key (exit 0)' {
        New-Artifact -RepoRoot $script:Root -RelativePath 'docs/cross.md' -FrontMatter @'
---
story: "contoso/portal#42"
phase: discovery
---

# Cross
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 0
    }

    It 'fails when phase is missing (exit 1)' {
        New-Artifact -RepoRoot $script:Root -RelativePath 'docs/nophase.md' -FrontMatter @'
---
story: "#1234"
---

# No phase
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match "missing 'phase'"
    }

    It 'fails on an unknown phase (exit 1)' {
        New-Artifact -RepoRoot $script:Root -RelativePath 'docs/badphase.md' -FrontMatter @'
---
story: "#1234"
phase: unknownphase
---

# Bad phase
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'is not one of:'
    }

    It 'fails on an unresolved relates path (exit 1)' {
        New-Artifact -RepoRoot $script:Root -RelativePath 'docs/badrelates.md' -FrontMatter @'
---
story: "#1234"
phase: create
relates:
  spec: docs/does-not-exist.md
---

# Bad relates
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'does not resolve to a file in the repo'
    }

    It 'passes when no graph artifacts exist at all (exit 0)' {
        New-Artifact -RepoRoot $script:Root -RelativePath 'docs/notes.md' -FrontMatter @'
# Just a heading, no front-matter at all
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Artifact graph OK:'
    }

    It 'rejects a story key with text after the number (exit 1)' {
        New-Artifact -RepoRoot $script:Root -RelativePath 'docs/lowerkey.md' -FrontMatter @'
---
story: "#12a"
phase: discovery
---

# Bad key
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'is not a valid story key'
    }

    It 'passes when a relates repo path resolves (exit 0)' {
        New-Artifact -RepoRoot $script:Root -RelativePath 'docs/relatestarget.md' -FrontMatter @'
---
story: "#1234"
phase: discovery
---

# Relates target
'@
        New-Artifact -RepoRoot $script:Root -RelativePath 'docs/relatessource.md' -FrontMatter @'
---
story: "#1234"
phase: create
relates:
  spec: docs/relatestarget.md
---

# Relates source
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Artifact graph OK:'
    }

    It 'does not check an external URL relates value (exit 0)' {
        New-Artifact -RepoRoot $script:Root -RelativePath 'docs/urlrelates.md' -FrontMatter @'
---
story: "#1234"
phase: create
relates:
  ticket: https://github.com/contoso/portal/issues/1234
---

# URL relates
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Artifact graph OK:'
    }

    It 'reports multiple violations together (exit 1)' {
        New-Artifact -RepoRoot $script:Root -RelativePath 'docs/multi1.md' -FrontMatter @'
---
story: not-a-key
phase: discovery
---

# First bad
'@
        New-Artifact -RepoRoot $script:Root -RelativePath 'docs/multi2.md' -FrontMatter @'
---
story: "#1234"
phase: unknownphase
---

# Second bad
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'is not a valid story key'
        $result.Output | Should -Match 'is not one of:'
        $result.Output | Should -Match '2 violation\(s\)\.'
    }

    It 'passes an intent block with a resolving hypothesis path (exit 0)' {
        New-Artifact -RepoRoot $script:Root -RelativePath 'docs/discovery/theme/hypothesis.md' -FrontMatter @'
---
story: "#1234"
phase: discovery
---

# Hypothesis
'@
        New-Artifact -RepoRoot $script:Root -RelativePath 'docs/intentsource.md' -FrontMatter @'
---
story: "#1234"
phase: elaboration
intent:
  hypothesis: docs/discovery/theme/hypothesis.md
  assumption: "approvers need arbitrary-pair comparison"
  decision-drivers:
    - "reuses the proven diff engine"
---

# Intent source
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Artifact graph OK:'
    }

    It 'fails on an unresolved intent.hypothesis path (exit 1)' {
        New-Artifact -RepoRoot $script:Root -RelativePath 'docs/badintent.md' -FrontMatter @'
---
story: "#1234"
phase: elaboration
intent:
  hypothesis: docs/discovery/missing/hypothesis.md
---

# Bad intent
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'intent.hypothesis'
        $result.Output | Should -Match 'does not resolve to a file in the repo'
    }

    It 'does not check an intent.hypothesis URL (exit 0)' {
        New-Artifact -RepoRoot $script:Root -RelativePath 'docs/urlintent.md' -FrontMatter @'
---
story: "#1234"
phase: elaboration
intent:
  hypothesis: https://contoso.example/wiki/hypothesis
---

# URL intent
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Artifact graph OK:'
    }

    It 'does not require a because reason by default (exit 0)' {
        New-Artifact -RepoRoot $script:Root -RelativePath 'docs/adrtarget.md' -FrontMatter @'
---
story: "#1234"
phase: governance
---

# ADR target
'@
        New-Artifact -RepoRoot $script:Root -RelativePath 'docs/nobecause.md' -FrontMatter @'
---
story: "#1234"
phase: create
relates:
  adr: docs/adrtarget.md
---

# No because
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Artifact graph OK:'
    }

    It 'requires a because reason on an intent edge under -Strict (exit 1)' {
        New-Artifact -RepoRoot $script:Root -RelativePath 'docs/adrtarget.md' -FrontMatter @'
---
story: "#1234"
phase: governance
---

# ADR target
'@
        New-Artifact -RepoRoot $script:Root -RelativePath 'docs/nobecause.md' -FrontMatter @'
---
story: "#1234"
phase: create
relates:
  adr: docs/adrtarget.md
---

# No because
'@

        $result = Invoke-Gate -RepoRoot $script:Root -Strict
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match "relates.adr has no 'because' reason"
    }

    It 'passes under -Strict when the because reason is present (exit 0)' {
        New-Artifact -RepoRoot $script:Root -RelativePath 'docs/adrtarget.md' -FrontMatter @'
---
story: "#1234"
phase: governance
---

# ADR target
'@
        New-Artifact -RepoRoot $script:Root -RelativePath 'docs/withbecause.md' -FrontMatter @'
---
story: "#1234"
phase: create
relates:
  adr: docs/adrtarget.md
because:
  adr: "records why the target decision was taken"
---

# With because
'@

        $result = Invoke-Gate -RepoRoot $script:Root -Strict
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'edge reasons enforced'
    }

    It 'requires intent.assumption on an elaboration artifact under -Strict (exit 1)' {
        New-Artifact -RepoRoot $script:Root -RelativePath 'docs/noassumption.md' -FrontMatter @'
---
story: "#1234"
phase: elaboration
---

# No assumption
'@

        $result = Invoke-Gate -RepoRoot $script:Root -Strict
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'missing intent.assumption'
    }

    It 'passes under -Strict when an elaboration artifact carries intent.assumption (exit 0)' {
        New-Artifact -RepoRoot $script:Root -RelativePath 'docs/withassumption.md' -FrontMatter @'
---
story: "#1234"
phase: elaboration
intent:
  assumption: "approvers need arbitrary-pair comparison"
---

# With assumption
'@

        $result = Invoke-Gate -RepoRoot $script:Root -Strict
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Artifact graph OK:'
    }

    It 'does not require intent.assumption without -Strict (exit 0)' {
        New-Artifact -RepoRoot $script:Root -RelativePath 'docs/noassumption.md' -FrontMatter @'
---
story: "#1234"
phase: elaboration
---

# No assumption
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Artifact graph OK:'
    }

    It 'does not require intent.assumption on a governance artifact under -Strict (exit 0)' {
        New-Artifact -RepoRoot $script:Root -RelativePath 'docs/adrs/0099-x.md' -FrontMatter @'
---
story: "#1234"
phase: governance
---

# Governance artifact
'@

        $result = Invoke-Gate -RepoRoot $script:Root -Strict
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Artifact graph OK:'
    }
}
