#requires -Version 7.4

BeforeAll { $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm' }

Describe 'Update-PullRequest' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $script:ScriptFolder -ChildPath 'Update-PullRequest.ps1'
        $script:BlockHeading = '## Before you publish'

        function Invoke-Helper {
            param([hashtable]$Parameters)
            if (-not $Parameters.ContainsKey('Repository')) { $Parameters['Repository'] = 'contoso/portal' }
            return (& $script:ScriptUnderTest @Parameters)
        }

        function global:ConvertTo-Recorded {
            param([object[]]$GhArgs)
            $list = [System.Collections.Generic.List[string]]::new()
            for ($i = 0; $i -lt $GhArgs.Count; $i++) {
                $list.Add([string]$GhArgs[$i])
                if ($GhArgs[$i] -eq '--body-file') {
                    foreach ($line in ((Get-Content -LiteralPath $GhArgs[$i + 1] -Raw) -split "`n")) { $list.Add($line) }
                    $i++
                }
            }
            return [string[]]$list
        }

        # A fake gh. The read-back echoes the last body file an edit received, so it matches what was sent.
        # It starts with an old body. -ViewBody changes what the read-back shows; it receives the state.
        function New-Invoker {
            param([hashtable]$State, [string]$Title = 'T', [bool]$IsDraft = $true, [scriptblock]$ViewBody)
            $State.Edits = [System.Collections.Generic.List[object]]::new()
            $State.EditCount = 0
            $State.Calls = [System.Collections.Generic.List[string]]::new()
            $State.Body = 'old body'
            return {
                param($ghArgs)
                $State.Calls.Add(([string[]]$ghArgs) -join ' ')
                if ($ghArgs[1] -eq 'edit') {
                    $State.Edits.Add((ConvertTo-Recorded -GhArgs $ghArgs))
                    $State.EditCount++
                    $index = [array]::IndexOf($ghArgs, '--body-file')
                    if ($index -ge 0) { $State.Body = Get-Content -LiteralPath $ghArgs[$index + 1] -Raw }
                    return ''
                }
                $body = if ($ViewBody) { & $ViewBody $State } else { $State.Body }
                return ([ordered]@{ number = 7; title = $Title; body = $body; isDraft = $IsDraft } | ConvertTo-Json)
            }.GetNewClosure()
        }
    }

    AfterAll {
        Remove-Item -Path Function:\ConvertTo-Recorded -ErrorAction SilentlyContinue
    }

    It 'passes only the repository, the title and the description to gh pr edit' {
        $state = @{}
        Invoke-Helper -Parameters @{ Id = 7; Title = 'T'; Description = "## Summary`n`n* one"; GhInvoker = (New-Invoker -State $state) } | Out-Null

        $state.Edits[0][0..2] | Should -Be @('pr', 'edit', '7')
        $options = @($state.Edits[0] | Where-Object { $_ -like '--*' })
        $options | Should -Be @('--repo', '--title', '--body-file')
    }

    It 'passes a multi-line description as one body file' {
        $state = @{}
        Invoke-Helper -Parameters @{ Id = 7; Description = "## Summary`n`n* one"; GhInvoker = (New-Invoker -State $state -IsDraft $false) } | Out-Null

        $args0 = $state.Edits[0]
        $idx = [array]::IndexOf($args0, '--body-file')
        $args0[($idx + 1)..($args0.Length - 1)] | Should -Be @('## Summary', '', '* one')
        $args0 | Should -Not -Contain '--title'
    }

    It 'reads the pull request before the edit when a description is passed' {
        $state = @{}
        Invoke-Helper -Parameters @{ Id = 7; Description = 'new text'; GhInvoker = (New-Invoker -State $state) } | Out-Null

        $state.Calls[0] | Should -BeLike 'pr view 7 *--json number,url,title,body,isDraft'
        $state.Calls[1] | Should -BeLike 'pr edit 7 *'
    }

    It 'puts the Before you publish block at the top of the description of a draft' {
        $state = @{}
        Invoke-Helper -Parameters @{ Id = 7; Description = "## Summary`n`n* one"; GhInvoker = (New-Invoker -State $state -IsDraft $true) } | Out-Null

        $state.Body | Should -BeLike "$($script:BlockHeading)*"
        $state.Body | Should -BeLike "*click Ready for review.`n`n## Summary`n`n* one"
    }

    It 'holds the block exactly once on a draft, even when the given description already holds it' {
        $state = @{}
        Invoke-Helper -Parameters @{ Id = 7; Description = "## Summary`n`n* one"; GhInvoker = (New-Invoker -State $state -IsDraft $true) } | Out-Null
        $first = $state.Body

        Invoke-Helper -Parameters @{ Id = 7; Description = ($first + "`n`n* more"); GhInvoker = (New-Invoker -State $state -IsDraft $true) } | Out-Null

        ([regex]::Matches($state.Body, [regex]::Escape($script:BlockHeading))).Count | Should -Be 1
        $state.Body | Should -BeLike "$($script:BlockHeading)*"
        $state.Body | Should -BeLike '*## Summary*'
    }

    It 'passes the description as given on a published pull request' {
        $state = @{}
        Invoke-Helper -Parameters @{ Id = 7; Description = "## Summary`n`n* one"; GhInvoker = (New-Invoker -State $state -IsDraft $false) } | Out-Null

        $state.Body | Should -BeExactly "## Summary`n`n* one"
        $state.Body | Should -Not -BeLike "*$($script:BlockHeading)*"
    }

    It 'never passes a draft or ready flag to gh' {
        $state = @{}
        Invoke-Helper -Parameters @{ Id = 7; Title = 'T'; Description = 'new text'; GhInvoker = (New-Invoker -State $state -IsDraft $true) } | Out-Null

        @($state.Calls | Where-Object { $_ -match '--draft|--ready|pr ready' }).Count | Should -Be 0
    }

    It 'changes the title alone and keeps the description' {
        $state = @{}
        $pr = Invoke-Helper -Parameters @{ Id = 7; Title = 'Show the owner'; GhInvoker = (New-Invoker -State $state -Title 'Show the owner') }

        $state.Edits[0] | Should -Not -Contain '--body-file'
        $pr.title | Should -Be 'Show the owner'
    }

    It 'refuses a call with nothing to change' {
        { Invoke-Helper -Parameters @{ Id = 7; GhInvoker = { '{}' } } } | Should -Throw '*Nothing to change*'
    }

    It 'refuses a description over 65536 characters and never edits' {
        $state = @{}
        { Invoke-Helper -Parameters @{ Id = 7; Description = ('x' * 65537); GhInvoker = (New-Invoker -State $state) } } | Should -Throw '*rejects more than 65536*'
        $state.Edits.Count | Should -Be 0
    }

    It 'refuses an empty or whitespace-only description on a draft, though the block would make it non-empty' {
        $state = @{}
        { Invoke-Helper -Parameters @{ Id = 7; Description = "  `n "; GhInvoker = (New-Invoker -State $state -IsDraft $true) } } | Should -Throw '*empty or whitespace-only*'
        $state.Edits.Count | Should -Be 0
    }

    It 'accepts a description line that starts with a dash' {
        $state = @{}
        { Invoke-Helper -Parameters @{ Id = 7; Description = "## Summary`n- a bullet"; GhInvoker = (New-Invoker -State $state) } } | Should -Not -Throw
        $state.Edits.Count | Should -Be 1
    }

    It 'refuses a title that starts with a dash or holds a line break' {
        { Invoke-Helper -Parameters @{ Id = 7; Title = '-bad'; GhInvoker = { '{}' } } } | Should -Throw '*option flag*'
        { Invoke-Helper -Parameters @{ Id = 7; Title = "one`ntwo"; GhInvoker = { '{}' } } } | Should -Throw '*one line*'
    }

    It 'makes one corrective call when the description reads back cut off, then succeeds' {
        $state = @{}
        $invoker = New-Invoker -State $state -ViewBody { param($s) if ($s.EditCount -eq 1) { '## Summary' } else { $s.Body } }

        $pr = Invoke-Helper -Parameters @{ Id = 7; Description = "## Summary`n`nthe full body is here"; GhInvoker = $invoker } 3>$null
        $state.Edits.Count | Should -Be 2
        $pr.body | Should -BeLike "*## Summary`n`nthe full body is here"
    }

    It 'throws when the description is still cut off after the corrective call' {
        $state = @{}
        $invoker = New-Invoker -State $state -ViewBody { param($s) if ($s.EditCount -ge 1) { '## Summary' } else { $s.Body } }
        { Invoke-Helper -Parameters @{ Id = 7; Description = "## Summary`n`na much longer body that must survive"; GhInvoker = $invoker } 3>$null } |
            Should -Throw '*truncated after a corrective update*'
    }

    It 'throws when the title does not read back as sent' {
        $invoker = { param($ghArgs) if ($ghArgs[1] -eq 'edit') { return '' }; return ([ordered]@{ number = 7; title = 'old'; body = 'x' } | ConvertTo-Json) }
        { Invoke-Helper -Parameters @{ Id = 7; Title = 'new'; GhInvoker = $invoker } } | Should -Throw "*read back as 'old'*"
    }

    It 'passes the description as a file that keeps blank lines and quotes, and removes it after the call' {
        $description = "## Summary`n`nsay `"yes`" > no`n`n* one"
        $state = @{}
        $inner = New-Invoker -State $state -IsDraft $false
        $invoker = {
            param($ghArgs)
            if ($ghArgs[1] -eq 'edit') { $state.Path = $ghArgs[[array]::IndexOf($ghArgs, '--body-file') + 1] }
            return (& $inner $ghArgs)
        }.GetNewClosure()

        Invoke-Helper -Parameters @{ Id = 7; Description = $description; GhInvoker = $invoker } | Out-Null

        $state.Body | Should -BeExactly $description
        Test-Path -LiteralPath $state.Path | Should -BeFalse
    }

    It 'makes the corrective call when the read-back lost its blank lines' {
        $state = @{}
        $invoker = New-Invoker -State $state -ViewBody {
            param($s)
            if ($s.EditCount -eq 1) { (($s.Body -split "`n") | Where-Object { $_ -ne '' }) -join "`n" } else { $s.Body }
        }

        Invoke-Helper -Parameters @{ Id = 7; Description = "## Summary`n`nbody one`n`nbody two"; GhInvoker = $invoker } 3>$null | Out-Null
        $state.Edits.Count | Should -Be 2
    }
}
