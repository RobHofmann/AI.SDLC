#requires -Version 7.4

Describe 'GateAnnotation' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'GateAnnotation.psm1') -Force

        function Invoke-Annotation {
            param([string[]]$Lines, [int]$ExitCode, [string]$Mode = 'Blocking')
            $script:Outcome = $null
            $written = & { $script:Outcome = Write-GateAnnotation -Lines $Lines -ExitCode $ExitCode -Clause 'C99' -What 'a test rule' -Mode $Mode -HowToRepeat 'pwsh gate.ps1' } 6>&1 | Out-String
            return [pscustomobject]@{ Outcome = $script:Outcome; Written = $written }
        }

        $script:Findings = @('Rule header:', '  docs/a.md:3  bad thing', 'FIX: do the good thing', '1 violation(s).')
        $script:SavedActions = $env:GITHUB_ACTIONS
    }

    BeforeEach { $env:GITHUB_ACTIONS = 'true' }

    AfterAll {
        $env:GITHUB_ACTIONS = $script:SavedActions
        Remove-Module GateAnnotation -Force -ErrorAction SilentlyContinue
    }

    It 'writes nothing and reports Succeeded for a gate that passed' {
        $r = Invoke-Annotation -Lines @('all good') -ExitCode 0

        $r.Outcome.Result | Should -Be 'Succeeded'
        $r.Written | Should -Not -Match '::(error|warning)'
    }

    It 'raises an error per located finding and a summary error, and reports Failed, for a Blocking gate' {
        $r = Invoke-Annotation -Lines $script:Findings -ExitCode 1

        $r.Outcome.Result | Should -Be 'Failed'
        $r.Written | Should -Match '(?m)^::error file=docs/a\.md,line=3,title=a test rule::C99: bad thing'
        $r.Written | Should -Match 'Fix: do the good thing'
        $r.Written | Should -Match 'pwsh gate\.ps1'
    }

    It 'raises warnings and reports SucceededWithIssues for an Advisory gate' {
        $r = Invoke-Annotation -Lines $script:Findings -ExitCode 1 -Mode Advisory

        $r.Outcome.Result | Should -Be 'SucceededWithIssues'
        $r.Written | Should -Match '(?m)^::warning '
        $r.Written | Should -Not -Match '::error'
    }

    It 'treats exit 2 as could-not-check: a warning, never a failure, in either mode' {
        $r = Invoke-Annotation -Lines @('No token, so NOTHING WAS CHECKED.') -ExitCode 2

        $r.Outcome.Result | Should -Be 'SucceededWithIssues'
        $r.Written | Should -Match '::warning title=a test rule::C99: a test rule COULD NOT BE CHECKED'
    }

    It 'writes no Azure DevOps logging command, only GitHub workflow commands' {
        $r = Invoke-Annotation -Lines $script:Findings -ExitCode 1

        $r.Written | Should -Not -Match '##vso'
    }

    It 'raises at most five findings of one gate as their own annotation' {
        $many = @('Rule header:') + @(1..7 | ForEach-Object { "  docs/a.md:$_  bad thing" }) + @('7 violation(s).')

        $r = Invoke-Annotation -Lines $many -ExitCode 1

        ([regex]::Matches($r.Written, '(?m)^::error file=')).Count | Should -Be 5
        $r.Written | Should -Match '2 more are in the log above'
    }

    It 'escapes a comma and a colon in a property and a new line in the message' {
        $written = & { Write-GateCommand -Type error -Title 'a, b: c' -File 'docs/a.md' -Line '4' -Message "one`ntwo 100%" } 6>&1 | Out-String

        $written | Should -Match 'title=a%2C b%3A c::one%0Atwo 100%25'
    }

    It 'prints plain ERROR lines instead of workflow commands outside GitHub Actions' {
        $env:GITHUB_ACTIONS = $null

        $r = Invoke-Annotation -Lines $script:Findings -ExitCode 1

        $r.Written | Should -Not -Match '::error'
        $r.Written | Should -Match '(?m)^ERROR docs/a\.md:3 - C99: bad thing'
    }

    It 'reports a gate that stopped with an error as a fault in the gate, and Failed' {
        $record = try { throw 'boom' } catch { $_ }

        $written = & { $script:Crash = Write-GateCrashAnnotation -Clause 'C99' -Script 'C:/x/Check-Thing.ps1' -ErrorRecord $record -HowToRepeat 'pwsh Check-Thing.ps1' } 6>&1 | Out-String

        $script:Crash.Result | Should -Be 'Failed'
        $written | Should -Match 'NOTHING WAS CHECKED'
        $written | Should -Match 'Check-Thing\.ps1'
        $written | Should -Match 'Reason: boom'
    }

    It 'names the script to repeat relative to the repository root' {
        $root = Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Path (Join-Path $root 'tools') -Force | Out-Null

        Get-GateRepeatCommand -Script (Join-Path $root 'tools' 'Check-X.ps1') -RepoRoot $root | Should -Be 'pwsh tools/Check-X.ps1'
    }
}
