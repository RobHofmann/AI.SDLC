#requires -Version 7.4

Describe 'New-AiSdlcUpdatePullRequest' {
    BeforeAll {
        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('aisdlc-update-pr-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
        $script:SourceUrl = 'https://github.com/contoso/AI.SDLC'

        $script:Changelog = @'
# Changelog

## v1.2.0 - 2026-10-03

What a consumer does: the step of v1.2.0.

## v1.1.0 - 2026-10-02

Story: #7.

- A change that asks nothing.

What a consumer does when it takes this release:

- Type the new names.
- Fix the text that names an old skill,
  such as your part of AGENTS.md.

Behaviour changes:

- Another change that asks nothing.

What a consumer does for these: run the new step once.

## v1.1.0-rc.1 - 2026-10-01

What a consumer does: the step of the pre-release.

## v1.0.0 - 2026-10-01

What a consumer does: the step of v1.0.0.
'@

        # A local stand-in for the AI.SDLC source, with one annotated tag and its changelog.
        function New-Source {
            # A message that starts with #7 would come back empty: git tag strips lines that start with #.
            param([string]$TagMessage = 'Release v1.1.0 for #7', [string]$Changelog = $script:Changelog)
            $source = Join-Path $script:TempRoot ('src-' + [guid]::NewGuid().ToString('n'))
            git init --quiet -b main $source
            git -C $source config user.email probe@example.invalid
            git -C $source config user.name probe
            [IO.File]::WriteAllText((Join-Path $source 'CHANGELOG.md'), $Changelog)
            git -C $source add -A
            git -C $source commit --quiet -m init
            git -C $source tag -a v1.1.0 -m $TagMessage
            return $source
        }

        # A consumer clone with a bare origin. Update-AiSdlc.ps1 is a stub that moves the ref and stages
        # apm.yml; -FindOutput adds a stub Find-RetiredSkillNames.ps1 that prints those lines.
        function New-Consumer {
            param([string]$Ref = 'v1.0.0', [string[]]$FindOutput, [int]$UpdateExit = 0)
            $base = Join-Path $script:TempRoot ('consumer-' + [guid]::NewGuid().ToString('n'))
            $seed = Join-Path $base 'seed'
            $origin = Join-Path $base 'origin.git'
            $work = Join-Path $base 'work'
            git init --quiet -b main $seed
            git -C $seed config user.email probe@example.invalid
            git -C $seed config user.name probe
            $hooks = Join-Path $seed '.claude' 'skills' 'ai-sdlc-hooks' 'scripts'
            $gates = Join-Path $seed '.claude' 'skills' 'ai-sdlc-gates' 'scripts'
            New-Item -ItemType Directory -Path $hooks, $gates -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'New-AiSdlcUpdatePullRequest.ps1'), (Join-Path $PSScriptRoot 'AiSdlcSetup.ps1') -Destination $hooks
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts' 'AiSdlcConfig.psm1') -Destination $gates
            Set-Content -LiteralPath (Join-Path $seed 'apm.yml') -Value "dependencies:`n  apm:`n    - git: $script:SourceUrl`n      path: core`n      ref: $Ref"
            Set-Content -LiteralPath (Join-Path $hooks 'Update-AiSdlc.ps1') -Value @"
param([string]`$RepoRoot, [string]`$Ref, [switch]`$NoGates)
if ($UpdateExit) { exit $UpdateExit }
`$apm = Join-Path `$RepoRoot 'apm.yml'
(Get-Content -LiteralPath `$apm -Raw) -replace '(?m)^(\s+ref:\s*)\S+', "```${1}`$Ref" | Set-Content -LiteralPath `$apm -NoNewline
git -C `$RepoRoot add -- apm.yml
exit 0
"@
            if ($PSBoundParameters.ContainsKey('FindOutput')) {
                $lines = @($FindOutput | ForEach-Object { "Write-Host '$($_ -replace "'", "''")'" })
                Set-Content -LiteralPath (Join-Path $hooks 'Find-RetiredSkillNames.ps1') -Value (@('param([string]$RepoRoot)') + $lines + 'exit 0')
            }
            git -C $seed add -A
            git -C $seed commit --quiet -m init
            git clone --quiet --bare $seed $origin
            git clone --quiet $origin $work
            git -C $work config user.email probe@example.invalid
            git -C $work config user.name probe
            return [pscustomobject]@{ Work = $work; Origin = $origin }
        }

        function New-FakeGh {
            $folder = Join-Path $script:TempRoot ('gh-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            if ($IsWindows) {
                $cmd = @('@echo off', 'echo %*>>"%FAKE_GH_LOG%"', 'if "%1 %2"=="pr create" echo https://github.com/contoso/portal/pull/4242', 'if "%1 %2"=="pr list" if defined FAKE_GH_LIST type "%FAKE_GH_LIST%"', 'exit /b 0') -join "`r`n"
                [IO.File]::WriteAllText((Join-Path $folder 'gh.cmd'), $cmd + "`r`n")
            }
            else {
                $sh = @('#!/bin/sh', 'echo "$*" >> "$FAKE_GH_LOG"', 'case "$1 $2" in "pr create") echo https://github.com/contoso/portal/pull/4242;; "pr list") [ -n "$FAKE_GH_LIST" ] && cat "$FAKE_GH_LIST";; esac', 'exit 0') -join "`n"
                [IO.File]::WriteAllText((Join-Path $folder 'gh'), $sh + "`n")
                chmod +x (Join-Path $folder 'gh')
            }
            return $folder
        }

        # Runs the script of the consumer in a child pwsh. Git reaches the stand-in source through an
        # insteadOf rule in the environment; a fake gh on the PATH logs each call.
        function Invoke-Update {
            param($Consumer, [string]$Source, [string[]]$Extra = @(), [switch]$CreatePullRequest, [string]$List)
            $folder = Join-Path $script:TempRoot ('desc-' + [guid]::NewGuid().ToString('n'))
            $gh = New-FakeGh
            $log = Join-Path $gh 'gh.log'
            $set = @{
                GIT_CONFIG_COUNT = '1'; GIT_CONFIG_KEY_0 = "url.$($Source -replace '\\', '/').insteadOf"; GIT_CONFIG_VALUE_0 = $script:SourceUrl
                PATH = $gh + [IO.Path]::PathSeparator + $env:PATH; FAKE_GH_LOG = $log; FAKE_GH_LIST = $List
            }
            $saved = @{}; foreach ($n in $set.Keys) { $saved[$n] = [Environment]::GetEnvironmentVariable($n); [Environment]::SetEnvironmentVariable($n, $set[$n]) }
            try {
                $arguments = @('-Ref', 'v1.1.0', '-RepoRoot', $Consumer.Work, '-DescriptionFolder', $folder) + $Extra
                if (-not $CreatePullRequest) { $arguments += '-SkipPullRequestCreation' }
                $script = Join-Path $Consumer.Work '.claude' 'skills' 'ai-sdlc-hooks' 'scripts' 'New-AiSdlcUpdatePullRequest.ps1'
                $output = & pwsh -NoProfile -NonInteractive -File $script @arguments *>&1 | Out-String
                $code = $LASTEXITCODE
            }
            finally { foreach ($n in $set.Keys) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) } }
            $read = { param($Name) $p = Join-Path $folder $Name; if (Test-Path -LiteralPath $p) { [IO.File]::ReadAllText($p) } }
            [pscustomobject]@{
                Code    = $code
                Output  = $output
                Body    = & $read 'body.md'
                Comment = & $read 'comment.md'
                GhCalls = @(if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log | ForEach-Object { $_.Trim() } })
                Branch  = @(git --git-dir $Consumer.Origin branch --list 'ai-sdlc-v1.1.0')
            }
        }

        $script:Finding = @(
            "Retired skill names: 2 place(s) in the repository's own files still use an old skill name."
            '  CLAUDE.md:3  generate-code -> implement'
            '  docs/guide.md:12  run-sdlc -> guide-me'
        )
    }

    AfterAll {
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'pushes a branch named for the tag, committed under the release issue with Refs, never Fixes' {
        $consumer = New-Consumer
        $r = Invoke-Update -Consumer $consumer -Source (New-Source)

        $r.Code | Should -Be 0 -Because $r.Output
        $r.Branch | Should -Not -BeNullOrEmpty
        (git --git-dir $consumer.Origin log -1 --format=%s 'ai-sdlc-v1.1.0') | Should -Be 'contoso/AI.SDLC#7: take the shared AI-SDLC at v1.1.0'
        (git --git-dir $consumer.Origin log -1 --format=%B 'ai-sdlc-v1.1.0') -join "`n" | Should -Match '(?m)^Refs contoso/AI\.SDLC#7$'
        (git --git-dir $consumer.Origin show 'ai-sdlc-v1.1.0:apm.yml') -join "`n" | Should -Match 'ref: v1\.1\.0'
        $r.Body | Should -Match '^Refs contoso/AI\.SDLC#7\n\nTakes the shared AI-SDLC at v1\.1\.0, from v1\.0\.0'
        $r.Body | Should -Not -Match '(?i)\b(fix(es|ed)?|close[sd]?|resolve[sd]?)\s+[\w./-]*#\d'
        $r.GhCalls | Should -BeNullOrEmpty -Because '-SkipPullRequestCreation calls no gh'
    }

    It 'does nothing when apm.yml already pins the tag' {
        $consumer = New-Consumer -Ref 'v1.1.0'
        $r = Invoke-Update -Consumer $consumer -Source (New-Source)

        $r.Code | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'Already on v1\.1\.0'
        $r.Branch | Should -BeNullOrEmpty
    }

    It 'does nothing when the update branch is already on origin, so a rerun opens nothing twice' {
        $consumer = New-Consumer
        git --git-dir $consumer.Origin branch 'ai-sdlc-v1.1.0' main
        $r = Invoke-Update -Consumer $consumer -Source (New-Source)

        $r.Code | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'already on origin'
        (git -C $consumer.Work branch --show-current) | Should -Be 'main'
    }

    It 'cannot start (exit 2) when the working tree has changes' {
        $consumer = New-Consumer
        Set-Content -LiteralPath (Join-Path $consumer.Work 'notes.txt') -Value 'work in progress'
        $r = Invoke-Update -Consumer $consumer -Source (New-Source)

        $r.Code | Should -Be 2
        $r.Output | Should -Match 'working tree has changes'
        $r.Branch | Should -BeNullOrEmpty
    }

    It 'pushes nothing with -WhatIf' {
        $consumer = New-Consumer
        $r = Invoke-Update -Consumer $consumer -Source (New-Source) -Extra @('-WhatIf')

        $r.Code | Should -Be 0 -Because $r.Output
        $r.Branch | Should -BeNullOrEmpty
    }

    It 'pushes nothing and exits 1 when the update fails' {
        $consumer = New-Consumer -UpdateExit 1
        $r = Invoke-Update -Consumer $consumer -Source (New-Source)

        $r.Code | Should -Be 1
        $r.Output | Should -Match 'Update-AiSdlc\.ps1 exited 1'
        $r.Branch | Should -BeNullOrEmpty
    }

    It 'finds the issue in the tag message past a word such as SHA-256' {
        $consumer = New-Consumer
        $r = Invoke-Update -Consumer $consumer -Source (New-Source -TagMessage 'Pins SHA-256 sums. Story #12.')

        $r.Code | Should -Be 0 -Because $r.Output
        (git --git-dir $consumer.Origin log -1 --format=%s 'ai-sdlc-v1.1.0') | Should -Be 'contoso/AI.SDLC#12: take the shared AI-SDLC at v1.1.0'
    }

    It 'still pushes without a key, and says so, when the tag message names no issue' {
        $consumer = New-Consumer
        $r = Invoke-Update -Consumer $consumer -Source (New-Source -TagMessage 'v1.1.0')

        $r.Code | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'No story key'
        (git --git-dir $consumer.Origin log -1 --format=%s 'ai-sdlc-v1.1.0') | Should -Be 'take the shared AI-SDLC at v1.1.0'
    }

    It 'opens the pull request with a body file, then lists the open ones to close the older' {
        $consumer = New-Consumer
        $r = Invoke-Update -Consumer $consumer -Source (New-Source) -CreatePullRequest

        $r.Code | Should -Be 0 -Because $r.Output
        $r.GhCalls[0] | Should -Match '^pr create --head ai-sdlc-v1\.1\.0 --base main --title .*--body-file '
        $r.GhCalls[1] | Should -Match '^pr list --state open --base main'
        $r.Output | Should -Match 'Opened pull request #4242'
    }

    It 'closes an older update pull request, and leaves a newer one, a pre-release and others open' {
        $consumer = New-Consumer
        $list = Join-Path $script:TempRoot ('list-' + [guid]::NewGuid().ToString('n') + '.json')
        @(
            @{ number = 11; headRefName = 'ai-sdlc-v1.0.9' }
            @{ number = 12; headRefName = 'ai-sdlc-v1.2.0' }
            @{ number = 13; headRefName = 'ai-sdlc-v1.0.0-rc.3' }
            @{ number = 14; headRefName = '9-some-feature' }
            @{ number = 4242; headRefName = 'ai-sdlc-v1.1.0' }
        ) | ConvertTo-Json | Set-Content -LiteralPath $list -Encoding utf8NoBOM
        $r = Invoke-Update -Consumer $consumer -Source (New-Source) -CreatePullRequest -List $list

        $r.Code | Should -Be 0 -Because $r.Output
        @($r.GhCalls | Where-Object { $_ -match '^pr close ' }) | Should -HaveCount 1
        @($r.GhCalls | Where-Object { $_ -match '^pr close 11 --comment .*Superseded by pull request #4242' }) | Should -HaveCount 1
    }

    Context 'the description tells the reviewer what to fix' {
        It 'holds the findings of the newly installed Find-RetiredSkillNames.ps1' {
            $r = Invoke-Update -Consumer (New-Consumer -FindOutput $script:Finding) -Source (New-Source)

            $r.Code | Should -Be 0 -Because $r.Output
            $r.Body | Should -Match '2 line\(s\) in 2 file\(s\)'
            $r.Body | Should -Match ([regex]::Escape('* `CLAUDE.md:3` generate-code -> implement'))
            $r.Body | Should -Match ([regex]::Escape('* `docs/guide.md:12` run-sdlc -> guide-me'))
            $r.Comment | Should -BeNullOrEmpty
        }

        It 'holds the consumer steps of each release after the pinned version, up to the tag' {
            $r = Invoke-Update -Consumer (New-Consumer -FindOutput $script:Finding) -Source (New-Source)

            $r.Body | Should -Match ([regex]::Escape('* Type the new names.'))
            $r.Body | Should -Match ([regex]::Escape("* Fix the text that names an old skill,`n  such as your part of AGENTS.md."))
            $r.Body | Should -Match ([regex]::Escape('What a consumer does for these: run the new step once.'))
            $r.Body | Should -Not -Match 'step of v1\.2\.0|step of v1\.0\.0|step of the pre-release|asks nothing|Behaviour changes'
        }

        It 'opens with a Before you merge list that names each step' {
            $mixed = @(
                "Retired skill names: 2 place(s) in the repository's own files still use an old skill name."
                '  docs/guide.md:12  run-sdlc -> guide-me'
                '  docs/history.md:4  run-sdlc -> guide-me'
            )
            $r = Invoke-Update -Consumer (New-Consumer -FindOutput $mixed) -Source (New-Source)

            $before = $r.Body.IndexOf('## Before you merge')
            $before | Should -BeGreaterThan 0
            $before | Should -BeLessThan $r.Body.IndexOf('## Old skill names')
            $r.Body | Should -Match ([regex]::Escape('* Rename the old skill names in the living files listed below.'))
            $r.Body | Should -Match ([regex]::Escape('* Add the history files listed below to paths.historyPaths in aisdlc.json.'))
            $r.Body | Should -Match ([regex]::Escape('"historyPaths": ["docs/history.md"]'))
        }

        It 'puts the per-file counts in the body and the full list in a comment when the list does not fit' {
            $many = @("Retired skill names: 300 place(s) in the repository's own files still use an old skill name.")
            foreach ($i in 1..300) { $many += "  docs/page-$($i % 3).md:$i  generate-code -> implement" }
            $r = Invoke-Update -Consumer (New-Consumer -FindOutput $many) -Source (New-Source) -CreatePullRequest

            $r.Code | Should -Be 0 -Because $r.Output
            $r.Body.Length | Should -BeLessOrEqual 4100 -Because 'the description stays within 4000 characters, plus the Refs line'
            $r.Body | Should -Match 'full list is in a comment'
            @(($r.Comment -split "`n") | Where-Object { $_ -match '^\* `docs/page-\d\.md:\d+` generate-code -> implement$' }) | Should -HaveCount 300
            @($r.GhCalls | Where-Object { $_ -match '^pr comment 4242 --body-file ' }) | Should -HaveCount 1
        }

        It 'says so in one line when there are no findings and no steps' {
            $none = @('Retired skill names: no file of the repository uses an old skill name.')
            $r = Invoke-Update -Consumer (New-Consumer -FindOutput $none) -Source (New-Source -Changelog "# Changelog`n`n## v1.1.0 - 2026-10-02`n`n- A change.`n")

            $r.Code | Should -Be 0 -Because $r.Output
            $r.Body | Should -Match 'No file of this repository uses an old skill name, and no release from v1\.0\.0 to v1\.1\.0 lists steps'
        }

        It 'says the names were not checked when the new version has no Find-RetiredSkillNames.ps1' {
            $r = Invoke-Update -Consumer (New-Consumer) -Source (New-Source)

            $r.Code | Should -Be 0 -Because $r.Output
            $r.Body | Should -Match 'Old skill names were not checked: v1\.1\.0 installed no Find-RetiredSkillNames\.ps1'
        }
    }
}
