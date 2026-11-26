#requires -Version 7.4

Describe 'Update-PullRequest' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Update-PullRequest.ps1'

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

        function New-Invoker {
            param([hashtable]$State, [string]$Title = 'T', [string]$Description = "## Summary`n`n* one")
            return {
                param($ghArgs)
                if ($ghArgs[1] -eq 'edit') { $State.Edits.Add((ConvertTo-Recorded -GhArgs $ghArgs)); return '' }
                return ([ordered]@{ number = 7; title = $Title; body = $Description } | ConvertTo-Json)
            }.GetNewClosure()
        }
    }

    AfterAll {
        Remove-Item -Path Function:\ConvertTo-Recorded -ErrorAction SilentlyContinue
    }

    It 'passes only the repository, the title and the description to gh pr edit' {
        $state = @{ Edits = [System.Collections.Generic.List[object]]::new() }
        Invoke-Helper -Parameters @{ Id = 7; Title = 'T'; Description = "## Summary`n`n* one"; GhInvoker = (New-Invoker -State $state) } | Out-Null

        $state.Edits[0][0..2] | Should -Be @('pr', 'edit', '7')
        $options = @($state.Edits[0] | Where-Object { $_ -like '--*' })
        $options | Should -Be @('--repo', '--title', '--body-file')
    }

    It 'passes a multi-line description as one body file' {
        $state = @{ Edits = [System.Collections.Generic.List[object]]::new() }
        Invoke-Helper -Parameters @{ Id = 7; Description = "## Summary`n`n* one"; GhInvoker = (New-Invoker -State $state) } | Out-Null

        $args0 = $state.Edits[0]
        $idx = [array]::IndexOf($args0, '--body-file')
        $args0[($idx + 1)..($args0.Length - 1)] | Should -Be @('## Summary', '', '* one')
        $args0 | Should -Not -Contain '--title'
    }

    It 'changes the title alone and keeps the description' {
        $state = @{ Edits = [System.Collections.Generic.List[object]]::new() }
        $pr = Invoke-Helper -Parameters @{ Id = 7; Title = 'Show the owner'; GhInvoker = (New-Invoker -State $state -Title 'Show the owner') }

        $state.Edits[0] | Should -Not -Contain '--body-file'
        $pr.title | Should -Be 'Show the owner'
    }

    It 'refuses a call with nothing to change' {
        { Invoke-Helper -Parameters @{ Id = 7; GhInvoker = { '{}' } } } | Should -Throw '*Nothing to change*'
    }

    It 'refuses a description over 65536 characters and never calls gh' {
        $state = @{ Edits = [System.Collections.Generic.List[object]]::new() }
        { Invoke-Helper -Parameters @{ Id = 7; Description = ('x' * 65537); GhInvoker = (New-Invoker -State $state) } } | Should -Throw '*rejects more than 65536*'
        $state.Edits.Count | Should -Be 0
    }

    It 'accepts a description line that starts with a dash' {
        $state = @{ Edits = [System.Collections.Generic.List[object]]::new() }
        { Invoke-Helper -Parameters @{ Id = 7; Description = "## Summary`n- a bullet"; GhInvoker = (New-Invoker -State $state -Description "## Summary`n- a bullet") } } | Should -Not -Throw
        $state.Edits.Count | Should -Be 1
    }

    It 'refuses a title that starts with a dash or holds a line break' {
        { Invoke-Helper -Parameters @{ Id = 7; Title = '-bad'; GhInvoker = { '{}' } } } | Should -Throw '*option flag*'
        { Invoke-Helper -Parameters @{ Id = 7; Title = "one`ntwo"; GhInvoker = { '{}' } } } | Should -Throw '*one line*'
    }

    It 'makes one corrective call when the description reads back cut off, then succeeds' {
        $state = @{ Edits = [System.Collections.Generic.List[object]]::new(); Views = 0 }
        $invoker = {
            param($ghArgs)
            if ($ghArgs[1] -eq 'edit') { $state.Edits.Add((ConvertTo-Recorded -GhArgs $ghArgs)); return '' }
            $state.Views++
            $desc = if ($state.Views -eq 1) { '## Summary' } else { "## Summary`n`nthe full body is here" }
            return ([ordered]@{ number = 7; title = 'T'; body = $desc } | ConvertTo-Json)
        }.GetNewClosure()

        $pr = Invoke-Helper -Parameters @{ Id = 7; Description = "## Summary`n`nthe full body is here"; GhInvoker = $invoker } 3>$null
        $state.Edits.Count | Should -Be 2
        $pr.body | Should -Be "## Summary`n`nthe full body is here"
    }

    It 'throws when the description is still cut off after the corrective call' {
        $invoker = { param($ghArgs) if ($ghArgs[1] -eq 'edit') { return '' }; return ([ordered]@{ number = 7; title = 'T'; body = '## Summary' } | ConvertTo-Json) }
        { Invoke-Helper -Parameters @{ Id = 7; Description = "## Summary`n`na much longer body that must survive"; GhInvoker = $invoker } 3>$null } |
            Should -Throw '*truncated after a corrective update*'
    }

    It 'throws when the title does not read back as sent' {
        $invoker = { param($ghArgs) if ($ghArgs[1] -eq 'edit') { return '' }; return ([ordered]@{ number = 7; title = 'old'; body = 'x' } | ConvertTo-Json) }
        { Invoke-Helper -Parameters @{ Id = 7; Title = 'new'; GhInvoker = $invoker } } | Should -Throw "*read back as 'old'*"
    }

    It 'passes the description as a file that keeps blank lines and quotes, and removes it after the call' {
        $description = "## Summary`n`nsay `"yes`" > no`n`n* one"
        $state = @{ Path = $null; Content = $null }
        $invoker = {
            param($ghArgs)
            if ($ghArgs[1] -eq 'edit') {
                $state.Path = $ghArgs[[array]::IndexOf($ghArgs, '--body-file') + 1]
                $state.Content = Get-Content -LiteralPath $state.Path -Raw
                return ''
            }
            return ([ordered]@{ number = 7; title = 'T'; body = "## Summary`n`nsay `"yes`" > no`n`n* one" } | ConvertTo-Json)
        }.GetNewClosure()

        Invoke-Helper -Parameters @{ Id = 7; Description = $description; GhInvoker = $invoker } | Out-Null

        $state.Content | Should -BeExactly $description
        Test-Path -LiteralPath $state.Path | Should -BeFalse
    }

    It 'makes the corrective call when the read-back lost its blank lines' {
        $state = @{ Edits = 0; Views = 0 }
        $invoker = {
            param($ghArgs)
            if ($ghArgs[1] -eq 'edit') { $state.Edits++; return '' }
            $state.Views++
            $desc = if ($state.Views -eq 1) { "## Summary`nbody one`nbody two" } else { "## Summary`n`nbody one`n`nbody two" }
            return ([ordered]@{ number = 7; title = 'T'; body = $desc } | ConvertTo-Json)
        }.GetNewClosure()

        Invoke-Helper -Parameters @{ Id = 7; Description = "## Summary`n`nbody one`n`nbody two"; GhInvoker = $invoker } 3>$null | Out-Null
        $state.Edits | Should -Be 2
    }
}
