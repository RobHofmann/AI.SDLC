#requires -Version 7.4

Describe 'Check-DocsWiki' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'DocToolTestHarness.psm1') -Force
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Check-DocsWiki.ps1'
        function Invoke-Gate {
            param([Parameter(Mandatory)][string]$RepoRoot, [switch]$Strict)
            $out = & $script:ScriptUnderTest -RepoRoot $RepoRoot -Strict:$Strict *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }
        function New-Page {
            param([Parameter(Mandatory)][string]$Path, [string]$Content = '')
            $dir = Split-Path -Path $Path -Parent
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            Set-Content -LiteralPath $Path -Value $Content -Encoding utf8
        }
    }

    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        Set-AiSdlcTestConfig -Root $script:Root

        $script:DocsDir = Join-Path -Path $script:Root -ChildPath 'docs'
        $script:FuncDir = Join-Path -Path $script:Root -ChildPath 'docs-functional'
        New-Item -ItemType Directory -Path $script:DocsDir -Force | Out-Null
        New-Item -ItemType Directory -Path $script:FuncDir -Force | Out-Null

        New-Page -Path (Join-Path $script:DocsDir 'index.md') -Content @'
# Technical docs

- [Architecture](architecture.md)
'@
        New-Page -Path (Join-Path $script:DocsDir 'architecture.md') -Content @'
# Architecture

See the [index](index.md) for the full map.
'@

        New-Page -Path (Join-Path $script:FuncDir 'index.md') -Content @'
# Functional docs

- [Onboarding](onboarding.md)
'@
        New-Page -Path (Join-Path $script:FuncDir 'onboarding.md') -Content @'
# Onboarding

