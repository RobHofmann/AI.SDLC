#requires -Version 7.4

Describe 'Test-Consumers' {
    BeforeAll {
        $script:Tool = Join-Path $PSScriptRoot 'Test-Consumers.ps1'
        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('tc-run-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
        Import-Module (Join-Path $PSScriptRoot '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' 'DocToolTestHarness.psm1') -Force
        $script:Pwsh = Join-Path $PSHOME ($IsWindows ? 'pwsh.exe' : 'pwsh')

        function New-FakeApm {
            $folder = Join-Path $script:TempRoot ('apm-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            $fake = @(
                'Add-Content -LiteralPath $env:FAKE_APM_LOG -Value ($args -join '' '')'
                'if ($env:GITHUB_ACTIONS) { Set-Content -LiteralPath ($env:FAKE_APM_LOG + ''.actions'') -Value $env:GITHUB_ACTIONS }'
                'if ($args[0] -ne ''install'') { exit 0 }'
                'if ($env:FAKE_APM_DROP_GIT) { Remove-Item -LiteralPath (Join-Path $PWD ''.git'') -Recurse -Force }'
                '$scripts = Join-Path $PWD ''.claude'' ''skills'' ''ai-sdlc-gates'' ''scripts'''
                'New-Item -ItemType Directory -Path $scripts -Force | Out-Null'
                'foreach ($name in ''Sync-AgentsFile.ps1'', ''Build-DocsIndex.ps1'', ''Invoke-LocalGates.ps1'') { Set-Content -LiteralPath (Join-Path $scripts $name) -Value ''exit 0'' }'
                'New-Item -ItemType Directory -Path (Join-Path $PWD ''apm_modules'') -Force | Out-Null'
                'if (Test-Path -LiteralPath (Join-Path $PWD ''leak.txt'')) { Set-Content -LiteralPath (Join-Path $PWD ''.claude'' ''skills'' ''ai-sdlc-gates'' ''SKILL.md'') -Value ''See apm_modules/x/SKILL.md.'' }'
                'exit 0'
            ) -join "`n"
            [IO.File]::WriteAllText((Join-Path $folder 'fake-apm.ps1'), $fake + "`n")
            if ($IsWindows) {
                [IO.File]::WriteAllText((Join-Path $folder 'apm.cmd'), "@echo off`r`n`"$script:Pwsh`" -NoProfile -File `"%~dp0fake-apm.ps1`" %*`r`nexit /b %ERRORLEVEL%`r`n")
            }
            else {
                [IO.File]::WriteAllText((Join-Path $folder 'apm'), "#!/bin/sh`nexec `"$script:Pwsh`" -NoProfile -File `"`$(dirname `"`$0`")/fake-apm.ps1`" `"`$@`"`n")
                chmod +x (Join-Path $folder 'apm')
            }
            return $folder
        }

        function New-SourceRoot {
            param([string[]]$Consumers = @('alpha'), [string[]]$Leaky = @())
            $root = Join-Path $script:TempRoot ('src-' + [guid]::NewGuid().ToString('n'))
            foreach ($name in $Consumers) {
                $folder = Join-Path $root 'test-consumers' $name
                New-Item -ItemType Directory -Path $folder -Force | Out-Null
                [IO.File]::WriteAllText((Join-Path $folder 'apm.yml'), "name: $name`ndependencies:`n  apm:`n    - ../../core`n")
                [IO.File]::WriteAllText((Join-Path $folder 'aisdlc.json'), "{ `"repository`": `"$name`", `"packs`": [] }`n")
                [IO.File]::WriteAllText((Join-Path $folder 'expect.json'), '{ "present": [ ".claude/skills/ai-sdlc-gates/scripts/Sync-AgentsFile.ps1" ], "absent": [ ".claude/skills/test-first-dotnet" ] }')
                if ($name -in $Leaky) { [IO.File]::WriteAllText((Join-Path $folder 'leak.txt'), "leak`n") }
            }
            return $root
        }

        function ConvertTo-ToolArgument {
            param([hashtable]$Parameters)
            foreach ($key in $Parameters.Keys) {
                $value = $Parameters[$key]
                if ($value -is [switch] -or $value -is [bool]) { if ($value) { "-$key" } }
                else { "-$key"; $value }
            }
        }

        function Invoke-Tool {
            param([hashtable]$Parameters, [string]$PathOverride, [switch]$DefaultWorkRoot, [switch]$ChildProcess)
            $work = Join-Path $script:TempRoot ('work-' + [guid]::NewGuid().ToString('n'))
            $log = Join-Path $script:TempRoot ('log-' + [guid]::NewGuid().ToString('n') + '.txt')
            $arguments = @(if (-not $DefaultWorkRoot) { '-WorkRoot', $work }) + @(ConvertTo-ToolArgument -Parameters $Parameters)
            $saved = @{ Path = $env:PATH; Log = $env:FAKE_APM_LOG }
            try {
                $env:PATH = if ($PathOverride) { $PathOverride } else { $script:FakeApm + [IO.Path]::PathSeparator + $env:PATH }
                $env:FAKE_APM_LOG = $log
                $run = if ($PathOverride -or $ChildProcess) { Invoke-ScriptInProcess -Path $script:Tool -Arguments $arguments }
                else { Invoke-WithInProcessCommand -Script @{ apm = (Join-Path $script:FakeApm 'fake-apm.ps1') } -ScriptBlock { Invoke-ScriptInProcess -Path $script:Tool -Arguments $arguments } }
                $out = $run.Output
                $code = $run.ExitCode
            }
            finally {
                $env:PATH = $saved.Path
                $env:FAKE_APM_LOG = $saved.Log
            }
            $calls = if (Test-Path -LiteralPath $log) { @(Get-Content -LiteralPath $log) } else { @() }
            [pscustomobject]@{ Code = $code; Output = $out; Work = $work; ApmCalls = $calls; Log = $log }
        }

        $script:FakeApm = New-FakeApm
    }

    AfterAll {
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'hides the workflow from the gates inside a test consumer, so their findings do not annotate the run, through a real apm shim and a child pwsh' {
        $root = New-SourceRoot
        $saved = $env:GITHUB_ACTIONS
        try {
            $env:GITHUB_ACTIONS = 'true'
            $r = Invoke-Tool -Parameters @{ RepoRoot = $root; Name = 'alpha'; Ci = $true } -ChildProcess
        }
        finally { $env:GITHUB_ACTIONS = $saved }
        $r.ApmCalls.Count | Should -BeGreaterThan 0
        Test-Path -LiteralPath ($r.Log + '.actions') | Should -BeFalse
    }

    It 'exits 2 when no folder under test-consumers/ matches -Name' {
        $root = New-SourceRoot
        $r = Invoke-Tool -Parameters @{ RepoRoot = $root; Name = 'missing' }

        $r.Code | Should -Be 2 -Because $r.Output
        $r.Output | Should -Match 'No test consumer found'
    }

    It 'exits 2 when apm is not on the PATH' {
        $root = New-SourceRoot
        $empty = Join-Path $script:TempRoot ('empty-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        $r = Invoke-Tool -Parameters @{ RepoRoot = $root; Name = 'alpha' } -PathOverride $empty

        $r.Code | Should -Be 2 -Because $r.Output
        $r.Output | Should -Match 'apm is not on the PATH'
    }

    It 'installs only the consumers that -Name selects, and skips the setup-script consumer' {
        $root = New-SourceRoot -Consumers @('alpha', 'beta')
        $r = Invoke-Tool -Parameters @{ RepoRoot = $root; Name = 'beta' }

        $r.Code | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'Test consumer: beta'
        $r.Output | Should -Not -Match 'Test consumer: alpha'
        $r.Output | Should -Not -Match 'Test consumer: setup-script'
        @($r.ApmCalls | Where-Object { $_ -eq 'install' }) | Should -HaveCount 1
        $r.ApmCalls | Should -Contain 'audit --ci'
    }

    It 'passes a consumer that gets what expect.json asks for, and deletes its work folder' {
        $root = New-SourceRoot
        $r = Invoke-Tool -Parameters @{ RepoRoot = $root; Name = 'alpha' }

        $r.Code | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'All 1 test consumer\(s\) install and pass their gates'
        Test-Path -LiteralPath $r.Work | Should -BeFalse
    }

    It 'keeps the work folder with -Keep' {
        $root = New-SourceRoot
        $r = Invoke-Tool -Parameters @{ RepoRoot = $root; Name = 'alpha'; Keep = $true }

        $r.Code | Should -Be 0 -Because $r.Output
        Test-Path -LiteralPath (Join-Path $r.Work 'alpha' 'aisdlc.json') | Should -BeTrue
    }

    It 'gives each run its own work folder by default, and names it with -Keep' {
        $root = New-SourceRoot
        $first = Invoke-Tool -Parameters @{ RepoRoot = $root; Name = 'alpha'; Keep = $true } -DefaultWorkRoot
        $second = Invoke-Tool -Parameters @{ RepoRoot = $root; Name = 'alpha'; Keep = $true } -DefaultWorkRoot
        $kept = foreach ($r in $first, $second) { [regex]::Match($r.Output, 'Kept the work folder: (?<path>\S+)').Groups['path'].Value.TrimEnd('.') }
        try {
            $first.Code | Should -Be 0 -Because $first.Output
            $kept[0] | Should -Match 'aisdlc-consumers-[0-9a-f]{8}$'
            $kept[1] | Should -Match 'aisdlc-consumers-[0-9a-f]{8}$'
            $kept[0] | Should -Not -Be $kept[1]
            Test-Path -LiteralPath (Join-Path $kept[0] 'alpha' 'aisdlc.json') | Should -BeTrue
        }
        finally { foreach ($dir in $kept) { if ($dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue } } }
    }

    It 'stops, and leaves the outer repository alone, when the work folder is no repository of its own' {
        $outer = Join-Path $script:TempRoot ('outer-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $outer -Force | Out-Null
        git init --quiet -b main $outer
        git -C $outer config --local user.email probe@example.invalid
        git -C $outer config --local user.name probe
        Set-Content -LiteralPath (Join-Path $outer 'keep.txt') -Value 'outer'
        git -C $outer add -A
        git -C $outer commit --quiet -m outer --no-verify
        $head = (git -C $outer rev-parse HEAD).Trim()
        $root = New-SourceRoot
        $saved = @{ Drop = $env:FAKE_APM_DROP_GIT; Log = $env:FAKE_APM_LOG }
        try {
            $env:FAKE_APM_DROP_GIT = '1'
            $env:FAKE_APM_LOG = Join-Path $script:TempRoot ('log-' + [guid]::NewGuid().ToString('n') + '.txt')
            $arguments = @('-WorkRoot', (Join-Path $outer 'work'), '-RepoRoot', $root, '-Name', 'alpha')
            $env:PATH = $script:FakeApm + [IO.Path]::PathSeparator + $env:PATH
            $run = Invoke-WithInProcessCommand -Script @{ apm = (Join-Path $script:FakeApm 'fake-apm.ps1') } -ScriptBlock { Invoke-ScriptInProcess -Path $script:Tool -Arguments $arguments }
        }
        finally {
            $env:FAKE_APM_DROP_GIT = $saved.Drop
            $env:FAKE_APM_LOG = $saved.Log
            $env:PATH = ($env:PATH -split [IO.Path]::PathSeparator | Where-Object { $_ -ne $script:FakeApm }) -join [IO.Path]::PathSeparator
        }

        $run.ExitCode | Should -Not -Be 0 -Because $run.Output
        $run.Output | Should -Match 'not a git repository of its own'
        (git -C $outer rev-parse HEAD).Trim() | Should -Be $head
        (git -C $outer config --local --get user.name) | Should -Be 'probe'
        @(git -C $outer status --porcelain --untracked-files=no) | Should -BeNullOrEmpty
    }

    It 'fails a consumer whose installed files link into apm_modules/' {
        $root = New-SourceRoot -Leaky @('alpha')
        $r = Invoke-Tool -Parameters @{ RepoRoot = $root; Name = 'alpha' }

        $r.Code | Should -Be 1 -Because $r.Output
        $r.Output | Should -Match 'SKILL\.md:1 links into apm_modules/'
        Test-Path -LiteralPath $r.Work | Should -BeFalse
    }

    It 'reports each failure as a GitHub Actions error annotation with -Ci, and fails' {
        $root = New-SourceRoot -Leaky @('alpha')
        $r = Invoke-Tool -Parameters @{ RepoRoot = $root; Name = 'alpha'; Ci = $true }

        $r.Code | Should -Be 1 -Because $r.Output
        $r.Output | Should -Match ([regex]::Escape('::error title=Test consumer::Test consumer alpha:'))
    }
}

Describe 'Test-Consumers -Upgrade' {
    BeforeAll {
        $script:Tool = Join-Path $PSScriptRoot 'Test-Consumers.ps1'
        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('tc-run-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
        Import-Module (Join-Path $PSScriptRoot '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' 'DocToolTestHarness.psm1') -Force
        $script:Pwsh = Join-Path $PSHOME ($IsWindows ? 'pwsh.exe' : 'pwsh')

        # A fake apm. Its install writes the scripts a version delivers, with a fake Update-AiSdlc.ps1 that
        # moves the refs and installs again, as the real one does. The install of $env:FAKE_OLD_REF puts
        # down a skill under a retired name; a later install removes it, unless FAKE_LEAVE_BEHIND is set.
        function New-UpgradeApm {
            $folder = Join-Path $script:TempRoot ('upapm-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            $update = @(
                'param([string]$RepoRoot, [string]$Ref, [switch]$NoGates, [switch]$SkipLongPaths)'
                '$apm = Join-Path $RepoRoot ''apm.yml'''
                '(Get-Content -LiteralPath $apm -Raw) -replace ''(?m)^(\s+ref:\s*)\S+'', "`${1}$Ref" | Set-Content -LiteralPath $apm -NoNewline'
                'Push-Location $RepoRoot; apm install; $code = $LASTEXITCODE; Pop-Location; exit $code'
            ) -join "`n"
            [IO.File]::WriteAllText((Join-Path $folder 'Update-AiSdlc.ps1'), $update + "`n")
            $fake = @(
                'if ($args[0] -ne ''install'') { Add-Content -LiteralPath $env:FAKE_APM_LOG -Value ($args -join '' ''); exit 0 }'
                '$ref = [regex]::Match((Get-Content -LiteralPath (Join-Path $PWD ''apm.yml'') -Raw), ''(?m)^\s+ref:\s*(\S+)'').Groups[1].Value'
                'Add-Content -LiteralPath $env:FAKE_APM_LOG -Value "install ref=$ref"'
                '$skills = Join-Path $PWD ''.claude'' ''skills'''
                '$gates = Join-Path $skills ''ai-sdlc-gates'' ''scripts'''
                '$hooks = Join-Path $skills ''ai-sdlc-hooks'' ''scripts'''
                'New-Item -ItemType Directory -Path $gates, $hooks -Force | Out-Null'
                'Set-Content -LiteralPath (Join-Path $gates ''Sync-AgentsFile.ps1'') -Value ''exit 0'''
                'Set-Content -LiteralPath (Join-Path $gates ''Invoke-LocalGates.ps1'') -Value "exit $(if ($env:FAKE_GATES_EXIT) { $env:FAKE_GATES_EXIT } else { 0 })"'
                'Set-Content -LiteralPath (Join-Path $hooks ''Find-RetiredSkillNames.ps1'') -Value "Write-Host ''Retired skill names: the fake list''"'
                'Copy-Item -LiteralPath (Join-Path $PSScriptRoot ''Update-AiSdlc.ps1'') -Destination $hooks'
                'Set-Content -LiteralPath (Join-Path $skills ''ai-sdlc-gates'' ''sync-manifest.json'') -Value ''{ "retired": { "old-skill": "new-skill" } }'''
                '$oldSkill = Join-Path $skills ''old-skill'''
                'if ($ref -eq $env:FAKE_OLD_REF) { New-Item -ItemType Directory -Path $oldSkill -Force | Out-Null; Set-Content -LiteralPath (Join-Path $oldSkill ''SKILL.md'') -Value ''old'' }'
                'elseif (-not $env:FAKE_LEAVE_BEHIND) { Remove-Item -LiteralPath $oldSkill -Recurse -Force -ErrorAction SilentlyContinue }'
                'exit 0'
            ) -join "`n"
            [IO.File]::WriteAllText((Join-Path $folder 'fake-apm.ps1'), $fake + "`n")
            if ($IsWindows) {
                [IO.File]::WriteAllText((Join-Path $folder 'apm.cmd'), "@echo off`r`n`"$script:Pwsh`" -NoProfile -File `"%~dp0fake-apm.ps1`" %*`r`nexit /b %ERRORLEVEL%`r`n")
            }
            else {
                [IO.File]::WriteAllText((Join-Path $folder 'apm'), "#!/bin/sh`nexec `"$script:Pwsh`" -NoProfile -File `"`$(dirname `"`$0`")/fake-apm.ps1`" `"`$@`"`n")
                chmod +x (Join-Path $folder 'apm')
            }
            return $folder
        }

        # A clone of AI.SDLC in small: test-consumers/alpha as it was at v0.9.0 and v1.0.0, a change after that, and
        # a CHANGELOG whose newest version is v1.1.0.
        function New-SourceRepo {
            $root = Join-Path $script:TempRoot ('repo-' + [guid]::NewGuid().ToString('n'))
            $alpha = Join-Path $root 'test-consumers' 'alpha'
            New-Item -ItemType Directory -Path $alpha -Force | Out-Null
            git init --quiet -b main $root
            git -C $root config user.email probe@example.invalid
            git -C $root config user.name probe
            [IO.File]::WriteAllText((Join-Path $alpha 'apm.yml'), "name: alpha`ndependencies:`n  apm:`n    - ../../core`n    - ../../packs/github-issues`n")
            [IO.File]::WriteAllText((Join-Path $root 'CHANGELOG.md'), "# Changelog`n`n## v0.9.0 - 2026-01-01`n")
            git -C $root add -A; git -C $root commit --quiet -m 'v0.9.0'; git -C $root tag v0.9.0
            [IO.File]::WriteAllText((Join-Path $alpha 'old.txt'), "as at v1.0.0`n")
            [IO.File]::WriteAllText((Join-Path $root 'CHANGELOG.md'), "# Changelog`n`n## v1.0.0 - 2026-02-01`n")
            git -C $root add -A; git -C $root commit --quiet -m 'v1.0.0'; git -C $root tag v1.0.0
            Remove-Item -LiteralPath (Join-Path $alpha 'old.txt')
            [IO.File]::WriteAllText((Join-Path $alpha 'new.txt'), "after v1.0.0`n")
            [IO.File]::WriteAllText((Join-Path $root 'CHANGELOG.md'), "# Changelog`n`n## v1.1.0 - 2026-03-01`n`n## v1.0.0 - 2026-02-01`n")
            git -C $root add -A; git -C $root commit --quiet -m 'the change'
            return $root
        }

        function Invoke-Upgrade {
            param([string]$Root, [string[]]$Extra = @(), [hashtable]$Env = @{})
            $work = Join-Path $script:TempRoot ('work-' + [guid]::NewGuid().ToString('n'))
            $log = Join-Path $script:TempRoot ('log-' + [guid]::NewGuid().ToString('n') + '.txt')
            $names = @('PATH', 'FAKE_APM_LOG', 'FAKE_OLD_REF', 'FAKE_GATES_EXIT', 'FAKE_LEAVE_BEHIND')
            $saved = @{}; foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
            try {
                $env:PATH = $script:UpgradeApm + [IO.Path]::PathSeparator + $env:PATH
                $env:FAKE_APM_LOG = $log
                $env:FAKE_OLD_REF = 'v1.0.0'
                foreach ($k in $Env.Keys) { [Environment]::SetEnvironmentVariable($k, $Env[$k]) }
                $arguments = @('-RepoRoot', $Root, '-WorkRoot', $work, '-Name', 'alpha', '-Upgrade', '-UpgradeTo', '1-change', '-SourceUrl', 'https://example.invalid/AI.SDLC', '-Keep') + $Extra
                $run = Invoke-WithInProcessCommand -Script @{ apm = (Join-Path $script:UpgradeApm 'fake-apm.ps1') } -ScriptBlock { Invoke-ScriptInProcess -Path $script:Tool -Arguments $arguments }
                $out = $run.Output
                $code = $run.ExitCode
            }
            finally { foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) } }
            $calls = if (Test-Path -LiteralPath $log) { @(Get-Content -LiteralPath $log) } else { @() }
            [pscustomobject]@{ Code = $code; Output = $out; Work = $work; ApmCalls = $calls }
        }

        $script:UpgradeApm = New-UpgradeApm
    }

    AfterAll {
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'installs the consumer as it was at the previous release, from that tag' {
        $r = Invoke-Upgrade -Root (New-SourceRepo)

        $r.Code | Should -Be 0 -Because $r.Output
        $r.ApmCalls[0] | Should -Be 'install ref=v1.0.0' -Because 'v1.0.0 is the newest tag below v1.1.0, the newest version in CHANGELOG.md'
        Test-Path -LiteralPath (Join-Path $r.Work 'upgrade-alpha' 'old.txt') | Should -BeTrue -Because 'the consumer comes from the tag'
        Test-Path -LiteralPath (Join-Path $r.Work 'upgrade-alpha' 'new.txt') | Should -BeFalse
        $manifest = Get-Content -LiteralPath (Join-Path $r.Work 'upgrade-alpha' 'apm.yml') -Raw
        $manifest | Should -Match '(?m)^    - git: https://example\.invalid/AI\.SDLC\r?\n      path: packs/github-issues\r?\n      ref: 1-change'
    }

    It 'upgrades with the Update-AiSdlc.ps1 of the old version, then runs the gates and apm audit' {
        $r = Invoke-Upgrade -Root (New-SourceRepo)

        $r.Code | Should -Be 0 -Because $r.Output
        @($r.ApmCalls | Where-Object { $_ -like 'install ref=*' }) | Should -Be @('install ref=v1.0.0', 'install ref=1-change')
        $r.ApmCalls | Should -Contain 'audit --ci'
        $r.Output | Should -Match 'All 1 test consumer\(s\) upgrade and pass their gates'
        $r.Output | Should -Match 'Retired skill names: the fake list'
    }

    It 'fails the consumer when a blocking gate fails after the update' {
        $r = Invoke-Upgrade -Root (New-SourceRepo) -Env @{ FAKE_GATES_EXIT = '1' }

        $r.Code | Should -Be 1
        $r.Output | Should -Match 'alpha: a blocking gate failed after the update from v1\.0\.0'
    }

    It 'fails the consumer when the update leaves a skill folder of a retired name behind' {
        $r = Invoke-Upgrade -Root (New-SourceRepo) -Env @{ FAKE_LEAVE_BEHIND = '1' }

        $r.Code | Should -Be 1
        $r.Output | Should -Match 'alpha: the update left \.claude/skills/old-skill behind'
    }

    It 'upgrades from the tag that -UpgradeFrom names' {
        $r = Invoke-Upgrade -Root (New-SourceRepo) -Extra @('-UpgradeFrom', 'v0.9.0') -Env @{ FAKE_OLD_REF = 'v0.9.0' }

        $r.Code | Should -Be 0 -Because $r.Output
        $r.ApmCalls[0] | Should -Be 'install ref=v0.9.0'
        Test-Path -LiteralPath (Join-Path $r.Work 'upgrade-alpha' 'old.txt') | Should -BeFalse -Because 'old.txt came after v0.9.0'
    }

    It 'fails with a clear message when the clone has no release tag below the newest version' {
        $root = New-SourceRepo
        git -C $root tag -d v0.9.0 v1.0.0 *> $null
        git -C $root tag v1.1.0
        $r = Invoke-Upgrade -Root $root

        $r.Code | Should -Be 1
        $r.Output | Should -Match 'no release tag below the newest version of CHANGELOG\.md'
    }

    It 'passes and says so when the clone has no release tag at all, as before the first release' {
        $root = New-SourceRepo
        git -C $root tag -d v0.9.0 v1.0.0 *> $null
        $r = Invoke-Upgrade -Root $root

        $r.Code | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'no release tag yet'
        $r.ApmCalls | Should -BeNullOrEmpty
    }
}