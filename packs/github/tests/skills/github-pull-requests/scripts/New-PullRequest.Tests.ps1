#requires -Version 7.4

Describe 'New-PullRequest' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'New-PullRequest.ps1'

        function Invoke-Helper {
            param([hashtable]$Parameters)
            if (-not $Parameters.ContainsKey('Repository')) { $Parameters['Repository'] = 'contoso/portal' }
            return (& $script:ScriptUnderTest @Parameters)
        }
    }

    It 'creates the pull request with gh pr create, the base, the head, the title and a body file' {
        $state = @{ CreateArgs = $null; Lines = $null }
        $invoker = {
            param($ghArgs)
            if ($ghArgs[1] -eq 'create') {
                $state.CreateArgs = [string[]]$ghArgs
                $state.Lines = (Get-Content -LiteralPath $ghArgs[[array]::IndexOf($ghArgs, '--body-file') + 1] -Raw) -split "`n"
                return "https://github.com/contoso/portal/pull/101`n"
            }
            return ([ordered]@{ number = 101; url = 'u'; title = 'T'; body = "## Summary`n`n- one`n- two" } | ConvertTo-Json)
        }.GetNewClosure()

        Invoke-Helper -Parameters @{
            Title = 'T'; Description = "## Summary`n`n- one`n- two"
            SourceBranch = 'refs/heads/42-short-name'; TargetBranch = 'main'; GhInvoker = $invoker
        } | Out-Null

        $state.CreateArgs[0..1] | Should -Be @('pr', 'create')
        $state.CreateArgs | Should -Contain '--repo'
        $state.CreateArgs[[array]::IndexOf($state.CreateArgs, '--head') + 1] | Should -Be '42-short-name'
        $state.CreateArgs[[array]::IndexOf($state.CreateArgs, '--base') + 1] | Should -Be 'main'
        $state.CreateArgs | Should -Not -Contain '--body'
        $state.Lines | Should -Be @('## Summary', '', '- one', '- two')
    }

    It 'strips leaked here-string delimiter lines (@) from the start and end of the description' {
        $state = @{ Lines = $null }
        $invoker = {
            param($ghArgs)
            if ($ghArgs[1] -eq 'create') {
                $state.Lines = (Get-Content -LiteralPath $ghArgs[[array]::IndexOf($ghArgs, '--body-file') + 1] -Raw) -split "`n"
                return 'https://github.com/contoso/portal/pull/101'
            }
            return ([ordered]@{ number = 101; url = 'u'; title = 'T'; body = "## Summary`n`n* one" } | ConvertTo-Json)
        }.GetNewClosure()

        Invoke-Helper -Parameters @{
            Title = 'T'; Description = "@`n## Summary`n`n* one`n@"
            SourceBranch = '42-x'; GhInvoker = $invoker
        } 3>$null | Out-Null

        $state.Lines | Should -Be @('## Summary', '', '* one')
    }

    It 'accepts a description line that begins with a dash' {
        $invoker = {
            param($ghArgs)
            if ($ghArgs[1] -eq 'create') { return 'https://github.com/contoso/portal/pull/1' }
            return ([ordered]@{ number = 1; url = 'u'; title = 'T'; body = "## Summary`n- a bullet" } | ConvertTo-Json)
        }

        { Invoke-Helper -Parameters @{
                Title = 'T'; Description = "## Summary`n- a bullet"
                SourceBranch = '42-x'; GhInvoker = $invoker
            } } | Should -Not -Throw
    }

    It 'refuses an empty or whitespace-only description' {
        $invoker = { param($ghArgs) return '{}' }
        { Invoke-Helper -Parameters @{
                Title = 'T'; Description = "   `n  "
                SourceBranch = '42-x'; GhInvoker = $invoker
            } } | Should -Throw '*empty or whitespace-only*'
    }

    It 'succeeds and returns the PR when the read-back is intact' {
        $full = "## Summary`n`nbody line one`nbody line two"
        $invoker = {
            param($ghArgs)
            if ($ghArgs[1] -eq 'create') { return 'https://github.com/contoso/portal/pull/202' }
            return ([ordered]@{ number = 202; url = 'https://github.com/contoso/portal/pull/202'; title = 'T'; body = "## Summary`n`nbody line one`nbody line two" } | ConvertTo-Json)
        }.GetNewClosure()

        $pr = Invoke-Helper -Parameters @{
            Title = 'T'; Description = $full
            SourceBranch = '42-x'; GhInvoker = $invoker
        }

        $pr.number | Should -Be 202
        $pr.body | Should -Be $full
    }

    It 'reads back the number that gh pr create printed' {
        $state = @{ ViewArgs = $null }
        $invoker = {
            param($ghArgs)
            if ($ghArgs[1] -eq 'create') { return 'https://github.com/contoso/portal/pull/303' }
            $state.ViewArgs = [string[]]$ghArgs
            return ([ordered]@{ number = 303; url = 'u'; title = 'T'; body = 'body text' } | ConvertTo-Json)
        }.GetNewClosure()

        Invoke-Helper -Parameters @{ Title = 'T'; Description = 'body text'; SourceBranch = '42-x'; GhInvoker = $invoker } | Out-Null

        $state.ViewArgs[0..2] | Should -Be @('pr', 'view', '303')
        $state.ViewArgs | Should -Contain '--json'
    }

    It 'accepts a read-back a few characters shorter than expected from benign normalization' {
        $full = "## Summary`n`nDescription body content AB"
        $state = @{ EditCalled = $false }
        $invoker = {
            param($ghArgs)
            if ($ghArgs[1] -eq 'create') { return 'https://github.com/contoso/portal/pull/505' }
            if ($ghArgs[1] -eq 'edit') { $state.EditCalled = $true }
            return ([ordered]@{ number = 505; url = 'u'; title = 'T'; body = "## Summary`n`nDescription body content" } | ConvertTo-Json)
        }.GetNewClosure()

        $pr = Invoke-Helper -Parameters @{
            Title = 'T'; Description = $full
            SourceBranch = '42-x'; GhInvoker = $invoker
        }

        $pr.number | Should -Be 505
        $state.EditCalled | Should -BeFalse
    }

    It 'issues one corrective edit when the first read-back is truncated, then succeeds' {
        $full = "## Summary`n`nfull body content here"
        $state = @{ ViewCount = 0; EditArgs = $null }
        $invoker = {
            param($ghArgs)
            if ($ghArgs[1] -eq 'create') { return 'https://github.com/contoso/portal/pull/303' }
            if ($ghArgs[1] -eq 'edit') { $state.EditArgs = [string[]]$ghArgs; return '' }
            $state.ViewCount++
            $desc = if ($state.ViewCount -eq 1) { '## Summary' } else { "## Summary`n`nfull body content here" }
            return ([ordered]@{ number = 303; url = 'u'; title = 'T'; body = $desc } | ConvertTo-Json)
        }.GetNewClosure()

        $pr = Invoke-Helper -Parameters @{
            Title = 'T'; Description = $full
            SourceBranch = '42-x'; GhInvoker = $invoker
        } 3>$null

        $state.EditArgs[0..2] | Should -Be @('pr', 'edit', '303')
        $state.EditArgs | Should -Contain '--body-file'
        $pr.body | Should -Be $full
    }

    It 'throws when the description is still truncated after a corrective edit' {
        $full = "## Summary`n`na much longer body that should survive"
        $invoker = {
            param($ghArgs)
            if ($ghArgs[1] -eq 'create') { return 'https://github.com/contoso/portal/pull/404' }
            if ($ghArgs[1] -eq 'edit') { return '' }
            return ([ordered]@{ number = 404; url = 'u'; title = 'T'; body = '## Summary' } | ConvertTo-Json)
        }.GetNewClosure()

        { Invoke-Helper -Parameters @{
                Title = 'T'; Description = $full
                SourceBranch = '42-x'; GhInvoker = $invoker
            } 3>$null } | Should -Throw '*truncated after a corrective update*'
    }

    It 'passes the description as a file, keeps blank lines and quotes, and removes the file after the call' {
        $description = "## Summary`n`nnot the old `">= 80%`" rule`n`n* one"
        $state = @{ Path = $null; Content = $null }
        $invoker = {
            param($ghArgs)
            if ($ghArgs[1] -eq 'create') {
                $state.Path = $ghArgs[[array]::IndexOf($ghArgs, '--body-file') + 1]
                $state.Content = Get-Content -LiteralPath $state.Path -Raw
                return 'https://github.com/contoso/portal/pull/606'
            }
            return ([ordered]@{ number = 606; url = 'u'; title = 'T'; body = "## Summary`n`nnot the old `">= 80%`" rule`n`n* one" } | ConvertTo-Json)
        }.GetNewClosure()

        Invoke-Helper -Parameters @{
            Title = 'T'; Description = $description
            SourceBranch = '42-x'; GhInvoker = $invoker
        } | Out-Null

        $state.Content | Should -BeExactly $description
        Test-Path -LiteralPath $state.Path | Should -BeFalse
    }

    It 'issues a corrective edit when the read-back lost its blank lines, though no text is missing' {
        $full = "## Summary`n`nbody one`n`nbody two"
        $state = @{ ViewCount = 0; EditCalled = $false }
        $invoker = {
            param($ghArgs)
            if ($ghArgs[1] -eq 'create') { return 'https://github.com/contoso/portal/pull/707' }
            if ($ghArgs[1] -eq 'edit') { $state.EditCalled = $true; return '' }
            $state.ViewCount++
            $desc = if ($state.ViewCount -eq 1) { "## Summary`nbody one`nbody two" } else { "## Summary`n`nbody one`n`nbody two" }
            return ([ordered]@{ number = 707; url = 'u'; title = 'T'; body = $desc } | ConvertTo-Json)
        }.GetNewClosure()

        $pr = Invoke-Helper -Parameters @{
            Title = 'T'; Description = $full
            SourceBranch = '42-x'; GhInvoker = $invoker
        } 3>$null

        $state.EditCalled | Should -BeTrue
        $pr.body | Should -Be $full
    }

    It 'refuses a description over 65536 characters before any gh call' {
        $state = @{ Called = $false }
        $invoker = { param($ghArgs) $state.Called = $true; return '{}' }.GetNewClosure()
        { Invoke-Helper -Parameters @{
                Title = 'T'; Description = ('x' * 65537)
                SourceBranch = '42-x'; GhInvoker = $invoker
            } } | Should -Throw '*rejects more than 65536*'
        $state.Called | Should -BeFalse
    }

    It 'reminds the caller to add the Fixes line when the branch names an issue and the description does not' {
        $invoker = {
            param($ghArgs)
            if ($ghArgs[1] -eq 'create') { return 'https://github.com/contoso/portal/pull/9' }
            return ([ordered]@{ number = 9; url = 'u'; title = 'T'; body = 'body text' } | ConvertTo-Json)
        }

        $out = Invoke-Helper -Parameters @{ Title = 'T'; Description = 'body text'; SourceBranch = '42-x'; GhInvoker = $invoker } 6>&1 | Out-String

        $out | Should -Match "does not say 'Fixes #42'"
    }

    It 'gives no Fixes reminder when the description links the issue' {
        $invoker = {
            param($ghArgs)
            if ($ghArgs[1] -eq 'create') { return 'https://github.com/contoso/portal/pull/9' }
            return ([ordered]@{ number = 9; url = 'u'; title = 'T'; body = "body text`n`nFixes #42" } | ConvertTo-Json)
        }

        $out = Invoke-Helper -Parameters @{ Title = 'T'; Description = "body text`n`nFixes #42"; SourceBranch = '42-x'; GhInvoker = $invoker } 6>&1 | Out-String

        $out | Should -Not -Match 'does not say'
    }
}
