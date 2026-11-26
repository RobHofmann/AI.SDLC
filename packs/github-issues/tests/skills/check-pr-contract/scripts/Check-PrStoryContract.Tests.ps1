#requires -Version 7.4

Describe 'Check-PrStoryContract' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Check-PrStoryContract.ps1'

        function New-TestRepo {
            param([string[]]$Accepted = @())
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $root 'docs' 'adrs') -Force | Out-Null
            $config = [ordered]@{
                paths   = [ordered]@{ adrFolder = 'docs/adrs' }
                tracker = [ordered]@{
                    repository           = 'contoso/portal'
                    refinedLabel         = 'refined'
                    dataModelPatterns    = @('Shared.Demo\.(Domain|Data)/.*/Models?/', 'Shared.Demo\.Domain/.*Entit')
                    acceptedRepositories = @($Accepted)
                }
            }
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value ($config | ConvertTo-Json -Depth 5) -Encoding utf8
            return $root
        }

        function New-Issue([int]$Number = 1234, [string]$State = 'OPEN', [string[]]$Labels = @('refined'), [string]$Kind = 'issues') {
            return @{ number = $Number; state = $State; labels = $Labels; url = "https://github.com/contoso/portal/$Kind/$Number" }
        }

        function New-FakeGh {
            param([string]$State = 'OPEN', [string[]]$Labels = @('refined'))
            $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            $log = Join-Path $folder 'gh.log'
            $issue = @{ number = 7; state = $State; url = 'https://github.com/contoso/ai-sdlc/issues/7'; labels = @($Labels | ForEach-Object { @{ name = $_ } }) } | ConvertTo-Json -Compress -Depth 4
            $script = Join-Path $folder 'gh.ps1'
            Set-Content -LiteralPath $script -Value @(
                "Add-Content -LiteralPath '$log' -Value (`$args -join ' ')"
                "Write-Output '$issue'"
                'exit 0'
            )
            return [pscustomobject]@{ Command = $script; Log = $log }
        }

        function Invoke-Gate {
            param([hashtable]$P = @{})
            # Always pin the PR-context inputs and gh unless the case overrides them, so the test never bleeds
            # host env vars (PR_STORY_KEY / PR_SOURCE_BRANCH / CHANGED_FILES) into the gate and never calls GitHub.
            foreach ($name in 'StoryKey', 'SourceBranch', 'PrTitle', 'PrDescription', 'PrNumber', 'ChangedFiles', 'GhToken') {
                if (-not $P.ContainsKey($name)) { $P[$name] = '' }
            }
            if (-not $P.ContainsKey('GhCommand')) { $P['GhCommand'] = 'gh-absent-for-test' }
            if (-not $P.ContainsKey('InCi')) { $P['InCi'] = $false }
            if (-not $P.ContainsKey('RepoRoot')) { $P['RepoRoot'] = New-TestRepo }
            $out = & $script:ScriptUnderTest @P *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }
    }

    It 'is a no-op when there is no PR context (exit 0)' {
        $r = Invoke-Gate @{ StoryKey = ''; SourceBranch = '' }
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'no-op'
    }

    It 'passes an open issue with the refined label' {
        $r = Invoke-Gate @{ StoryKey = '#1234'; IssueForTest = (New-Issue) }
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'dev-active'
    }

    It 'reads a bare number passed in as the issue key' {
        $r = Invoke-Gate @{ StoryKey = '1234'; IssueForTest = (New-Issue) }
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match '#1234'
    }

    It 'passes a closed issue that carries the refined label, because work can follow a closed story' {
        $r = Invoke-Gate @{ StoryKey = '#1234'; IssueForTest = (New-Issue -State 'CLOSED') }
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'dev-active'
    }

    It 'fails a closed issue without the refined label' {
        $r = Invoke-Gate @{ StoryKey = '#1234'; IssueForTest = (New-Issue -State 'CLOSED' -Labels @('to-refine')) }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match "does not carry the 'refined' label"
    }

    It 'fails an open issue without the refined label' {
        $r = Invoke-Gate @{ StoryKey = '#1234'; IssueForTest = (New-Issue -Labels @('to-refine')) }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match "does not carry the 'refined' label"
    }

    It 'uses the refined label named in tracker.refinedLabel' {
        $repo = New-TestRepo
        $config = Get-Content -LiteralPath (Join-Path $repo 'aisdlc.json') -Raw | ConvertFrom-Json -AsHashtable
        $config.tracker.refinedLabel = 'ready'
        Set-Content -LiteralPath (Join-Path $repo 'aisdlc.json') -Value ($config | ConvertTo-Json -Depth 5) -Encoding utf8
        $r = Invoke-Gate @{ RepoRoot = $repo; StoryKey = '#1234'; IssueForTest = (New-Issue -Labels @('ready')) }
        $r.ExitCode | Should -Be 0
    }

    It 'fails a key that names a pull request instead of an issue' {
        $r = Invoke-Gate @{ StoryKey = '#1234'; IssueForTest = (New-Issue -State 'MERGED' -Kind 'pull') }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'is a pull request, not an issue'
    }

    It 'derives the story key from the source branch' {
        $r = Invoke-Gate @{ SourceBranch = 'refs/heads/42-short-name'; IssueForTest = (New-Issue -Number 42) }
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match '#42'
        $r.Output | Should -Match 'read from the PR source branch'
    }

    It 'fails when the source branch carries no story key' {
        $r = Invoke-Gate @{ SourceBranch = 'refs/heads/some-feature' }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'No story key'
    }

    It 'reads the story key from the PR title when the branch carries none' {
        $r = Invoke-Gate @{ SourceBranch = 'refs/heads/some-feature'; PrTitle = '#2891: one reading level for everything we keep'; IssueForTest = (New-Issue -Number 2891) }
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match '#2891'
        $r.Output | Should -Match 'read from the PR title'
    }

    It 'reads the story key from the PR body when title and branch carry none' {
        $r = Invoke-Gate @{ SourceBranch = 'refs/heads/some-feature'; PrTitle = 'One reading level'; PrDescription = "## Summary`nFixes #2891 end to end."; IssueForTest = (New-Issue -Number 2891) }
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'read from the PR body'
    }

    It 'reads the key from the issues the PR closes when no text carries one' {
        $r = Invoke-Gate @{ SourceBranch = 'refs/heads/some-feature'; PrTitle = 'One reading level'; PrNumber = '7'; ClosingIssuesForTest = @('https://github.com/contoso/portal/issues/2891'); IssueForTest = (New-Issue -Number 2891) }
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match '#2891'
        $r.Output | Should -Match 'read from the issues the PR closes'
    }

    It 'refuses a closing issue of another repository that tracker.acceptedRepositories does not list' {
        $r = Invoke-Gate @{ PrNumber = '7'; ClosingIssuesForTest = @('https://github.com/contoso/billing/issues/12'); IssueForTest = (New-Issue -Number 12) }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'contoso/billing#12'
        $r.Output | Should -Match 'tracker\.acceptedRepositories'
    }

    It 'refuses a key of another repository in the title, and reads no issue for it' {
        $gh = New-FakeGh
        $r = Invoke-Gate @{ PrTitle = 'contoso/billing#12: take the change'; GhCommand = $gh.Command }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'belongs to contoso/billing'
        $r.Output | Should -Match 'accepted: none'
        Test-Path -LiteralPath $gh.Log | Should -BeFalse -Because 'a refused repository is never read'
    }

    It 'reads a key of an accepted repository from that repository, and passes a dev-active issue' {
        $gh = New-FakeGh
        $r = Invoke-Gate @{ RepoRoot = (New-TestRepo -Accepted 'contoso/ai-sdlc'); PrTitle = 'contoso/ai-sdlc#7: take the shared AI-SDLC at v1.1.0'; PrDescription = 'Refs contoso/ai-sdlc#7'; GhCommand = $gh.Command }
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'contoso/ai-sdlc#7'
        $r.Output | Should -Match 'in the accepted repository contoso/ai-sdlc'
        (Get-Content -LiteralPath $gh.Log) | Should -Match '^issue view 7 -R contoso/ai-sdlc --json '
    }

    It 'matches an accepted repository without regard to case' {
        $r = Invoke-Gate @{ RepoRoot = (New-TestRepo -Accepted 'Contoso/AI-SDLC'); PrDescription = 'Refs contoso/ai-sdlc#7'; IssueForTest = (New-Issue -Number 7) }
        $r.ExitCode | Should -Be 0 -Because $r.Output
    }

    It 'holds an issue of an accepted repository to the same dev-active rule' {
        $gh = New-FakeGh -Labels @('to-refine')
        $r = Invoke-Gate @{ RepoRoot = (New-TestRepo -Accepted 'contoso/ai-sdlc'); PrDescription = 'Refs contoso/ai-sdlc#7'; GhCommand = $gh.Command }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match "does not carry the 'refined' label"

        $closed = New-FakeGh -State 'CLOSED'
        $r = Invoke-Gate @{ RepoRoot = (New-TestRepo -Accepted 'contoso/ai-sdlc'); PrDescription = 'Refs contoso/ai-sdlc#7'; GhCommand = $closed.Command }
        $r.ExitCode | Should -Be 0 -Because 'a release issue closes at the release, and an update pull request still names it'
    }

    It 'asks a domain-model change with a key of an accepted repository for an ADR with that same key' {
        $repo = New-TestRepo -Accepted 'contoso/ai-sdlc'
        Set-Content -LiteralPath (Join-Path $repo 'docs' 'adrs' '0099-x.md') -Value "---`nstory: `"#7`"`n---`n# ADR 0099`n" -NoNewline
        $model = 'Demo/src/Shared.Demo.Domain/Common/Models/Core/OrderLine.cs'
        $r = Invoke-Gate @{ RepoRoot = $repo; PrDescription = 'Refs contoso/ai-sdlc#7'; IssueForTest = (New-Issue -Number 7); ChangedFiles = $model }
        $r.ExitCode | Should -Be 1 -Because 'issue #7 of this repository is another issue'
        $r.Output | Should -Match 'governing ADR'

        Set-Content -LiteralPath (Join-Path $repo 'docs' 'adrs' '0099-x.md') -Value "---`nstory: `"contoso/ai-sdlc#7`"`n---`n# ADR 0099`n" -NoNewline
        $r = Invoke-Gate @{ RepoRoot = $repo; PrDescription = 'Refs contoso/ai-sdlc#7'; IssueForTest = (New-Issue -Number 7); ChangedFiles = $model }
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'governed by an ADR'
    }

    It 'prefers the branch over the title, so the branch convention still wins' {
        $r = Invoke-Gate @{ SourceBranch = 'refs/heads/42-short-name'; PrTitle = '#99 in the title'; IssueForTest = (New-Issue -Number 42) }
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match '#42'
        $r.Output | Should -Match 'read from the PR source branch'
    }

    It 'prefers an explicit story key over every other source' {
        $r = Invoke-Gate @{ StoryKey = '#7'; SourceBranch = 'refs/heads/42-short-name'; PrTitle = '#99'; IssueForTest = (New-Issue -Number 7) }
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'read from the story key passed in'
    }

    It 'names every place it looked when no source carries a key' {
        $r = Invoke-Gate @{ SourceBranch = 'refs/heads/some-feature'; PrTitle = 'No key here'; PrDescription = 'nor here' }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'the PR title, the PR body and the issues the PR closes'
    }

    It 'does not read a markdown heading or an HTML entity as a key' {
        $r = Invoke-Gate @{ SourceBranch = 'refs/heads/some-feature'; PrDescription = "# Title`nSee &#123; for the entity." }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'No story key'
    }

    It 'stays a no-op when there is no PR context at all, title and body included' {
        $r = Invoke-Gate @{ StoryKey = ''; SourceBranch = ''; PrTitle = ''; PrDescription = ''; PrNumber = '' }
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'no-op'
    }

    It 'blocks (exit 1) when GitHub says no issue has that number' {
        $r = Invoke-Gate @{ StoryKey = '#1234'; IssueErrorForTest = 'GraphQL: Could not resolve to an issue or pull request with the number of 1234. (repository.issue)' }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'does not exist'
    }

    It 'cannot check (exit 2) when the repository cannot be resolved with the token' {
        $r = Invoke-Gate @{ StoryKey = '#1234'; IssueErrorForTest = "GraphQL: Could not resolve to a Repository with the name 'contoso/portal'. (repository)" }
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'no permission rather than no issue'
    }

    It 'cannot check (exit 2) when the credentials themselves do not work' {
        $r = Invoke-Gate @{ StoryKey = '#1234'; IssueErrorForTest = 'HTTP 401: Bad credentials (https://api.github.com/graphql)' }
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'Bad credentials'
        $r.Output | Should -Match 'neither a pass nor a violation'
    }

    It 'cannot check (exit 2) when gh is not installed, rather than failing closed' {
        $r = Invoke-Gate @{ StoryKey = '#1234' }
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'could not be checked at all'
        $r.Output | Should -Match 'not installed'
    }

    It 'cannot check (exit 2) in CI when GH_TOKEN is missing' {
        $r = Invoke-Gate @{ StoryKey = '#1234'; GhCommand = 'pwsh'; InCi = $true; GhToken = '' }
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'GH_TOKEN is not set'
    }

    It 'fails a domain-model change with no governing ADR' {
        $r = Invoke-Gate @{
            StoryKey     = '#1234'
            IssueForTest = (New-Issue)
            ChangedFiles = 'Demo/src/Shared.Demo.Domain/Common/Models/Core/OrderLine.cs'
        }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'governing ADR'
    }

    It 'detects a Shared.Demo.Data model change and fails it with no governing ADR' {
        $r = Invoke-Gate @{
            StoryKey     = '#1234'
            IssueForTest = (New-Issue)
            ChangedFiles = 'Demo/src/Shared.Demo.Data/Common/Models/Membership/OrderLineMembership.cs'
        }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'governing ADR'
    }

    It 'does not accept an unrelated ADR in the diff that does not govern the story' {
        $repo = New-TestRepo
        Set-Content -LiteralPath (Join-Path $repo 'docs' 'adrs' '0099-other.md') -Value "---`nstory: `"#999`"`nphase: governance`n---`n# ADR 0099`n" -NoNewline
        $r = Invoke-Gate @{
            RepoRoot     = $repo
            StoryKey     = '#1234'
            IssueForTest = (New-Issue)
            ChangedFiles = "Demo/src/Shared.Demo.Domain/Common/Models/Core/OrderLine.cs`ndocs/adrs/0099-other.md"
        }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'governing ADR'
    }

    It 'passes a domain-model change when an existing ADR has a matching quoted story' {
        $repo = New-TestRepo
        Set-Content -LiteralPath (Join-Path $repo 'docs' 'adrs' '0099-x.md') -Value "---`nstory: `"#1234`"`nphase: governance`n---`n# ADR 0099`n" -NoNewline
        $r = Invoke-Gate @{
            RepoRoot     = $repo
            StoryKey     = '#1234'
            IssueForTest = (New-Issue)
            ChangedFiles = 'Demo/src/Shared.Demo.Domain/Common/Models/Core/OrderLine.cs'
        }
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'governed by an ADR'
    }

    It 'treats an unquoted number in the ADR story as the same key' {
        $repo = New-TestRepo
        Set-Content -LiteralPath (Join-Path $repo 'docs' 'adrs' '0099-x.md') -Value "---`nstory: 1234`n---`n# ADR 0099`n" -NoNewline
        $r = Invoke-Gate @{
            RepoRoot     = $repo
            StoryKey     = '#1234'
            IssueForTest = (New-Issue)
            ChangedFiles = 'Demo/src/Shared.Demo.Domain/Common/Models/Core/OrderLine.cs'
        }
        $r.ExitCode | Should -Be 0
    }

    It 'treats a key of the tracker repository in the ADR story as the same key' {
        $repo = New-TestRepo
        Set-Content -LiteralPath (Join-Path $repo 'docs' 'adrs' '0099-x.md') -Value "---`nstory: `"contoso/portal#1234`"`n---`n# ADR 0099`n" -NoNewline
        $r = Invoke-Gate @{
            RepoRoot     = $repo
            StoryKey     = '#1234'
            IssueForTest = (New-Issue)
            ChangedFiles = 'Demo/src/Shared.Demo.Domain/Common/Models/Core/OrderLine.cs'
        }
        $r.ExitCode | Should -Be 0
    }

    It 'rejects an ADR story value that is not a story key, and names it' {
        $repo = New-TestRepo
        Set-Content -LiteralPath (Join-Path $repo 'docs' 'adrs' '0099-x.md') -Value "---`nstory: `"see #1234`"`n---`n# ADR 0099`n" -NoNewline
        $r = Invoke-Gate @{
            RepoRoot     = $repo
            StoryKey     = '#1234'
            IssueForTest = (New-Issue)
            ChangedFiles = 'Demo/src/Shared.Demo.Domain/Common/Models/Core/OrderLine.cs'
        }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match "not a story key: 0099-x.md \('see #1234'\)"
    }

    It 'reports an unquoted # in the ADR story as the comment trap, with a FIX line' {
        $repo = New-TestRepo
        Set-Content -LiteralPath (Join-Path $repo 'docs' 'adrs' '0099-x.md') -Value "---`nstory: #1234`n---`n# ADR 0099`n" -NoNewline
        $r = Invoke-Gate @{
            RepoRoot     = $repo
            StoryKey     = '#1234'
            IssueForTest = (New-Issue)
            ChangedFiles = 'Demo/src/Shared.Demo.Domain/Common/Models/Core/OrderLine.cs'
        }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match "empty 'story:' value: 0099-x.md"
        $r.Output | Should -Match 'FIX: Quote the key'
    }
}
