#requires -Version 7.4

Describe 'The shared scripts are wired the same way in every repository' {
    BeforeAll {
        $script:SkillsRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..' '..')).Path
        $script:SourceRoot = $null
        if ((Split-Path -Leaf (Split-Path -Parent $script:SkillsRoot)) -eq '.apm') {
            $dir = $script:SkillsRoot
            while ($dir) {
                if ((Test-Path -LiteralPath (Join-Path $dir 'core' '.apm' 'skills')) -and (Test-Path -LiteralPath (Join-Path $dir 'packs'))) {
                    $script:SourceRoot = $dir
                    break
                }
                $dir = Split-Path -Parent $dir
            }
        }

        function Get-SkillFolder {
            if ($script:SourceRoot) {
                return @(Get-ChildItem -Path (Join-Path $script:SourceRoot 'core' '.apm' 'skills' '*'), (Join-Path $script:SourceRoot 'packs' '*' '.apm' 'skills' '*') -Directory)
            }
            return @(Get-ChildItem -Path (Join-Path $script:SkillsRoot '*') -Directory)
        }

        function Find-Skill {
            param([Parameter(Mandatory)][string]$Name)
            $sibling = Join-Path $script:SkillsRoot $Name
            if (Test-Path -LiteralPath $sibling) { return (Resolve-Path -LiteralPath $sibling).Path }
            if ($script:SourceRoot) {
                $found = @(Get-ChildItem -Path (Join-Path $script:SourceRoot 'core' '.apm' 'skills' $Name), (Join-Path $script:SourceRoot 'packs' '*' '.apm' 'skills' $Name) -Directory -ErrorAction SilentlyContinue)
                if ($found.Count -gt 0) { return $found[0].FullName }
            }
            return $null
        }

        function Get-ScriptFile {
            param([string[]]$Include = @('*.ps1', '*.psm1'), [switch]$WithTests)
            $files = foreach ($skill in (Get-SkillFolder)) {
                $scripts = Join-Path $skill.FullName 'scripts'
                if (-not (Test-Path -LiteralPath $scripts)) { continue }
                Get-ChildItem -LiteralPath $scripts -File | Where-Object {
                    $name = $_.Name
                    @($Include | Where-Object { $name -like $_ }).Count -gt 0
                }
            }
            if (-not $WithTests) { $files = $files | Where-Object { $_.Name -notlike '*.Tests.ps1' } }
            return @($files)
        }

        function Get-HookRegistration {
            if ($script:SourceRoot) {
                return @(Get-ChildItem -Path (Join-Path $script:SourceRoot 'core' '.apm' 'hooks' '*.json') -File |
                        ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding utf8 | ConvertFrom-Json })
            }
            $settings = Join-Path $script:SkillsRoot '..' 'settings.json'
            if (-not (Test-Path -LiteralPath $settings)) { return @() }
            return @(Get-Content -LiteralPath $settings -Raw -Encoding utf8 | ConvertFrom-Json)
        }

        $script:NoTestExemption = [ordered]@{}
    }

    Context 'every gate and runner script carries its help and its tests' {
        It 'finds the scripts of the installed skills, so an empty scan cannot pass' {
            @(Get-ScriptFile -Include 'Check-*.ps1').Count | Should -BeGreaterThan 0
        }

        It 'every Check and Invoke script carries a <# .SYNOPSIS help block and #Requires -Version 7' {
            $offenders = foreach ($file in (Get-ScriptFile -Include 'Check-*.ps1', 'Invoke-*.ps1')) {
                $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
                if ($text -notmatch '(?s)<#\s*\.SYNOPSIS') { "$($file.Name) has no <# .SYNOPSIS block" }
                if ($text -notmatch '(?mi)^#Requires -Version 7') { "$($file.Name) has no #Requires -Version 7 line" }
            }

            @($offenders) | Should -BeNullOrEmpty
        }

        It 'every Check and Invoke script has a matching Pester file, apart from the ones exempted here by name' {
            $offenders = foreach ($file in (Get-ScriptFile -Include 'Check-*.ps1', 'Invoke-*.ps1')) {
                if ($script:NoTestExemption.Contains($file.Name)) { continue }
                $test = Join-Path $file.DirectoryName ($file.BaseName + '.Tests.ps1')
                if (-not (Test-Path -LiteralPath $test)) { "$($file.Name) has no $($file.BaseName).Tests.ps1" }
            }

            @($offenders) | Should -BeNullOrEmpty
        }

        It 'exempts no script that now has a Pester file, so the list cannot go stale' {
            $stale = foreach ($file in (Get-ScriptFile -Include 'Invoke-*.ps1', 'Check-*.ps1')) {
                if (-not $script:NoTestExemption.Contains($file.Name)) { continue }
                if (Test-Path -LiteralPath (Join-Path $file.DirectoryName ($file.BaseName + '.Tests.ps1'))) { "$($file.Name) is exempted but has a Pester file" }
            }

            @($stale) | Should -BeNullOrEmpty
        }
    }

    Context 'every gate is registered and tells the reader how to fix what it found' {
        It 'every Check script prints a FIX: line' {
            $silent = foreach ($file in (Get-ScriptFile -Include 'Check-*.ps1')) {
                if ((Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8) -notmatch 'FIX:') { $file.Name }
            }

            @($silent) | Should -BeNullOrEmpty
        }

        It 'every Check script is listed in the gates.json of its own skill, so the runner runs it' {
            $missing = foreach ($file in (Get-ScriptFile -Include 'Check-*.ps1')) {
                $manifest = Join-Path $file.Directory.Parent.FullName 'gates.json'
                if (-not (Test-Path -LiteralPath $manifest)) { "$($file.Name) sits in a skill with no gates.json"; continue }
                $scripts = @((Get-Content -LiteralPath $manifest -Raw -Encoding utf8 | ConvertFrom-Json).gates | ForEach-Object { $_.script })
                if ("scripts/$($file.Name)" -notin $scripts) { "$($file.Name) is not in $($file.Directory.Parent.Name)/gates.json" }
            }

            @($missing) | Should -BeNullOrEmpty
        }
    }

    Context 'the scripts contain no control characters' {
        It 'no script or test carries a stray control character' {
            $suspect = foreach ($file in (Get-ScriptFile -WithTests)) {
                $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
                if (-not $text) { continue }
                $match = [regex]::Match($text, '[\x00-\x08\x0B\x0C\x0E-\x1F]')
                if ($match.Success) { '{0} contains character 0x{1:X2}' -f $file.Name, [int]$match.Value[0] }
            }

            @($suspect) | Should -BeNullOrEmpty
        }
    }

    Context 'a relative repository root works, the way the sibling gates accept one' {
        It 'every script that cuts the root off a path by its length resolves -RepoRoot first' {
            $offenders = foreach ($file in (Get-ScriptFile -Include '*.ps1')) {
                $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
                if ($text -notmatch '\[string\]\$RepoRoot') { continue }
                $cut = [regex]::Match($text, '\.Substring\(\$(RepoRoot|Root)\.Length\)')
                if (-not $cut.Success) { continue }
                $resolve = [regex]::Match($text, 'Resolve-Path -LiteralPath \$RepoRoot')
                if (-not $resolve.Success) { "$($file.Name) cuts the root off a path and never resolves it"; continue }
                if ($resolve.Index -gt $cut.Index) { "$($file.Name) cuts the root off a path before it resolves it" }
            }

            @($offenders) | Should -BeNullOrEmpty
        }
    }

    Context 'the push hook is registered for every push form' {
        It 'runs Deny-IncompletePush.ps1 for git push and for git -C with a path' {
            $registrations = @(Get-HookRegistration)
            if ($registrations.Count -eq 0) { Set-ItResult -Skipped -Because 'this layout carries no hook registration to read'; return }

            $pushHooks = @($registrations | ForEach-Object { $_.hooks.PreToolUse } | Where-Object { @($_.matcher -split '\|') -contains 'Bash' } |
                    ForEach-Object { $_.hooks } | Where-Object { $_.command -like '*Deny-IncompletePush.ps1' })

            @($pushHooks.if) | Should -Contain 'Bash(*git* *push*)' -Because 'Claude Code 2.x matched it for git push, git -C <dir> push and cd <dir> && git push, and not for git log (probed 2026-10-20)'
        }

        It 'starts Deny-IncompletePush.ps1 at most twice per shell command, because Copilot CLI ignores if and runs every entry in turn' {
            $registrations = @(Get-HookRegistration)
            if ($registrations.Count -eq 0) { Set-ItResult -Skipped -Because 'this layout carries no hook registration to read'; return }

            $pushHooks = @($registrations | ForEach-Object { $_.hooks.PreToolUse } | Where-Object { $_.matcher -match 'Bash|PowerShell' } |
                    ForEach-Object { $_.hooks } | Where-Object { $_.command -like '*Deny-IncompletePush.ps1' })

            $pushHooks.Count | Should -BeLessOrEqual 2
        }

        It 'runs Deny-IncompletePush.ps1 for a push through the PowerShell tool too' {
            $registrations = @(Get-HookRegistration)
            if ($registrations.Count -eq 0) { Set-ItResult -Skipped -Because 'this layout carries no hook registration to read'; return }

            $pushHooks = @($registrations | ForEach-Object { $_.hooks.PreToolUse } | Where-Object { @($_.matcher -split '\|') -contains 'PowerShell' } |
                    ForEach-Object { $_.hooks } | Where-Object { $_.command -like '*Deny-IncompletePush.ps1' })

            @($pushHooks.if) | Should -Contain 'PowerShell(*git* *push*)'
        }

        It 'never registers a Bash or PowerShell command hook for every tool call' {
            $registrations = @(Get-HookRegistration)
            if ($registrations.Count -eq 0) { Set-ItResult -Skipped -Because 'this layout carries no hook registration to read'; return }

            $everyTool = @($registrations | ForEach-Object { $_.hooks.PreToolUse } | Where-Object { -not $_.matcher -or $_.matcher -eq '*' } |
                    ForEach-Object { $_.hooks } | Where-Object { $_.command -like '*Deny-IncompletePush.ps1' -or $_.command -like '*Deny-StaleGraphQuery.ps1' })

            $everyTool | Should -BeNullOrEmpty
        }
    }

    Context 'the agent never merges, and no allow rule runs an open command' {
        It 'runs Deny-AgentMerge.ps1 for the Bash and the PowerShell tool' {
            $registrations = @(Get-HookRegistration)
            if ($registrations.Count -eq 0) { Set-ItResult -Skipped -Because 'this layout carries no hook registration to read'; return }

            $mergeHooks = @($registrations | ForEach-Object { $_.hooks.PreToolUse } | Where-Object { $_.matcher -match 'Bash|PowerShell' } |
                    ForEach-Object { $_.hooks } | Where-Object { $_.command -like '*Deny-AgentMerge.ps1' })

            @($mergeHooks.if) | Should -Contain 'Bash(*gh* *merge*)'
            @($mergeHooks.if) | Should -Contain 'PowerShell(*gh* *merge*)'
        }

        It 'allows no pwsh -Command or -c rule, because any command could follow the allowed one' {
            $rules = foreach ($skill in (Get-SkillFolder)) {
                $manifest = Join-Path $skill.FullName 'gates.json'
                if (Test-Path -LiteralPath $manifest) { @((Get-Content -LiteralPath $manifest -Raw -Encoding utf8 | ConvertFrom-Json).allow) }
            }

            @($rules | Where-Object { $_ -match '(?i)\bpwsh\b.*\s-(?:Command|c)\s' }) | Should -BeNullOrEmpty
        }

        It 'allows no git or gh rule with a wildcard before its subcommand' {
            $rules = foreach ($skill in (Get-SkillFolder)) {
                $manifest = Join-Path $skill.FullName 'gates.json'
                if (Test-Path -LiteralPath $manifest) { @((Get-Content -LiteralPath $manifest -Raw -Encoding utf8 | ConvertFrom-Json).allow) }
            }

            # A * there also matches global options such as git -c core.sshCommand=..., which run any command.
            @($rules | Where-Object { $_ -match '^(?:(?:Bash|PowerShell)\()?(?:git|gh)(?:\s+-[^\s*]*)*\s+(?:-\S*)?\*' }) | Should -BeNullOrEmpty
        }

        It 'allows a push only to a named remote, never with an open option before it' {
            $rules = foreach ($skill in (Get-SkillFolder)) {
                $manifest = Join-Path $skill.FullName 'gates.json'
                if (Test-Path -LiteralPath $manifest) { @((Get-Content -LiteralPath $manifest -Raw -Encoding utf8 | ConvertFrom-Json).allow) }
            }
            $pushRules = @($rules | ForEach-Object { $_ -replace '^(?:Bash|PowerShell)\((.*)\)$', '$1' } | Where-Object { $_ -match '^git\s+push\b' })

            # An open option such as --receive-pack=<cmd> runs a command when the remote is a local path.
            $open = @($pushRules | Where-Object {
                    $tokens = @(($_ -split '\s+') | Select-Object -Skip 2)
                    if ($tokens.Count -gt 0 -and $tokens[0] -in '--set-upstream', '-u') { $tokens = @($tokens | Select-Object -Skip 1) }
                    $tokens.Count -gt 0 -and $tokens[0] -match '^[*-]'
                })
            $open | Should -BeNullOrEmpty
        }
    }

    Context 'the shared pull request action' {
        It 'ships the composite action with its three inputs and no Azure DevOps logging command' {
            $action = Join-Path (Find-Skill 'ai-sdlc-gates') 'assets' 'actions' 'ai-sdlc-pr' 'action.yml'
            Test-Path -LiteralPath $action | Should -BeTrue
            $text = Get-Content -LiteralPath $action -Raw -Encoding utf8

            $text | Should -Match '(?m)^\s+using: composite'
            foreach ($name in 'coverage-file', 'pre-gate-command', 'private-terms') { $text | Should -Match "(?m)^  ${name}:" }
            $text | Should -Match 'Invoke-LocalGates\.ps1'
            $text | Should -Match 'Install-Gitleaks\.ps1' -Because 'the C03 gate scans with the pinned gitleaks that the action installs'
            $text | Should -Not -Match '##vso'
        }
    }

    Context 'the documentation drift check runs for everyone, not only for people with an agent' {
        BeforeAll {
            $script:PrePush = Join-Path (Find-Skill 'ai-sdlc-hooks') 'githooks' 'pre-push'
        }

        It 'the pre-push hook, which fires from any tool, runs the blocking gates of the installed packs' {
            Get-Content -LiteralPath $script:PrePush -Raw | Should -Match 'Invoke-LocalGates\.ps1'
            Get-Content -LiteralPath $script:PrePush -Raw | Should -Match '-BlockingOnly'
        }

        It 'the dotnet pack registers Check-DocDrift.ps1 as a blocking gate, so that run covers it' {
            $skill = Find-Skill 'dotnet-gates'
            if (-not $skill) { Set-ItResult -Skipped -Because 'the dotnet pack is not installed here'; return }

            $drift = @((Get-Content -LiteralPath (Join-Path $skill 'gates.json') -Raw -Encoding utf8 | ConvertFrom-Json).gates |
                    Where-Object { $_.script -eq 'scripts/Check-DocDrift.ps1' })

            $drift | Should -HaveCount 1
            $drift[0].mode | Should -Be 'Blocking'
        }

        It 'the pre-push hook does not run Check-DocDrift.ps1 a second time next to the runner' {
            $code = @(Get-Content -LiteralPath $script:PrePush | Where-Object { $_ -notmatch '^\s*#' })
            @($code | Where-Object { $_ -match 'Check-DocDrift\.ps1' }) | Should -BeNullOrEmpty
        }
    }

    Context 'the skills reach for the documentation tools instead of checking by eye' {
        BeforeAll {
            function Get-SkillText {
                param([Parameter(Mandatory)][string]$Name)
                return Get-Content -LiteralPath (Join-Path (Find-Skill $Name) 'SKILL.md') -Raw -Encoding utf8
            }
        }

        It 'write-docs runs the drift check before it drafts a fix with the generator' {
            $skill = Get-SkillText 'write-docs'

            $skill.IndexOf('Check-DocDrift.ps1') | Should -BeGreaterThan -1
            $skill.IndexOf('Update-DocFromGraph.ps1') | Should -BeGreaterThan $skill.IndexOf('Check-DocDrift.ps1')
            $skill | Should -Match 'Check-DocGraphClaims\.ps1'
        }

        It 'write-docs generates, then verifies each claim itself, then merges, and drops what it could not confirm' {
            $skill = Get-SkillText 'write-docs'

            $generate = $skill.IndexOf('Update-DocFromGraph.ps1')
            $verify = $skill.IndexOf('Verify each added claim before you merge it')
            $merge = $skill.IndexOf('Merge what survived')
            $generate | Should -BeGreaterThan -1
            $verify | Should -BeGreaterThan $generate
            $merge | Should -BeGreaterThan $verify
            $skill | Should -Match 'yours, not a script'
            $skill | Should -Match 'Drop every claim you could not confirm'
            $skill | Should -Match 'add-only'
            $skill | Should -Match 'C09'
        }

        It 'wrap-up checks what the documentation now claims' {
            $skill = Get-SkillText 'wrap-up'

            $skill | Should -Match 'Check-DocDrift\.ps1'
            $skill | Should -Match 'Check-DocGraphClaims\.ps1'
        }

        It 'walk-substrate offers the code graph and states what it cannot see' {
            $skill = Get-SkillText 'walk-substrate'

            $skill | Should -Match 'Invoke-GraphifyIndex\.ps1'
            $skill | Should -Match 'Get-ProjectConsumer'
            $skill | Should -Match 'Service Bus'
        }
    }
}
