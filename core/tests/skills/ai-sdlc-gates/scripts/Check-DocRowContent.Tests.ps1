#requires -Version 7.4

Describe 'Check-DocRowContent' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Check-DocRowContent.ps1'

        Import-Module (Join-Path $PSScriptRoot 'DocToolTestHarness.psm1') -Force

        function New-Repo {
            param([hashtable]$Files)
            return New-DocToolRepo -Files $Files -Prefix 'drc'
        }

        function Invoke-RowContent {
            param([hashtable]$ScriptArgs)
            $out = & $script:ScriptUnderTest @ScriptArgs *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }
    }

    It 'reports <Name>' -ForEach @(
        @{
            Name     = 'a page admitting the source did not describe something'
            Page     = "# Thing`n`nThis behaviour is not described in the cited sources."
            Expected = '\[voidclaim\]'
        }
        @{
            Name     = 'a table row that names a thing and says nothing about it'
            Page     = "# Thing`n`n| Name | What it does |`n| --- | --- |`n| ``AlphaService`` | |"
            Expected = '\[emptyrow\]'
        }
        @{
            Name     = 'a template fragment left behind'
            Page     = "# Thing`n`n| ``AlphaService`` | Public type Source: somewhere |"
            Expected = '\[fragment\]'
        }
        @{
            Name     = 'a table header with no rows under it'
            Page     = "# Thing`n`n| Name | What it does |`n| --- | --- |`n`nProse after the table."
            Expected = '\[emptytable\]'
        }
        @{
            Name     = 'an absolute path from one machine'
            Page     = "# Thing`n`nSee ``D:\src\Demo\Thing.cs`` for the detail."
            Expected = '\[machinepath\]'
        }
    ) {
        $root = New-Repo -Files @{ 'docs/thing.md' = $Page }

        $r = Invoke-RowContent -ScriptArgs @{ RepoRoot = $root }

        $r.Output | Should -Match $Expected
    }

    It 'reports a table header and separator that end the page, with no rows at all' {
        $root = New-Repo -Files @{
            'docs/thing.md' = "# Thing`n`n| Name | What it does |`n| --- | --- |"
        }

        $r = Invoke-RowContent -ScriptArgs @{ RepoRoot = $root }

        $r.Output | Should -Match '\[emptytable\]'
    }

    It 'passes a page whose rows all carry a fact' {
        $root = New-Repo -Files @{
            'docs/thing.md' = "# Thing`n`n| Name | What it does |`n| --- | --- |`n| ``AlphaService`` | Resolves an order. |"
        }

        $r = Invoke-RowContent -ScriptArgs @{ RepoRoot = $root }

        $r.Output | Should -Match 'Every documented row carries a fact'
        $r.ExitCode | Should -Be 0
    }

    It 'leaves a row alone whose cells are all code, because it is a mapping and not a description' {
        $root = New-Repo -Files @{
            'docs/thing.md' = "# Thing`n`n| From | To |`n| --- | --- |`n| ``AlphaService`` | ``BetaService`` |"
        }

        $r = Invoke-RowContent -ScriptArgs @{ RepoRoot = $root }

        $r.Output | Should -Not -Match '\[emptyrow\]'
    }

    It 'exempts the page that quotes the phrase in order to forbid it' {
        $root = New-Repo -Files @{
            'docs/graphify-code-graph.md' = "# Graph`n`nNever write that something is not described in the cited sources."
        }

        $r = Invoke-RowContent -ScriptArgs @{ RepoRoot = $root }

        $r.Output | Should -Not -Match '\[voidclaim\]'
    }

    It 'reads docs-functional as well, because house style is not scoped to one layer' {
        $root = New-Repo -Files @{
            'docs-functional/thing.md' = "# Thing`n`nThis is not described in the cited sources."
        }

        $r = Invoke-RowContent -ScriptArgs @{ RepoRoot = $root }

        $r.Output | Should -Match '\[voidclaim\].*docs-functional/thing\.md'
    }

    It 'stays advisory by default and fails only when asked' {
        $root = New-Repo -Files @{ 'docs/thing.md' = "# Thing`n`nNot described in the cited sources." }

        $advisory = Invoke-RowContent -ScriptArgs @{ RepoRoot = $root }
        $strict = Invoke-RowContent -ScriptArgs @{ RepoRoot = $root; FailOnFinding = $true }

        $advisory.ExitCode | Should -Be 0
        $strict.ExitCode | Should -Be 1
    }

    It 'summarises rather than printing every finding of one kind' {
        $rows = (1..25 | ForEach-Object { "| ``Thing$_`` | |" }) -join "`n"
        $root = New-Repo -Files @{
            'docs/thing.md' = "# Thing`n`n| Name | What it does |`n| --- | --- |`n$rows"
        }

        $r = Invoke-RowContent -ScriptArgs @{ RepoRoot = $root; MaximumFindingsPerRule = 5 }

        $r.Output | Should -Match '\[emptyrow\] and 20 more'
    }
}
