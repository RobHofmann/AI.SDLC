#requires -Version 7.4

Describe 'AiSdlcConfig' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force

        function New-ConfigRepo {
            param([string]$Json, [switch]$Git, [string]$Apm)
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('aisdlc-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path (Join-Path $root 'sub' 'deeper') -Force | Out-Null
            if ($Git) { git -C $root init --quiet }
            if ($null -ne $Json) { Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value $Json -Encoding utf8 }
            if ($Apm) { Set-Content -LiteralPath (Join-Path $root 'apm.yml') -Value $Apm -Encoding utf8 }
            return (Resolve-Path $root).Path
        }
    }

    It 'finds the repository root from a folder below the one that holds aisdlc.json' {
        $root = New-ConfigRepo -Json '{ "repository": "Demo" }'

        Find-AiSdlcRepoRoot -StartPath (Join-Path $root 'sub' 'deeper') | Should -Be $root
    }

    It 'falls back to the git top level when no aisdlc.json exists' {
        $root = New-ConfigRepo -Json $null -Git

        Find-AiSdlcRepoRoot -StartPath (Join-Path $root 'sub') | Should -Be $root
    }

    It 'reads the values the repository sets and keeps the defaults for the rest' {
        $root = New-ConfigRepo -Json '{ "repository": "Demo", "paths": { "docsRoots": ["docs", "docs-functional"] } }'

        $config = Get-AiSdlcConfig -RepoRoot $root

        $config.repository | Should -Be 'Demo'
        $config.paths.docsRoots | Should -Be @('docs', 'docs-functional')
        $config.paths.adrFolder | Should -Be 'docs/adrs'
        $config.repoRoot | Should -Be $root
    }

    It 'gives every default when the repository has no aisdlc.json' {
        $root = New-ConfigRepo -Json $null -Git

        $config = Get-AiSdlcConfig -RepoRoot $root

        $config.configFile | Should -BeNullOrEmpty
        $config.paths.docsRoots | Should -Be @('docs')
        @($config.packs).Count | Should -Be 0
    }

    It 'has no default for a path that no script reads' {
        $config = Get-AiSdlcConfig -RepoRoot (New-ConfigRepo -Json $null -Git)

        @($config.paths.Keys) | Should -Not -Contain 'aiSdlcFolder'
    }

    It 'names the file when aisdlc.json is not valid JSON' {
        $root = New-ConfigRepo -Json '{ not json'

        { Get-AiSdlcConfig -RepoRoot $root } | Should -Throw '*aisdlc.json is not valid JSON*'
    }

    It 'returns a configured path as a full path, or as written with -Relative' {
        $root = New-ConfigRepo -Json '{ "paths": { "solution": "src/App.sln" } }'

        Get-AiSdlcPath -Name solution -RepoRoot $root | Should -Be (Join-Path $root 'src/App.sln')
        Get-AiSdlcPath -Name solution -RepoRoot $root -Relative | Should -Be 'src/App.sln'
    }

    It 'returns nothing for a path the repository leaves empty' {
        $root = New-ConfigRepo -Json '{ "paths": { "solution": "" } }'

        @(Get-AiSdlcPath -Name solution -RepoRoot $root).Count | Should -Be 0
    }

    It 'names the known paths when asked for one that does not exist' {
        $root = New-ConfigRepo -Json '{}'

        { Get-AiSdlcPath -Name nope -RepoRoot $root } | Should -Throw '*no path named*docsRoots*'
    }

    It 'reads the packs from the git dependencies of apm.yml, in their order, and not from aisdlc.json' {
        $apm = @(
            'dependencies:'
            '  apm:'
            '    - git: https://example.invalid/_git/AI.SDLC'
            '      path: core'
            '      ref: v2.0.0'
            '    - git: https://example.invalid/_git/AI.SDLC'
            '      path: packs/github-issues'
            '      ref: v2.0.0'
            '    - git: https://example.invalid/_git/AI.SDLC'
            '      path: "packs/bicep"   # the templates'
            '      ref: v2.0.0'
        ) -join "`n"
        $root = New-ConfigRepo -Json '{ "packs": ["dotnet"] }' -Apm $apm

        (Get-AiSdlcConfig -RepoRoot $root).packs | Should -Be @('github-issues', 'bicep')
    }

    It 'reads a pack from a local path or a shorthand with a ref, and not from a parent folder named packs' {
        $apm = "dependencies:`n  apm:`n    - ../AI.SDLC/packs/dotnet`n    - org/project/AI.SDLC/packs/github-issues#v2.0.0`n    - C:/src/packs/AI.SDLC/core"
        $root = New-ConfigRepo -Json '{}' -Apm $apm

        (Get-AiSdlcConfig -RepoRoot $root).packs | Should -Be @('dotnet', 'github-issues')
    }

    It 'has no packs when the repository has no apm.yml, even when aisdlc.json still lists them' {
        $root = New-ConfigRepo -Json '{ "packs": ["bicep"] }'

        @((Get-AiSdlcConfig -RepoRoot $root).packs).Count | Should -Be 0
    }

    It 'says a pack is installed only when apm.yml lists it, and core always' {
        $root = New-ConfigRepo -Json '{}' -Apm "dependencies:`n  apm:`n    - ../AI.SDLC/core`n    - ../AI.SDLC/packs/bicep`n    - ../AI.SDLC/packs/github-issues"

        Test-AiSdlcPack -Name bicep -RepoRoot $root | Should -BeTrue
        Test-AiSdlcPack -Name dotnet -RepoRoot $root | Should -BeFalse
        Test-AiSdlcPack -Name core -RepoRoot $root | Should -BeTrue
    }

    It 'gives the GitHub defaults for the tracker, the knowledge folder and the visibility' {
        $config = Get-AiSdlcConfig -RepoRoot (New-ConfigRepo -Json $null -Git)

        $config.visibility | Should -Be 'private'
        $config.paths.knowledgeRoot | Should -Be '../Knowledge'
        $config.paths.discoveryRoot | Should -Be 'docs-functional/discovery'
        $config.tracker.refinedLabel | Should -Be 'refined'
        $config.tracker.sizeLabelPrefix | Should -Be 'size:'
        @($config.tracker.acceptedRepositories) | Should -BeNullOrEmpty
        $config.github.trunk | Should -Be 'main'
        @($config.PSObject.Properties.Name) | Should -Not -Contain 'docGenerator'
        @($config.dotnet.Keys) | Should -Not -Contain 'docGeneratorEndpoint'
    }

    It 'reads the other repositories whose issues a pull request may name from tracker.acceptedRepositories' {
        $config = Get-AiSdlcConfig -RepoRoot (New-ConfigRepo -Json '{ "tracker": { "acceptedRepositories": ["contoso/ai-sdlc"] } }')

        @($config.tracker.acceptedRepositories) | Should -Be @('contoso/ai-sdlc')
        $config.tracker.refinedLabel | Should -Be 'refined'
    }

    It 'matches a GitHub issue key and not a bare number, an entity or a heading' {
        $pattern = Get-AiSdlcStoryPattern -RepoRoot (New-ConfigRepo -Json '{}')

        'Fixes #42' | Should -Match $pattern
        'see contoso/portal#42' | Should -Match $pattern
        'issue 42' | Should -Not -Match $pattern
        'a &#123; entity' | Should -Not -Match $pattern
        '# Title' | Should -Not -Match $pattern
        'PR#42' | Should -Not -Match $pattern
    }

    It 'uses tracker.keyPattern when the repository sets one' {
        $root = New-ConfigRepo -Json '{ "tracker": { "keyPattern": "PROJ-\\d+" } }'

        Get-AiSdlcStoryPattern -RepoRoot $root | Should -Be 'PROJ-\d+'
        Get-AiSdlcStoryKey -Text 'Work on PROJ-7 today' -RepoRoot $root | Should -Be 'PROJ-7'
    }

    It 'finds the first story key in a text and writes it as #<n>' {
        Get-AiSdlcStoryKey -Text 'Fixes #042 and #7' | Should -Be '#42'
        Get-AiSdlcStoryKey -Text 'Fixes contoso/portal#9' | Should -Be 'contoso/portal#9'
        Get-AiSdlcStoryKey -Text 'nothing here' | Should -BeNullOrEmpty
        Get-AiSdlcStoryKey -Text '' | Should -BeNullOrEmpty
    }

    It 'reads the front matter story value <Value> as <Status> <Key>' -ForEach @(
        @{ Value = '"#42"'; Status = 'ok'; Key = '#42' }
        @{ Value = "'#42'"; Status = 'ok'; Key = '#42' }
        @{ Value = '42'; Status = 'ok'; Key = '#42' }
        @{ Value = '"042"'; Status = 'ok'; Key = '#42' }
        @{ Value = 'contoso/portal#42'; Status = 'ok'; Key = 'contoso/portal#42' }
        @{ Value = '"contoso/portal#42"'; Status = 'ok'; Key = 'contoso/portal#42' }
        @{ Value = ''; Status = 'empty'; Key = $null }
        @{ Value = '""'; Status = 'empty'; Key = $null }
        @{ Value = '#42'; Status = 'empty'; Key = $null }
        @{ Value = 'not-a-key'; Status = 'invalid'; Key = $null }
        @{ Value = '"PR#42"'; Status = 'invalid'; Key = $null }
        @{ Value = '"# Title"'; Status = 'invalid'; Key = $null }
    ) {
        $story = ConvertTo-AiSdlcStoryKey -Value $Value
        $story.Status | Should -Be $Status
        $story.Key | Should -Be $Key
    }

    It 'checks the front matter story value against tracker.keyPattern when the repository sets one' {
        $root = New-ConfigRepo -Json '{ "tracker": { "keyPattern": "PROJ-\\d+" } }'

        (ConvertTo-AiSdlcStoryKey -Value '"PROJ-7"' -RepoRoot $root).Key | Should -Be 'PROJ-7'
        (ConvertTo-AiSdlcStoryKey -Value '"#7"' -RepoRoot $root).Status | Should -Be 'invalid'
    }

    It 'reads the story key from a branch whose last segment starts with the issue number' {
        Get-AiSdlcBranchStoryKey -Branch '42-short-name' | Should -Be '#42'
        Get-AiSdlcBranchStoryKey -Branch 'feature/42-x' | Should -Be '#42'
        Get-AiSdlcBranchStoryKey -Branch 'refs/heads/bug/42' | Should -Be '#42'
        Get-AiSdlcBranchStoryKey -Branch 'feature/x-42' | Should -BeNullOrEmpty
        Get-AiSdlcBranchStoryKey -Branch 'main' | Should -BeNullOrEmpty
        Get-AiSdlcBranchStoryKey -Branch '' | Should -BeNullOrEmpty
    }

    It 'lists the package manifests with their hooks, and only the packages that run unless asked for all' {
        $root = New-ConfigRepo -Json '{}' -Apm "dependencies:`n  apm:`n    - ../AI.SDLC/packs/dotnet"
        foreach ($skill in @(@{ Name = 'core-gates'; Json = '{ "package": "core", "gates": [ { "name": "g", "script": "scripts/G.ps1" } ] }' },
                @{ Name = 'net-gates'; Json = '{ "package": "dotnet", "gates": [], "setup": "scripts/Setup.ps1", "preflight": "scripts/Pre.ps1", "postEdit": { "extensions": [".CS"], "script": "scripts/Post.ps1" } }' },
                @{ Name = 'bicep-rules'; Json = '{ "package": "bicep", "gates": [] }' })) {
            $folder = Join-Path $root '.claude' 'skills' $skill.Name
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $folder 'gates.json') -Value $skill.Json
        }

        $running = @(Get-AiSdlcPackage -RepoRoot $root)
        $all = @(Get-AiSdlcPackage -RepoRoot $root -All)

        $running.Package | Should -Be @('core', 'dotnet')
        $all.Count | Should -Be 3
        ($all | Where-Object Package -eq 'bicep').Runs | Should -BeFalse
        $net = $running | Where-Object Package -eq 'dotnet'
        $net.Setup | Should -Be (Join-Path $root '.claude' 'skills' 'net-gates' 'scripts/Setup.ps1')
        $net.Preflight | Should -Match 'Pre\.ps1$'
        $net.PostEdit.Extensions | Should -Be @('.cs')
        @(($running | Where-Object Package -eq 'core').Gates).Count | Should -Be 1
    }

    It 'lists the documentation units and the facts script a package names' {
        $root = New-ConfigRepo -Json '{}' -Apm "dependencies:`n  apm:`n    - ../AI.SDLC/packs/bicep"
        $folder = Join-Path $root '.claude' 'skills' 'bicep-rules'
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $folder 'gates.json') -Value '{ "package": "bicep", "gates": [], "docUnits": [ { "glob": "{bicepRoot}/*", "kind": "building block" } ], "docFacts": "scripts/Get-Facts.ps1" }'

        $bicep = @(Get-AiSdlcPackage -RepoRoot $root) | Where-Object Package -eq 'bicep'

        $bicep.DocUnits[0].glob | Should -Be '{bicepRoot}/*'
        $bicep.DocFacts | Should -Be (Join-Path $folder 'scripts/Get-Facts.ps1')
    }

}
