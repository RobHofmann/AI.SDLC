#requires -Version 7.4

BeforeAll { $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm' }

Describe 'Build-DocsIndex' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'DocToolTestHarness.psm1') -Force
        $script:ScriptUnderTest = Join-Path -Path $script:ScriptFolder -ChildPath 'Build-DocsIndex.ps1'

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

    Context 'the first whole sentence of the summary' {
        It 'takes a first sentence that wraps over <Lines> lines whole' -Tag '89' -ForEach @(
            @{ Lines = 2; Text = "This sentence starts on one line`nand ends on the next. Then comes more."; Expected = 'This sentence starts on one line and ends on the next.' }
            @{ Lines = 3; Text = "This sentence starts here,`nruns over a second line,`nand ends on the third. Then comes more."; Expected = 'This sentence starts here, runs over a second line, and ends on the third.' }
        ) {
            Set-Page -Relative 'docs/wrap.md' -Text "# Wrap`n`n$Text`n"

            Invoke-Builder | Out-Null

            ((Get-IndexLine -Match '\[Wrap\]') -replace '^.* - ', '') | Should -Be $Expected
        }

        It 'does not take the second sentence' -Tag '89' {
            Set-Page -Relative 'docs/second.md' -Text "# Second`n`nFirst sentence here.`nSecond sentence there.`n"

            Invoke-Builder | Out-Null

            ((Get-IndexLine -Match '\[Second\]') -replace '^.* - ', '') | Should -Be 'First sentence here.'
        }

        It 'takes a first sentence whole when a wrapped line starts with a code span' -Tag '89' {
            Set-Page -Relative 'docs/tick.md' -Text "# Tick`n`nThis sentence moves a rule into`n``powershell-conventions``. It also adds more.`n"

            Invoke-Builder | Out-Null

            Get-IndexLine -Match '\[Tick\]' | Should -Match ' - This sentence moves a rule into `powershell-conventions`\.$'
        }

        It 'takes a paragraph that starts with a code span' -Tag '89' {
            Set-Page -Relative 'docs/lead.md' -Text "# Lead`n`n``Build-DocsIndex.ps1`` writes the index`nof each layer. Then more.`n"

            Invoke-Builder | Out-Null

            Get-IndexLine -Match '\[Lead\]' | Should -Match ' - `Build-DocsIndex\.ps1` writes the index of each layer\.$'
        }

        It 'ends the paragraph at a code fence that opens with <Fence>' -Tag '89' -ForEach @(
            @{ Fence = '```' }
            @{ Fence = '~~~' }
        ) {
            Set-Page -Relative 'docs/fence.md' -Text "# Fence`n`nThis paragraph has no stop`n$Fence`nfenced code`n$Fence`n"

            Invoke-Builder | Out-Null

            ((Get-IndexLine -Match '\[Fence\]') -replace '^.* - ', '') | Should -Be 'This paragraph has no stop'
        }

        It 'does not end the sentence at <Case>' -Tag '89' -ForEach @(
            @{ Case = 'e.g.'; Text = 'Use a gate, e.g. the docs gate, to check it. Next.'; Expected = 'Use a gate, e.g. the docs gate, to check it.' }
            @{ Case = 'a version'; Text = 'Release v2.8.0 changed the index. Next.'; Expected = 'Release v2.8.0 changed the index.' }
            @{ Case = 'a dot inside a code span'; Text = 'Run `Build. It now` to write it. Next.'; Expected = 'Run `Build. It now` to write it.' }
        ) {
            Set-Page -Relative 'docs/cases.md' -Text "# Cases`n`n$Text`n"

            Invoke-Builder | Out-Null

            ((Get-IndexLine -Match '\[Cases\]') -replace '^.* - ', '') | Should -Be $Expected
        }
    }
}
