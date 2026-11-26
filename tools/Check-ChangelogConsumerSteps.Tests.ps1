#requires -Version 7.4

# The update pull request of a consumer reads the steps of a release only under one fixed heading
# (Get-ConsumerStep in New-AiSdlcUpdatePullRequest.ps1). This test keeps the AI.SDLC CHANGELOG in that
# form, so no release loses its steps (#92). It lives in tools/, because it reads this repository only.
Describe 'The consumer steps in CHANGELOG.md' {
    BeforeAll {
        $script:Heading = 'What a consumer does when it takes this release:'

        function Get-HeadingProblem {
            param([string]$Path)
            $lines = @(Get-Content -LiteralPath $Path)
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -notmatch '^What a consumer') { continue }
                if ($lines[$i] -cne $script:Heading) { "CHANGELOG.md:$($i + 1)  not the fixed heading: $($lines[$i])"; continue }
                $blank = $i + 1 -lt $lines.Count -and $lines[$i + 1] -eq ''
                $item = $i + 2 -lt $lines.Count -and $lines[$i + 2] -match '^[-*] '
                if (-not ($blank -and $item)) { "CHANGELOG.md:$($i + 1)  no blank line and list item below the heading" }
            }
        }

        function New-Changelog([string]$Text) {
            $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('n') + '.md')
            [IO.File]::WriteAllText($path, $Text)
            $path
        }
    }

    It 'writes every consumer heading of this repository as the fixed heading, with a list below it' -Tag '92' {
        Get-HeadingProblem -Path (Join-Path $PSScriptRoot '..' 'CHANGELOG.md') | Should -BeNullOrEmpty
    }

    It 'fails a line that starts with What a consumer but is not the fixed heading' -Tag '92' {
        $path = New-Changelog "## v1.0.0`n`nWhat a consumer does: run the step.`n"

        Get-HeadingProblem -Path $path | Should -Match 'not the fixed heading'
    }

    It 'fails the fixed heading without a blank line and a list item below it' -Tag '92' {
        $path = New-Changelog "## v1.0.0`n`nWhat a consumer does when it takes this release: run the step.`n`n## v0.9.0`n`nWhat a consumer does when it takes this release:`nrun the step.`n"

        @(Get-HeadingProblem -Path $path) | Should -HaveCount 2
    }

    It 'passes the fixed heading with a blank line and a - or * item below it' -Tag '92' {
        $path = New-Changelog "## v1.0.0`n`nWhat a consumer does when it takes this release:`n`n- Run the step.`n`n## v0.9.0`n`nWhat a consumer does when it takes this release:`n`n* Run the step.`n"

        Get-HeadingProblem -Path $path | Should -BeNullOrEmpty
    }
}
