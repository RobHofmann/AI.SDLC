#requires -Version 7.4

Describe 'Build-DocsIndex' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'DocToolTestHarness.psm1') -Force
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Build-DocsIndex.ps1'

        function Invoke-Builder {
            param([hashtable]$Extra = @{})
            $out = & $script:ScriptUnderTest -RepoRoot $script:Root @Extra *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }

        function Set-Page {
            param([Parameter(Mandatory)][string]$Relative, [Parameter(Mandatory)][string]$Text)
            $full = Join-Path $script:Root $Relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
            Set-Content -LiteralPath $full -Value $Text -Encoding utf8
        }

        function Get-IndexLine {
            param([string]$Match)
            $index = Get-Content -LiteralPath (Join-Path $script:Root 'docs/index.md') -Encoding utf8
            return @($index | Where-Object { $_ -match $Match })[0]
        }
    }

    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'docs') -Force | Out-Null
        Set-AiSdlcTestConfig -Root $script:Root
    }

    It 'flattens a relative link in the summary, because the index sits a folder above the page' {
        Set-Page -Relative 'docs/adrs/0046-thing.md' -Text "# ADR 0046: A thing`n`n[ADR 0040](0040-other.md) made every gate report through a wrapper.`n"

        Invoke-Builder | Out-Null

        $line = Get-IndexLine -Match '0046-thing'
        $line | Should -Match 'ADR 0040 made every gate report'
        $line | Should -Not -Match '0040-other\.md'
    }

    It 'keeps an absolute link, which resolves from anywhere' {
        Set-Page -Relative 'docs/page.md' -Text "# Page`n`nSee [the docs](https://example.com/a) for the rest.`n"

        Invoke-Builder | Out-Null

        Get-IndexLine -Match '\[Page\]' | Should -Match 'https://example\.com/a'
    }

    It 'keeps the plain text of a page with no link' {
        Set-Page -Relative 'docs/plain.md' -Text "# Plain`n`nThis page says one thing.`n"

        Invoke-Builder | Out-Null

        Get-IndexLine -Match '\[Plain\]' | Should -Match 'This page says one thing\.'
    }

    It 'reports drift with -Check instead of writing' {
        Set-Page -Relative 'docs/plain.md' -Text "# Plain`n`nThis page says one thing.`n"
        Set-Page -Relative 'docs/index.md' -Text "# Index`n`nout of date`n"

        $r = Invoke-Builder -Extra @{ Check = $true }

        $r.ExitCode | Should -Not -Be 0
        (Get-Content -LiteralPath (Join-Path $script:Root 'docs/index.md') -Raw) | Should -Match 'out of date'
    }
}
