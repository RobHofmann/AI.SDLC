#requires -Version 7.4

BeforeAll { $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm' }

Describe 'Check-BicepConventions' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $script:ScriptFolder -ChildPath 'Check-BicepConventions.ps1'
        $script:RoleGuid = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
        $script:OtherGuid = '11111111-2222-3333-4444-555555555555'
        $script:Lookup = 'roles/builtin-roles.bicep'

        function Initialize-BicepRepo {
            param([hashtable]$Files = @{}, [string[]]$RoleLookupFiles, [string]$Parent = $TestDrive)
            $root = Join-Path $Parent ([guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            $config = @{ repository = 'Fixture' }
            if ($PSBoundParameters.ContainsKey('RoleLookupFiles')) { $config['bicep'] = @{ roleLookupFiles = $RoleLookupFiles } }
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value ($config | ConvertTo-Json -Depth 4) -Encoding utf8
            foreach ($rel in $Files.Keys) {
                $full = Join-Path $root $rel
                New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
                Set-Content -LiteralPath $full -Value $Files[$rel] -Encoding utf8
            }
            return $root
        }

        function Invoke-Gate {
            param([string]$Root, [string]$Rule)
            $arguments = @{ RepoRoot = $Root }
            if ($Rule) { $arguments['Rule'] = $Rule }
            $out = & $script:ScriptUnderTest @arguments *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }
    }

    Context 'ModuleTag: a registry module call pinned to latest' {
        It 'reports <Name> with its file and line (exit 1)' -Tag '#87' -ForEach @(
            @{ Name = 'an alias reference'; Line = "module net 'br/platform:modules/network:latest' = {" }
            @{ Name = 'a host reference'; Line = "module net 'br:registry.example.io/modules/network:latest' = {" }
            @{ Name = 'an upper-case LATEST'; Line = "module net 'br/platform:modules/network:LATEST' = {" }
            @{ Name = 'an import statement'; Line = "import { x } from 'br/platform:modules/network:latest'" }
            @{ Name = 'the end of an import over several lines'; Line = "} from 'br/platform:modules/network:latest'" }
            @{ Name = 'an extension declaration'; Line = "extension 'br:registry.example.io/extensions/graph:latest'" }
            @{ Name = 'a test declaration'; Line = "test check 'br/platform:modules/network:latest' = {" }
            @{ Name = 'an import with an alias'; Line = "import 'br/platform:modules/types:latest' as types" }
            @{ Name = 'a reference that starts its own line'; Line = "  'br/platform:modules/network:latest' = {" }
        ) {
            $root = Initialize-BicepRepo -Files @{ 'building-blocks/a/main.bicep' = "targetScope = 'subscription'`n$Line`n  name: 'x'`n}" }

            $r = Invoke-Gate -Root $root

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'building-blocks/a/main\.bicep:2 '
            $r.Output | Should -Match 'BICEP-01'
            $r.Output | Should -Match '(?m)^FIX: \S'
        }

        It 'leaves <Name> alone (exit 0)' -Tag '#87' -ForEach @(
            @{ Name = 'a dated tag'; Text = "module net 'br/platform:modules/network:2026.01.01.1-main' = {}" }
            @{ Name = 'a tag that only starts with latest'; Text = "module net 'br/platform:modules/network:latest-main' = {}" }
            @{ Name = 'latest inside a multi-line block comment'; Text = "/*`nmodule old 'br/platform:modules/network:latest' = {}`n*/`nvar a = 1" }
            @{ Name = 'latest after a line comment'; Text = "var a = 1 // was 'br/platform:modules/network:latest'" }
            @{ Name = 'a quote escape that does not end the string'; Text = "var a = 'it\'s // br/platform:modules/network:latest'" }
            @{ Name = 'a multi-line string that holds slashes'; Text = "var a = '''`n// not a comment`n'''`nmodule net 'br/platform:modules/network:2026.01.01.1-main' = {}" }
            @{ Name = 'a block comment start inside a string'; Text = "var a = 'x /* y'`nmodule net 'br/platform:modules/network:2026.01.01.1-main' = {}" }
            @{ Name = 'a plain string that is no module call'; Text = "var example = 'br/platform:modules/network:latest'" }
        ) {
            $root = Initialize-BicepRepo -Files @{ 'main.bicep' = $Text }

            $r = Invoke-Gate -Root $root

            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match 'OK'
        }

        It 'reports a latest call after a string that holds two slashes on the same line' -Tag '#87' {
            $root = Initialize-BicepRepo -Files @{ 'main.bicep' = "var u = 'https://x/y'; module net 'br/platform:modules/network:latest' = {}" }

            $r = Invoke-Gate -Root $root

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'main\.bicep:1 '
        }

        It 'reports a latest call that follows a multi-line string' -Tag '#87' {
            $root = Initialize-BicepRepo -Files @{ 'main.bicep' = "var a = '''`n// text`n'''`nmodule net 'br/platform:modules/network:latest' = {}" }

            $r = Invoke-Gate -Root $root

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'main\.bicep:4 '
        }

        It 'reports a using line of a .bicepparam file in the <Name> form (exit 1)' -Tag '#87' -ForEach @(
            @{ Name = 'alias'; Line = "using 'br/platform:modules/network:latest'" }
            @{ Name = 'full host'; Line = "using 'br:registry.example.io/modules/network:latest'" }
        ) {
            $root = Initialize-BicepRepo -Files @{ 'params/main.bicepparam' = "$Line`nparam location = 'westeurope'" }

            $r = Invoke-Gate -Root $root

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'params/main\.bicepparam:1 '
            $r.Output | Should -Match 'BICEP-01'
        }

        It 'leaves a .bicepparam file alone when its using line names <Name> (exit 0)' -Tag '#87' -ForEach @(
            @{ Name = 'a dated tag'; Line = "using 'br/platform:modules/network:2026.01.01.1-main'" }
            @{ Name = 'a local template'; Line = "using './main.bicep'" }
            @{ Name = 'latest only in a comment'; Line = "using './main.bicep' // was 'br/platform:modules/network:latest'" }
            @{ Name = 'a local template and a multi-line string that holds the word using'; Line = "using './main.bicep'`nparam note = '''`nDeploy using 'br/platform:modules/network:latest'`n'''" }
        ) {
            $root = Initialize-BicepRepo -Files @{ 'main.bicepparam' = $Line }

            $r = Invoke-Gate -Root $root

            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match 'OK'
        }

        It 'exits 3 with one plain line when the repository holds no Bicep file' -Tag '#87' {
            $root = Initialize-BicepRepo

            $r = Invoke-Gate -Root $root

            $r.ExitCode | Should -Be 3
            @($r.Output -split '\r?\n' | Where-Object { $_.Trim() }) | Should -HaveCount 1
            $r.Output | Should -Match 'Not applicable: .*no Bicep file'
        }

        It 'skips .claude, .git, apm_modules and node_modules by their path inside the repository' -Tag '#87' -ForEach @(
            @{ Folder = '.claude/skills/x' }
            @{ Folder = '.git/hooks' }
            @{ Folder = 'apm_modules/pkg' }
            @{ Folder = 'node_modules/pkg' }
        ) {
            $root = Initialize-BicepRepo -Files @{ "$Folder/main.bicep" = "module net 'br/platform:modules/network:latest' = {}" }

            (Invoke-Gate -Root $root).ExitCode | Should -Be 3
        }

        It 'still finds the templates of a repository that sits inside a folder named .claude' -Tag '#87' {
            $parent = Join-Path $TestDrive '.claude/worktrees'
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
            $root = Initialize-BicepRepo -Parent $parent -Files @{ 'main.bicep' = "module net 'br/platform:modules/network:latest' = {}" }

            $r = Invoke-Gate -Root $root

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'main\.bicep:1 '
        }

        It 'checks the module tag when Rule is not given and never exits 2 (no role setting needed)' -Tag '#87' {
            $root = Initialize-BicepRepo -Files @{ 'main.bicep' = 'var a = 1' }

            $r = Invoke-Gate -Root $root

            $r.ExitCode | Should -Be 0 -Because $r.Output
        }
    }

    Context 'RoleId: a role ID written inline instead of read from a lookup file' {
        BeforeAll {
            $script:LookupText = "var roles = {`n  reader: '$($script:RoleGuid)'`n}"
        }

        It 'reports an inline lookup GUID in <File> with its file and line (exit 1)' -Tag '#87' -ForEach @(
            @{ File = 'main.bicep' }
            @{ File = 'main.bicepparam' }
        ) {
            $root = Initialize-BicepRepo -RoleLookupFiles @($script:Lookup) -Files @{
                $script:Lookup = $script:LookupText
                $File          = "param a = 1`nparam role = '$($script:RoleGuid)'"
            }

            $r = Invoke-Gate -Root $root -Rule 'RoleId'

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match ([regex]::Escape("$File`:2 "))
            $r.Output | Should -Match 'BICEP-02'
            $r.Output | Should -Match '(?m)^FIX: \S'
            $r.Output | Should -Not -Match 'builtin-roles\.bicep:'
        }

        It 'reports an upper-case form of a lookup GUID' -Tag '#87' {
            $root = Initialize-BicepRepo -RoleLookupFiles @($script:Lookup) -Files @{
                $script:Lookup = $script:LookupText
                'main.bicep'   = "var r = '$($script:RoleGuid.ToUpperInvariant())'"
            }

            $r = Invoke-Gate -Root $root -Rule 'RoleId'

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'main\.bicep:1 '
        }

        It 'leaves <Name> alone (exit 0)' -Tag '#87' -ForEach @(
            @{ Name = 'a GUID in a line comment'; Text = "var a = 1 // reader $script:RoleGuid" }
            @{ Name = 'a GUID in a block comment'; Text = "/*`n$script:RoleGuid`n*/`nvar a = 1" }
            @{ Name = 'a GUID that no lookup file holds'; Text = "var a = '$script:OtherGuid'" }
        ) {
            $root = Initialize-BicepRepo -RoleLookupFiles @($script:Lookup) -Files @{
                $script:Lookup = $script:LookupText
                'main.bicep'   = $Text
            }

            $r = Invoke-Gate -Root $root -Rule 'RoleId'

            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match 'OK'
        }

        It 'reads a lookup file that is not Bicep as plain text' -Tag '#87' {
            $root = Initialize-BicepRepo -RoleLookupFiles @('roles/roles.json') -Files @{
                'roles/roles.json' = "{ `"reader`": `"$($script:RoleGuid)`" }"
                'main.bicep'       = "var r = '$($script:RoleGuid)'"
            }

            $r = Invoke-Gate -Root $root -Rule 'RoleId'

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'main\.bicep:1 '
        }

        It 'accepts a single string for roleLookupFiles' -Tag '#87' {
            $root = Initialize-BicepRepo -Files @{ $script:Lookup = $script:LookupText; 'main.bicep' = "var r = '$($script:RoleGuid)'" }
            $config = Get-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Raw | ConvertFrom-Json -AsHashtable
            $config['bicep'] = @{ roleLookupFiles = $script:Lookup }
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value ($config | ConvertTo-Json -Depth 4) -Encoding utf8

            (Invoke-Gate -Root $root -Rule 'RoleId').ExitCode | Should -Be 1
        }

        It 'exits 3 when bicep.roleLookupFiles is <Case>' -Tag '#87' -ForEach @(
            @{ Case = 'not set'; Set = $false }
            @{ Case = 'an empty list'; Set = $true }
        ) {
            $files = @{ 'main.bicep' = "var r = '$($script:RoleGuid)'" }
            $root = if ($Set) { Initialize-BicepRepo -RoleLookupFiles @() -Files $files } else { Initialize-BicepRepo -Files $files }

            $r = Invoke-Gate -Root $root -Rule 'RoleId'

            $r.ExitCode | Should -Be 3
            $r.Output | Should -Match 'Not applicable: .*bicep\.roleLookupFiles'
        }

        It 'does not read a file under <Folder>' -Tag '#87' -ForEach @(
            @{ Folder = 'apm_modules/pkg' }
            @{ Folder = '.claude/skills/x' }
        ) {
            $root = Initialize-BicepRepo -RoleLookupFiles @($script:Lookup) -Files @{
                $script:Lookup            = $script:LookupText
                'main.bicep'              = 'var a = 1'
                "$Folder/main.bicepparam" = "param role = '$($script:RoleGuid)'"
            }

            $r = Invoke-Gate -Root $root -Rule 'RoleId'

            $r.ExitCode | Should -Be 0 -Because $r.Output
        }

        It 'collects the GUIDs of every named lookup file' -Tag '#87' {
            $root = Initialize-BicepRepo -RoleLookupFiles @($script:Lookup, 'roles/custom-roles.bicep') -Files @{
                $script:Lookup               = $script:LookupText
                'roles/custom-roles.bicep'   = "var custom = '$($script:OtherGuid)'"
                'main.bicep'                 = "var r = '$($script:OtherGuid)'"
            }

            $r = Invoke-Gate -Root $root -Rule 'RoleId'

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'main\.bicep:1 '
            $r.Output | Should -Not -Match 'custom-roles\.bicep:'
        }

        It 'exits 2 with a FIX line when the second of two lookup files does not exist' -Tag '#87' {
            $root = Initialize-BicepRepo -RoleLookupFiles @($script:Lookup, 'roles/missing.bicep') -Files @{ $script:Lookup = $script:LookupText; 'main.bicep' = 'var a = 1' }

            $r = Invoke-Gate -Root $root -Rule 'RoleId'

            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match '(?m)^FIX: .*roles/missing\.bicep'
        }

        It 'exits 3 when the repository holds no Bicep file' -Tag '#87' {
            $root = Initialize-BicepRepo -RoleLookupFiles @($script:Lookup)

            $r = Invoke-Gate -Root $root -Rule 'RoleId'

            $r.ExitCode | Should -Be 3
            $r.Output | Should -Match 'Not applicable: .*no Bicep file'
        }

        It 'exits 2 with a FIX line when a named lookup file does not exist' -Tag '#87' {
            $root = Initialize-BicepRepo -RoleLookupFiles @('roles/missing.bicep') -Files @{ 'main.bicep' = 'var a = 1' }

            $r = Invoke-Gate -Root $root -Rule 'RoleId'

            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match 'Could not check'
            $r.Output | Should -Match '(?m)^FIX: .*roles/missing\.bicep'
        }

        It 'exits 2 with a FIX line when a lookup file holds no GUID' -Tag '#87' {
            $root = Initialize-BicepRepo -RoleLookupFiles @($script:Lookup) -Files @{ $script:Lookup = "var roles = {}"; 'main.bicep' = 'var a = 1' }

            $r = Invoke-Gate -Root $root -Rule 'RoleId'

            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match '(?m)^FIX: \S'
        }

        It 'exits 2 when a lookup file holds a GUID only in a comment' -Tag '#87' {
            $root = Initialize-BicepRepo -RoleLookupFiles @($script:Lookup) -Files @{ $script:Lookup = "// $script:RoleGuid"; 'main.bicep' = 'var a = 1' }

            (Invoke-Gate -Root $root -Rule 'RoleId').ExitCode | Should -Be 2
        }
    }
}
