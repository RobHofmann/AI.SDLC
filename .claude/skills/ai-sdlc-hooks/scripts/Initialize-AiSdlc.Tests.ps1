#requires -Version 7.4
Describe 'Initialize-AiSdlc' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Initialize-AiSdlc.ps1'
        $script:HooksPath = '.claude/skills/ai-sdlc-hooks/githooks'

        function New-TempRepo {
            param([switch]$WithoutHookFile, [switch]$WithHooksPathSet, [string]$Packs = '[]')
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ("init-aisdlc-" + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            git -C $root init --quiet
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value '{}'
            Set-Content -LiteralPath (Join-Path $root 'apm.yml') -Value ((@('dependencies:', '  apm:') + @($Packs | ConvertFrom-Json | ForEach-Object { "    - ../AI.SDLC/packs/$_" })) -join "`n")
            if (-not $WithoutHookFile) {
                New-Item -ItemType Directory -Path (Join-Path $root $script:HooksPath) -Force | Out-Null
                Set-Content -Path (Join-Path $root $script:HooksPath 'pre-push') -Value "#!/bin/sh`nexit 0"
            }
            if ($WithHooksPathSet) { git -C $root config --local core.hooksPath $script:HooksPath }
            return $root
        }

        function Add-FakePack {
            param([string]$Root, [string]$Skill, [string]$Package)
            $folder = Join-Path $Root '.claude' 'skills' $Skill
            New-Item -ItemType Directory -Path (Join-Path $folder 'scripts') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $folder 'gates.json') -Value "{ `"package`": `"$Package`", `"gates`": [], `"setup`": `"scripts/Setup.ps1`" }"
            Set-Content -LiteralPath (Join-Path $folder 'scripts' 'Setup.ps1') -Value @"
