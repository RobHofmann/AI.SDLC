#requires -Version 7.4

Describe 'DocToolTestHarness' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'DocToolTestHarness.psm1') -Force
        $script:Made = [System.Collections.Generic.List[string]]::new()

        function New-Layout {
            param([string[]]$Folders, [hashtable]$Files = @{})
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
            foreach ($f in $Folders) { New-Item -ItemType Directory -Path (Join-Path $root $f) -Force | Out-Null }
            foreach ($rel in $Files.Keys) {
                $full = Join-Path $root $rel
                New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
                Set-Content -LiteralPath $full -Value $Files[$rel] -Encoding utf8
            }
            return $root
        }
    }

    AfterAll {
        foreach ($dir in $script:Made) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Context 'New-DocToolRepo' {
        It 'writes each file at its relative path, with its parent folders' {
            $root = New-DocToolRepo -Prefix 'dth' -Files @{ 'docs/deep/page.md' = '# Page'; 'README.md' = '# Readme' }
            $script:Made.Add($root)

            Get-Content -LiteralPath (Join-Path $root 'docs' 'deep' 'page.md') -Raw | Should -Match '# Page'
            Test-Path -LiteralPath (Join-Path $root 'README.md') | Should -BeTrue
            Split-Path $root -Leaf | Should -BeLike 'dth-*'
        }

        It 'adds the test aisdlc.json by default' {
            $root = New-DocToolRepo -Files @{ 'docs/a.md' = '# A' }
            $script:Made.Add($root)

            $config = Get-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Raw | ConvertFrom-Json
            $config.paths.docsRoots | Should -Be @('docs', 'docs-functional')
            @($config.tracker.dataModelPatterns).Count | Should -Be 2
        }

        It 'leaves out aisdlc.json with -NoConfig' {
            $root = New-DocToolRepo -NoConfig -Files @{ 'docs/a.md' = '# A' }
            $script:Made.Add($root)

            Test-Path -LiteralPath (Join-Path $root 'aisdlc.json') | Should -BeFalse
        }

        It 'keeps an aisdlc.json that the files bring' {
            $root = New-DocToolRepo -Files @{ 'aisdlc.json' = '{ "repository": "Own" }' }
            $script:Made.Add($root)

            (Get-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Raw | ConvertFrom-Json).repository | Should -Be 'Own'
        }

        It 'commits every file with -InitialiseGit, so git reports them as tracked' {
            $root = New-DocToolRepo -InitialiseGit -Files @{ 'docs/a.md' = '# A'; 'src/b.cs' = 'class B {}' }
            $script:Made.Add($root)

            $tracked = @(git -C $root ls-files)
            $tracked | Should -Contain 'docs/a.md'
            $tracked | Should -Contain 'src/b.cs'
            $tracked | Should -Contain 'aisdlc.json'
            @(git -C $root status --porcelain) | Should -HaveCount 0
        }

        It 'creates no git repository without -InitialiseGit' {
            $root = New-DocToolRepo -Files @{ 'docs/a.md' = '# A' }
            $script:Made.Add($root)

            Test-Path -LiteralPath (Join-Path $root '.git') | Should -BeFalse
        }
    }

    Context 'Set-AiSdlcTestConfig' {
        It 'replaces only the path values it is given' {
            $root = New-Layout -Folders @('.')
            Set-AiSdlcTestConfig -Root $root -Paths @{ docsRoots = @('docs') }

            $config = Get-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Raw | ConvertFrom-Json
            @($config.paths.docsRoots) | Should -Be @('docs')
            $config.paths.technicalDocs | Should -Be 'docs'
            $config.paths.solution | Should -Be 'Demo/Demo.sln'
        }

        It 'does not carry a change from one call into the next' {
            $first = New-Layout -Folders @('.')
            $second = New-Layout -Folders @('.')
            Set-AiSdlcTestConfig -Root $first -Paths @{ solution = 'Other.sln' }
            Set-AiSdlcTestConfig -Root $second

            (Get-Content -LiteralPath (Join-Path $second 'aisdlc.json') -Raw | ConvertFrom-Json).paths.solution | Should -Be 'Demo/Demo.sln'
        }
    }

    Context 'Find-AiSdlcSkillFolder' {
        It 'finds a sibling skill in an installed layout' {
            $root = New-Layout -Folders @('.claude/skills/ai-sdlc-gates/scripts', '.claude/skills/dotnet-gates')

            $found = Find-AiSdlcSkillFolder -Name 'dotnet-gates' -From (Join-Path $root '.claude/skills/ai-sdlc-gates/scripts')

            $found | Should -Be (Resolve-Path -LiteralPath (Join-Path $root '.claude/skills/dotnet-gates')).Path
        }

        It 'finds a pack skill in the source layout' {
            $root = New-Layout -Folders @('core/.apm/skills/ai-sdlc-gates/scripts', 'packs/dotnet/.apm/skills/dotnet-gates')

            $found = Find-AiSdlcSkillFolder -Name 'dotnet-gates' -From (Join-Path $root 'core/.apm/skills/ai-sdlc-gates/scripts')

            $found | Should -Be (Resolve-Path -LiteralPath (Join-Path $root 'packs/dotnet/.apm/skills/dotnet-gates')).Path
        }

        It 'returns nothing for a skill that is in neither layout' {
            $root = New-Layout -Folders @('core/.apm/skills/ai-sdlc-gates/scripts', 'packs/dotnet/.apm/skills/dotnet-gates')

            Find-AiSdlcSkillFolder -Name 'missing-skill' -From (Join-Path $root 'core/.apm/skills/ai-sdlc-gates/scripts') | Should -BeNullOrEmpty
        }

        It 'finds the real ai-sdlc-hooks skill from this folder' {
            Find-AiSdlcSkillFolder -Name 'ai-sdlc-hooks' -From $PSScriptRoot | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Get-AiSdlcHookSettings' {
        It 'merges the hook entries of every hooks json file in the source layout' {
            $root = New-Layout -Folders @('core/.apm/skills/ai-sdlc-gates/scripts') -Files @{
                'core/.apm/hooks/a.json' = '{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "a" } ] } ] } }'
                'core/.apm/hooks/b.json' = '{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "b" } ] } ], "PreToolUse": [ { "matcher": "Bash", "hooks": [] } ] } }'
            }

            $settings = Get-AiSdlcHookSettings -From (Join-Path $root 'core/.apm/skills/ai-sdlc-gates/scripts')

            @($settings.hooks.Stop) | Should -HaveCount 2
            @($settings.hooks.Stop.hooks.command) | Should -Be @('a', 'b')
            @($settings.hooks.PreToolUse) | Should -HaveCount 1
        }

        It 'reads .claude/settings.json in an installed layout' {
            $root = New-Layout -Folders @('.claude/skills/ai-sdlc-gates/scripts') -Files @{
                '.claude/settings.json' = '{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "installed" } ] } ] } }'
            }

            $settings = Get-AiSdlcHookSettings -From (Join-Path $root '.claude/skills/ai-sdlc-gates/scripts')

            $settings.hooks.Stop[0].hooks[0].command | Should -Be 'installed'
        }

        It 'returns nothing when an installed layout has no settings.json' {
            $root = New-Layout -Folders @('.claude/skills/ai-sdlc-gates/scripts')

            Get-AiSdlcHookSettings -From (Join-Path $root '.claude/skills/ai-sdlc-gates/scripts') | Should -BeNullOrEmpty
        }
    }

    Context 'ConvertTo-ParameterTable' {
        It 'binds a named value, a switch at the end and a switch before another name' {
            $table = ConvertTo-ParameterTable -Arguments @('-Name', 'x', '-Check', '-List', 'a,b', '-Ci')

            $table.Name | Should -Be 'x'
            $table.Check | Should -BeTrue
            $table.List | Should -Be 'a,b'
            $table.Ci | Should -BeTrue
        }

        It 'reads the -Name:value form and keeps a value that is not a string' {
            $table = ConvertTo-ParameterTable -Arguments @('-Mode:Blocking', '-Count', 3)

            $table.Mode | Should -Be 'Blocking'
            $table.Count | Should -Be 3
        }

        It 'refuses a value that has no parameter name before it' {
            { ConvertTo-ParameterTable -Arguments @('loose') } | Should -Throw '*does not name a parameter*'
        }
    }

    Context 'Invoke-ScriptInProcess' {
        BeforeAll {
            $script:Probe = Join-Path $TestDrive 'Probe.ps1'
            Set-Content -LiteralPath $script:Probe -Encoding utf8 -Value @"
param([string]`$Name, [switch]`$Fail, [switch]`$Throw, [int]`$Code = 0)
Write-Host "host `$Name"
Write-Output "out `$Name"
`$env:AISDLC_PROBE_SET = 'leaked'
Set-Location -LiteralPath ([IO.Path]::GetTempPath())
if (`$Throw) { throw 'probe broke' }
if (`$Fail) { exit 4 }
if (`$Code) { exit `$Code }
"@
        }

        It 'returns the output of every stream and exit 0 for a script that ends without exit' {
            $r = Invoke-ScriptInProcess -Path $script:Probe -Arguments @('-Name', 'a')

            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'host a'
            $r.Output | Should -Match 'out a'
        }

        It 'returns the exit code of the script, also in LASTEXITCODE' {
            $r = Invoke-ScriptInProcess -Path $script:Probe -Arguments @('-Fail')

            $r.ExitCode | Should -Be 4
            $LASTEXITCODE | Should -Be 4
        }

        It 'turns a terminating error into exit 1 with the message, as pwsh -File does' {
            $r = Invoke-ScriptInProcess -Path $script:Probe -Arguments @('-Name', 'b', '-Throw')

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'out b'
            $r.Output | Should -Match 'probe broke'
        }

        It 'puts the location and the environment variables back' {
            $before = (Get-Location).Path
            $env:AISDLC_PROBE_KEEP = 'kept'

            Invoke-ScriptInProcess -Path $script:Probe -Parameters @{ Name = 'c' } | Out-Null

            (Get-Location).Path | Should -Be $before
            $env:AISDLC_PROBE_SET | Should -BeNullOrEmpty
            $env:AISDLC_PROBE_KEEP | Should -Be 'kept'
            Remove-Item Env:AISDLC_PROBE_KEEP
        }

        It 'returns the output as lines too, one per record' {
            $r = Invoke-ScriptInProcess -Path $script:Probe -Arguments @('-Name', 'd')

            $r.Lines | Should -Be @('host d', 'out d')
        }
    }

    Context 'Invoke-WithInProcessCommand' {
        BeforeAll {
            $script:Stand = Join-Path $TestDrive 'Stand.ps1'
            Set-Content -LiteralPath $script:Stand -Encoding utf8 -Value @"
param([string]`$Name, [switch]`$Loud)
Write-Host "stand `$Name `$Loud pid `$PID"
exit 3
"@
            $script:Fake = Join-Path $TestDrive 'fake-tool.ps1'
            Set-Content -LiteralPath $script:Fake -Encoding utf8 -Value @'
Write-Output "fake $($args -join ' ') pid $PID"
exit 5
'@
        }

        It 'runs pwsh -File in this process, with the output lines and the exit code of the script' {
            $lines = Invoke-WithInProcessCommand -ScriptBlock {
                @(& pwsh -NoProfile -File $script:Stand -Name x -Loud 2>&1 | ForEach-Object { "$_" })
                $script:Code = $LASTEXITCODE
            }

            $lines | Should -Be @("stand x True pid $PID")
            $script:Code | Should -Be 3
        }

        It 'still starts the real pwsh for a call without -File' {
            $out = Invoke-WithInProcessCommand -ScriptBlock { & pwsh -NoProfile -Command 'Write-Output $PID' }

            [int]"$out".Trim() | Should -Not -Be $PID
        }

        It 'runs each command of -Script in this process with the same arguments' {
            $out = Invoke-WithInProcessCommand -Script @{ faketool = $script:Fake } -ScriptBlock {
                & faketool audit --ci
                $script:Code = $LASTEXITCODE
            }

            $out | Should -Be "fake audit --ci pid $PID"
            $script:Code | Should -Be 5
        }

        It 'removes the stand-ins afterwards, also when the script block throws' {
            { Invoke-WithInProcessCommand -Script @{ faketool = $script:Fake } -ScriptBlock { throw 'inside' } } | Should -Throw 'inside'

            Get-Command faketool -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            (Get-Command pwsh).CommandType | Should -Be 'Application'
        }

        It 'puts back a global function of the same name that was there before, also after a nested call' {
            function global:faketool { 'outer' }
            try {
                $inner = Invoke-WithInProcessCommand -Script @{ faketool = $script:Fake } -ScriptBlock {
                    Invoke-WithInProcessCommand -ScriptBlock { 'nested' } | Out-Null
                    & faketool
                }

                $inner | Should -Match '^fake'
                faketool | Should -Be 'outer'
                (Get-Command pwsh).CommandType | Should -Be 'Application'
            }
            finally { Remove-Item -LiteralPath function:\faketool -ErrorAction SilentlyContinue }
        }
    }
}