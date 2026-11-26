#requires -Version 7.4

BeforeAll { $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm' }

Describe 'StoryMoveGh' {
    BeforeAll {
        Import-Module (Join-Path -Path $script:ScriptFolder -ChildPath 'StoryMoveGh.psm1') -Force

        function New-ConfigRepo {
            param([string]$Json)
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('storymove-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value $Json -Encoding utf8
            return $root
        }
    }

    It 'sends the arguments to the invoker and returns what it returns' {
        $script:seen = $null
        $result = Invoke-GitHubCli -Arguments @('issue', 'view', '42') -Invoker { param($a) $script:seen = $a; 'out' }

        $result | Should -Be 'out'
        $script:seen | Should -Be @('issue', 'view', '42')
    }

    It 'prefers the repository and label that the caller passes' {
        $root = New-ConfigRepo -Json '{ "tracker": { "repository": "contoso/tracker", "inReviewLabel": "waits" } }'

        $settings = Get-StoryMoveSettings -RepoRoot $root -Repository 'contoso/portal' -Label 'custom'

        $settings.Repository | Should -Be 'contoso/portal'
        $settings.Label | Should -Be 'custom'
        $settings.RepoArgs | Should -Be @('--repo', 'contoso/portal')
    }

    It 'reads tracker.repository and tracker.inReviewLabel from aisdlc.json' {
        $root = New-ConfigRepo -Json '{ "tracker": { "repository": "contoso/tracker", "inReviewLabel": "waits" }, "github": { "repository": "contoso/portal" } }'

        $settings = Get-StoryMoveSettings -RepoRoot $root

        $settings.Repository | Should -Be 'contoso/tracker'
        $settings.Label | Should -Be 'waits'
    }

    It 'falls back to github.repository, and then to no repository so gh reads the git remote' {
        $withGithub = Get-StoryMoveSettings -RepoRoot (New-ConfigRepo -Json '{ "github": { "repository": "contoso/portal" } }')
        $none = Get-StoryMoveSettings -RepoRoot (New-ConfigRepo -Json '{}')

        $withGithub.Repository | Should -Be 'contoso/portal'
        $withGithub.Label | Should -Be 'in-review'
        $none.Repository | Should -BeNullOrEmpty
        @($none.RepoArgs).Count | Should -Be 0
    }
}
