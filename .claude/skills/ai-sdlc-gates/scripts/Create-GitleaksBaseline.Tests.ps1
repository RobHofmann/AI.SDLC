#requires -Version 7.4

Describe 'Create-GitleaksBaseline' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path $PSScriptRoot 'Create-GitleaksBaseline.ps1'

        function gitleaks { }
        function git { }

        $rulesHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('# rules'))).ToLowerInvariant()
        $script:PinFile = Join-Path $TestDrive 'gitleaks-rules.json'
        @{ configurations = [ordered]@{
                GitleaksUdmCombo  = @{ url = 'https://example.invalid/rules/0123abc/GitleaksUdmCombo.toml'; sha256 = $rulesHash }
                UDMSecretChecksv8 = @{ url = 'https://example.invalid/rules/0123abc/UDMSecretChecksv8.toml'; sha256 = $rulesHash }
                GitleaksOriginal  = @{ url = 'https://example.invalid/gitleaks/gitleaks/v8.30.1/config/gitleaks.toml'; sha256 = $rulesHash }
            }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:PinFile

        function Invoke-Create {
            param([hashtable]$Options = @{}, [switch]$DefaultTemp)
            $work = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
            $temp = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $work -Force | Out-Null
            if (-not $DefaultTemp) { $Options['tempDrive'] = $temp }
            if (-not $Options.ContainsKey('PinFile')) { $Options['PinFile'] = $script:PinFile }
            Push-Location $work
            try {
                $out = & $script:ScriptUnderTest @Options *>&1 | Out-String
                return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out; Work = $work; Temp = $temp }
            }
            finally { Pop-Location }
        }
    }

    BeforeEach {
        $global:LASTEXITCODE = 0
        Mock Invoke-WebRequest { Set-Content -LiteralPath $OutFile -Value '# rules' -NoNewline }
        Mock git {
            if ($args[0] -eq 'config') { return 'https://example.invalid/_git/Repo' }
            if ($args[0] -eq 'clone') { New-Item -ItemType Directory -Path $args[-1] -Force | Out-Null; $global:LASTEXITCODE = 0 }
        }
        Mock gitleaks {
            $at = [array]::IndexOf($args, '--report-path')
            ConvertTo-Json -InputObject @(@{ Fingerprint = 'b:2' }, @{ Fingerprint = 'a:1' }) | Set-Content -LiteralPath $args[$at + 1]
            $global:LASTEXITCODE = 99
        }
    }

    It 'writes the baseline in the current folder, sorted on Fingerprint' {
        $r = Invoke-Create

        $baseline = Get-Content -LiteralPath (Join-Path $r.Work 'gitleaks-baseline.json') -Raw | ConvertFrom-Json
        @($baseline.Fingerprint) | Should -Be @('a:1', 'b:2')
    }

    It 'uses the name given in -BaselineFileName' {
        $r = Invoke-Create -Options @{ BaselineFileName = 'custom.json' }

        Test-Path -LiteralPath (Join-Path $r.Work 'custom.json') | Should -BeTrue
    }

    It 'clones the remote into the temporary folder and scans that clone, not the working folder' {
        $r = Invoke-Create
        $clone = Join-Path $r.Temp 'gitleaksbaseline'

        Should -Invoke git -Times 1 -Exactly -ParameterFilter { $args[0] -eq 'clone' -and $args -contains 'https://example.invalid/_git/Repo' -and $args[-1] -eq $clone }
        Should -Invoke gitleaks -Times 1 -Exactly -ParameterFilter { $args[0] -eq 'git' -and $args[1] -eq $clone }
    }

    It 'puts the clone in the system temp folder when -tempDrive is not given' {
        Invoke-Create -DefaultTemp | Out-Null
        $clone = Join-Path ([IO.Path]::GetTempPath()) 'gitleaksbaseline'

        Should -Invoke gitleaks -Times 1 -Exactly -ParameterFilter { $args[1] -eq $clone }
        Test-Path -LiteralPath $clone | Should -BeFalse
    }

    It 'exits 1 and scans nothing when the clone fails' {
        Mock git {
            if ($args[0] -eq 'config') { return 'https://example.invalid/_git/Repo' }
            $global:LASTEXITCODE = 128
        }

        $r = Invoke-Create

        $r.Code | Should -Be 1
        Should -Invoke gitleaks -Times 0 -Exactly
        Test-Path -LiteralPath (Join-Path $r.Work 'gitleaks.toml') | Should -BeFalse
    }

    It 'exits 1 and downloads nothing when the repository has no origin remote' {
        Mock git { }

        $r = Invoke-Create

        $r.Code | Should -Be 1
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'scans with the downloaded configuration and redacts the findings' {
        Invoke-Create | Out-Null

        Should -Invoke gitleaks -Times 1 -Exactly -ParameterFilter { $args[0] -eq 'git' -and ($args -contains '--redact') -and (($args -join ' ') -match 'gitleaks\.toml') }
    }

    It 'removes the downloaded configuration and the temporary clone afterwards' {
        $r = Invoke-Create

        Test-Path -LiteralPath (Join-Path $r.Work 'gitleaks.toml') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $r.Temp 'gitleaksbaseline') | Should -BeFalse
    }

    It 'downloads the rule set that <Configuration> names from its pinned URL' -ForEach @(
        @{ Configuration = 'GitleaksUdmCombo'; Pattern = 'GitleaksUdmCombo\.toml$' }
        @{ Configuration = 'UDMSecretChecksv8'; Pattern = 'UDMSecretChecksv8\.toml$' }
        @{ Configuration = 'GitleaksOriginal'; Pattern = 'gitleaks/gitleaks/v8\.30\.1/config/gitleaks\.toml$' }
    ) {
        Invoke-Create -Options @{ gitleaksConfiguration = $Configuration } | Out-Null

        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -match $Pattern }
    }

    It 'exits 1, deletes the download and scans nothing when its SHA-256 does not match the pin' {
        Mock Invoke-WebRequest { Set-Content -LiteralPath $OutFile -Value '# changed rules' -NoNewline }

        $r = Invoke-Create

        $r.Code | Should -Be 1
        $r.Output | Should -Match 'SHA-256'
        Test-Path -LiteralPath (Join-Path $r.Work 'gitleaks.toml') | Should -BeFalse
        Should -Invoke gitleaks -Times 0 -Exactly
        Should -Invoke git -Times 0 -Exactly -ParameterFilter { $args[0] -eq 'clone' }
    }

    It 'refuses a configuration name it does not know' {
        { & $script:ScriptUnderTest -gitleaksConfiguration 'Unknown' } | Should -Throw
    }

    It 'exits 1 and scans nothing when gitleaks is not installed' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'gitleaks' }

        $r = Invoke-Create

        $r.Code | Should -Be 1
        Should -Invoke gitleaks -Times 0 -Exactly
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'exits 1 when the configuration could not be downloaded' {
        Mock Invoke-WebRequest { }

        $r = Invoke-Create

        $r.Code | Should -Be 1
        Should -Invoke gitleaks -Times 0 -Exactly
    }
}
