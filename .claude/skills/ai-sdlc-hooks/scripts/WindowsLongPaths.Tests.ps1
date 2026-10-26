#requires -Version 7.4
Describe 'Enable-WindowsLongPath' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'WindowsLongPaths.ps1')
    }

    BeforeEach {
        Mock Start-Process { }
        Mock Set-ItemProperty { }
        $script:SavedCi = @{ GITHUB_ACTIONS = $env:GITHUB_ACTIONS; CI = $env:CI }
        $env:GITHUB_ACTIONS = $null
        $env:CI = $null
    }

    AfterEach {
        $env:GITHUB_ACTIONS = $script:SavedCi.GITHUB_ACTIONS
        $env:CI = $script:SavedCi.CI
    }

    It 'returns nothing and asks nothing when long paths are already on' -Skip:(-not $IsWindows) {
        Mock Get-ItemProperty { [pscustomobject]@{ LongPathsEnabled = 1 } }
        Enable-WindowsLongPath | Should -BeNullOrEmpty
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It 'returns the fix when long paths stay off after the prompt' -Skip:(-not $IsWindows) {
        Mock Get-ItemProperty { [pscustomobject]@{ LongPathsEnabled = 0 } }
        Enable-WindowsLongPath 6> $null | Should -Match 'LongPathsEnabled to 1'
    }

    It 'never asks in a pipeline, and says long paths are off' -Skip:(-not $IsWindows) {
        Mock Get-ItemProperty { [pscustomobject]@{ LongPathsEnabled = 0 } }
        $env:GITHUB_ACTIONS = 'true'
        Enable-WindowsLongPath | Should -Match 'long paths are off'
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It 'returns nothing off Windows' -Skip:$IsWindows {
        Enable-WindowsLongPath | Should -BeNullOrEmpty
    }
}
