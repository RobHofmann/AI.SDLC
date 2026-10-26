#requires -Version 7.4

Describe 'Install-Apm' {
    BeforeAll {
        $script:Script = Join-Path $PSScriptRoot 'Install-Apm.ps1'

        function New-FakeRelease {
            param([string]$Platform = 'linux-x86_64')
            $work = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
            $content = Join-Path $work "apm-$Platform"
            New-Item -ItemType Directory -Path $content -Force | Out-Null
            if ($Platform -like 'windows-*') {
                Set-Content -LiteralPath (Join-Path $content 'apm.exe') -Value 'fake apm'
                $archive = Join-Path $work 'apm.zip'
                Compress-Archive -LiteralPath $content -DestinationPath $archive
            }
            else {
                Set-Content -LiteralPath (Join-Path $content 'apm') -Value 'fake apm'
                $archive = Join-Path $work 'apm.tar.gz'
                Push-Location $work
                try { tar -czf 'apm.tar.gz' "apm-$Platform" }
                finally { Pop-Location }
            }
            return [pscustomobject]@{ Archive = $archive; Hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() }
        }

        function New-Pin {
            param([string]$Hash, [hashtable]$Assets)
            $file = Join-Path $TestDrive ([guid]::NewGuid().ToString('n') + '.json')
            $pin = [ordered]@{ version = 'v9.9.9' }
            if ($Hash) { $pin.sha256 = $Hash }
            if ($Assets) { $pin.assets = $Assets }
            Set-Content -LiteralPath $file -Value ($pin | ConvertTo-Json)
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

        $out = & $script:Script -Prefix $prefix -Platform linux-x86_64 -SourceFile $release.Archive -PinFile (New-Pin -Hash $release.Hash) | Out-String

        Test-Path -LiteralPath (Join-Path $prefix 'apm-linux-x86_64' 'apm') | Should -BeTrue
        $out | Should -Match 'SHA-256 checked'
    }

    It 'refuses the release and installs nothing when its SHA-256 does not match' {
        $release = New-FakeRelease
        $prefix = Join-Path $TestDrive 'prefix-bad'

        { & $script:Script -Prefix $prefix -Platform linux-x86_64 -SourceFile $release.Archive -PinFile (New-Pin -Hash ('0' * 64)) } | Should -Throw '*did not match its pinned SHA-256*'
        Test-Path -LiteralPath $prefix | Should -BeFalse
    }

    It 'takes the digest of the platform from the assets map' {
        $release = New-FakeRelease -Platform 'darwin-arm64'
        $prefix = Join-Path $TestDrive 'prefix-mac'
        $pin = New-Pin -Hash ('0' * 64) -Assets @{ 'darwin-arm64' = $release.Hash }

        & $script:Script -Prefix $prefix -Platform darwin-arm64 -SourceFile $release.Archive -PinFile $pin | Out-Null

        Test-Path -LiteralPath (Join-Path $prefix 'apm-darwin-arm64' 'apm') | Should -BeTrue
    }

    It 'unpacks the Windows zip and finds apm.exe' {
        $release = New-FakeRelease -Platform 'windows-x86_64'
        $prefix = Join-Path $TestDrive 'prefix-win'

        & $script:Script -Prefix $prefix -Platform windows-x86_64 -SourceFile $release.Archive -PinFile (New-Pin -Assets @{ 'windows-x86_64' = $release.Hash }) | Out-Null

        Test-Path -LiteralPath (Join-Path $prefix 'apm-windows-x86_64' 'apm.exe') | Should -BeTrue
    }

    It 'refuses a platform the pin has no digest for, and installs nothing' {
        $release = New-FakeRelease -Platform 'windows-x86_64'
        $prefix = Join-Path $TestDrive 'prefix-none'

        { & $script:Script -Prefix $prefix -Platform windows-x86_64 -SourceFile $release.Archive -PinFile (New-Pin -Hash $release.Hash) } | Should -Throw '*pins no APM*windows-x86_64*'
        Test-Path -LiteralPath $prefix | Should -BeFalse
    }

    It 'puts APM on the PATH of this process, and of the later steps in a workflow' {
        $release = New-FakeRelease
        $prefix = Join-Path $TestDrive 'prefix-path'
        $env:GITHUB_PATH = Join-Path $TestDrive 'github-path.txt'

        $out = & $script:Script -Prefix $prefix -Platform linux-x86_64 -SourceFile $release.Archive -PinFile (New-Pin -Hash $release.Hash) | Out-String

        $bin = Join-Path $prefix 'apm-linux-x86_64'
        @($env:PATH -split [regex]::Escape([IO.Path]::PathSeparator)) | Should -Contain $bin
        @(Get-Content -LiteralPath $env:GITHUB_PATH) | Should -Contain $bin
        $out | Should -Not -Match '##vso'
    }

    It 'installs nothing with -WhatIf' {
        $release = New-FakeRelease
        $prefix = Join-Path $TestDrive 'prefix-whatif'

        & $script:Script -Prefix $prefix -Platform linux-x86_64 -SourceFile $release.Archive -PinFile (New-Pin -Hash $release.Hash) -WhatIf | Out-Null

        Test-Path -LiteralPath $prefix | Should -BeFalse
    }

    It 'pins a version and a 64-character digest for every published platform' {
        $pin = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'apm-version.json') -Raw | ConvertFrom-Json

        $pin.version | Should -Match '^v\d+\.\d+\.\d+$'
        $pin.sha256 | Should -Match '^[0-9a-f]{64}$'
        foreach ($platform in 'linux-x86_64', 'linux-arm64', 'darwin-x86_64', 'darwin-arm64', 'windows-x86_64') {
            $pin.assets.$platform | Should -Match '^[0-9a-f]{64}$' -Because "$platform needs a digest"
        }
        $pin.assets.'linux-x86_64' | Should -Be $pin.sha256 -Because 'older copies of the script read the top-level digest for linux-x86_64'
    }
}