Back to the [index](index.md).
'@
    }

    It 'passes a clean wiki fixture (exit 0)' {
        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Docs-wiki OK:'
    }

    It 'fails on a broken relative link (exit 1)' {
        New-Page -Path (Join-Path $script:DocsDir 'architecture.md') -Content @'
# Architecture

See [the missing page](does-not-exist.md) for more.
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'broken relative link'
    }

    It 'fails on an orphan page (exit 1)' {
        New-Page -Path (Join-Path $script:DocsDir 'orphan.md') -Content @'
# Orphan

This page is not linked from the index or any other page.
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'orphan'
    }

    It 'fails on a broken relative link in the docs-functional layer (exit 1)' {
        New-Page -Path (Join-Path $script:FuncDir 'onboarding.md') -Content @'
# Onboarding

See [the missing functional page](missing-functional.md).
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'broken relative link'
        $result.Output | Should -Match 'docs-functional/onboarding\.md'
    }

    It 'fails on an orphan page in the docs-functional layer (exit 1)' {
        New-Page -Path (Join-Path $script:FuncDir 'lonely.md') -Content @'
# Lonely

Not referenced anywhere.
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'orphan'
        $result.Output | Should -Match 'docs-functional/lonely\.md'
    }

    It 'ignores external and anchor links and passes (exit 0)' {
        New-Page -Path (Join-Path $script:DocsDir 'architecture.md') -Content @'
# Architecture

See the [index](index.md) for the full map.
Visit [the site](https://example.com/missing) or mail [support](mailto:support@example.com).
Jump to [a section](#some-anchor) below.
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Docs-wiki OK:'
    }

    It 'strips the #anchor from a path#anchor target and validates the path (exit 0)' {
        New-Page -Path (Join-Path $script:DocsDir 'architecture.md') -Content @'
# Architecture

See the [index heading](index.md#technical-docs) for the full map.
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Docs-wiki OK:'
    }

    It 'fails when the path before a #anchor does not resolve (exit 1)' {
        New-Page -Path (Join-Path $script:DocsDir 'architecture.md') -Content @'
# Architecture

See [a heading](no-such-file.md#heading) for more.
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'broken relative link'
    }

    It 'does not treat a nested index.md as an orphan (exit 0)' {
        New-Page -Path (Join-Path (Join-Path $script:DocsDir 'sub') 'index.md') -Content @'
# Sub index

Standalone section index, not linked from anywhere.
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Docs-wiki OK:'
    }

    It 'does not treat a README.md as an orphan (exit 0)' {
        New-Page -Path (Join-Path $script:DocsDir 'README.md') -Content @'
# Readme

Unlinked readme that must be exempt from the orphan rule.
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Docs-wiki OK:'
    }

    It 'does not treat a *template* page as an orphan (exit 0)' {
        New-Page -Path (Join-Path $script:DocsDir 'adr-template.md') -Content @'
# ADR template

Unlinked template page that must be exempt from the orphan rule.
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Docs-wiki OK:'
    }

    It 'does not treat a page linked only by another non-index page as an orphan (exit 0)' {
        New-Page -Path (Join-Path $script:DocsDir 'architecture.md') -Content @'
# Architecture

See the [index](index.md) and the [detail](detail.md).
'@
        New-Page -Path (Join-Path $script:DocsDir 'detail.md') -Content @'
# Detail

Linked only from architecture.md, never from the index.
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Docs-wiki OK:'
    }

    It 'prints an absent-index note and judges orphans by inbound links only when index.md is missing (exit 0)' {
        # With the index absent the index check is skipped, so a page is an orphan only when nothing
        # links to it. Remove the unlinked architecture.md (it would orphan), and link detail.md from
        # an exempt README so every non-exempt page has an inbound link.
        Remove-Item -LiteralPath (Join-Path $script:DocsDir 'index.md') -Force
        Remove-Item -LiteralPath (Join-Path $script:DocsDir 'architecture.md') -Force
        New-Page -Path (Join-Path $script:DocsDir 'README.md') -Content @'
# Readme

Entry point linking to [detail](detail.md).
'@
        New-Page -Path (Join-Path $script:DocsDir 'detail.md') -Content @'
# Detail

Linked by the README.
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'is absent - skipping the index check'
        $result.Output | Should -Match 'Docs-wiki OK:'
    }

    It 'still reports an orphan when index.md is absent and the page has no inbound links (exit 1)' {
        Remove-Item -LiteralPath (Join-Path $script:DocsDir 'index.md') -Force
        New-Page -Path (Join-Path $script:DocsDir 'architecture.md') -Content @'
# Architecture

No links to anything.
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'is absent - skipping the index check'
        $result.Output | Should -Match 'orphan'
    }

    It 'reports a page with no page-to-page cross-link as a graph advisory in default mode (exit 0)' {
        # The default fixture pages link only the index, so they are isolated for connectivity, which the
        # index does not satisfy. In default (non-strict) mode this is advisory and must not fail the build.
        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'graph advisory'
        $result.Output | Should -Match 'isolated page'
    }

    It 'fails an isolated page under -Strict (exit 1)' {
        $result = Invoke-Gate -RepoRoot $script:Root -Strict
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'isolated page'
    }

    It 'passes under -Strict when every content page cross-links another content page (exit 0)' {
        New-Page -Path (Join-Path $script:DocsDir 'architecture.md') -Content @'
# Architecture

See the [index](index.md) and the related [detail](detail.md).
'@
        New-Page -Path (Join-Path $script:DocsDir 'detail.md') -Content @'
# Detail

Part of the [architecture](architecture.md).
'@
        New-Page -Path (Join-Path $script:FuncDir 'onboarding.md') -Content @'
# Onboarding

Back to the [index](index.md); see also [concepts](concepts.md).
'@
        New-Page -Path (Join-Path $script:FuncDir 'concepts.md') -Content @'
# Concepts

Used during [onboarding](onboarding.md).
'@

        $result = Invoke-Gate -RepoRoot $script:Root -Strict
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Docs-wiki OK:'
        $result.Output | Should -Match '0 isolated'
    }

    It 'does not scan links shown inside fenced code blocks or inline code spans (exit 0)' {
        New-Page -Path (Join-Path $script:DocsDir 'architecture.md') -Content @'
# Architecture

See the [index](index.md) for the full map.

A fenced example:

```
[example](does-not-exist-in-fence.md)
```

An inline example: `[example](does-not-exist-inline.md)`.
'@

        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Docs-wiki OK:'
    }

    It 'strips fenced code blocks even with CRLF line endings (exit 0)' {
        $crlf = [string]::Join("`r`n", @('# Architecture', '', 'See the [index](index.md).', '', '```', '[x](does-not-exist-in-fence.md)', '```'))
        New-Page -Path (Join-Path $script:DocsDir 'architecture.md') -Content $crlf
        $result = Invoke-Gate -RepoRoot $script:Root
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Docs-wiki OK:'
    }
}
