#requires -Version 7.4

BeforeAll {
    $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm'
    $script:ScriptUnderTest = Join-Path -Path $script:ScriptFolder -ChildPath 'Check-PrSize.ps1'
    $script:SavedEnvironment = @{}
    foreach ($name in 'CHANGED_FILES', 'PR_TARGET_BRANCH', 'AISDLC_CHANGE_BASE') {
        $script:SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $null)
    }

    function New-Lines {
        param([int]$Count, [string]$Prefix = 'line')
        return @(1..$Count | ForEach-Object { "$Prefix $_" })
    }

    function Write-RepoFile {
        param([string]$Repo, [string]$Path, [string[]]$Lines)
        $full = Join-Path $Repo $Path
        New-Item -ItemType Directory -Path (Split-Path $full) -Force | Out-Null
        Set-Content -LiteralPath $full -Value $Lines
    }

    function New-GitRepo {
        param([object]$Config, [string]$RawConfig, [hashtable]$Files = @{}, [string[]]$Lock, [switch]$NoOrigin)
        $PSNativeCommandUseErrorActionPreference = $true
        $repo = Join-Path $TestDrive ('repo-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        git -C $repo init --quiet -b work
        git -C $repo config user.email probe@example.invalid
        git -C $repo config user.name probe
        git -C $repo config core.autocrlf false
        if ($RawConfig) { Set-Content -LiteralPath (Join-Path $repo 'aisdlc.json') -Value $RawConfig }
        elseif ($null -ne $Config) { Set-Content -LiteralPath (Join-Path $repo 'aisdlc.json') -Value ($Config | ConvertTo-Json -Depth 5) }
        foreach ($path in $Files.Keys) { Write-RepoFile -Repo $repo -Path $path -Lines $Files[$path] }
        if ($Lock) {
            $lines = @("lockfile_version: '1'", 'dependencies:', '- repo_url: _local/core', '  name: ai-sdlc-core', '  deployed_files:') + @($Lock | ForEach-Object { "  - $_" }) + @('  package_type: apm_package')
            Set-Content -LiteralPath (Join-Path $repo 'apm.lock.yaml') -Value $lines
        }
        Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value 'base'
        git -C $repo add -A
        git -C $repo commit --quiet -m base
        if (-not $NoOrigin) { git -C $repo update-ref refs/remotes/origin/main HEAD }
        return $repo
    }

    function Save-Commit {
        param([string]$Repo)
        $PSNativeCommandUseErrorActionPreference = $true
        git -C $Repo add -A
        git -C $Repo commit --quiet -m change
    }

    function Invoke-Check {
        param([string]$Repo)
        $out = & $script:ScriptUnderTest -RepoRoot $Repo *>&1 | Out-String
        [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
    }

    function New-Limit {
        param([object]$Limit, [object]$Exclude)
        $pullRequest = [ordered]@{ sizeLimit = $Limit }
        if ($null -ne $Exclude) { $pullRequest['sizeExclude'] = $Exclude }
        return [ordered]@{ repository = 'Probe'; pullRequest = $pullRequest }
    }
}

AfterAll {
    foreach ($name in $script:SavedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $script:SavedEnvironment[$name]) }
}

