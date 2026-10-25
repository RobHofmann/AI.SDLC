#requires -Version 7.4

Describe 'The code graph is read through one checked door' {
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

        function Get-SharedRoot {
            if ($script:SourceRoot) { return @((Join-Path $script:SourceRoot 'core'), (Join-Path $script:SourceRoot 'packs')) }
            $claude = Split-Path -Parent $script:SkillsRoot
            return @($script:SkillsRoot, (Join-Path $claude 'agents') | Where-Object { Test-Path -LiteralPath $_ })
        }

        function Get-ToolText {
            param([Parameter(Mandatory)][string]$Skill, [Parameter(Mandatory)][string]$Name)
            return Get-Content -LiteralPath (Join-Path (Find-Skill $Skill) 'scripts' $Name) -Raw -Encoding utf8
        }

        function Get-GraphNamingScript {
            $found = foreach ($skill in (Get-SkillFolder)) {
                $scripts = Join-Path $skill.FullName 'scripts'
                if (-not (Test-Path -LiteralPath $scripts)) { continue }
                foreach ($file in (Get-ChildItem -Path (Join-Path $scripts '*') -File -Include '*.ps1', '*.psm1')) {
                    if ($file.Name -like '*.Tests.ps1') { continue }
                    $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
                    if (-not $text -or $text -notmatch 'graph\.json') { continue }
                    [pscustomobject]@{ Name = $file.Name; Text = $text }
                }
            }
            return @($found)
        }

        $script:GraphDoorExemption = [ordered]@{
            'CodeGraph.psm1'           = 'is the door: it reads the graph and checks the freshness'
            'Invoke-GraphifyIndex.ps1' = 'builds the graph and reports on it'
            'Invoke-DocGraphLink.ps1'  = 'writes the documentation edges back into it'
        }
    }

    Context 'every consumer of the graph goes through the one door' {
        It 'finds the scripts that name graph.json, so an empty scan cannot pass' {
            @(Get-GraphNamingScript).Count | Should -BeGreaterThan 0
        }

        It 'no script parses graph.json for itself, since the door is where the freshness check lives' {
            $offenders = foreach ($tool in (Get-GraphNamingScript)) {
                if ($script:GraphDoorExemption.Contains($tool.Name)) { continue }
                if ($tool.Text -match '(?m)Get-Content[^\r\n]*\$GraphPath') { "$($tool.Name) parses the graph itself" }
            }

            @($offenders) | Should -BeNullOrEmpty -Because 'a second reader is a second place where the freshness check can be forgotten'
        }

        It 'a script that names graph.json calls Get-GraphIndex, or is exempted here by name with a reason' {
            $offenders = foreach ($tool in (Get-GraphNamingScript)) {
                if ($script:GraphDoorExemption.Contains($tool.Name)) { continue }
                if ($tool.Text -notmatch 'Get-GraphIndex') { "$($tool.Name) names the graph without going through Get-GraphIndex" }
            }

            @($offenders) | Should -BeNullOrEmpty
        }

        It 'the door checks the freshness on every load, so no caller has to remember to ask' {
            $door = [regex]::Match((Get-ToolText 'dotnet-code-graph' 'CodeGraph.psm1'), '(?s)function Get-GraphIndex \{.*?\r?\n\}')

            $door.Success | Should -BeTrue
            $door.Value | Should -Match 'Get-GraphFreshness'
            $door.Value | Should -Match 'Write-GraphFreshnessWarning'
        }

        It 'the generator refuses a stale graph, because it writes claims a reader then trusts' {
            $text = Get-ToolText 'dotnet-code-graph' 'Update-DocFromGraph.ps1'

            $text | Should -Match "Freshness\.State -eq 'Stale'"
            $text | Should -Match 'AllowStaleGraph'
        }
    }

    Context 'an agent asks the graph through the wrapper' {
        It 'no shared skill or agent tells an agent to run a raw graphify query, which checks nothing' {
            $offenders = foreach ($root in (Get-SharedRoot)) {
                foreach ($file in (Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.md')) {
                    if ($file.FullName -notmatch '[\\/](skills|agents)[\\/]') { continue }
                    $number = 0
                    foreach ($line in (Get-Content -LiteralPath $file.FullName -Encoding utf8)) {
                        $number++
                        if ($line -notmatch 'graphify\s+(affected|explain|path)\b') { continue }
                        if ($line -match 'Invoke-GraphifyQuery') { continue }
                        "$($file.Name) names a raw query on line $number"
                    }
                }
            }

            @($offenders) | Should -BeNullOrEmpty -Because 'the CLI reads the graph without checking it, so the instruction has to point at the wrapper'
        }

        It 'the hook that catches a raw query anyway is registered for Bash and for PowerShell' {
            if ($script:SourceRoot) {
                $registration = Join-Path (Split-Path -Parent (Split-Path -Parent (Find-Skill 'dotnet-code-graph'))) 'hooks' 'dotnet-hooks.json'
            }
            else {
                $registration = Join-Path (Split-Path -Parent $script:SkillsRoot) 'settings.json'
            }
            if (-not (Test-Path -LiteralPath $registration)) { Set-ItResult -Skipped -Because "this layout has no $([IO.Path]::GetFileName($registration)) to read"; return }

            $hooks = @((Get-Content -LiteralPath $registration -Raw -Encoding utf8 | ConvertFrom-Json).hooks.PreToolUse |
                    Where-Object { @($_.matcher -split '\|') -contains 'Bash' -and @($_.matcher -split '\|') -contains 'PowerShell' } | ForEach-Object { $_.hooks } |
                    Where-Object { $_.command -eq 'pwsh -NoProfile -File .claude/skills/dotnet-code-graph/scripts/Deny-StaleGraphQuery.ps1' })

            $hooks.Count | Should -BeGreaterThan 0
            @($hooks.if) | Should -Contain 'Bash(graphify*)'
            @($hooks.if) | Should -Contain 'PowerShell(*graphify*)'
        }

        It 'the wrapper asks only the read-only queries, so it cannot become a second extract path' {
            $text = Get-ToolText 'dotnet-code-graph' 'Invoke-GraphifyQuery.ps1'

            $allowed = [regex]::Match($text, "(?m)^\`$script:AllowedSubcommand = @\(([^)]+)\)")

            $allowed.Success | Should -BeTrue
            $allowed.Groups[1].Value | Should -Not -Match 'extract'
            $text | Should -Match 'Get-GraphIndex'
        }
    }

    Context 'the two modules agree on what a test double is called' {
        It 'DocSurface and CodeGraph carry the same prefix pattern' {
            $pattern = "(?m)^\`$script:TestDoublePrefix = '([^']+)'\r?`$"

            $values = foreach ($module in @(@('dotnet-gates', 'DocSurface.psm1'), @('dotnet-code-graph', 'CodeGraph.psm1'))) {
                $match = [regex]::Match((Get-ToolText $module[0] $module[1]), $pattern)
                $match.Success | Should -BeTrue -Because "$($module[1]) should declare the pattern once"
                $match.Groups[1].Value
            }

            @($values)[0] | Should -Be @($values)[1]
        }
    }

    Context 'the pinned graphify version is written once' {
        It 'graphify-version.json holds the pin' {
            $pin = (Get-Content -LiteralPath (Join-Path (Find-Skill 'dotnet-code-graph') 'scripts' 'graphify-version.json') -Raw -Encoding utf8 | ConvertFrom-Json).graphifyVersion

            $pin | Should -Match '^[0-9]+\.[0-9]+\.[0-9]+$'
        }

        It 'every graphify pin written out in a shared file matches graphify-version.json' {
            $pin = (Get-Content -LiteralPath (Join-Path (Find-Skill 'dotnet-code-graph') 'scripts' 'graphify-version.json') -Raw -Encoding utf8 | ConvertFrom-Json).graphifyVersion

            $stale = foreach ($root in (Get-SharedRoot)) {
                foreach ($file in (Get-ChildItem -LiteralPath $root -Recurse -File -Include '*.md', '*.ps1', '*.psm1', '*.yml', '*.yaml', '*.json')) {
                    $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
                    if (-not $text) { continue }
                    foreach ($match in [regex]::Matches($text, 'graphifyy==([0-9]+\.[0-9]+\.[0-9]+)')) {
                        if ($match.Groups[1].Value -ne $pin) { "$($file.Name) names $($match.Groups[1].Value)" }
                    }
                }
            }

            @($stale) | Should -BeNullOrEmpty
        }
    }

    Context 'the documentation tools share one set of rules and say what they did not check' {
        It 'DocSurface holds the rules, and no tool keeps its own copy, because the copies drifted' {
            $module = Get-ToolText 'dotnet-gates' 'DocSurface.psm1'

            $module | Should -Match 'function Get-NamedSourceFile'
            $module | Should -Match 'function Test-ServiceShaped'
            $module | Should -Match 'function Resolve-ProjectByPageName'
            foreach ($tool in @(@('dotnet-gates', 'Check-DocDrift.ps1'), @('dotnet-code-graph', 'Invoke-DocGraphLink.ps1'), @('dotnet-code-graph', 'Update-DocFromGraph.ps1'))) {
                $text = Get-ToolText $tool[0] $tool[1]
                $text | Should -Match 'DocSurface\.psm1'
                $text | Should -Not -Match 'function Get-NamedSourceFile'
                $text | Should -Not -Match 'function Test-ServiceShaped'
            }
        }

        It 'the drift check needs no code graph, so installing graphify is not a prerequisite' {
            $text = Get-ToolText 'dotnet-gates' 'Check-DocDrift.ps1'

            $text | Should -Not -Match '\$GraphPath'
            $text | Should -Match 'no code graph'
        }

        It 'the drift check states its own reach, so a clean run is not read as a correct page' {
            $text = Get-ToolText 'dotnet-gates' 'Check-DocDrift.ps1'

            $text | Should -Match 'NOT CHECKED'
            $text | Should -Match 'not that the pages are correct'
        }

        It 'the relational check reads the graph through CodeGraph and is registered as a gate' {
            Get-ToolText 'dotnet-code-graph' 'Check-DocGraphClaims.ps1' | Should -Match 'CodeGraph\.psm1'
            Get-Content -LiteralPath (Join-Path (Find-Skill 'dotnet-code-graph') 'gates.json') -Raw | Should -Match 'Check-DocGraphClaims\.ps1'
        }

        It 'the generator sends relationships, not only names' {
            $text = Get-ToolText 'dotnet-code-graph' 'Update-DocFromGraph.ps1'

            $text | Should -Match 'CodeGraph\.psm1'
            $text | Should -Match 'Get-ProjectConsumer'
            $text | Should -Match 'Get-ProjectImplementation'
            $text | Should -Match 'ContractProject'
        }

        It 'the generator tells the caller the verification is theirs, so neither assumes the other did it' {
            $text = Get-ToolText 'dotnet-code-graph' 'Update-DocFromGraph.ps1'

            $text | Should -Match 'Verify each added claim against the source'
            $text | Should -Match 'never edits the page and never commits'
        }

        It 'the skill reads the markers the tools print, so a thin page and an untraced name each have a route' {
            $skill = Get-Content -LiteralPath (Join-Path (Find-Skill 'dotnet-code-graph') 'SKILL.md') -Raw -Encoding utf8
            $drift = Get-ToolText 'dotnet-gates' 'Check-DocDrift.ps1'
            $generator = Get-ToolText 'dotnet-code-graph' 'Update-DocFromGraph.ps1'

            foreach ($marker in @('\[thin\]', 'UNVERIFIED:', 'doc-candidates/')) { $skill | Should -Match $marker }
            $drift | Should -Match '\[thin\]'
            $generator | Should -Match 'UNVERIFIED:'
            $generator | Should -Match 'doc-candidates'
        }

        It 'both graph consumers explain a missing graph as a refresh in progress, not only as an error' {
            Get-ToolText 'dotnet-code-graph' 'Update-DocFromGraph.ps1' | Should -Match 'refresh in progress'
            Get-ToolText 'dotnet-code-graph' 'Check-DocGraphClaims.ps1' | Should -Match 'refresh in progress'
        }
    }
}
