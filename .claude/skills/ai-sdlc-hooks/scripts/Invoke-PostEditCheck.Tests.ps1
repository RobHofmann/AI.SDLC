#requires -Version 7.4

Describe 'Invoke-PostEditCheck' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts' 'AiSdlcConfig.psm1') -Force
        Import-Module (Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts' 'DocToolTestHarness.psm1') -Force
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-PostEditCheck.ps1'

        $script:FailingReadingLevel = Join-Path -Path $TestDrive -ChildPath 'reading-fail.ps1'
        Set-Content -Path $script:FailingReadingLevel -Value @'
param([string]$RepoRoot, [string]$Path)
Write-Output "$Path : 1 sentence over 25 words"
exit 1
'@

        $script:CleanReadingLevel = Join-Path -Path $TestDrive -ChildPath 'reading-clean.ps1'
        Set-Content -Path $script:CleanReadingLevel -Value @'
param([string]$RepoRoot, [string]$Path)
Write-Output 'Reading level OK'
exit 0
'@

        $script:CleanEmDash = Join-Path -Path $TestDrive -ChildPath 'emdash-clean.ps1'
        Set-Content -Path $script:CleanEmDash -Value @'
param([string]$RepoRoot, [string]$Path)
exit 0
'@

        $script:FailingEmDash = Join-Path -Path $TestDrive -ChildPath 'emdash-fail.ps1'
        Set-Content -Path $script:FailingEmDash -Value @'
param([string]$RepoRoot, [string]$Path)
Write-Output "${Path}:3  an em-dash line"
exit 1
'@

        $script:PackCheck = @'
param([string[]]$File, [string[]]$Relative, [string]$RepoRoot)
Add-Content -LiteralPath (Join-Path $RepoRoot 'pack-calls.log') -Value ($Relative -join ',')
if ($Relative -like '*Broken*') { Write-Output "pack check ran on $($Relative -join ', ')" }
'@

        function Invoke-Hook {
            param(
                [string]$Payload,
                [string]$RepoRoot = $script:Root,
                [string]$ReadingLevelScript = $script:CleanReadingLevel,
                [string]$EmDashScript = $script:CleanEmDash
            )
            $out = & $script:ScriptUnderTest -Payload $Payload -RepoRoot $RepoRoot -ReadingLevelScript $ReadingLevelScript -EmDashScript $EmDashScript *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }

        function New-Payload {
            param([string]$FilePath, [string]$Tool = 'Edit')
            return (@{ hook_event_name = 'PostToolUse'; tool_name = $Tool; tool_input = @{ file_path = $FilePath } } | ConvertTo-Json -Compress)
        }
    }

    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'docs') -Force | Out-Null
        Set-AiSdlcTestConfig -Root $script:Root
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'Demo/src/Proj/Sub') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/page.md') -Value "# Page`nText.`n"
        Set-Content -LiteralPath (Join-Path $script:Root 'Demo/src/Proj/Proj.csproj') -Value '<Project />'
        Set-Content -LiteralPath (Join-Path $script:Root 'Demo/src/Proj/Sub/Thing.cs') -Value 'class Thing {}'
        Set-Content -LiteralPath (Join-Path $script:Root 'notes.txt') -Value 'plain'

        $pack = Join-Path $script:Root '.claude' 'skills' 'demo-pack'
        New-Item -ItemType Directory -Path (Join-Path $pack 'scripts') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $pack 'gates.json') -Value '{ "package": "dotnet", "gates": [], "postEdit": { "extensions": [".cs", ".razor"], "script": "scripts/Check-Edit.ps1" } }'
        Set-Content -LiteralPath (Join-Path $pack 'scripts' 'Check-Edit.ps1') -Value $script:PackCheck
    }

    Context 'payloads and files it leaves alone' {
        It 'stays silent on a payload that is not JSON' {
            $r = Invoke-Hook -Payload 'not json'
            $r.ExitCode | Should -Be 0
            $r.Output.Trim() | Should -BeNullOrEmpty
        }

        It 'stays silent on a file type it has no check for' {
            $r = Invoke-Hook -Payload (New-Payload -FilePath (Join-Path $script:Root 'notes.txt')) -ReadingLevelScript $script:FailingReadingLevel
            $r.Output.Trim() | Should -BeNullOrEmpty
        }

        It 'stays silent on a file outside the repository' {
            $outside = Join-Path $TestDrive 'outside.md'
            Set-Content -LiteralPath $outside -Value '# Outside'
            $r = Invoke-Hook -Payload (New-Payload -FilePath $outside) -ReadingLevelScript $script:FailingReadingLevel
            $r.Output.Trim() | Should -BeNullOrEmpty
        }

        It 'stays silent when the pack that claims the file type reports nothing' {
            $r = Invoke-Hook -Payload (New-Payload -FilePath (Join-Path $script:Root 'Demo/src/Proj/Sub/Thing.cs'))
            $r.Output.Trim() | Should -BeNullOrEmpty
        }

        It 'stays silent on a file type whose pack apm.yml does not list' {
            Set-AiSdlcTestPack -Root $script:Root -Packs blazor
            $broken = Join-Path $script:Root 'Demo/src/Proj/Sub/Broken.cs'
            Set-Content -LiteralPath $broken -Value 'class Broken {'

            $r = Invoke-Hook -Payload (New-Payload -FilePath $broken)

            $r.Output.Trim() | Should -BeNullOrEmpty
        }
    }

    Context 'a markdown edit' {
        It 'returns the reading-level findings as additionalContext when the gate fails' {
            $r = Invoke-Hook -Payload (New-Payload -FilePath (Join-Path $script:Root 'docs/page.md')) -ReadingLevelScript $script:FailingReadingLevel

            $r.ExitCode | Should -Be 0
            $json = $r.Output | ConvertFrom-Json
            $json.hookSpecificOutput.hookEventName | Should -Be 'PostToolUse'
            $json.hookSpecificOutput.additionalContext | Should -Match 'Reading level \(C11\) on docs/page.md'
            $json.hookSpecificOutput.additionalContext | Should -Match '1 sentence over 25 words'
        }

        It 'passes the edited file to the reading-level gate as a repository-relative path' {
            $r = Invoke-Hook -Payload (New-Payload -FilePath (Join-Path $script:Root 'docs/page.md')) -ReadingLevelScript $script:FailingReadingLevel
            ($r.Output | ConvertFrom-Json).hookSpecificOutput.additionalContext | Should -Match 'docs/page.md : 1 sentence'
        }

        It 'returns the em-dash findings when that gate fails' {
            $r = Invoke-Hook -Payload (New-Payload -FilePath (Join-Path $script:Root 'docs/page.md')) -EmDashScript $script:FailingEmDash
            ($r.Output | ConvertFrom-Json).hookSpecificOutput.additionalContext | Should -Match 'Em-dash \(C06\)'
        }

        It 'passes the edited file to the em-dash gate, so a finding elsewhere does not blame this file' {
            $r = Invoke-Hook -Payload (New-Payload -FilePath (Join-Path $script:Root 'docs/page.md')) -EmDashScript $script:FailingEmDash
            ($r.Output | ConvertFrom-Json).hookSpecificOutput.additionalContext | Should -Match 'docs/page.md:3  an em-dash line'
            ($r.Output | ConvertFrom-Json).hookSpecificOutput.additionalContext | Should -Not -Match 'the push will run'
        }

        It 'stays silent when both gates pass' {
            $r = Invoke-Hook -Payload (New-Payload -FilePath (Join-Path $script:Root 'docs/page.md'))
            $r.Output.Trim() | Should -BeNullOrEmpty
        }

        It 'accepts a relative path and the Write tool' {
            $r = Invoke-Hook -Payload (New-Payload -FilePath 'docs/page.md' -Tool 'Write') -ReadingLevelScript $script:FailingReadingLevel
            $r.Output | Should -Match 'additionalContext'
        }

        It 'reads the Copilot toolArgs shape too' {
            $payload = @{ tool_name = 'Edit'; toolArgs = (@{ path = 'docs/page.md' } | ConvertTo-Json -Compress) } | ConvertTo-Json -Compress
            $r = Invoke-Hook -Payload $payload -ReadingLevelScript $script:FailingReadingLevel
            $r.Output | Should -Match 'additionalContext'
        }

        It 'writes the feedback at the top level too, the only shape Copilot CLI reads after an edit' {
            $r = Invoke-Hook -Payload (New-Payload -FilePath 'docs/page.md') -ReadingLevelScript $script:FailingReadingLevel
            $json = $r.Output | ConvertFrom-Json

            $json.additionalContext | Should -Match 'Reading level \(C11\) on docs/page.md'
            $json.additionalContext | Should -Be $json.hookSpecificOutput.additionalContext
        }

        It 'checks the file of an apply_patch call, the way a GPT model edits in Copilot CLI' {
            $payload = @{ hook_event_name = 'PostToolUse'; tool_name = 'Edit'; tool_input = "*** Begin Patch`n*** Update File: docs/page.md`n@@`n-Text.`n+More text.`n*** End Patch`n" } | ConvertTo-Json -Compress
            $r = Invoke-Hook -Payload $payload -ReadingLevelScript $script:FailingReadingLevel

            ($r.Output | ConvertFrom-Json).additionalContext | Should -Match 'docs/page.md : 1 sentence'
        }
    }

    Context 'a file type an installed pack claims' {
        It 'runs the postEdit script of the pack and returns what it wrote as additionalContext' {
            $broken = Join-Path $script:Root 'Demo/src/Proj/Sub/Broken.cs'
            Set-Content -LiteralPath $broken -Value 'class Broken {'

            $r = Invoke-Hook -Payload (New-Payload -FilePath $broken)

            $r.ExitCode | Should -Be 0
            ($r.Output | ConvertFrom-Json).hookSpecificOutput.additionalContext | Should -Match 'pack check ran on Demo/src/Proj/Sub/Broken.cs'
        }

        It 'hands a Razor file to the same pack, because the pack names both extensions' {
            $razor = Join-Path $script:Root 'Demo/src/Proj/Sub/BrokenPage.razor'
            Set-Content -LiteralPath $razor -Value '<h1>Page'

            $r = Invoke-Hook -Payload (New-Payload -FilePath $razor)

            $r.Output | Should -Match 'pack check ran on'
        }

        It 'checks every file of a patch and returns one answer, skipping a file the patch deleted' {
            $broken = Join-Path $script:Root 'Demo/src/Proj/Sub/Broken.cs'
            Set-Content -LiteralPath $broken -Value 'class Broken {'
            $patch = @(
                '*** Begin Patch'
                '*** Update File: docs/page.md'
                '@@'
                '-Text.'
                '+More text.'
                '*** Update File: Demo/src/Proj/Sub/Broken.cs'
                '@@'
                '-class Broken {'
                '+class Broken { int x;'
                '*** Delete File: docs/gone.md'
                '*** End Patch'
            ) -join "`n"
            $payload = @{ hook_event_name = 'PostToolUse'; tool_name = 'Edit'; tool_input = $patch } | ConvertTo-Json -Compress

            $r = Invoke-Hook -Payload $payload -ReadingLevelScript $script:FailingReadingLevel

            @($r.Output.Trim() -split "`n") | Should -HaveCount 1
            $context = ($r.Output | ConvertFrom-Json).additionalContext
            $context | Should -Match 'Reading level \(C11\) on docs/page.md'
            $context | Should -Match 'pack check ran on Demo/src/Proj/Sub/Broken.cs'
            $context | Should -Not -Match 'gone\.md'
        }

        It 'runs the pack script once for all the files of a patch it claims' {
            $patch = @(
                '*** Begin Patch'
                '*** Update File: Demo/src/Proj/Sub/Broken.cs'
                '@@'
                '-x'
                '+y'
                '*** Update File: Demo/src/Proj/Sub/Other.cs'
                '@@'
                '-x'
                '+y'
                '*** Update File: Demo/src/Proj/Sub/Thing.cs'
                '@@'
                '-class Thing {}'
                '+class Thing { }'
                '*** End Patch'
            ) -join "`n"
            foreach ($name in 'Broken.cs', 'Other.cs') { Set-Content -LiteralPath (Join-Path $script:Root "Demo/src/Proj/Sub/$name") -Value 'x' }
            $payload = @{ hook_event_name = 'PostToolUse'; tool_name = 'Edit'; tool_input = $patch } | ConvertTo-Json -Compress

            $r = Invoke-Hook -Payload $payload

            @(Get-Content -LiteralPath (Join-Path $script:Root 'pack-calls.log')) | Should -HaveCount 1
            ($r.Output | ConvertFrom-Json).additionalContext | Should -Match 'pack check ran on Demo/src/Proj/Sub/Broken.cs, Demo/src/Proj/Sub/Other.cs, Demo/src/Proj/Sub/Thing.cs'
        }
    }

    Context 'wiring' {
        It 'is registered in the hook entries of the package for Edit and Write' {
            $settings = Get-AiSdlcHookSettings -From $PSScriptRoot
            $settings | Should -Not -BeNullOrEmpty
            $post = @($settings.hooks.PostToolUse)
            $entry = $post | Where-Object { $_.matcher -eq 'Edit|Write' }
            $entry | Should -Not -BeNullOrEmpty
            @($entry.hooks.command) | Should -Contain 'pwsh -NoProfile -File .claude/skills/ai-sdlc-hooks/scripts/Invoke-PostEditCheck.ps1'
        }

        It 'names only hook scripts that exist in an installed skill' {
            $settings = Get-AiSdlcHookSettings -From $PSScriptRoot
            $commands = @($settings.hooks.PSObject.Properties.Value | ForEach-Object { $_ } | ForEach-Object { $_.hooks } | ForEach-Object { $_.command })
            $commands | Should -Not -BeNullOrEmpty
            $missing = foreach ($command in $commands) {
                foreach ($match in [regex]::Matches($command, '\.claude/skills/([^/\s]+)/(\S+\.ps1)')) {
                    $skill = Find-AiSdlcSkillFolder -Name $match.Groups[1].Value -From $PSScriptRoot
                    if (-not $skill -or -not (Test-Path -LiteralPath (Join-Path $skill $match.Groups[2].Value))) { $match.Value }
                }
            }
            $missing | Should -BeNullOrEmpty
        }

        It 'finds the dotnet build step through the postEdit entry of dotnet-gates' {
            $dotnetGates = Find-AiSdlcSkillFolder -Name 'dotnet-gates' -From $PSScriptRoot
            if (-not $dotnetGates) { Set-ItResult -Skipped -Because 'the dotnet pack is not installed here, so there is no dotnet-gates skill to read'; return }
            $gates = Get-Content -LiteralPath (Join-Path $dotnetGates 'gates.json') -Raw | ConvertFrom-Json
            @($gates.postEdit.extensions) | Should -Be @('.cs', '.razor')
            Test-Path -LiteralPath (Join-Path $dotnetGates $gates.postEdit.script) | Should -BeTrue
        }
    }
}