[CmdletBinding(SupportsShouldProcess)]
param([string]`$RepoRoot, [switch]`$Minimal, [switch]`$Plan)
if (`$Plan) { if (-not `$Minimal) { '$Skill install' }; return }
[pscustomobject]@{ Step = '$Skill setup'; Status = 'PASS'; Detail = "minimal=`$Minimal whatif=`$WhatIfPreference" }
"@
        }

        function Invoke-Init {
            param([string]$Root, [switch]$WhatIf, [switch]$Minimal, [switch]$SkipGraphify)
            $p = @{ RepoRoot = $Root; SkipGlobalGitConfig = $true }
            if ($WhatIf) { $p['WhatIf'] = $true }
            if ($Minimal) { $p['Minimal'] = $true }
            if ($SkipGraphify) { $p['SkipGraphify'] = $true }
            $out = & $script:ScriptUnderTest @p *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }
    }

    AfterAll {
        Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'init-aisdlc-*' -Directory -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'refuses a directory that is not a git working tree' {
        $plain = Join-Path ([System.IO.Path]::GetTempPath()) ("init-aisdlc-" + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $plain -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $plain 'aisdlc.json') -Value '{}'
        $r = Invoke-Init -Root $plain
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'not inside a git working tree'
    }

    It 'points core.hooksPath at the git hooks of the ai-sdlc-hooks skill on a fresh clone' {
        $root = New-TempRepo
        $r = Invoke-Init -Root $root
        $r.ExitCode | Should -Be 0
        (git -C $root config --local core.hooksPath) | Should -Be $script:HooksPath
        $r.Output | Should -Match 'SET'
    }

    It 'moves a clone that still points at .githooks to the new folder' {
        $root = New-TempRepo
        git -C $root config --local core.hooksPath .githooks
        Invoke-Init -Root $root | Out-Null
        (git -C $root config --local core.hooksPath) | Should -Be $script:HooksPath
    }

    It 'is idempotent and reports the hook wiring as already in place' {
        $root = New-TempRepo -WithHooksPathSet
        $r = Invoke-Init -Root $root
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'already'
        (git -C $root config --local core.hooksPath) | Should -Be $script:HooksPath
    }

    It 'changes nothing under -WhatIf' {
        $root = New-TempRepo
        $r = Invoke-Init -Root $root -WhatIf
        $r.ExitCode | Should -Be 0
        (git -C $root config --local core.hooksPath 2>$null) | Should -BeNullOrEmpty
        $r.Output | Should -Match 'WHATIF'
    }

    Context 'the temp/ folder' {
        BeforeAll {
            function Get-Exclude([string]$Root) {
                $path = Join-Path $Root '.git' 'info' 'exclude'
                if (Test-Path -LiteralPath $path) { return @(Get-Content -LiteralPath $path) }
                return @()
            }
        }

        It 'adds temp/ to .git/info/exclude when no ignore rule covers it, once' {
            $root = New-TempRepo
            $r = Invoke-Init -Root $root
            $r.ExitCode | Should -Be 0 -Because $r.Output
            git -C $root check-ignore -q temp/preflight/receipt.json
            $LASTEXITCODE | Should -Be 0
            Invoke-Init -Root $root | Out-Null
            @(Get-Exclude $root | Where-Object { $_ -eq 'temp/' }) | Should -HaveCount 1
        }

        It 'leaves .git/info/exclude alone when .gitignore already covers temp/' {
            $root = New-TempRepo
            Set-Content -LiteralPath (Join-Path $root '.gitignore') -Value 'temp/'
            $r = Invoke-Init -Root $root
            $r.ExitCode | Should -Be 0 -Because $r.Output
            Get-Exclude $root | Should -Not -Contain 'temp/'
        }

        It 'changes nothing under -WhatIf' {
            $root = New-TempRepo
            Invoke-Init -Root $root -WhatIf | Out-Null
            Get-Exclude $root | Should -Not -Contain 'temp/'
        }

        It 'adds the receipt folder that paths.preflightReceipts names to .git/info/exclude' {
            $root = New-TempRepo
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value '{ "paths": { "preflightReceipts": "out/receipts" } }'
            $r = Invoke-Init -Root $root
            $r.ExitCode | Should -Be 0 -Because $r.Output
            git -C $root check-ignore -q out/receipts/x.json
            $LASTEXITCODE | Should -Be 0
            Get-Exclude $root | Should -Contain 'temp/'
            Invoke-Init -Root $root | Out-Null
            @(Get-Exclude $root | Where-Object { $_ -eq '/out/receipts/' }) | Should -HaveCount 1
        }

        It 'anchors a one-part receipt folder at the root, so git does not ignore that name at every depth' {
            $root = New-TempRepo
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value '{ "paths": { "preflightReceipts": "out" } }'
            $r = Invoke-Init -Root $root
            $r.ExitCode | Should -Be 0 -Because $r.Output
            git -C $root check-ignore -q out/x.json
            $LASTEXITCODE | Should -Be 0
            git -C $root check-ignore -q src/out/x.json
            $LASTEXITCODE | Should -Be 1 -Because 'a folder named out deeper in the tree is not the receipt folder'
            Get-Exclude $root | Should -Contain '/out/'
        }

        It 'writes a receipt folder given with a leading ./ as a rule git matches, once' {
            $root = New-TempRepo
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value '{ "paths": { "preflightReceipts": "./out" } }'
            $r = Invoke-Init -Root $root
            $r.ExitCode | Should -Be 0 -Because $r.Output
            git -C $root check-ignore -q out/x.json
            $LASTEXITCODE | Should -Be 0
            Invoke-Init -Root $root | Out-Null
            @(Get-Exclude $root | Where-Object { $_ -eq '/out/' }) | Should -HaveCount 1
            Get-Exclude $root | Should -Not -Contain './out/'
        }

        It 'writes a receipt folder given with a leading / as a rule git matches, because the receipts land under the repository' {
            $root = New-TempRepo
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value '{ "paths": { "preflightReceipts": "/out" } }'
            $r = Invoke-Init -Root $root
            $r.ExitCode | Should -Be 0 -Because $r.Output
            git -C $root check-ignore -q out/x.json
            $LASTEXITCODE | Should -Be 0
        }

        It 'adds no rule of its own for a receipt folder under temp/' {
            $root = New-TempRepo
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value '{ "paths": { "preflightReceipts": "temp/receipts" } }'
            Invoke-Init -Root $root | Out-Null
            Get-Exclude $root | Should -Not -Contain 'temp/receipts/'
            @(Get-Exclude $root | Where-Object { $_ -eq 'temp/' }) | Should -HaveCount 1
        }
    }

    It 'fails when the tree carries no pre-push hook to enable' {
        $root = New-TempRepo -WithoutHookFile
        $r = Invoke-Init -Root $root
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'no \.claude/skills/ai-sdlc-hooks/githooks/pre-push found'
    }

    It 'reports the core toolchain rows so a developer sees what is missing' {
        $root = New-TempRepo
        $r = Invoke-Init -Root $root
        $r.Output | Should -Match 'PowerShell 7'
        $r.Output | Should -Match 'pwsh on PATH'
        $r.Output | Should -Match 'Pester'
        $r.Output | Should -Match 'gitleaks'
    }

    It 'says up front what it is about to do, before it does it, with the plan of each pack' {
        $root = New-TempRepo -Packs '["dotnet"]'
        Add-FakePack -Root $root -Skill 'demo-dotnet' -Package 'dotnet'
        $r = Invoke-Init -Root $root -WhatIf
        $r.Output | Should -Match 'This run will do: git wiring, prerequisite check, demo-dotnet install\.'
        $r.Output.IndexOf('This run will do') | Should -BeLessThan $r.Output.IndexOf('[1] Git hooks')
    }

    It 'runs the setup of each pack apm.yml lists, and skips a pack it does not list' {
        $root = New-TempRepo -Packs '["dotnet"]'
        Add-FakePack -Root $root -Skill 'demo-dotnet' -Package 'dotnet'
        Add-FakePack -Root $root -Skill 'demo-bicep' -Package 'bicep'
        $r = Invoke-Init -Root $root
        $r.Output | Should -Match 'demo-dotnet setup'
        $r.Output | Should -Not -Match 'demo-bicep setup'
    }

    It 'passes its switches and -WhatIf through to the setup of a pack' {
        $root = New-TempRepo -Packs '["dotnet"]'
        Add-FakePack -Root $root -Skill 'demo-dotnet' -Package 'dotnet'
        $r = Invoke-Init -Root $root -Minimal -WhatIf
        $r.Output | Should -Match 'minimal=True whatif=True'
        $r.Output | Should -Match 'This run will do: git wiring, prerequisite check\.'
    }

    It 'points the developer at the local gate runner when it finishes' {
        $root = New-TempRepo
        $r = Invoke-Init -Root $root
        $r.Output | Should -Match '\.claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates\.ps1'
    }

    It 'finds the setup scripts the shipped packs declare' {
        Import-Module (Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts' 'DocToolTestHarness.psm1') -Force
        $checked = 0
        foreach ($skill in 'dotnet-gates', 'dotnet-code-graph', 'azure-devops-pull-requests') {
            $folder = Find-AiSdlcSkillFolder -Name $skill -From $PSScriptRoot
            if (-not $folder) { continue }
            $manifest = Get-Content -LiteralPath (Join-Path $folder 'gates.json') -Raw | ConvertFrom-Json
            $manifest.setup | Should -Not -BeNullOrEmpty -Because "$skill declares a setup step"
            Test-Path -LiteralPath (Join-Path $folder $manifest.setup) | Should -BeTrue
            $checked++
        }
        if ($checked -eq 0) { Set-ItResult -Skipped -Because 'none of the packs with a setup step is installed here' }
    }

    It 'writes the shared parts of AGENTS.md at the end of a run' {
        $root = New-TempRepo
        $assets = Join-Path $root '.claude' 'skills' 'ai-sdlc-gates' 'assets'
        New-Item -ItemType Directory -Path $assets -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $assets 'agents-core.md') -Value "## Communication`n`nSay the main thing first."
        Set-Content -LiteralPath (Join-Path $root 'AGENTS.md') -Value "# AGENTS.md`n`n## Build`n`nRun the build.`n"
        $r = Invoke-Init -Root $root
        $r.ExitCode | Should -Be 0 -Because $r.Output
        (Get-Content -LiteralPath (Join-Path $root 'AGENTS.md') -Raw) | Should -Match 'ai-sdlc:core:start'
        $r.Output | Should -Match 'AGENTS\.md'
    }

    It 'leaves AGENTS.md alone under -WhatIf' {
        $root = New-TempRepo
        $assets = Join-Path $root '.claude' 'skills' 'ai-sdlc-gates' 'assets'
        New-Item -ItemType Directory -Path $assets -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $assets 'agents-core.md') -Value "## Communication`n`nSay the main thing first."
        Set-Content -LiteralPath (Join-Path $root 'AGENTS.md') -Value "# AGENTS.md`n`n## Build`n`nRun the build.`n"
        $r = Invoke-Init -Root $root -WhatIf
        (Get-Content -LiteralPath (Join-Path $root 'AGENTS.md') -Raw) | Should -Not -Match 'ai-sdlc:core:start'
        $r.Output | Should -Match 'would write the shared parts'
    }
}
