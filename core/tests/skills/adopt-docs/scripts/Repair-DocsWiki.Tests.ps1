#requires -Version 7.4

Describe 'Repair-DocsWiki' {
    BeforeAll {
        $script:Tool = Join-Path $PSScriptRoot 'Repair-DocsWiki.ps1'
        Import-Module (Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts' 'DocToolTestHarness.psm1') -Force
        $script:Em = [string][char]0x2014

        function New-DocsRepo {
            param([hashtable]$Pages)
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('repair-docs-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $root | Out-Null
            git -C $root init --quiet
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value '{ "paths": { "docsRoots": ["docs"], "technicalDocs": "docs", "adrFolder": "docs/adrs" } }'
            foreach ($name in $Pages.Keys) {
                $path = Join-Path $root 'docs' $name
                New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
                [IO.File]::WriteAllText($path, $Pages[$name])
            }
            return $root
        }

        function Invoke-Repair {
            param([string]$Root)
            $run = Invoke-ScriptInProcess -Path $script:Tool -Arguments @('-RepoRoot', $Root, '-NoGates')
            [pscustomobject]@{ Code = $run.ExitCode; Output = $run.Output }
        }

        function Read-Page { param([string]$Root, [string]$Name) Get-Content -LiteralPath (Join-Path $Root 'docs' $Name) -Raw }
    }

    AfterAll {
        Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'repair-docs-*' -Directory -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'replaces each em-dash with a hyphen between spaces and keeps the words' {
        $root = New-DocsRepo @{ 'a.md' = "# A`n`nThe API $($script:Em) the core part $($script:Em)and more.`n" }
        (Invoke-Repair $root).Code | Should -Be 0

        $page = Read-Page $root 'a.md'
        $page | Should -Not -Match $script:Em
        $page | Should -Match 'The API - the core part - and more\.'
    }

    It 'gives a page without an H1 a title from its file name' {
        $root = New-DocsRepo @{ 'getting-started.md' = "Some text about starting.`n" }
        Invoke-Repair $root | Out-Null

        (Read-Page $root 'getting-started.md') | Should -Match '\A# Getting Started'
    }

    It 'adds a Related section that links the index and the pages next to it, described by where they sit' {
        $root = New-DocsRepo @{
            'area/one.md' = "# One`n`nThe first page explains the first thing. More text.`n"
            'area/two.md' = "# Two`n`nThe second page explains the second thing.`n"
        }
        Invoke-Repair $root | Out-Null

        $one = Read-Page $root 'area/one.md'
        $one | Should -Match '(?m)^## Related$'
        $one | Should -Match '\[Index\]\(\.\./index\.md\) - every page of this wiki\.'
        $one | Should -Match '\[Two\]\(two\.md\) - a page in the same folder\.'
        (Read-Page $root 'area/two.md') | Should -Match '\[One\]\(one\.md\) - a page in the same folder\.'
    }

    It 'links a page that is alone in its folder to a page elsewhere in the wiki' {
        $root = New-DocsRepo @{
            'guide.md'       = "# Guide`n`nThe guide explains the app.`n"
            'ops/runbook.md' = "# Runbook`n`nThe runbook says what to do when the app stops.`n"
        }
        Invoke-Repair $root | Out-Null

        (Read-Page $root 'guide.md') | Should -Match '\[Runbook\]\(ops/runbook\.md\) - a page in ops\.'
    }

    It 'never copies text from one page into another, so a line number or hard word stays where it is' {
        $root = New-DocsRepo @{
            'deploy.md' = "Deployment is orchestrated $($script:Em) see Program.cs:42 for the bootstrap.`n"
            'notes.md'  = "# Notes`n`nOld notes.`n"
        }
        Invoke-Repair $root | Out-Null

        $notes = Read-Page $root 'notes.md'
        $notes | Should -Match '\[Deploy\]\(deploy\.md\) - a page in the same folder\.'
        $notes | Should -Not -Match 'Program\.cs'
        $notes | Should -Not -Match 'orchestrated'
    }

    It 'leaves a page that already has a Related section alone' {
        $text = "# Kept`n`nBody.`n`n## Related`n`n- [Other](other.md) - the other page.`n"
        $root = New-DocsRepo @{ 'kept.md' = $text; 'other.md' = "# Other`n`nOther body.`n" }
        Invoke-Repair $root | Out-Null

        (Read-Page $root 'kept.md') | Should -Be $text
    }

    It 'writes the docs index' {
        $root = New-DocsRepo @{ 'a.md' = "# A`n`nPage A.`n"; 'b.md' = "# B`n`nPage B.`n" }
        Invoke-Repair $root | Out-Null

        $index = Read-Page $root 'index.md'
        $index | Should -Match '\(\./a\.md\)'
        $index | Should -Match '\(\./b\.md\)'
    }

    It 'never gives a decision record a new title' {
        $adr = "---`nstatus: accepted`n---`nNo heading here, on purpose.`n"
        $root = New-DocsRepo @{ 'adrs/0001-x.md' = $adr; 'adrs/0002-y.md' = "# Y`n`nSecond record.`n" }
        Invoke-Repair $root | Out-Null

        $page = Read-Page $root 'adrs/0001-x.md'
        $page | Should -Not -Match '(?m)^# '
        $page | Should -Match '(?m)^## Related$'
    }

    It 'changes nothing on a second run' {
        $root = New-DocsRepo @{ 'a.md' = "Text $($script:Em) with a dash.`n"; 'b.md' = "# B`n`nPage B.`n" }
        Invoke-Repair $root | Out-Null
        $second = Invoke-Repair $root

        $second.Output | Should -Match '0 page\(s\) changed'
    }

    It 'changes no file with -WhatIf' {
        $text = "Text $($script:Em) with a dash.`n"
        $root = New-DocsRepo @{ 'a.md' = $text }
        Invoke-ScriptInProcess -Path $script:Tool -Arguments @('-RepoRoot', $root, '-WhatIf') | Out-Null

        (Read-Page $root 'a.md') | Should -Be $text
        Test-Path (Join-Path $root 'docs' 'index.md') | Should -BeFalse
    }
}