Describe 'Check-PrSize' {
    Context 'a pull request above the limit gets a warning that names its size and the limit (AC-1)' {
        It 'reports 11 changed lines against a limit of 10' -Tag '#61' {
            $repo = New-GitRepo -Config (New-Limit -Limit 10)
            Write-RepoFile -Repo $repo -Path 'src/App.ps1' -Lines (New-Lines 11)
            Save-Commit -Repo $repo

            $r = Invoke-Check -Repo $repo

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match '11 changed lines'
            $r.Output | Should -Match 'limit of 10'
            $r.Output | Should -Match 'src/App\.ps1'
            $r.Output | Should -Match 'FIX: '
        }

        It 'counts removed lines as well as added lines' -Tag '#61' {
            $repo = New-GitRepo -Config (New-Limit -Limit 10) -Files @{ 'src/Old.ps1' = (New-Lines 6) }
            Remove-Item -LiteralPath (Join-Path $repo 'src/Old.ps1')
            Write-RepoFile -Repo $repo -Path 'src/New.ps1' -Lines (New-Lines 5 -Prefix 'new')
            Save-Commit -Repo $repo

            $r = Invoke-Check -Repo $repo

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match '11 changed lines \(5 added, 6 removed\)'
        }

        It 'counts the lines of every commit since the merge base, not only the last one' -Tag '#61' {
            $repo = New-GitRepo -Config (New-Limit -Limit 10)
            Write-RepoFile -Repo $repo -Path 'src/One.ps1' -Lines (New-Lines 6)
            Save-Commit -Repo $repo
            Write-RepoFile -Repo $repo -Path 'src/Two.ps1' -Lines (New-Lines 6)
            Save-Commit -Repo $repo

            $r = Invoke-Check -Repo $repo

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match '12 changed lines'
        }
    }

    Context 'the base ref' {
        It 'measures against origin/<PR_TARGET_BRANCH> when the pull request action sets it' -Tag '#61' {
            $repo = New-GitRepo -Config (New-Limit -Limit 10)
            Write-RepoFile -Repo $repo -Path 'src/Base.ps1' -Lines (New-Lines 30)
            Save-Commit -Repo $repo
            git -C $repo update-ref refs/remotes/origin/develop HEAD
            Write-RepoFile -Repo $repo -Path 'src/App.ps1' -Lines (New-Lines 3)
            Save-Commit -Repo $repo
            $env:PR_TARGET_BRANCH = 'develop'
            try { $r = Invoke-Check -Repo $repo }
            finally { Remove-Item Env:PR_TARGET_BRANCH -ErrorAction SilentlyContinue }

            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match '3 changed lines'
        }
    }

    Context 'a pull request at or below the limit gets no warning, and installed files do not count (AC-3)' {
        It 'passes <Count> changed lines against a limit of 10' -Tag '#61' -ForEach @(
            @{ Count = 10 }
            @{ Count = 3 }
        ) {
            $repo = New-GitRepo -Config (New-Limit -Limit 10)
            Write-RepoFile -Repo $repo -Path 'src/App.ps1' -Lines (New-Lines $Count)
            Save-Commit -Repo $repo

            $r = Invoke-Check -Repo $repo

            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match "$Count changed lines"
            $r.Output | Should -Not -Match 'FIX: '
        }

        It 'does not count an edit that is not committed' -Tag '#61' {
            $repo = New-GitRepo -Config (New-Limit -Limit 10)
            Write-RepoFile -Repo $repo -Path 'src/App.ps1' -Lines (New-Lines 2)
            Save-Commit -Repo $repo
            Write-RepoFile -Repo $repo -Path 'src/Draft.ps1' -Lines (New-Lines 50)

            $r = Invoke-Check -Repo $repo

            $r.ExitCode | Should -Be 0 -Because $r.Output
        }

        It 'counts a moved file by what changed in it, not as all new' -Tag '#61' {
            $repo = New-GitRepo -Config (New-Limit -Limit 10) -Files @{ 'src/Old.ps1' = (New-Lines 40) }
            $PSNativeCommandUseErrorActionPreference = $true
            git -C $repo mv src/Old.ps1 src/Moved.ps1
            Save-Commit -Repo $repo

            $r = Invoke-Check -Repo $repo

            $r.ExitCode | Should -Be 0 -Because $r.Output
        }

        It 'skips the files that apm.lock.yaml at the base lists as installed' -Tag '#61' {
            $repo = New-GitRepo -Config (New-Limit -Limit 10) -Lock @('.claude/skills/probe/SKILL.md')
            Write-RepoFile -Repo $repo -Path '.claude/skills/probe/SKILL.md' -Lines (New-Lines 50)
            Save-Commit -Repo $repo

            $r = Invoke-Check -Repo $repo

            $r.ExitCode | Should -Be 0 -Because $r.Output
        }
    }

    Context 'a repository that sets no limit is reported as not checked (AC-4)' {
        It 'exits 3 and says so when aisdlc.json has no pullRequest.sizeLimit' -Tag '#61' {
            $repo = New-GitRepo -Config ([ordered]@{ repository = 'Probe' })
            Write-RepoFile -Repo $repo -Path 'src/App.ps1' -Lines (New-Lines 500)
            Save-Commit -Repo $repo

            $r = Invoke-Check -Repo $repo

            $r.ExitCode | Should -Be 3 -Because $r.Output
            $r.Output | Should -Match 'NOT CHECKED'
            $r.Output | Should -Match 'pullRequest\.sizeLimit'
        }

        It 'exits 3 when the base holds no aisdlc.json' -Tag '#61' {
            $repo = New-GitRepo -Config $null
            Write-RepoFile -Repo $repo -Path 'src/App.ps1' -Lines (New-Lines 500)
            Save-Commit -Repo $repo

            $r = Invoke-Check -Repo $repo

            $r.ExitCode | Should -Be 3 -Because $r.Output
            $r.Output | Should -Match 'NOT CHECKED'
        }
    }

    Context 'files that match the exclude patterns do not count (AC-2)' {
        It 'leaves out the files that pullRequest.sizeExclude matches' -Tag '#61' {
            $repo = New-GitRepo -Config (New-Limit -Limit 10 -Exclude @('docs/**', '**/*.Tests.ps1', 'apm.lock.yaml'))
            Write-RepoFile -Repo $repo -Path 'docs/guide/Page.md' -Lines (New-Lines 50)
            Write-RepoFile -Repo $repo -Path 'tests/App.Tests.ps1' -Lines (New-Lines 50)
            Write-RepoFile -Repo $repo -Path 'src/App.ps1' -Lines (New-Lines 4)
            Save-Commit -Repo $repo

            $r = Invoke-Check -Repo $repo

            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match '4 changed lines'
            $r.Output | Should -Match '2 file\(s\) left out'
        }

        It 'still counts a file that no pattern matches' -Tag '#61' {
            $repo = New-GitRepo -Config (New-Limit -Limit 10 -Exclude @('docs/**'))
            Write-RepoFile -Repo $repo -Path 'documentation/Page.md' -Lines (New-Lines 50)
            Save-Commit -Repo $repo

            $r = Invoke-Check -Repo $repo

            $r.ExitCode | Should -Be 1 -Because $r.Output
        }
    }

    Context 'it reads the limit and the patterns at the base, so a change cannot loosen its own check (AC-5)' {
        It 'keeps the base limit when the change raises it in aisdlc.json' -Tag '#61' {
            $repo = New-GitRepo -Config (New-Limit -Limit 10)
            Set-Content -LiteralPath (Join-Path $repo 'aisdlc.json') -Value ((New-Limit -Limit 5000) | ConvertTo-Json -Depth 5)
            Write-RepoFile -Repo $repo -Path 'src/App.ps1' -Lines (New-Lines 50)
            Save-Commit -Repo $repo

            $r = Invoke-Check -Repo $repo

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'limit of 10'
        }

        It 'ignores an exclude pattern that the change adds' -Tag '#61' {
            $repo = New-GitRepo -Config (New-Limit -Limit 10)
            Set-Content -LiteralPath (Join-Path $repo 'aisdlc.json') -Value ((New-Limit -Limit 10 -Exclude @('**')) | ConvertTo-Json -Depth 5)
            Write-RepoFile -Repo $repo -Path 'src/App.ps1' -Lines (New-Lines 50)
            Save-Commit -Repo $repo

            $r = Invoke-Check -Repo $repo

            $r.ExitCode | Should -Be 1 -Because $r.Output
        }

        It 'does not report a limit that the base does not set yet, when the change adds one' -Tag '#61' {
            $repo = New-GitRepo -Config ([ordered]@{ repository = 'Probe' })
            Set-Content -LiteralPath (Join-Path $repo 'aisdlc.json') -Value ((New-Limit -Limit 10) | ConvertTo-Json -Depth 5)
            Write-RepoFile -Repo $repo -Path 'src/App.ps1' -Lines (New-Lines 50)
            Save-Commit -Repo $repo

            $r = Invoke-Check -Repo $repo

            $r.ExitCode | Should -Be 3 -Because $r.Output
        }
    }

    Context 'a file that git sees as binary' {
        It 'names a binary file that no pattern leaves out as not measured, and exits 2' -Tag '#61' {
            $repo = New-GitRepo -Config (New-Limit -Limit 10)
            [System.IO.File]::WriteAllBytes((Join-Path $repo 'logo.png'), [byte[]](0, 1, 2, 0, 255, 10, 0, 3))
            Save-Commit -Repo $repo

            $r = Invoke-Check -Repo $repo

            $r.ExitCode | Should -Be 2 -Because $r.Output
            $r.Output | Should -Match 'logo\.png'
            $r.Output | Should -Match 'pullRequest\.sizeExclude'
        }

        It 'names a text file that .gitattributes marks as binary, so the mark cannot hide its size' -Tag '#61' {
            $repo = New-GitRepo -Config (New-Limit -Limit 10)
            Set-Content -LiteralPath (Join-Path $repo '.gitattributes') -Value 'src/** binary'
            Write-RepoFile -Repo $repo -Path 'src/App.ps1' -Lines (New-Lines 5)
            Save-Commit -Repo $repo

            $r = Invoke-Check -Repo $repo

            $r.ExitCode | Should -Be 2 -Because $r.Output
            $r.Output | Should -Match 'src/App\.ps1'
        }

        It 'passes a binary file that a pattern leaves out' -Tag '#61' {
            $repo = New-GitRepo -Config (New-Limit -Limit 10 -Exclude @('**/*.png'))
            New-Item -ItemType Directory -Path (Join-Path $repo 'img') -Force | Out-Null
            [System.IO.File]::WriteAllBytes((Join-Path $repo 'img/logo.png'), [byte[]](0, 1, 2, 0, 255, 10, 0, 3))
            Save-Commit -Repo $repo

            $r = Invoke-Check -Repo $repo

            $r.ExitCode | Should -Be 0 -Because $r.Output
        }

        It 'still warns when the counted lines alone are above the limit' -Tag '#61' {
            $repo = New-GitRepo -Config (New-Limit -Limit 10)
            [System.IO.File]::WriteAllBytes((Join-Path $repo 'logo.png'), [byte[]](0, 1, 2, 0, 255, 10, 0, 3))
            Write-RepoFile -Repo $repo -Path 'src/App.ps1' -Lines (New-Lines 20)
            Save-Commit -Repo $repo

            $r = Invoke-Check -Repo $repo

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'logo\.png'
        }
    }

    Context 'it fails closed: what it cannot read is named as not checked (exit 2)' {
        It 'exits 2 when there is no merge base' -Tag '#61' {
            $repo = New-GitRepo -Config (New-Limit -Limit 10) -NoOrigin
            Write-RepoFile -Repo $repo -Path 'src/App.ps1' -Lines (New-Lines 50)
            Save-Commit -Repo $repo

            $r = Invoke-Check -Repo $repo

            $r.ExitCode | Should -Be 2 -Because $r.Output
            $r.Output | Should -Match 'NOTHING WAS CHECKED'
            $r.Output | Should -Match 'FIX: '
        }

        It 'exits 2 when CHANGED_FILES is set but there is no merge base' -Tag '#61' {
            $repo = New-GitRepo -Config (New-Limit -Limit 10) -NoOrigin
            Write-RepoFile -Repo $repo -Path 'src/App.ps1' -Lines (New-Lines 50)
            Save-Commit -Repo $repo
            $env:CHANGED_FILES = 'src/App.ps1'
            try { $r = Invoke-Check -Repo $repo }
            finally { Remove-Item Env:CHANGED_FILES -ErrorAction SilentlyContinue }

            $r.ExitCode | Should -Be 2 -Because $r.Output
        }

        It 'exits 2 when the limit is <Case>' -Tag '#61' -ForEach @(
            @{ Case = 'a string'; Limit = '400' }
            @{ Case = 'zero'; Limit = 0 }
            @{ Case = 'below zero'; Limit = -5 }
            @{ Case = 'not a whole number'; Limit = 1.5 }
            @{ Case = 'true'; Limit = $true }
        ) {
            $repo = New-GitRepo -Config (New-Limit -Limit $Limit)
            Write-RepoFile -Repo $repo -Path 'src/App.ps1' -Lines (New-Lines 2)
            Save-Commit -Repo $repo

            $r = Invoke-Check -Repo $repo

            $r.ExitCode | Should -Be 2 -Because $r.Output
            $r.Output | Should -Match 'pullRequest\.sizeLimit'
        }

        It 'exits 2 when sizeExclude is <Case>' -Tag '#61' -ForEach @(
            @{ Case = 'a string'; Exclude = 'docs/**' }
            @{ Case = 'a list with a number'; Exclude = @('docs/**', 5) }
        ) {
            $repo = New-GitRepo -Config (New-Limit -Limit 10 -Exclude $Exclude)
            Write-RepoFile -Repo $repo -Path 'src/App.ps1' -Lines (New-Lines 2)
            Save-Commit -Repo $repo

            $r = Invoke-Check -Repo $repo

            $r.ExitCode | Should -Be 2 -Because $r.Output
            $r.Output | Should -Match 'pullRequest\.sizeExclude'
        }

        It 'exits 2 when aisdlc.json at the base is not valid JSON' -Tag '#61' {
            $repo = New-GitRepo -RawConfig '{ "pullRequest": { "sizeLimit": 10 '
            Set-Content -LiteralPath (Join-Path $repo 'aisdlc.json') -Value ((New-Limit -Limit 10) | ConvertTo-Json -Depth 5)
            Write-RepoFile -Repo $repo -Path 'src/App.ps1' -Lines (New-Lines 2)
            Save-Commit -Repo $repo

            $r = Invoke-Check -Repo $repo

            $r.ExitCode | Should -Be 2 -Because $r.Output
            $r.Output | Should -Match 'aisdlc\.json'
        }
    }
}
