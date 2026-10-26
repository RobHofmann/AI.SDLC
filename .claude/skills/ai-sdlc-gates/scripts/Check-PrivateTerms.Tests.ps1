#requires -Version 7.4

Describe 'Check-PrivateTerms' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path $PSScriptRoot 'Check-PrivateTerms.ps1'
        $script:SavedTerms = $env:AISDLC_PRIVATE_TERMS
        $script:SavedBranch = $env:PR_SOURCE_BRANCH
        $script:SavedTitle = $env:PR_TITLE
        $script:SavedBody = $env:PR_DESCRIPTION
        $script:SavedActions = $env:GITHUB_ACTIONS
        $script:SavedEventPath = $env:GITHUB_EVENT_PATH
        $script:SavedWorkspace = $env:GITHUB_WORKSPACE

        function New-TermsRepo {
            param([string]$Visibility = 'public', [hashtable]$Files = @{ 'docs/page.md' = "# Page`nNothing to see." }, [string]$Config)
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            git -C $root init --quiet --initial-branch main
            git -C $root config user.email probe@example.invalid
            git -C $root config user.name probe
            if (-not $Config) { $Config = "{ `"visibility`": `"$Visibility`", `"paths`": { `"knowledgeRoot`": `"knowledge`" } }" }
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value $Config
            foreach ($rel in $Files.Keys) {
                $full = Join-Path $root $rel
                New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
                Set-Content -LiteralPath $full -Value $Files[$rel]
            }
            git -C $root add -A
            git -C $root commit --quiet -m 'init' --no-verify
            return $root
        }

        function New-TermsFile {
            param([string[]]$Lines)
            $path = Join-Path $TestDrive ('terms-' + [guid]::NewGuid().ToString('n') + '.txt')
            Set-Content -LiteralPath $path -Value $Lines
            return $path
        }

        function Invoke-Check {
            param([string]$Root, [hashtable]$Options = @{})
            $out = & $script:ScriptUnderTest -RepoRoot $Root @Options *>&1 | Out-String
            return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out }
        }

        # Acts as a GitHub Actions run of the repository at $Workspace, with the event file GitHub writes.
        function Set-GitHubRun {
            param([string]$Workspace, [bool]$Private, [switch]$PullRequest, [switch]$Fork)
            $payload = [ordered]@{ repository = [ordered]@{ full_name = 'contoso/portal'; private = $Private } }
            if ($PullRequest -or $Fork) {
                $head = if ($Fork) { 'someone/portal' } else { 'contoso/portal' }
                $payload.pull_request = [ordered]@{ head = [ordered]@{ repo = [ordered]@{ full_name = $head } } }
            }
            $path = Join-Path $TestDrive ('event-' + [guid]::NewGuid().ToString('n') + '.json')
            Set-Content -LiteralPath $path -Value ($payload | ConvertTo-Json -Depth 6)
            $env:GITHUB_ACTIONS = 'true'
            $env:GITHUB_EVENT_PATH = $path
            $env:GITHUB_WORKSPACE = $Workspace
        }
    }

    BeforeEach {
        $env:AISDLC_PRIVATE_TERMS = $null
        $env:PR_SOURCE_BRANCH = $null
        $env:PR_TITLE = $null
        $env:PR_DESCRIPTION = $null
        $env:GITHUB_ACTIONS = $null
        $env:GITHUB_EVENT_PATH = $null
        $env:GITHUB_WORKSPACE = $null
    }

    AfterAll {
        $env:AISDLC_PRIVATE_TERMS = $script:SavedTerms
        $env:PR_SOURCE_BRANCH = $script:SavedBranch
        $env:PR_TITLE = $script:SavedTitle
        $env:PR_DESCRIPTION = $script:SavedBody
        $env:GITHUB_ACTIONS = $script:SavedActions
        $env:GITHUB_EVENT_PATH = $script:SavedEventPath
        $env:GITHUB_WORKSPACE = $script:SavedWorkspace
    }

    It 'skips a private repository' {
        $root = New-TermsRepo -Visibility private

        $r = Invoke-Check -Root $root -Options @{ TermsFile = (New-TermsFile -Lines 'Fabrikam') }

        $r.Code | Should -Be 0
        $r.Output | Should -Match 'skipped: the repository is private'
    }

    It 'checks a private repository with -Force' {
        $root = New-TermsRepo -Visibility private -Files @{ 'docs/page.md' = 'Built for Fabrikam.' }

        $r = Invoke-Check -Root $root -Options @{ TermsFile = (New-TermsFile -Lines 'Fabrikam'); Force = $true }

        $r.Code | Should -Be 1
    }

    It 'reports a tracked file by its line and rule number, and never prints the matched text or the rule' {
        $root = New-TermsRepo -Files @{ 'docs/page.md' = "# Page`nBuilt for Fabrikam." }
        $terms = New-TermsFile -Lines @('# made-up list', 'Woodgrove', 'Fabrikam')

        $r = Invoke-Check -Root $root -Options @{ TermsFile = $terms }

        $r.Code | Should -Be 1
        $r.Output | Should -Match 'docs/page\.md:2  rule 3'
        $r.Output | Should -Not -Match 'Fabrikam'
        $r.Output | Should -Not -Match 'Woodgrove'
        $r.Output | Should -Match '(?m)^FIX: '
    }

    It 'matches case-sensitively unless the rule starts with (?i)' {
        $root = New-TermsRepo -Files @{ 'docs/page.md' = 'fabrikam in lower case.' }

        (Invoke-Check -Root $root -Options @{ TermsFile = (New-TermsFile -Lines 'Fabrikam') }).Code | Should -Be 0
        (Invoke-Check -Root $root -Options @{ TermsFile = (New-TermsFile -Lines '(?i)Fabrikam') }).Code | Should -Be 1
    }

    It 'reads the list from AISDLC_PRIVATE_TERMS, with the line number in that content' {
        $root = New-TermsRepo -Files @{ 'docs/page.md' = 'A Woodgrove note.' }
        $env:AISDLC_PRIVATE_TERMS = "# list`n`nWoodgrove"

        $r = Invoke-Check -Root $root

        $r.Code | Should -Be 1
        $r.Output | Should -Match 'docs/page\.md:1  rule 3'
    }

    It 'falls back to the list in the knowledge folder' {
        $root = New-TermsRepo -Files @{ 'docs/page.md' = 'A Woodgrove note.' }
        $list = Join-Path $root 'knowledge' 'ai-sdlc' 'private-terms.txt'
        New-Item -ItemType Directory -Path (Split-Path $list -Parent) -Force | Out-Null
        Set-Content -LiteralPath $list -Value 'Woodgrove'

        $r = Invoke-Check -Root $root

        $r.Code | Should -Be 1
        $r.Output | Should -Match 'docs/page\.md:1  rule 1'
    }

    It 'does not report the list file itself when it is tracked in the repository' {
        $root = New-TermsRepo -Config '{ "visibility": "public", "paths": { "privateTermsFile": "config/terms.txt" } }' -Files @{ 'config/terms.txt' = 'Woodgrove' }

        $r = Invoke-Check -Root $root

        $r.Code | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'Private terms OK'
    }

    It 'exits 2 when no list is found, and 1 with -Required' {
        $root = New-TermsRepo

        (Invoke-Check -Root $root).Code | Should -Be 2
        (Invoke-Check -Root $root -Options @{ Required = $true }).Code | Should -Be 1
    }

    It 'reports an invalid rule by its number and exits 2' {
        $root = New-TermsRepo

        $r = Invoke-Check -Root $root -Options @{ TermsFile = (New-TermsFile -Lines @('Woodgrove', '([unclosed')) }

        $r.Code | Should -Be 2
        $r.Output | Should -Match 'rule 2 is not a valid regular expression'
        $r.Output | Should -Not -Match 'unclosed'
    }

    It 'skips a binary file' {
        $root = New-TermsRepo
        [IO.File]::WriteAllBytes((Join-Path $root 'blob.bin'), [byte[]](@(0, 1, 2) + [Text.Encoding]::ASCII.GetBytes('Fabrikam')))
        git -C $root add blob.bin
        git -C $root commit --quiet -m 'binary' --no-verify

        (Invoke-Check -Root $root -Options @{ TermsFile = (New-TermsFile -Lines 'Fabrikam') }).Code | Should -Be 0
    }

    It 'checks a staged new file' {
        $root = New-TermsRepo
        Set-Content -LiteralPath (Join-Path $root 'new.md') -Value 'Fabrikam'
        git -C $root add new.md

        $r = Invoke-Check -Root $root -Options @{ TermsFile = (New-TermsFile -Lines 'Fabrikam') }

        $r.Code | Should -Be 1
        $r.Output | Should -Match 'new\.md:1  rule 1'
    }

    It 'hides a file name that matches a rule' {
        $root = New-TermsRepo -Files @{ 'docs/fabrikam-notes.md' = 'Clean text.' }

        $r = Invoke-Check -Root $root -Options @{ TermsFile = (New-TermsFile -Lines 'fabrikam') }

        $r.Code | Should -Be 1
        $r.Output | Should -Match 'file name hidden'
        $r.Output | Should -Not -Match 'fabrikam'
    }

    It 'checks the commit messages after the base ref' {
        $root = New-TermsRepo
        $base = (git -C $root rev-parse HEAD).Trim()
        Set-Content -LiteralPath (Join-Path $root 'docs/other.md') -Value 'Clean.'
        git -C $root add -A
        git -C $root commit --quiet -m "Add a page`n`nAsked by Woodgrove." --no-verify

        $r = Invoke-Check -Root $root -Options @{ TermsFile = (New-TermsFile -Lines 'Woodgrove'); BaseRef = $base }

        $r.Code | Should -Be 1
        $r.Output | Should -Match 'commit [0-9a-f]+:3  rule 1'
    }

    It 'checks the branch name and the pull request title and description' {
        $root = New-TermsRepo
        $env:PR_SOURCE_BRANCH = '42-woodgrove-fix'
        $env:PR_TITLE = 'Fix for Woodgrove'
        $env:PR_DESCRIPTION = "Fixes #42`nWoodgrove asked."

        $r = Invoke-Check -Root $root -Options @{ TermsFile = (New-TermsFile -Lines '(?i)woodgrove') }

        $r.Code | Should -Be 1
        $r.Output | Should -Match 'the branch name  rule 1'
        $r.Output | Should -Match 'the pull request title  rule 1'
        $r.Output | Should -Match 'the pull request description:2  rule 1'
        $r.Output | Should -Not -Match '(?i)woodgrove'
    }

    It 'checks a repository that GitHub Actions says is public although aisdlc.json says private, and fails on the setting' {
        $root = New-TermsRepo -Visibility private
        Set-GitHubRun -Workspace $root -Private $false -PullRequest

        $r = Invoke-Check -Root $root -Options @{ TermsFile = (New-TermsFile -Lines 'Fabrikam') }

        $r.Code | Should -Be 1 -Because $r.Output
        $r.Output | Should -Not -Match 'skipped'
        $r.Output | Should -Match 'visibility'
        $r.Output | Should -Match '(?m)^FIX: .*"visibility": "public"'
    }

    It 'reports the terms in a repository that GitHub Actions says is public although aisdlc.json says private' {
        $root = New-TermsRepo -Visibility private -Files @{ 'docs/page.md' = 'Built for Fabrikam.' }
        Set-GitHubRun -Workspace $root -Private $false

        $r = Invoke-Check -Root $root -Options @{ TermsFile = (New-TermsFile -Lines 'Fabrikam') }

        $r.Code | Should -Be 1
        $r.Output | Should -Match 'docs/page\.md:1  rule 1'
    }

    It 'fails a public repository in GitHub Actions when no list is found, also without -Required' {
        $root = New-TermsRepo
        Set-GitHubRun -Workspace $root -Private $false -PullRequest

        $r = Invoke-Check -Root $root

        $r.Code | Should -Be 1 -Because $r.Output
        $r.Output | Should -Match 'AISDLC_PRIVATE_TERMS'
    }

    It 'warns on a pull request from a fork that gets no list, and names the run before the merge' {
        $root = New-TermsRepo
        Set-GitHubRun -Workspace $root -Private $false -Fork

        $r = Invoke-Check -Root $root

        $r.Code | Should -Be 2 -Because $r.Output
        $r.Output | Should -Match 'fork'
        $r.Output | Should -Match '(?m)^FIX: .*-Required'
    }

    It 'fails a pull request from a fork with -Required, as AI.SDLC runs it' {
        $root = New-TermsRepo
        Set-GitHubRun -Workspace $root -Private $false -Fork

        (Invoke-Check -Root $root -Options @{ Required = $true }).Code | Should -Be 1
    }

    It 'keeps the old behaviour for a private repository in GitHub Actions' {
        $root = New-TermsRepo -Visibility private
        Set-GitHubRun -Workspace $root -Private $true -PullRequest

        $r = Invoke-Check -Root $root

        $r.Code | Should -Be 0
        $r.Output | Should -Match 'skipped: the repository is private'
    }

    It 'ignores the event file for a folder other than the checked-out repository' {
        $private = New-TermsRepo -Visibility private
        $public = New-TermsRepo
        Set-GitHubRun -Workspace (Join-Path $TestDrive 'other-checkout') -Private $false -PullRequest

        (Invoke-Check -Root $private).Code | Should -Be 0
        (Invoke-Check -Root $public).Code | Should -Be 2
    }

    It 'passes a clean public repository and names the list it read' {
        $root = New-TermsRepo

        $r = Invoke-Check -Root $root -Options @{ TermsFile = (New-TermsFile -Lines 'Fabrikam') }

        $r.Code | Should -Be 0
        $r.Output | Should -Match 'Private terms OK'
    }
}
