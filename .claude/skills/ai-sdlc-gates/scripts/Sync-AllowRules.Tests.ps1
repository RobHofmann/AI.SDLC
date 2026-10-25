#requires -Version 7.4

Describe 'Sync-AllowRules' {
    BeforeAll {
        $script:Script = Join-Path $PSScriptRoot 'Sync-AllowRules.ps1'
        Import-Module (Join-Path $PSScriptRoot 'DocToolTestHarness.psm1') -Force

        function New-AllowRepo {
            param(
                [string[]]$Packs = @(),
                [hashtable]$Manifests = @{ 'ai-sdlc-gates' = @{ package = 'core'; gates = @(); allow = @('git status *') } },
                [string]$Settings,
                [string]$Config = '{ "paths": { "knowledgeRoot": "knowledge-missing" } }'
            )
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('sar-' + [guid]::NewGuid().ToString('n'))
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
            'check-pr-contract' = @{ package = 'github-issues'; allow = @('pwsh .claude/skills/check-pr-contract/scripts/Check-*') }
            'dotnet-gates'      = @{ package = 'dotnet'; allow = @('dotnet test *') }
        }

        $allow = (Invoke-Sync -Root $root).Settings.permissions.allow

        $allow | Should -Contain 'Bash(pwsh .claude/skills/check-pr-contract/scripts/Check-*)'
        $allow | Should -Not -Contain 'Bash(dotnet test *)'
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
    }
}
