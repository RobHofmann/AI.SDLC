#Requires -Modules Pester

Describe 'the gitleaks config at the root of AI.SDLC' {
    BeforeAll {
        $script:Root = Resolve-Path (Join-Path $PSScriptRoot '..')
        $script:ConfigFile = Join-Path $script:Root '.gitleaks.toml'
        Import-Module (Join-Path $script:Root 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' 'GitleaksConfig.psm1') -Force
    }

    It 'exists, so a plain gitleaks run in this repository picks it up' {
        Test-Path -LiteralPath $script:ConfigFile -PathType Leaf | Should -BeTrue
    }

    It 'extends the default rules' {
        (Get-Content -LiteralPath $script:ConfigFile -Raw) | Should -Match '(?m)^useDefault\s*=\s*true\s*$'
    }

    It 'allows the same paths as the gate config, so a plain run and the C03 gate agree' {
        $text = Get-Content -LiteralPath $script:ConfigFile -Raw
        $listed = @([regex]::Matches($text, "'''(.+?)'''") | ForEach-Object { $_.Groups[1].Value })
        $listed | Should -Be @(Get-GitleaksAllowedPath)
    }
}
