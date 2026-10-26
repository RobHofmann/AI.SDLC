#requires -Version 7.4

Describe 'PullRequestDescription' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'PullRequestDescription.psm1') -Force
    }

    Context 'ConvertTo-PrDescriptionLine' {
        It 'splits a description on <Case> line endings' -ForEach @(
            @{ Case = 'Unix'; Text = "a`n`nb" }
            @{ Case = 'Windows'; Text = "a`r`n`r`nb" }
            @{ Case = 'old Mac'; Text = "a`r`rb" }
        ) {
            @(ConvertTo-PrDescriptionLine -Description $Text) | Should -Be @('a', '', 'b')
        }

        It 'returns one empty line for an empty description' {
            $lines = @(ConvertTo-PrDescriptionLine -Description '')

            $lines.Count | Should -Be 1
            $lines[0] | Should -Be ''
        }

        It 'strips every leaked here-string delimiter line at the start and the end, and warns once' {
            $output = @(ConvertTo-PrDescriptionLine -Description "@'`n @ `nbody`n'@`n@" 3>&1)
            $warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })

            @($output | Where-Object { $_ -is [string] }) | Should -Be @('body')
            $warnings.Count | Should -Be 1
            $warnings[0].Message | Should -Match 'Stripped a leaked here-string delimiter line'
        }

        It 'keeps a delimiter line in the middle of the description, and does not warn' {
            $output = @(ConvertTo-PrDescriptionLine -Description "a`n@`nb" 3>&1)

            $output | Should -Be @('a', '@', 'b')
            @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Count | Should -Be 0
        }

        It 'keeps a line that only starts with an at sign' {
            @(ConvertTo-PrDescriptionLine -Description "@mention`nbody") | Should -Be @('@mention', 'body')
        }

        It 'returns no line for a description that holds only delimiters' {
            @(ConvertTo-PrDescriptionLine -Description "@'`n'@" 3>$null).Count | Should -Be 0
        }
    }

    Context 'Assert-PrDescriptionLength' {
        It 'accepts a description of exactly 65536 characters' {
            { Assert-PrDescriptionLength -Lines @('x' * 65536) } | Should -Not -Throw
        }

        It 'refuses a description of 65537 characters, and names its length' {
            { Assert-PrDescriptionLength -Lines @('x' * 65537) } | Should -Throw '*65537 characters*'
        }

        It 'counts the line breaks between the lines' {
            { Assert-PrDescriptionLength -Lines @(('x' * 32768), ('x' * 32768)) } | Should -Throw '*65537 characters*'
        }

        It 'accepts hyphen bullets and a markdown rule' {
            { Assert-PrDescriptionLength -Lines @('## Summary', '- one', '---') } | Should -Not -Throw
        }
    }

    Context 'New-PrDescriptionFile' {
        It 'writes the lines joined with LF, as UTF-8 without a byte order mark, to a new file in the temp folder' {
            $path = New-PrDescriptionFile -Lines @('## Summary', '', ('caf' + [char]0x00E9 + ' "quoted"'))
            try {
                Split-Path $path -Parent | Should -Be ([IO.Path]::GetTempPath().TrimEnd([IO.Path]::DirectorySeparatorChar))
                Split-Path $path -Leaf | Should -Match '^pr-description-[0-9a-f]{32}\.md$'
                $bytes = [IO.File]::ReadAllBytes($path)
                $bytes[0] | Should -Not -Be 0xEF
                [Text.Encoding]::UTF8.GetString($bytes) | Should -BeExactly ("## Summary`n`ncaf" + [char]0x00E9 + ' "quoted"')
            }
            finally {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        }

        It 'writes a new file on each call' {
            $first = New-PrDescriptionFile -Lines @('a')
            $second = New-PrDescriptionFile -Lines @('a')
            try {
                $second | Should -Not -Be $first
            }
            finally {
                Remove-Item -LiteralPath $first, $second -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Get-PrDescriptionLineCount' {
        It 'counts <Expected> line(s) in <Case>' -ForEach @(
            @{ Case = 'no text'; Text = $null; Expected = 0 }
            @{ Case = 'an empty text'; Text = ''; Expected = 0 }
            @{ Case = 'one line'; Text = 'a'; Expected = 1 }
            @{ Case = 'a text with a blank line inside'; Text = "a`n`nb"; Expected = 3 }
            @{ Case = 'a text with Windows line endings'; Text = "a`r`nb`r`nc"; Expected = 3 }
            @{ Case = 'a text with trailing line breaks'; Text = "a`nb`n`n`n"; Expected = 2 }
            @{ Case = 'a text of only spaces'; Text = '   '; Expected = 1 }
        ) {
            Get-PrDescriptionLineCount -Text $Text | Should -Be $Expected
        }
    }

    Context 'Get-PrDescriptionContentLength' {
        It 'counts <Expected> character(s) in <Case>' -ForEach @(
            @{ Case = 'no text'; Text = $null; Expected = 0 }
            @{ Case = 'an empty text'; Text = ''; Expected = 0 }
            @{ Case = 'a text with spaces, tabs and line breaks'; Text = "a b`tc`r`n`nd "; Expected = 4 }
        ) {
            Get-PrDescriptionContentLength -Text $Text | Should -Be $Expected
        }
    }

    Context 'Test-PrDescriptionTruncated' {
        It 'reports a lost line even when no content was lost' {
            Test-PrDescriptionTruncated -ExpectedContentLength 100 -ActualContentLength 100 -ExpectedLineCount 5 -ActualLineCount 4 | Should -BeTrue
        }

        It 'does not report more lines than expected' {
            Test-PrDescriptionTruncated -ExpectedContentLength 100 -ActualContentLength 100 -ExpectedLineCount 4 -ActualLineCount 5 | Should -BeFalse
        }

        It 'skips the line check when <Case>' -ForEach @(
            @{ Case = 'no line count is given'; Parameters = @{} }
            @{ Case = 'only the expected line count is given'; Parameters = @{ ExpectedLineCount = 5 } }
            @{ Case = 'only the actual line count is given'; Parameters = @{ ActualLineCount = 1 } }
        ) {
            Test-PrDescriptionTruncated -ExpectedContentLength 100 -ActualContentLength 100 @Parameters | Should -BeFalse
        }

        It 'returns <Expected> for <Actual> of <ExpectedLength> characters, with a tolerance of <Tolerance>' -ForEach @(
            @{ ExpectedLength = 100; Actual = 92; Tolerance = 8; Expected = $false }
            @{ ExpectedLength = 100; Actual = 91; Tolerance = 8; Expected = $true }
            @{ ExpectedLength = 1000; Actual = 980; Tolerance = 20; Expected = $false }
            @{ ExpectedLength = 1000; Actual = 979; Tolerance = 20; Expected = $true }
            @{ ExpectedLength = 1001; Actual = 980; Tolerance = 21; Expected = $false }
            @{ ExpectedLength = 1001; Actual = 979; Tolerance = 21; Expected = $true }
            @{ ExpectedLength = 100; Actual = 150; Tolerance = 8; Expected = $false }
        ) {
            Test-PrDescriptionTruncated -ExpectedContentLength $ExpectedLength -ActualContentLength $Actual | Should -Be $Expected
        }

        It 'uses the tolerances the caller passes' {
            Test-PrDescriptionTruncated -ExpectedContentLength 100 -ActualContentLength 99 -MinimumAbsoluteTolerance 0 -RelativeTolerance 0 | Should -BeTrue
            Test-PrDescriptionTruncated -ExpectedContentLength 100 -ActualContentLength 50 -MinimumAbsoluteTolerance 0 -RelativeTolerance 0.5 | Should -BeFalse
        }
    }

    Context 'Invoke-GitHubCli' {
        AfterEach {
            Remove-Item -Path function:global:gh -ErrorAction SilentlyContinue
        }

        It 'passes the arguments to the invoker as one list, and returns what it returns' {
            $state = @{ Received = $null }
            $invoker = { param($ghArgs) $state.Received = $ghArgs; 'from invoker' }.GetNewClosure()

            Invoke-GitHubCli -Arguments @('pr', 'view', '7') -Invoker $invoker | Should -Be 'from invoker'
            $state.Received | Should -Be @('pr', 'view', '7')
        }

        It 'calls gh without an invoker, and returns its output as one text' {
            function global:gh { $global:LASTEXITCODE = 0; 'line one'; 'line two' }

            $output = Invoke-GitHubCli -Arguments @('pr', 'view', '7')

            $output | Should -BeOfType [string]
            $output | Should -Match '(?s)line one.*line two'
        }

        It 'throws with the arguments, the exit code and the output when gh fails' {
            function global:gh { $global:LASTEXITCODE = 1; 'no pull requests found' }

            { Invoke-GitHubCli -Arguments @('pr', 'view', '7') } | Should -Throw 'gh pr view 7 failed (exit 1): no pull requests found'
        }
    }

    Context 'Get-PrFromJson' {
        It 'refuses <Case>' -ForEach @(
            @{ Case = 'no JSON'; Json = $null }
            @{ Case = 'an empty text'; Json = '' }
            @{ Case = 'a text of only white space'; Json = " `n " }
        ) {
            { Get-PrFromJson -Json $Json } | Should -Throw 'gh returned no JSON to parse.'
        }

        It 'reads the pull request from the JSON' {
            $pr = Get-PrFromJson -Json '{ "number": 7, "body": "a\nb" }'

            $pr.number | Should -Be 7
            $pr.body | Should -Be "a`nb"
        }

        It 'throws on text that is not JSON' {
            { Get-PrFromJson -Json 'not json' } | Should -Throw
        }
    }

    Context 'Get-PrNumberFromUrl' {
        It 'reads the number from the URL that gh pr create prints' {
            Get-PrNumberFromUrl -Text "https://github.com/contoso/portal/pull/42`n" | Should -Be 42
        }

        It 'throws when the output holds no pull request URL' {
            { Get-PrNumberFromUrl -Text 'a pull request already exists' } | Should -Throw '*no pull request URL*'
        }
    }

    Context 'Get-RepositoryArgument' {
        It 'returns --repo with the name when one is given' {
            Get-RepositoryArgument -Repository 'contoso/portal' | Should -Be @('--repo', 'contoso/portal')
        }

        It 'returns nothing when no name is given, so gh reads the repository from the remote' {
            @(Get-RepositoryArgument -Repository '').Count | Should -Be 0
        }
    }

    Context 'Get-PullRequestReadBack' {
        It 'asks gh to view the pull request as JSON, and returns it read' {
            $state = @{ Received = $null }
            $invoker = { param($ghArgs) $state.Received = $ghArgs; '{ "number": 42, "body": "body" }' }.GetNewClosure()

            $pr = Get-PullRequestReadBack -Id 42 -Repository 'contoso/portal' -GhInvoker $invoker

            $pr.body | Should -Be 'body'
            @($state.Received | ForEach-Object { [string]$_ }) | Should -Be @('pr', 'view', '42', '--repo', 'contoso/portal', '--json', 'number,url,title,body')
        }

        It 'leaves --repo out when no repository is given' {
            $state = @{ Received = $null }
            $invoker = { param($ghArgs) $state.Received = $ghArgs; '{ "number": 42, "body": "body" }' }.GetNewClosure()

            Get-PullRequestReadBack -Id 42 -GhInvoker $invoker | Out-Null

            $state.Received | Should -Not -Contain '--repo'
        }

        It 'throws when gh shows nothing' {
            { Get-PullRequestReadBack -Id 42 -GhInvoker { param($ghArgs) '' } } | Should -Throw 'gh returned no JSON to parse.'
        }
    }
}
