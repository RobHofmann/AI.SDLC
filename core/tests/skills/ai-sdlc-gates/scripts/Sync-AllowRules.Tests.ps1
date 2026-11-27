#requires -Version 7.4

BeforeAll { $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm' }

Describe 'Sync-AllowRules' {
    BeforeAll {
        $script:Script = Join-Path $script:ScriptFolder 'Sync-AllowRules.ps1'
        Import-Module (Join-Path $PSScriptRoot 'DocToolTestHarness.psm1') -Force

        function New-AllowRepo {
            param(
                [string[]]$Packs = @(),
                [hashtable]$Manifests = @{ 'ai-sdlc-gates' = @{ package = 'core'; gates = @(); allow = @('git status *') } },
                [string]$Settings,
                [string]$Config = '{ "paths": { "knowledgeRoot": "knowledge-missing" } }',
                [string]$Parent = [System.IO.Path]::GetTempPath()
            )
            $root = Join-Path $Parent ('sar-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value $Config -Encoding utf8
            Set-Content -LiteralPath (Join-Path $root 'apm.yml') -Value ((@('dependencies:', '  apm:') + @($Packs | ForEach-Object { "    - ../AI.SDLC/packs/$_" })) -join "`n")
            foreach ($skill in $Manifests.Keys) {
                $folder = Join-Path $root '.claude' 'skills' $skill
                New-Item -ItemType Directory -Path $folder -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $folder 'gates.json') -Value ($Manifests[$skill] | ConvertTo-Json -Depth 5) -Encoding utf8
            }
            if ($PSBoundParameters.ContainsKey('Settings')) {
                [IO.File]::WriteAllText((Join-Path $root '.claude' 'settings.json'), $Settings)
            }
            return $root
        }

        function Invoke-Sync {
            param([string]$Root, [switch]$Check)
            $extra = @()
            if ($Check) { $extra += '-Check' }
            $run = Invoke-ScriptInProcess -Path $script:Script -Arguments (@('-RepoRoot', $Root) + $extra)
            $path = Join-Path $Root '.claude' 'settings.json'
            $json = try { Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable } catch { $null }
            return [pscustomobject]@{ Code = $run.ExitCode; Output = $run.Output; Settings = $json }
        }
    }

    It 'writes each command of an installed package as a Bash and a PowerShell rule' {
        $root = New-AllowRepo

        $result = Invoke-Sync -Root $root

        $result.Code | Should -Be 0
        $result.Settings.permissions.allow | Should -Be @('Bash(git status *)', 'PowerShell(git status *)')
    }

    It 'writes an entry that names its shell as it is' {
        $root = New-AllowRepo -Manifests @{ 'ai-sdlc-gates' = @{ package = 'core'; allow = @('PowerShell(./run.ps1 *)') } }

        (Invoke-Sync -Root $root).Settings.permissions.allow | Should -Be @('PowerShell(./run.ps1 *)')
    }

    It 'adds the rules of a pack that apm.yml installs, and none of a pack it does not install' {
        $root = New-AllowRepo -Packs @('github-issues') -Manifests @{
            'ai-sdlc-gates'     = @{ package = 'core'; allow = @('git status *') }
            'check-pr-contract' = @{ package = 'github-issues'; allow = @('gh issue view *') }
            'dotnet-gates'      = @{ package = 'dotnet'; allow = @('dotnet test *') }
        }

        $allow = (Invoke-Sync -Root $root).Settings.permissions.allow

        $allow | Should -Contain 'Bash(gh issue view *)'
        $allow | Should -Not -Contain 'Bash(dotnet test *)'
    }

    It 'writes a rule for each gate script by its exact name, in both shells and both pwsh forms' -Tag '#103' {
        $root = New-AllowRepo -Manifests @{ 'ai-sdlc-gates' = @{ package = 'core'; gates = @(@{ name = 'A gate'; script = 'scripts/Check-Thing.ps1' }); allow = @() } }

        $allow = (Invoke-Sync -Root $root).Settings.permissions.allow

        $allow | Should -Be @(
            'Bash(pwsh -NoProfile -File .claude/skills/ai-sdlc-gates/scripts/Check-Thing.ps1)',
            'PowerShell(pwsh -NoProfile -File .claude/skills/ai-sdlc-gates/scripts/Check-Thing.ps1)',
            'Bash(pwsh .claude/skills/ai-sdlc-gates/scripts/Check-Thing.ps1)',
            'PowerShell(pwsh .claude/skills/ai-sdlc-gates/scripts/Check-Thing.ps1)')
    }

    It 'writes a gate rule with the exact arguments of the entry and no star, so the writing form still asks' -Tag '#103' {
        $gate = @{ name = 'Allow rules'; script = 'scripts/Sync-AllowRules.ps1'; args = @{ Check = $true } }
        $root = New-AllowRepo -Manifests @{ 'ai-sdlc-gates' = @{ package = 'core'; gates = @($gate); allow = @() } }

        $allow = (Invoke-Sync -Root $root).Settings.permissions.allow

        $allow | Should -Contain 'Bash(pwsh .claude/skills/ai-sdlc-gates/scripts/Sync-AllowRules.ps1 -Check)'
        $allow | Should -Contain 'PowerShell(pwsh -NoProfile -File .claude/skills/ai-sdlc-gates/scripts/Sync-AllowRules.ps1 -Check)'
        @($allow | Where-Object { $_ -match 'Sync-AllowRules\.ps1(\)| \*)' }).Count | Should -Be 0
    }

    It 'writes the arguments of a gate in a stable order, with a value and a list' -Tag '#103' {
        $gate = @{ name = 'A gate'; script = 'scripts/Check-Thing.ps1'; args = @{ Path = @('core', 'docs'); Language = 'YamlPowerShell'; Strict = $true } }
        $root = New-AllowRepo -Manifests @{ 'ai-sdlc-gates' = @{ package = 'core'; gates = @($gate); allow = @() } }

        $allow = (Invoke-Sync -Root $root).Settings.permissions.allow

        $allow | Should -Contain 'Bash(pwsh .claude/skills/ai-sdlc-gates/scripts/Check-Thing.ps1 -Language YamlPowerShell -Path core,docs -Strict)'
    }

    It 'writes no gate rule for an argument value with a shell character in it' -Tag '#103' {
        $gate = @{ name = 'A gate'; script = 'scripts/Check-Thing.ps1'; args = @{ Path = 'a;b' } }
        $root = New-AllowRepo -Manifests @{ 'ai-sdlc-gates' = @{ package = 'core'; gates = @($gate); allow = @('git status *') } }

        $allow = (Invoke-Sync -Root $root).Settings.permissions.allow

        @($allow | Where-Object { $_ -match 'Check-Thing' }).Count | Should -Be 0
    }

    It 'never writes a package rule that opens a whole shell (<Entry>)' -Tag '#103' -ForEach @(
        @{ Entry = 'Bash(*)' }
        @{ Entry = 'PowerShell(*)' }
        @{ Entry = 'pwsh *' }
        @{ Entry = 'Bash(bash *)' }
    ) {
        $root = New-AllowRepo -Manifests @{ 'ai-sdlc-gates' = @{ package = 'core'; allow = @('git status *', $Entry) } }

        $result = Invoke-Sync -Root $root

        $result.Settings.permissions.allow | Should -Be @('Bash(git status *)', 'PowerShell(git status *)')
        $result.Output | Should -Match 'Allow rule not written'
    }

    It 'writes no rule for a gate script path that leaves the scripts folder' -Tag '#103' {
        $root = New-AllowRepo -Manifests @{ 'ai-sdlc-gates' = @{ package = 'core'; gates = @(@{ name = 'A gate'; script = '../other/Check-Thing.ps1' }); allow = @('git status *') } }

        $allow = (Invoke-Sync -Root $root).Settings.permissions.allow

        @($allow | Where-Object { $_ -match 'Check-Thing' }).Count | Should -Be 0
    }

    It 'never writes a package rule that ends in a wildcard over a scripts folder (<Entry>)' -Tag '#103' -ForEach @(
        @{ Entry = 'pwsh .claude/skills/check-pr-contract/scripts/Check-*' }
        @{ Entry = 'pwsh .claude/skills/check-pr-contract/scripts/Run.ps1*' }
        @{ Entry = 'Bash(pwsh .claude/skills/check-pr-contract/scripts/*)' }
        @{ Entry = 'pwsh .claude/skills/*/scripts/Run.ps1 *' }
        @{ Entry = 'pwsh .claude\skills\check-pr-contract\scripts\*' }
    ) {
        $root = New-AllowRepo -Manifests @{ 'ai-sdlc-gates' = @{ package = 'core'; allow = @('git status *', $Entry) } }

        $result = Invoke-Sync -Root $root

        $result.Settings.permissions.allow | Should -Be @('Bash(git status *)', 'PowerShell(git status *)')
        $result.Output | Should -Match 'Allow rule not written'
    }

    It 'removes a wildcard rule over a scripts folder that an older release wrote, and keeps the rest' -Tag '#103' {
        $settings = '{ "permissions": { "allow": [ "Bash(make *)", "Bash(pwsh .claude/skills/ai-sdlc-gates/scripts/Check-*)", "PowerShell(pwsh -NoProfile -File .claude/skills/dotnet-gates/scripts/Check-*)" ] } }'
        $root = New-AllowRepo -Settings $settings

        $result = Invoke-Sync -Root $root

        $result.Code | Should -Be 0
        $result.Settings.permissions.allow | Should -Be @('Bash(make *)', 'Bash(git status *)', 'PowerShell(git status *)')
    }

    It 'reports a wildcard rule over a scripts folder as drift under -Check, and writes nothing' -Tag '#103' {
        $settings = '{ "permissions": { "allow": [ "Bash(git status *)", "PowerShell(git status *)", "Bash(pwsh .claude/skills/ai-sdlc-gates/scripts/Check-*)" ] } }'
        $root = New-AllowRepo -Settings $settings

        $result = Invoke-Sync -Root $root -Check

        $result.Code | Should -Be 1
        $result.Output | Should -Match 'wildcard over a scripts folder'
        $result.Output | Should -Match ([regex]::Escape('Bash(pwsh .claude/skills/ai-sdlc-gates/scripts/Check-*)'))
        $result.Settings.permissions.allow.Count | Should -Be 3
    }

    It 'keeps the rules the repository added and the rest of the settings, and adds no rule twice' {
        $settings = '{ "permissions": { "allow": [ "Bash(make *)", "Bash(git status *)" ] }, "hooks": { "Stop": [] } }'
        $root = New-AllowRepo -Settings $settings

        $result = Invoke-Sync -Root $root

        $result.Settings.permissions.allow | Should -Be @('Bash(make *)', 'Bash(git status *)', 'PowerShell(git status *)')
        $result.Settings.Contains('hooks') | Should -BeTrue
    }

    It 'fails the check and names the missing rule, and writes nothing' {
        $root = New-AllowRepo -Settings '{ "permissions": { "allow": [ "Bash(git status *)" ] } }'

        $result = Invoke-Sync -Root $root -Check

        $result.Code | Should -Be 1
        $result.Output | Should -Match 'PowerShell\(git status \*\)'
        $result.Settings.permissions.allow | Should -Be @('Bash(git status *)')
    }

    It 'passes the check when every rule is there' {
        $root = New-AllowRepo
        Invoke-Sync -Root $root | Out-Null

        (Invoke-Sync -Root $root -Check).Code | Should -Be 0
    }

    It 'writes the absolute path of the knowledge folder into settings.local.json, never into settings.json' {
        $root = New-AllowRepo -Config '{ "paths": { "knowledgeRoot": "Knowledge" } }' -Settings '{}'
        New-Item -ItemType Directory -Path (Join-Path $root 'Knowledge') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.claude' 'settings.local.json'), '{ "permissions": { "allow": ["Bash(ls)"] } }')

        $result = Invoke-Sync -Root $root
        Invoke-Sync -Root $root | Out-Null

        $result.Code | Should -Be 0
        $local = Get-Content -LiteralPath (Join-Path $root '.claude' 'settings.local.json') -Raw | ConvertFrom-Json -AsHashtable
        $expected = (Resolve-Path -LiteralPath (Join-Path $root 'Knowledge')).Path.Replace('\', '/')
        @($local.permissions.additionalDirectories) | Should -Be @($expected)
        @($local.permissions.allow) | Should -Be @('Bash(ls)')
        $result.Settings.permissions.Contains('additionalDirectories') | Should -BeFalse
    }

    It 'writes a knowledge folder on a network share (UNC path) without the FileSystem:: prefix' -Skip:(-not $IsWindows) {
        # The repository and its knowledge sibling both sit on the share, as on a mapped network drive.
        $local = Join-Path $TestDrive ('share-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path (Join-Path $local 'Knowledge') -Force | Out-Null
        $parent = '//localhost/' + $local.Substring(0, 1) + '$' + $local.Substring(2).Replace('\', '/')
        if (-not (Test-Path -LiteralPath $parent)) { Set-ItResult -Skipped -Because 'the admin share is not available'; return }
        $root = New-AllowRepo -Parent $parent -Config '{ "paths": { "knowledgeRoot": "../Knowledge" } }' -Settings '{}'

        $result = Invoke-Sync -Root $root

        $result.Code | Should -Be 0 -Because $result.Output
        $settings = Get-Content -LiteralPath (Join-Path $root '.claude' 'settings.local.json') -Raw | ConvertFrom-Json -AsHashtable
        $written = @($settings.permissions.additionalDirectories)
        $written | Should -Be @((Resolve-Path -LiteralPath ($parent + '/Knowledge')).ProviderPath.Replace('\', '/'))
        $written[0] | Should -BeLike '//localhost/*'
        $written[0] | Should -Not -Match 'FileSystem::'
    }

    It 'adds a knowledge folder next to the repository, inside its parent folder' {
        $parent = Join-Path ([System.IO.Path]::GetTempPath()) ('sar-parent-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path (Join-Path $parent 'Knowledge') -Force | Out-Null
        $root = New-AllowRepo -Parent $parent -Config '{ "paths": { "knowledgeRoot": "../Knowledge" } }' -Settings '{}'

        $result = Invoke-Sync -Root $root

        $result.Code | Should -Be 0
        $local = Get-Content -LiteralPath (Join-Path $root '.claude' 'settings.local.json') -Raw | ConvertFrom-Json -AsHashtable
        @($local.permissions.additionalDirectories) | Should -Be @((Resolve-Path -LiteralPath (Join-Path $parent 'Knowledge')).ProviderPath.Replace('\', '/'))
    }

    It 'adds the knowledge folder next to the main checkout when the repository is a linked worktree' {
        $parent = Join-Path ([System.IO.Path]::GetTempPath()) ('sar-wt-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path (Join-Path $parent 'Knowledge') -Force | Out-Null
        $main = New-AllowRepo -Parent $parent -Config '{ "paths": { "knowledgeRoot": "../Knowledge" } }' -Settings '{}'
        git -C $main init -q
        git -C $main add -A
        git -C $main -c user.name=probe -c user.email=probe@example.invalid commit -q -m init --no-verify
        $worktree = Join-Path $main '.claude' 'worktrees' 'fix'
        git -C $main worktree add -q -b fix $worktree 2>$null

        $result = Invoke-Sync -Root $worktree

        $result.Code | Should -Be 0 -Because $result.Output
        $settings = Get-Content -LiteralPath (Join-Path $worktree '.claude' 'settings.local.json') -Raw | ConvertFrom-Json -AsHashtable
        @($settings.permissions.additionalDirectories) | Should -Be @((Resolve-Path -LiteralPath (Join-Path $parent 'Knowledge')).ProviderPath.Replace('\', '/'))
    }

    It 'skips a knowledge folder outside the parent folder (<Case>), with a FIX line and exit 0' -ForEach @(
        @{ Case = 'an absolute path elsewhere'; Relative = $false }
        @{ Case = 'a relative path that climbs out'; Relative = $true }
        @{ Case = 'the parent folder itself'; Relative = $true; Value = '..' }
    ) {
        $base = Join-Path ([System.IO.Path]::GetTempPath()) ('sar-base-' + [guid]::NewGuid().ToString('n'))
        $parent = Join-Path $base 'repos'
        # The name starts like the parent folder, so a plain prefix match without a separator would let it in.
        $outside = Join-Path $base 'repos-other' 'Knowledge'
        New-Item -ItemType Directory -Path $parent, $outside -Force | Out-Null
        $value = if ($Value) { $Value } elseif ($Relative) { '../../repos-other/Knowledge' } else { $outside.Replace('\', '/') }
        $root = New-AllowRepo -Parent $parent -Config (@{ paths = @{ knowledgeRoot = $value } } | ConvertTo-Json) -Settings '{}'

        $result = Invoke-Sync -Root $root

        $result.Code | Should -Be 0
        $result.Output | Should -Match 'outside the parent folder of this repository'
        $result.Output | Should -Match 'FIX:'
        Test-Path -LiteralPath (Join-Path $root '.claude' 'settings.local.json') | Should -BeFalse
    }

    It 'skips a knowledge folder that a link inside the repository points elsewhere' {
        $base = Join-Path ([System.IO.Path]::GetTempPath()) ('sar-link-' + [guid]::NewGuid().ToString('n'))
        $parent = Join-Path $base 'repos'
        $outside = Join-Path $base 'elsewhere'
        New-Item -ItemType Directory -Path $parent, $outside -Force | Out-Null
        $root = New-AllowRepo -Parent $parent -Config '{ "paths": { "knowledgeRoot": "kb" } }' -Settings '{}'
        # A junction needs no admin rights on Windows; elsewhere a symlink stands in for the committed link.
        $type = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        New-Item -ItemType $type -Path (Join-Path $root 'kb') -Target $outside | Out-Null

        $result = Invoke-Sync -Root $root

        $result.Code | Should -Be 0
        $result.Output | Should -Match 'reached through a link'
        Test-Path -LiteralPath (Join-Path $root '.claude' 'settings.local.json') | Should -BeFalse
    }

    It 'keeps settings.local.json out of git through .git/info/exclude, once' {
        $root = New-AllowRepo -Config '{ "paths": { "knowledgeRoot": "Knowledge" } }' -Settings '{}'
        New-Item -ItemType Directory -Path (Join-Path $root 'Knowledge') -Force | Out-Null
        git -C $root init -q
        git -C $root check-ignore -q --no-index -- .claude/settings.local.json
        $LASTEXITCODE | Should -Be 1

        Invoke-Sync -Root $root | Out-Null
        Invoke-Sync -Root $root | Out-Null

        git -C $root check-ignore -q --no-index -- .claude/settings.local.json
        $LASTEXITCODE | Should -Be 0
        $exclude = Get-Content -LiteralPath (Join-Path $root '.git' 'info' 'exclude')
        @($exclude | Where-Object { $_ -eq '/.claude/settings.local.json' }).Count | Should -Be 1
    }

    It 'adds no exclude line when an ignore rule already covers settings.local.json' {
        $root = New-AllowRepo -Config '{ "paths": { "knowledgeRoot": "Knowledge" } }' -Settings '{}'
        New-Item -ItemType Directory -Path (Join-Path $root 'Knowledge') -Force | Out-Null
        git -C $root init -q
        Set-Content -LiteralPath (Join-Path $root '.gitignore') -Value '.claude/settings.local.json'

        Invoke-Sync -Root $root | Out-Null

        $exclude = Get-Content -LiteralPath (Join-Path $root '.git' 'info' 'exclude') -ErrorAction SilentlyContinue
        @($exclude | Where-Object { $_ -eq '/.claude/settings.local.json' }).Count | Should -Be 0
    }

    It 'writes no settings.local.json when the knowledge folder is not there, or with -Check' {
        $root = New-AllowRepo
        Invoke-Sync -Root $root | Out-Null
        Test-Path -LiteralPath (Join-Path $root '.claude' 'settings.local.json') | Should -BeFalse

        $checked = New-AllowRepo -Config '{ "paths": { "knowledgeRoot": "Knowledge" } }'
        New-Item -ItemType Directory -Path (Join-Path $checked 'Knowledge') -Force | Out-Null
        Invoke-Sync -Root $checked -Check | Out-Null
        Test-Path -LiteralPath (Join-Path $checked '.claude' 'settings.local.json') | Should -BeFalse
    }

    It 'says it could not check when settings.json is not valid JSON' {
        $root = New-AllowRepo -Settings '{ not json'

        $result = Invoke-Sync -Root $root -Check

        $result.Code | Should -Be 2
        $result.Output | Should -Match 'not valid JSON'
        $result.Output | Should -Match '(?m)^FIX: \S'
    }

    It 'is not applicable when no package part is installed' -Tag '#46' {
        $root = New-AllowRepo -Manifests @{}

        $result = Invoke-Sync -Root $root -Check

        $result.Code | Should -Be 3
        $result.Output | Should -Match 'not applicable'
    }
}

Describe 'Allow rules of the shipped packages' {
    BeforeAll {
        $script:Script = Join-Path $script:ScriptFolder 'Sync-AllowRules.ps1'
        Import-Module (Join-Path $PSScriptRoot 'DocToolTestHarness.psm1') -Force
        # The test lives at core/tests/skills/ai-sdlc-gates/scripts, five folders below the repository root.
        $script:Source = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..' '..' '..' '..' '..')).Path
        $script:Manifests = @(Get-ChildItem -Path (Join-Path $script:Source 'core'), (Join-Path $script:Source 'packs') -Recurse -Force -Filter gates.json -File |
                Where-Object { $_.FullName -match '[\\/]\.apm[\\/]skills[\\/][^\\/]+[\\/]gates\.json$' })
        $script:Wildcard = '\.claude[\\/]skills[\\/]\S*\*'
    }

    It 'finds the package manifests to check' -Tag '#103' {
        $script:Manifests.Count | Should -BeGreaterThan 5
    }

    It 'has no allow entry in a package source that ends in a wildcard over a scripts folder' -Tag '#103' {
        $bad = foreach ($manifest in $script:Manifests) {
            $data = Get-Content -LiteralPath $manifest.FullName -Raw | ConvertFrom-Json -AsHashtable
            foreach ($entry in @($data['allow'])) { if ([string]$entry -match $script:Wildcard) { "$($manifest.FullName): $entry" } }
        }
        @($bad) | Should -BeNullOrEmpty
    }

    It 'has no rule in the committed .claude/settings.json that ends in a wildcard over a scripts folder' -Tag '#103' {
        $settings = Join-Path $script:Source '.claude' 'settings.json'
        if (-not (Test-Path -LiteralPath $settings)) { Set-ItResult -Skipped -Because 'this copy has no .claude/settings.json'; return }
        $allow = @((Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json -AsHashtable)['permissions']['allow'])
        @($allow | Where-Object { [string]$_ -match $script:Wildcard }) | Should -BeNullOrEmpty
    }

    It 'lets every gate of every package run without a prompt in a fresh consumer' -Tag '#103' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('sar-fresh-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        try {
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value '{ "paths": { "knowledgeRoot": "knowledge-missing" } }' -Encoding utf8
            $packs = @(Get-ChildItem -LiteralPath (Join-Path $script:Source 'packs') -Directory | ForEach-Object { "    - ../AI.SDLC/packs/$($_.Name)" })
            Set-Content -LiteralPath (Join-Path $root 'apm.yml') -Value ((@('dependencies:', '  apm:', '    - ../AI.SDLC/core') + $packs) -join "`n")
            $expected = foreach ($manifest in $script:Manifests) {
                $skill = $manifest.Directory.Name
                $folder = Join-Path $root '.claude' 'skills' $skill
                New-Item -ItemType Directory -Path $folder -Force | Out-Null
                Copy-Item -LiteralPath $manifest.FullName -Destination $folder
                $data = Get-Content -LiteralPath $manifest.FullName -Raw | ConvertFrom-Json -AsHashtable
                foreach ($gate in @($data['gates'])) {
                    if ($gate) { [pscustomobject]@{ Path = ".claude/skills/$skill/$($gate['script'])"; HasArgs = [bool]$gate['args'] } }
                }
            }

            $run = Invoke-ScriptInProcess -Path $script:Script -Arguments @('-RepoRoot', $root)
            $run.ExitCode | Should -Be 0
            $allow = @((Get-Content -LiteralPath (Join-Path $root '.claude' 'settings.json') -Raw | ConvertFrom-Json -AsHashtable)['permissions']['allow'])

            @($expected).Count | Should -BeGreaterThan 20
            foreach ($gate in $expected) {
                # The rule holds the script and the arguments of the entry, and never a star.
                $tail = if ($gate.HasArgs) { '( -[^*()]+)' } else { '' }
                foreach ($shell in 'Bash', 'PowerShell') {
                    foreach ($form in 'pwsh ', 'pwsh -NoProfile -File ') {
                        $pattern = '^' + [regex]::Escape("$shell($form$($gate.Path)") + $tail + '\)$'
                        @($allow | Where-Object { $_ -match $pattern }).Count | Should -BeGreaterThan 0 -Because "$shell $form$($gate.Path) must run without a prompt"
                    }
                }
            }
        }
        finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
