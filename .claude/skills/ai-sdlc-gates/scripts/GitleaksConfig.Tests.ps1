#requires -Version 7.4

Describe 'GitleaksConfig' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'GitleaksConfig.psm1') -Force

        # A line as sync-manifest.json holds it. The hash is made here, so this file holds no such line itself.
        function New-ManifestLine {
            do {
                $hash = [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([Text.Encoding]::UTF8.GetBytes([guid]::NewGuid().ToString()))).ToLowerInvariant()
                $groups = $hash.ToCharArray() | Group-Object
                $entropy = -($groups | ForEach-Object { $p = $_.Count / $hash.Length; $p * [Math]::Log($p, 2) } | Measure-Object -Sum).Sum
            } while ($entropy -lt 3.7)
            return '        ".claude/skills/summary/modes/' + 'accessible.md": "' + $hash + '",'
        }
    }

    It 'extends the default rules of gitleaks without -RulesPath' {
        $path = New-GitleaksConfig -Path (Join-Path $TestDrive 'default.toml')

        $text = Get-Content -LiteralPath $path -Raw
        $text | Should -Match '(?m)^\[extend\]\s*\nuseDefault = true'
        $text | Should -Match '(?m)^\[\[allowlists\]\]'
    }

    It 'extends the rule set that -RulesPath names, by its full path in forward slashes' {
        $rules = Join-Path $TestDrive 'rules.toml'
        Set-Content -LiteralPath $rules -Value '# rules'

        $text = Get-Content -LiteralPath (New-GitleaksConfig -Path (Join-Path $TestDrive 'pinned.toml') -RulesPath $rules) -Raw

        $text | Should -Match ([regex]::Escape("path = '$(([IO.Path]::GetFullPath($rules)).Replace('\', '/'))'"))
        $text | Should -Not -Match 'useDefault'
    }

    It 'reads the pinned URL and SHA-256 of the default rule set, the one CI and the pre-flight share' {
        $pin = Get-GitleaksRulesPin

        $pin.Name | Should -Be 'GitleaksUdmCombo'
        $pin.Url | Should -Match '^https://'
        $pin.Sha256 | Should -Match '^[0-9a-f]{64}$'
    }

    It 'returns nothing for a rule set the pin file does not name' {
        Get-GitleaksRulesPin -Configuration 'Missing' | Should -BeNullOrEmpty
    }

    It 'accepts a rules file only when its SHA-256 matches the pin' {
        $file = Join-Path $TestDrive 'rules-check.toml'
        Set-Content -LiteralPath $file -Value '# rules' -NoNewline
        $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()

        Test-GitleaksRulesFile -Path $file -Pin ([pscustomobject]@{ Sha256 = $hash }) | Should -BeTrue
        Test-GitleaksRulesFile -Path $file -Pin ([pscustomobject]@{ Sha256 = ('0' * 64) }) | Should -BeFalse
        Test-GitleaksRulesFile -Path (Join-Path $TestDrive 'none.toml') -Pin ([pscustomobject]@{ Sha256 = $hash }) | Should -BeFalse
    }

    It 'allows the sync manifest in a consumer and in AI.SDLC, and nothing else of that name' {
        $patterns = @(Get-GitleaksAllowedPath)

        @($patterns | Where-Object { '.claude/skills/ai-sdlc-gates/sync-manifest.json' -match $_ }) | Should -Not -BeNullOrEmpty
        @($patterns | Where-Object { 'core/.apm/skills/ai-sdlc-gates/sync-manifest.json' -match $_ }) | Should -Not -BeNullOrEmpty
        @($patterns | Where-Object { 'src/sync-manifest.json' -match $_ }) | Should -BeNullOrEmpty
    }

    It 'makes gitleaks skip the hashes of the sync manifest, and still find the same line elsewhere' -Skip:(-not (Get-Command gitleaks -ErrorAction SilentlyContinue)) {
        $scan = Join-Path $TestDrive 'scan'
        $manifest = Join-Path $scan '.claude' 'skills' 'ai-sdlc-gates' 'sync-manifest.json'
        New-Item -ItemType Directory -Path (Split-Path $manifest -Parent) -Force | Out-Null
        Set-Content -LiteralPath $manifest -Value (New-ManifestLine)
        Set-Content -LiteralPath (Join-Path $scan 'other.json') -Value (New-ManifestLine)
        $config = New-GitleaksConfig -Path (Join-Path $TestDrive 'scan.toml')
        $report = Join-Path $TestDrive 'report.json'

        gitleaks dir $scan --config $config --no-banner --report-format json --report-path $report *> $null

        $findings = @(Get-Content -LiteralPath $report -Raw | ConvertFrom-Json)
        $findings | Should -HaveCount 1
        $findings[0].File | Should -Match 'other\.json$'
    }

    Context 'the paths a repository names in secretScan.allowPaths' {
        BeforeEach {
            $script:Repo = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $script:Repo -Force | Out-Null
        }

        It 'adds them as an allowlist of their own, next to the allowlist of the AI-SDLC' {
            Set-Content -LiteralPath (Join-Path $script:Repo 'aisdlc.json') -Value '{ "secretScan": { "allowPaths": [ "^\\.runtime/", "(^|/)app-secrets\\.yaml$" ] } }'

            $text = Get-Content -LiteralPath (New-GitleaksConfig -Path (Join-Path $TestDrive 'repo.toml') -RepoRoot $script:Repo) -Raw

            ([regex]::Matches($text, '(?m)^\[\[allowlists\]\]')).Count | Should -Be 2
            $text | Should -Match ([regex]::Escape("'''^\.runtime/'''"))
            $text | Should -Match ([regex]::Escape("'''(^|/)app-secrets\.yaml$'''"))
        }

        It 'writes the same config as before when aisdlc.json names no paths' {
            Set-Content -LiteralPath (Join-Path $script:Repo 'aisdlc.json') -Value '{ "repository": "contoso" }'

            $with = Get-Content -LiteralPath (New-GitleaksConfig -Path (Join-Path $TestDrive 'none.toml') -RepoRoot $script:Repo) -Raw
            $without = Get-Content -LiteralPath (New-GitleaksConfig -Path (Join-Path $TestDrive 'plain.toml')) -Raw

            $with | Should -Be $without
        }

        It 'refuses a pattern that is <Why>, and names the field' -ForEach @(
            @{ Why = 'not anchored'; Pattern = 'app-secrets\\.yaml' }
            @{ Why = 'a match for every path'; Pattern = '^.*' }
            @{ Why = 'a match for any file in a folder'; Pattern = '(^|/)' }
            @{ Why = 'holding a quote'; Pattern = "^a'''b" }
            @{ Why = 'not a regular expression'; Pattern = '^a[' }
        ) {
            $json = @{ secretScan = @{ allowPaths = @($Pattern) } } | ConvertTo-Json -Depth 3
            Set-Content -LiteralPath (Join-Path $script:Repo 'aisdlc.json') -Value $json

            { New-GitleaksConfig -Path (Join-Path $TestDrive 'bad.toml') -RepoRoot $script:Repo } | Should -Throw '*secretScan.allowPaths*'
        }

        It 'says which paths the scan skips, so a reviewer sees a wider list' {
            Set-Content -LiteralPath (Join-Path $script:Repo 'aisdlc.json') -Value '{ "secretScan": { "allowPaths": [ "^\\.runtime/" ] } }'

            $out = New-GitleaksConfig -Path (Join-Path $TestDrive 'shown.toml') -RepoRoot $script:Repo 6>&1 | Out-String

            $out | Should -Match 'secretScan\.allowPaths'
            $out | Should -Match ([regex]::Escape('^\.runtime/'))
        }

        It 'makes gitleaks skip a named path, and still find the same secret elsewhere' -Skip:(-not (Get-Command gitleaks -ErrorAction SilentlyContinue)) {
            Set-Content -LiteralPath (Join-Path $script:Repo 'aisdlc.json') -Value '{ "secretScan": { "allowPaths": [ "(^|/)app-secrets\\.yaml$" ] } }'
            $scan = Join-Path $script:Repo 'scan'
            New-Item -ItemType Directory -Path $scan -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $scan 'app-secrets.yaml') -Value (New-ManifestLine)
            Set-Content -LiteralPath (Join-Path $scan 'other.json') -Value (New-ManifestLine)
            $config = New-GitleaksConfig -Path (Join-Path $TestDrive 'repo-scan.toml') -RepoRoot $script:Repo
            $report = Join-Path $TestDrive 'repo-report.json'

            gitleaks dir $scan --config $config --no-banner --report-format json --report-path $report *> $null

            $findings = @(Get-Content -LiteralPath $report -Raw | ConvertFrom-Json)
            $findings | Should -HaveCount 1
            $findings[0].File | Should -Match 'other\.json$'
        }
    }
}
