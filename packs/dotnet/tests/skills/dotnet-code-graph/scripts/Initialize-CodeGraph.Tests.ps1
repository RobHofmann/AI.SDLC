#requires -Version 7.4
Describe 'Initialize-CodeGraph' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Initialize-CodeGraph.ps1'
        $script:Text = Get-Content -LiteralPath $script:ScriptUnderTest -Raw -Encoding utf8
        $script:Pinned = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'graphify-version.json') -Raw -Encoding utf8 | ConvertFrom-Json).graphifyVersion
    }

    It 'plans the pinned install by default, and nothing with -Minimal or -SkipGraphify' {
        @(& $script:ScriptUnderTest -RepoRoot $TestDrive -Plan) | Should -Be @('pinned Graphify CLI + first code graph')
        @(& $script:ScriptUnderTest -RepoRoot $TestDrive -Plan -Minimal).Count | Should -Be 0
        @(& $script:ScriptUnderTest -RepoRoot $TestDrive -Plan -SkipGraphify).Count | Should -Be 0
    }

    It 'pins the install to the version the accuracy benchmark was written against' {
        $script:Pinned | Should -Not -BeNullOrEmpty
        $rows = @(& $script:ScriptUnderTest -RepoRoot $TestDrive -WhatIf 6>$null)
        ($rows | ForEach-Object { $_.Detail }) -join "`n" | Should -Match ([regex]::Escape("graphifyy==$script:Pinned"))
    }

    It 'reports the graph row, no model sign-in row, and drops the install with -SkipGraphify' {
        $rows = @(& $script:ScriptUnderTest -RepoRoot $TestDrive -SkipGraphify -WhatIf 6>$null)
        $rows.Step | Should -Contain 'Graphify code graph'
        $rows.Step | Should -Not -Contain 'Documentation generator access'
        $rows.Step | Should -Not -Contain 'Graphify install'
    }

    It 'names the pin on every branch of the graphify row, so the output does not depend on what is installed' {
        $lines = @([regex]::Matches($script:Text, "(?m)^\s*New-Row 'Graphify code graph'.*$") | ForEach-Object { $_.Value })
        $lines.Count | Should -BeGreaterThan 1
        foreach ($line in $lines) { $line | Should -Match '\$pinnedVersion' }
    }

    It 'checks no model sign-in, because no step calls a model' {
        $script:Text | Should -Not -Match 'get-access-token'
    }

    It 'links the documentation edges after the first build, or the graph the doc tools need is incomplete' {
        $script:Text.IndexOf('Invoke-GraphifyIndex.ps1') | Should -BeGreaterThan -1
        $script:Text.IndexOf('Invoke-DocGraphLink.ps1') | Should -BeGreaterThan -1
        $script:Text.IndexOf("Join-Path `$PSScriptRoot 'Invoke-GraphifyIndex.ps1'") | Should -BeLessThan $script:Text.IndexOf("Join-Path `$PSScriptRoot 'Invoke-DocGraphLink.ps1'")
    }
}
