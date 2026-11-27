#requires -Version 7.4

BeforeAll { $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm' }

Describe 'Check-PrStoryContract' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $script:ScriptFolder -ChildPath 'Check-PrStoryContract.ps1'

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

    It 'is not applicable when there is no PR context (exit 3)' -Tag '#46' {
        $r = Invoke-Gate @{ StoryKey = ''; SourceBranch = '' }
        $r.ExitCode | Should -Be 3
        $r.Output | Should -Match 'not applicable'
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
        $model = "Demo/src/Shared.Demo.Domain/Common/Models/Core/OrderLine.cs`ndocs/adrs/0099-x.md"
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

    It 'stays not applicable when there is no PR context at all, title and body included' {
        $r = Invoke-Gate @{ StoryKey = ''; SourceBranch = ''; PrTitle = ''; PrDescription = ''; PrNumber = '' }
        $r.ExitCode | Should -Be 3
        $r.Output | Should -Match 'not applicable'
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
        $r.Output | Should -Match '(?m)^FIX: \S'
        $r.Output | Should -Not -Match '::warning::'
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

    It 'does not count an older ADR of the same story that the PR leaves alone' {
        $repo = New-TestRepo
        Set-Content -LiteralPath (Join-Path $repo 'docs' 'adrs' '0050-older.md') -Value "---`nstory: `"#1234`"`n---`n# ADR 0050`n" -NoNewline
        $r = Invoke-Gate @{
            RepoRoot     = $repo
            StoryKey     = '#1234'
            IssueForTest = (New-Issue)
            ChangedFiles = 'Demo/src/Shared.Demo.Domain/Common/Models/Core/OrderLine.cs'
        }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'governing ADR'
        $r.Output | Should -Match 'older ADR of the same story does not govern this change'
    }

    It 'counts an ADR that the PR changes, also when the list uses backslashes' {
        $repo = New-TestRepo
        Set-Content -LiteralPath (Join-Path $repo 'docs' 'adrs' '0050-older.md') -Value "---`nstory: `"#1234`"`n---`n# ADR 0050`n" -NoNewline
        $r = Invoke-Gate @{
            RepoRoot     = $repo
            StoryKey     = '#1234'
            IssueForTest = (New-Issue)
            ChangedFiles = "Demo/src/Shared.Demo.Domain/Common/Models/Core/OrderLine.cs`r`ndocs\adrs\0050-older.md"
        }
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'governed by an ADR'
    }

    It 'does not count a changed ADR that the PR deletes' {
        $repo = New-TestRepo
        $r = Invoke-Gate @{
            RepoRoot     = $repo
            StoryKey     = '#1234'
            IssueForTest = (New-Issue)
            ChangedFiles = "Demo/src/Shared.Demo.Domain/Common/Models/Core/OrderLine.cs`ndocs/adrs/0060-deleted.md"
        }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'governing ADR'
    }

    It 'does not count a changed file outside the ADR folder that carries the story' {
        $repo = New-TestRepo
        New-Item -ItemType Directory -Path (Join-Path $repo 'docs' 'other') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'docs' 'other' '0070-x.md') -Value "---`nstory: `"#1234`"`n---`n# Not an ADR`n" -NoNewline
        $r = Invoke-Gate @{
            RepoRoot     = $repo
            StoryKey     = '#1234'
            IssueForTest = (New-Issue)
            ChangedFiles = "Demo/src/Shared.Demo.Domain/Common/Models/Core/OrderLine.cs`ndocs/other/0070-x.md"
        }
        $r.ExitCode | Should -Be 1
    }

    It 'passes a domain-model change when an ADR that the PR adds has a matching quoted story' {
        $repo = New-TestRepo
        Set-Content -LiteralPath (Join-Path $repo 'docs' 'adrs' '0099-x.md') -Value "---`nstory: `"#1234`"`nphase: governance`n---`n# ADR 0099`n" -NoNewline
        $r = Invoke-Gate @{
            RepoRoot     = $repo
            StoryKey     = '#1234'
            IssueForTest = (New-Issue)
            ChangedFiles = "Demo/src/Shared.Demo.Domain/Common/Models/Core/OrderLine.cs`ndocs/adrs/0099-x.md"
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
            ChangedFiles = "Demo/src/Shared.Demo.Domain/Common/Models/Core/OrderLine.cs`ndocs/adrs/0099-x.md"
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
            ChangedFiles = "Demo/src/Shared.Demo.Domain/Common/Models/Core/OrderLine.cs`ndocs/adrs/0099-x.md"
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
            ChangedFiles = "Demo/src/Shared.Demo.Domain/Common/Models/Core/OrderLine.cs`ndocs/adrs/0099-x.md"
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
            ChangedFiles = "Demo/src/Shared.Demo.Domain/Common/Models/Core/OrderLine.cs`ndocs/adrs/0099-x.md"
        }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match "empty 'story:' value: 0099-x.md"
        $r.Output | Should -Match 'FIX: Quote the key'
    }

    Context 'No-ADR waiver' {
        BeforeAll {
            $script:ModelFile = 'Demo/src/Shared.Demo.Domain/Common/Models/Core/OrderLine.cs'

            function New-WaiverRepo {
                $repo = New-TestRepo
                & git -C $repo init --quiet -b main
                & git -C $repo add .
                & git -C $repo -c user.name=Test -c user.email=test@example.com commit --quiet -m 'base'
                & git -C $repo tag base
                return $repo
            }

            function Add-WaiverCommit {
                param([string]$Repo, [string]$Trailer, [string]$Name = $script:ModelFile)
                $path = Join-Path $Repo $Name
                New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
                [IO.File]::WriteAllText($path, [guid]::NewGuid().ToString(), [Text.UTF8Encoding]::new($false))
                $message = "change`n`nBody paragraph.`n"
                if ($Trailer) { $message += "`n$Trailer`n" }
                $messageFile = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.txt')
                [IO.File]::WriteAllText($messageFile, $message, [Text.UTF8Encoding]::new($false))
                & git -C $Repo add -A
                & git -C $Repo -c user.name=Test -c user.email=test@example.com commit --quiet --cleanup=verbatim -F $messageFile
            }

            function Invoke-WaiverGate([string]$Repo, [hashtable]$Extra = @{}) {
                $p = @{ RepoRoot = $Repo; StoryKey = '#1234'; IssueForTest = (New-Issue); ChangedFiles = $script:ModelFile; BaseRef = 'base' }
                foreach ($name in $Extra.Keys) { $p[$name] = $Extra[$name] }
                return Invoke-Gate $p
            }
        }

        It 'passes a data-model change with no ADR when a commit carries a No-ADR trailer, and prints the waiver' -Tag '#60' {
            $repo = New-WaiverRepo
            Add-WaiverCommit -Repo $repo -Trailer 'No-ADR: a field rename that no reader sees'
            $sha = (& git -C $repo rev-parse HEAD).Substring(0, 12)
            $r = Invoke-WaiverGate $repo
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match ([regex]::Escape("Waiver used: No-ADR: a field rename that no reader sees (commit $sha)"))
        }

        It 'reads the trailer key in any case and from an earlier commit of the pull request' -Tag '#60' {
            $repo = New-WaiverRepo
            Add-WaiverCommit -Repo $repo -Trailer 'no-adr: easy to undo'
            Add-WaiverCommit -Repo $repo -Name 'README.md'
            (Invoke-WaiverGate $repo).ExitCode | Should -Be 0
        }

        It 'fails a data-model change when no commit carries a No-ADR trailer' -Tag '#60' {
            $repo = New-WaiverRepo
            Add-WaiverCommit -Repo $repo
            $r = Invoke-WaiverGate $repo
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'governing ADR'
            $r.Output | Should -Match 'No-ADR'
        }

        It 'clears nothing for a trailer with <Name>' -Tag '#60' -ForEach @(
            @{ Name = 'an empty why'; Trailer = 'No-ADR:'; Cause = 'gives no why' }
            @{ Name = 'a control character'; Trailer = "No-ADR: bad$([char]1)text"; Cause = 'control character' }
            @{ Name = 'a unicode line separator'; Trailer = "No-ADR: bad$([char]0x2028)text"; Cause = 'control character' }
        ) {
            $repo = New-WaiverRepo
            Add-WaiverCommit -Repo $repo -Trailer $Trailer
            $r = Invoke-WaiverGate $repo
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'governing ADR'
            $r.Output | Should -Match 'Waiver not used: '
            $r.Output | Should -Match ([regex]::Escape($Cause))
        }

        It 'does not read a trailer of a commit before the base' -Tag '#60' {
            $repo = New-TestRepo
            & git -C $repo init --quiet -b main
            & git -C $repo add .
            & git -C $repo -c user.name=Test -c user.email=test@example.com commit --quiet -m 'base'
            Add-WaiverCommit -Repo $repo -Trailer 'No-ADR: an old reason'
            & git -C $repo tag base
            Add-WaiverCommit -Repo $repo
            $r = Invoke-WaiverGate $repo
            $r.ExitCode | Should -Be 1
        }

        It 'takes the base from PR_BASE_SHA when it is set' -Tag '#60' {
            $repo = New-WaiverRepo
            $baseSha = (& git -C $repo rev-parse HEAD)
            Add-WaiverCommit -Repo $repo -Trailer 'No-ADR: easy to undo'
            $saved = $env:PR_BASE_SHA
            try {
                $env:PR_BASE_SHA = $baseSha
                $r = Invoke-WaiverGate $repo @{ BaseRef = '' }
            }
            finally { $env:PR_BASE_SHA = $saved }
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'Waiver used: No-ADR: easy to undo'
        }

        It 'applies no waiver when git cannot read a base' -Tag '#60' {
            $repo = New-WaiverRepo
            Add-WaiverCommit -Repo $repo -Trailer 'No-ADR: easy to undo'
            $r = Invoke-WaiverGate $repo @{ BaseRef = 'no-such-ref' }
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'governing ADR'
        }
    }
}
