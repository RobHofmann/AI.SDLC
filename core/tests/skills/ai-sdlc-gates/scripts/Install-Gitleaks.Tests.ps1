#requires -Version 7.4

Describe 'Install-Gitleaks' {
    BeforeAll {
        $script:Script = Join-Path $PSScriptRoot 'Install-Gitleaks.ps1'

        function New-FakeRelease {
            param([string]$Platform = 'linux-x86_64')
            $work = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
            $content = Join-Path $work 'content'
            New-Item -ItemType Directory -Path $content -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $content 'LICENSE') -Value 'MIT'
            if ($Platform -like 'windows-*') {
                Set-Content -LiteralPath (Join-Path $content 'gitleaks.exe') -Value 'fake gitleaks'
                $archive = Join-Path $work 'gitleaks.zip'
                Compress-Archive -Path (Join-Path $content '*') -DestinationPath $archive
            }
            else {
                Set-Content -LiteralPath (Join-Path $content 'gitleaks') -Value 'fake gitleaks'
                $archive = Join-Path $work 'gitleaks.tar.gz'
                Push-Location $content
                try { tar -czf ../gitleaks.tar.gz gitleaks LICENSE }
                finally { Pop-Location }
            }
            return [pscustomobject]@{ Archive = $archive; Hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() }
        }

        function New-Pin {
            param([hashtable]$Assets)
            $file = Join-Path $TestDrive ([guid]::NewGuid().ToString('n') + '.json')
            Set-Content -LiteralPath $file -Value ([ordered]@{ version = 'v9.9.9'; assets = $Assets } | ConvertTo-Json)
            return $file
        }
    }

    BeforeEach {
        $script:SavedPath = $env:PATH
        $script:SavedGithubPath = $env:GITHUB_PATH
        $env:GITHUB_PATH = $null
    }

    AfterEach {
        $env:PATH = $script:SavedPath
        $env:GITHUB_PATH = $script:SavedGithubPath
    }

    It 'unpacks the release when its SHA-256 matches the pin' {
        $release = New-FakeRelease
        $prefix = Join-Path $TestDrive 'prefix-ok'

        $out = & $script:Script -Prefix $prefix -Platform linux-x86_64 -SourceFile $release.Archive -PinFile (New-Pin -Assets @{ 'linux-x86_64' = $release.Hash }) | Out-String

        Test-Path -LiteralPath (Join-Path $prefix 'gitleaks-v9.9.9-linux-x86_64' 'gitleaks') | Should -BeTrue
        $out | Should -Match 'SHA-256 checked'
    }

    It 'refuses the release and installs nothing when its SHA-256 does not match' {
        $release = New-FakeRelease
        $prefix = Join-Path $TestDrive 'prefix-bad'

        { & $script:Script -Prefix $prefix -Platform linux-x86_64 -SourceFile $release.Archive -PinFile (New-Pin -Assets @{ 'linux-x86_64' = ('0' * 64) }) } | Should -Throw '*did not match its pinned SHA-256*'
        Test-Path -LiteralPath $prefix | Should -BeFalse
    }

    It 'unpacks the Windows zip and finds gitleaks.exe' {
        $release = New-FakeRelease -Platform 'windows-x86_64'
        $prefix = Join-Path $TestDrive 'prefix-win'

        & $script:Script -Prefix $prefix -Platform windows-x86_64 -SourceFile $release.Archive -PinFile (New-Pin -Assets @{ 'windows-x86_64' = $release.Hash }) | Out-Null

        Test-Path -LiteralPath (Join-Path $prefix 'gitleaks-v9.9.9-windows-x86_64' 'gitleaks.exe') | Should -BeTrue
    }

    It 'refuses a platform the pin has no digest for, and installs nothing' {
        $release = New-FakeRelease
        $prefix = Join-Path $TestDrive 'prefix-none'

        { & $script:Script -Prefix $prefix -Platform darwin-arm64 -SourceFile $release.Archive -PinFile (New-Pin -Assets @{ 'linux-x86_64' = $release.Hash }) } | Should -Throw '*pins no gitleaks*darwin-arm64*'
        Test-Path -LiteralPath $prefix | Should -BeFalse
    }

    It 'downloads the release asset that gitleaks names for the platform' {
        $release = New-FakeRelease
        $prefix = Join-Path $TestDrive 'prefix-download'
        $global:GitleaksDownload = $release.Archive
        Mock Invoke-WebRequest { Copy-Item -LiteralPath $global:GitleaksDownload -Destination $OutFile }

        try { & $script:Script -Prefix $prefix -Platform linux-x86_64 -PinFile (New-Pin -Assets @{ 'linux-x86_64' = $release.Hash }) | Out-Null }
        finally { Remove-Variable -Name GitleaksDownload -Scope Global -ErrorAction SilentlyContinue }

        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://github.com/gitleaks/gitleaks/releases/download/v9.9.9/gitleaks_9.9.9_linux_x64.tar.gz' }
    }

    It 'puts gitleaks on the PATH of this process, and of the later steps in a workflow' {
        $release = New-FakeRelease
        $prefix = Join-Path $TestDrive 'prefix-path'
        $env:GITHUB_PATH = Join-Path $TestDrive 'github-path.txt'

        $out = & $script:Script -Prefix $prefix -Platform linux-x86_64 -SourceFile $release.Archive -PinFile (New-Pin -Assets @{ 'linux-x86_64' = $release.Hash }) | Out-String

        $bin = Join-Path $prefix 'gitleaks-v9.9.9-linux-x86_64'
        @($env:PATH -split [regex]::Escape([IO.Path]::PathSeparator)) | Should -Contain $bin
        @(Get-Content -LiteralPath $env:GITHUB_PATH) | Should -Contain $bin
        $out | Should -Not -Match '##vso'
    }

    It 'installs nothing with -WhatIf' {
        $release = New-FakeRelease
        $prefix = Join-Path $TestDrive 'prefix-whatif'

        & $script:Script -Prefix $prefix -Platform linux-x86_64 -SourceFile $release.Archive -PinFile (New-Pin -Assets @{ 'linux-x86_64' = $release.Hash }) -WhatIf | Out-Null

        Test-Path -LiteralPath $prefix | Should -BeFalse
    }

    It 'pins a version and a 64-character digest for every published platform' {
        $pin = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'gitleaks-version.json') -Raw | ConvertFrom-Json

        $pin.version | Should -Match '^v\d+\.\d+\.\d+$'
        foreach ($platform in 'linux-x86_64', 'linux-arm64', 'darwin-x86_64', 'darwin-arm64', 'windows-x86_64') {
            $pin.assets.$platform | Should -Match '^[0-9a-f]{64}$' -Because "$platform needs a digest"
        }
    }

    It 'pins the gitleaks version whose rules gitleaks-rules.json pins' {
        $pin = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'gitleaks-version.json') -Raw | ConvertFrom-Json
        $rules = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'gitleaks-rules.json') -Raw | ConvertFrom-Json

        $rules.configurations.GitleaksOriginal.url | Should -Match ([regex]::Escape("/gitleaks/gitleaks/$($pin.version)/"))
    }
}
