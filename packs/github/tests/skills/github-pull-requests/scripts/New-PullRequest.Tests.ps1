#requires -Version 7.4

BeforeAll { $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm' }

Describe 'New-PullRequest' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $script:ScriptFolder -ChildPath 'New-PullRequest.ps1'

        function Invoke-Helper {
            param([hashtable]$Parameters)
            if (-not $Parameters.ContainsKey('Repository')) { $Parameters['Repository'] = 'contoso/portal' }
            return (& $script:ScriptUnderTest @Parameters)
        }

        # A fake gh that echoes the body file it last received, so the read-back matches what was sent.
        # -ViewBody changes what the read-back shows; it receives the state and returns the body text.
        function New-Invoker {
            param(
                [hashtable]$State,
                [int]$Number = 101,
                [scriptblock]$ViewBody,
                [bool]$IsDraft = $true,
                [switch]$FailReviewer
            )
            $State.Views = 0; $State.Edits = 0; $State.Body = $null; $State.CreateArgs = $null
            $State.ViewArgs = $null; $State.EditArgs = $null; $State.ReviewerArgs = $null; $State.Calls = [System.Collections.Generic.List[string]]::new()
            return {
                param($ghArgs)
                $State.Calls.Add(([string[]]$ghArgs) -join ' ')
                if ($ghArgs[0] -eq 'api') { return '[]' }
                if ($ghArgs[1] -eq 'create') {
                    $State.CreateArgs = [string[]]$ghArgs
                    $State.Body = Get-Content -LiteralPath $ghArgs[[array]::IndexOf($ghArgs, '--body-file') + 1] -Raw
                    return "https://github.com/contoso/portal/pull/$Number`n"
                }
                if ($ghArgs[1] -eq 'edit' -and $ghArgs -contains '--add-reviewer') {
                    $State.ReviewerArgs = [string[]]$ghArgs
                    if ($FailReviewer) { throw 'reviewer refused' }
                    return ''
                }
                if ($ghArgs[1] -eq 'edit') {
                    $State.Edits++
                    $State.EditArgs = [string[]]$ghArgs
                    $State.Body = Get-Content -LiteralPath $ghArgs[[array]::IndexOf($ghArgs, '--body-file') + 1] -Raw
                    return ''
                }
                $State.Views++
                $State.ViewArgs = [string[]]$ghArgs
                $body = if ($ViewBody) { & $ViewBody $State } else { $State.Body }
                return ([ordered]@{ number = $Number; url = "https://github.com/contoso/portal/pull/$Number"; title = 'T'; body = $body; isDraft = $IsDraft } | ConvertTo-Json)
            }.GetNewClosure()
        }
    }

    It 'creates the pull request with gh pr create, the base, the head, the title and a body file' {
        $state = @{}
        $invoker = New-Invoker -State $state

        Invoke-Helper -Parameters @{
            Title = 'T'; Description = "## Summary`n`n- one`n- two"
            SourceBranch = 'refs/heads/42-short-name'; TargetBranch = 'main'; GhInvoker = $invoker
        } | Out-Null

        $state.CreateArgs[0..1] | Should -Be @('pr', 'create')
        $state.CreateArgs | Should -Contain '--repo'
        $state.CreateArgs[[array]::IndexOf($state.CreateArgs, '--head') + 1] | Should -Be '42-short-name'
        $state.CreateArgs[[array]::IndexOf($state.CreateArgs, '--base') + 1] | Should -Be 'main'
        $state.CreateArgs | Should -Not -Contain '--body'
        @($state.Body -split "`n")[-4..-1] | Should -Be @('## Summary', '', '- one', '- two')
    }

    It 'always creates a draft' {
        $state = @{}
        Invoke-Helper -Parameters @{ Title = 'T'; Description = 'body text'; SourceBranch = '42-x'; GhInvoker = (New-Invoker -State $state) } | Out-Null

        $state.CreateArgs | Should -Contain '--draft'
    }

    It 'starts the body file with the Before you publish block, once, then the description' {
        $state = @{}
        Invoke-Helper -Parameters @{ Title = 'T'; Description = "## Summary`n`nbody text"; SourceBranch = '42-x'; GhInvoker = (New-Invoker -State $state) } | Out-Null

        $state.Body | Should -BeLike '## Before you publish*'
        $state.Body | Should -BeLike "*click Ready for review.`n`n## Summary`n`nbody text"
        ([regex]::Matches($state.Body, '## Before you publish')).Count | Should -Be 1
    }

    It 'asks gh for the isDraft field in the read-back' {
        $state = @{}
        Invoke-Helper -Parameters @{ Title = 'T'; Description = 'body text'; SourceBranch = '42-x'; GhInvoker = (New-Invoker -State $state) } | Out-Null

        $state.ViewArgs[[array]::IndexOf($state.ViewArgs, '--json') + 1] | Should -Be 'number,url,title,body,isDraft'
    }

    It 'strips leaked here-string delimiter lines (@) from the start and end of the description' {
        $state = @{}
        Invoke-Helper -Parameters @{
            Title = 'T'; Description = "@`n## Summary`n`n* one`n@"
            SourceBranch = '42-x'; GhInvoker = (New-Invoker -State $state)
        } 3>$null | Out-Null

        @($state.Body -split "`n")[-3..-1] | Should -Be @('## Summary', '', '* one')
        $state.Body | Should -Not -Match '(?m)^@$'
    }

    It 'accepts a description line that begins with a dash' {
        $state = @{}
        { Invoke-Helper -Parameters @{
                Title = 'T'; Description = "## Summary`n- a bullet"
                SourceBranch = '42-x'; GhInvoker = (New-Invoker -State $state)
            } } | Should -Not -Throw
    }

    It 'refuses an empty or whitespace-only description, though the block would make it non-empty' {
        $state = @{}
        { Invoke-Helper -Parameters @{
                Title = 'T'; Description = "   `n  "
                SourceBranch = '42-x'; GhInvoker = (New-Invoker -State $state)
            } } | Should -Throw '*empty or whitespace-only*'
        $state.CreateArgs | Should -BeNullOrEmpty
    }

    It 'succeeds and returns the PR when the read-back is intact' {
        $full = "## Summary`n`nbody line one`nbody line two"
        $state = @{}

        $pr = Invoke-Helper -Parameters @{
            Title = 'T'; Description = $full
            SourceBranch = '42-x'; GhInvoker = (New-Invoker -State $state -Number 202)
        }

        $pr.number | Should -Be 202
        $pr.url | Should -Be 'https://github.com/contoso/portal/pull/202'
        $pr.body | Should -BeLike '## Before you publish*'
        $pr.body | Should -BeLike "*$full"
    }

    It 'reads back the number that gh pr create printed' {
        $state = @{}

        Invoke-Helper -Parameters @{ Title = 'T'; Description = 'body text'; SourceBranch = '42-x'; GhInvoker = (New-Invoker -State $state -Number 303) } | Out-Null

        $state.ViewArgs[0..2] | Should -Be @('pr', 'view', '303')
        $state.ViewArgs | Should -Contain '--json'
    }

    It 'accepts a read-back a few characters shorter than expected from benign normalization' {
        $state = @{}
        $invoker = New-Invoker -State $state -Number 505 -ViewBody { param($s) $s.Body -replace 'AB$', '' }

        $pr = Invoke-Helper -Parameters @{
            Title = 'T'; Description = "## Summary`n`nDescription body content AB"
            SourceBranch = '42-x'; GhInvoker = $invoker
        }

        $pr.number | Should -Be 505
        $state.Edits | Should -Be 0
    }

    It 'issues one corrective edit when the first read-back is truncated, then succeeds' {
        $full = "## Summary`n`nfull body content here"
        $state = @{}
        $invoker = New-Invoker -State $state -Number 303 -ViewBody { param($s) if ($s.Views -eq 1) { '## Summary' } else { $s.Body } }

        $pr = Invoke-Helper -Parameters @{
            Title = 'T'; Description = $full
            SourceBranch = '42-x'; GhInvoker = $invoker
        } 3>$null

        $state.EditArgs[0..2] | Should -Be @('pr', 'edit', '303')
        $state.EditArgs | Should -Contain '--body-file'
        $state.Edits | Should -Be 1
        $pr.body | Should -BeLike "*$full"
    }

    It 'throws when the description is still truncated after a corrective edit' {
        $state = @{}
        $invoker = New-Invoker -State $state -Number 404 -ViewBody { param($s) '## Summary' }

        { Invoke-Helper -Parameters @{
                Title = 'T'; Description = "## Summary`n`na much longer body that should survive"
                SourceBranch = '42-x'; GhInvoker = $invoker
            } 3>$null } | Should -Throw '*truncated after a corrective update*'
    }

    It 'passes the description as a file, keeps blank lines and quotes, and removes the file after the call' {
        $description = "## Summary`n`nnot the old `">= 80%`" rule`n`n* one"
        $state = @{}
        $inner = New-Invoker -State $state -Number 606
        $invoker = {
            param($ghArgs)
            if ($ghArgs[1] -eq 'create') { $state.Path = $ghArgs[[array]::IndexOf($ghArgs, '--body-file') + 1] }
            return (& $inner $ghArgs)
        }.GetNewClosure()

        Invoke-Helper -Parameters @{
            Title = 'T'; Description = $description
            SourceBranch = '42-x'; GhInvoker = $invoker
        } | Out-Null

        $state.Body | Should -BeLike '## Before you publish*'
        $state.Body | Should -BeLike "*$description"
        Test-Path -LiteralPath $state.Path | Should -BeFalse
    }

    It 'issues a corrective edit when the read-back lost its blank lines, though no text is missing' {
        $state = @{}
        $invoker = New-Invoker -State $state -Number 707 -ViewBody {
            param($s)
            if ($s.Views -eq 1) { (($s.Body -split "`n") | Where-Object { $_ -ne '' }) -join "`n" } else { $s.Body }
        }

        $pr = Invoke-Helper -Parameters @{
            Title = 'T'; Description = "## Summary`n`nbody one`n`nbody two"
            SourceBranch = '42-x'; GhInvoker = $invoker
        } 3>$null

        $state.Edits | Should -Be 1
        $pr.body | Should -BeLike "*## Summary`n`nbody one`n`nbody two"
    }

    It 'refuses a description over 65536 characters before any gh call' {
        $state = @{}
        $invoker = New-Invoker -State $state
        { Invoke-Helper -Parameters @{
                Title = 'T'; Description = ('x' * 65537)
                SourceBranch = '42-x'; GhInvoker = $invoker
            } } | Should -Throw '*rejects more than 65536*'
        $state.Calls.Count | Should -Be 0
    }

    It 'reminds the caller to add the Fixes line when the branch names an issue and the description does not' {
        $state = @{}

        $out = Invoke-Helper -Parameters @{ Title = 'T'; Description = 'body text'; SourceBranch = '42-x'; GhInvoker = (New-Invoker -State $state) } 6>&1 | Out-String

        $out | Should -Match "does not say 'Fixes #42'"
    }

    It 'gives no Fixes reminder when the description links the issue' {
        $state = @{}

        $out = Invoke-Helper -Parameters @{ Title = 'T'; Description = "body text`n`nFixes #42"; SourceBranch = '42-x'; GhInvoker = (New-Invoker -State $state) } 6>&1 | Out-String

        $out | Should -Not -Match 'does not say'
    }

    It 'requests a Copilot review after the create, with --add-reviewer @copilot' {
        $state = @{}

        Invoke-Helper -Parameters @{ Title = 'T'; Description = 'body text'; SourceBranch = '42-x'; GhInvoker = (New-Invoker -State $state -Number 808) } 6>$null | Out-Null

        $state.ReviewerArgs[0..2] | Should -Be @('pr', 'edit', '808')
        $state.ReviewerArgs[[array]::IndexOf($state.ReviewerArgs, '--add-reviewer') + 1] | Should -Be '@copilot'
        $state.ReviewerArgs[[array]::IndexOf($state.ReviewerArgs, '--repo') + 1] | Should -Be 'contoso/portal'
        $createIndex = $state.Calls.FindIndex({ param($c) $c -like 'pr create*' })
        $reviewIndex = $state.Calls.FindIndex({ param($c) $c -like '*--add-reviewer*' })
        $reviewIndex | Should -BeGreaterThan $createIndex
    }

    It 'adds the Copilot result to the returned object and keeps number and url' {
        $state = @{}

        $pr = Invoke-Helper -Parameters @{ Title = 'T'; Description = 'body text'; SourceBranch = '42-x'; GhInvoker = (New-Invoker -State $state -Number 809) } 6>$null

        $pr.number | Should -Be 809
        $pr.CopilotReview.Requested | Should -BeTrue
        $pr.CopilotReview.Reason | Should -Be 'forced'
    }

    It 'does not request a Copilot review with -SkipCopilotReview' {
        $state = @{}

        Invoke-Helper -Parameters @{ Title = 'T'; Description = 'body text'; SourceBranch = '42-x'; SkipCopilotReview = $true; GhInvoker = (New-Invoker -State $state) } | Out-Null

        $state.ReviewerArgs | Should -BeNullOrEmpty
        @($state.Calls | Where-Object { $_ -like 'api*' }).Count | Should -Be 0
    }

    It 'still returns the pull request when the Copilot request fails' {
        $state = @{}

        $pr = Invoke-Helper -Parameters @{ Title = 'T'; Description = 'body text'; SourceBranch = '42-x'; GhInvoker = (New-Invoker -State $state -Number 810 -FailReviewer) } 3>$null 6>$null

        $pr.number | Should -Be 810
        $pr.CopilotReview.Requested | Should -BeFalse
    }
}
