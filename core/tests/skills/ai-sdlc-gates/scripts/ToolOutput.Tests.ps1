#requires -Version 7.4

Describe 'ToolOutput' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'ToolOutput.psm1') -Force
    }

    It 'formats a number the same way whatever the current culture is' {
        $saved = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            $results = @{}
            foreach ($culture in @('en-US', 'nl-NL', 'de-DE')) {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::new($culture)
                $results[$culture] = (Write-Invariant -Template '{0:N0} page(s)' -Values @(1234) 6>&1 | Out-String).Trim()
            }

            $results['en-US'] | Should -Be '1,234 page(s)'
            $results['nl-NL'] | Should -Be $results['en-US']
            $results['de-DE'] | Should -Be $results['en-US']
        }
        finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $saved
        }
    }

    It 'writes the text once, with no leading or trailing decoration' {
        $text = (Write-Invariant -Template 'plain {0}' -Values @('line') 6>&1 | Out-String).Trim()

        $text | Should -Be 'plain line'
    }

    It 'accepts a colour without changing the text' {
        $plain = (Write-Invariant -Template '{0:N0} finding(s)' -Values @(3) 6>&1 | Out-String).Trim()
        $coloured = (Write-Invariant -Template '{0:N0} finding(s)' -Values @(3) -ForegroundColor Yellow 6>&1 | Out-String).Trim()

        $coloured | Should -Be $plain
    }

    It 'exports only the writer, so the invariant culture stays private to the module' {
        $exported = @((Get-Module ToolOutput).ExportedFunctions.Keys)

        $exported | Should -Be @('Write-Invariant')
    }
}
