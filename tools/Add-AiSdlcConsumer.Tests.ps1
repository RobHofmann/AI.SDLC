#requires -Version 7.4

Describe 'Add-AiSdlcConsumer' {
    BeforeAll {
        $script:Tool = Join-Path $PSScriptRoot 'Add-AiSdlcConsumer.ps1'
        Import-Module (Join-Path $PSScriptRoot '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' 'DocToolTestHarness.psm1') -Force
        # The script ends without exit, so pwsh -File gives 0 even when its last native command failed.
        # In this process that exit code would stay in $LASTEXITCODE, so this wrapper sets it to 0 after a
        # normal end. The script only ever calls exit 0, and a terminating error still gives 1.
        $script:RunTool = Join-Path $TestDrive 'Run-Tool.ps1'
        Set-Content -LiteralPath $script:RunTool -Value @(
            'param([string]$Tool, [hashtable]$Parameters)'
            '& $Tool @Parameters'
            '$global:LASTEXITCODE = 0'
        )

        function New-TargetRepo {
            param([hashtable]$Files = @{}, [string]$Remote)
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('aac-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            git -C $root init --quiet
            if ($Remote) { git -C $root remote add origin $Remote }
            foreach ($name in $Files.Keys) {
                $path = Join-Path $root $name
                New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
                Set-Content -LiteralPath $path -Value $Files[$name]
            }
            return $root
        }

        function Get-ApmPack {
            param([string]$Target)
            @(Select-String -LiteralPath (Join-Path $Target 'apm.yml') -Pattern '^\s+path: packs/(\S+)$' | ForEach-Object { $_.Matches[0].Groups[1].Value })
        }

        function Invoke-Tool {
            param([string]$Target, [string[]]$Extra = @(), [switch]$Install)
            $seam = @(if (-not $Install) { '-SkipInstall' })
            $arguments = @('-TargetRepo', $Target, '-Ref', 'v9.9.9') + $seam + $Extra
            if ($Extra -contains '-WhatIf') {
                # A child process, because in this process the What if lines go to the host and no stream catches them.
                $output = & pwsh -NoProfile -File $script:Tool @arguments 2>&1 | Out-String
                return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $output }
            }
            $run = Invoke-ScriptInProcess -Path $script:RunTool -Parameters @{ Tool = $script:Tool; Parameters = (ConvertTo-ParameterTable -Arguments $arguments) }
            return [pscustomobject]@{ Code = $run.ExitCode; Output = $run.Output }
        }

        function New-FakeCommand {
            param([string]$Folder, [string]$Name, [int]$ExitCode)
            New-Item -ItemType Directory -Path $Folder -Force | Out-Null
            if ($IsWindows) { [IO.File]::WriteAllText((Join-Path $Folder "$Name.cmd"), "@echo off`r`nexit /b $ExitCode`r`n") }
            else {
                [IO.File]::WriteAllText((Join-Path $Folder $Name), "#!/bin/sh`nexit $ExitCode`n")
                chmod +x (Join-Path $Folder $Name)
            }
        }

        function Invoke-WithFakes {
            param([string]$Folder, [scriptblock]$Script)
            $savedPath = $env:PATH
            try {
                $env:PATH = $Folder + [IO.Path]::PathSeparator + $env:PATH
                & $Script
            }
            finally { $env:PATH = $savedPath }
        }
    }

    It 'picks the packs from what the repository holds, and reads the GitHub repository from the remote' {
        $target = New-TargetRepo -Remote 'https://github.com/contoso/portal.git' -Files @{
            'src/App.sln'                 = ''
            'src/Portal/Page.razor'       = ''
            'infra/main.bicep'            = ''
            '.claude/skills/x/ignored.cs' = ''
        }
        $result = Invoke-Tool -Target $target

        $result.Code | Should -Be 0 -Because $result.Output
        $config = Get-Content (Join-Path $target 'aisdlc.json') -Raw | ConvertFrom-Json
        Get-ApmPack $target | Should -Be @('dotnet', 'blazor', 'bicep', 'github', 'github-issues')
        $config.PSObject.Properties.Name | Should -Not -Contain 'packs'
        $config.repository | Should -Be 'portal'
        $config.visibility | Should -Be 'private'
        $config.github.repository | Should -Be 'contoso/portal'
        $config.github.trunk | Should -Be 'main'
        $config.tracker.repository | Should -Be 'contoso/portal'
        $config.tracker.refinedLabel | Should -Be 'refined'
        @($config.tracker.acceptedRepositories) | Should -Be @('RobHofmann/AI.SDLC') -Because 'an update pull request names the release issue of the AI.SDLC source'
    }

    It 'keeps an accepted repository added by hand on a -Force rerun, next to the AI.SDLC source' {
        $target = New-TargetRepo -Remote 'https://github.com/contoso/portal.git'
        Invoke-Tool -Target $target | Out-Null
        $path = Join-Path $target 'aisdlc.json'
        $config = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        $config.tracker.acceptedRepositories = @('contoso/platform')
        [IO.File]::WriteAllText($path, ($config | ConvertTo-Json -Depth 10))

        $result = Invoke-Tool -Target $target -Extra @('-Force')

        $result.Code | Should -Be 0 -Because $result.Output
        @((Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).tracker.acceptedRepositories) | Should -Be @('RobHofmann/AI.SDLC', 'contoso/platform')
    }

    It 'reads an SSH remote too' {
        $target = New-TargetRepo -Remote 'git@github.com:contoso/portal.git'
        Invoke-Tool -Target $target | Out-Null

        (Get-Content (Join-Path $target 'aisdlc.json') -Raw | ConvertFrom-Json).github.repository | Should -Be 'contoso/portal'
    }

    It 'always adds github and github-issues, and no stack pack to a repository without one' {
        $target = New-TargetRepo -Files @{ 'README.md' = 'x' }
        $result = Invoke-Tool -Target $target

        $result.Code | Should -Be 0 -Because $result.Output
        Get-ApmPack $target | Should -Be @('github', 'github-issues')
        $apm = Get-Content (Join-Path $target 'apm.yml') -Raw
        $apm | Should -Match 'path: core'
        $apm | Should -Match '(?m)^    - git: https://github\.com/RobHofmann/AI\.SDLC$'
        $apm | Should -Not -Match 'packs/dotnet'
        $result.Output | Should -Match 'github\.repository in aisdlc\.json' -Because 'the repository has no GitHub remote yet'
    }

    It 'adds the knowledge pack only when asked, with the setting to fill in' {
        $target = New-TargetRepo -Files @{ 'README.md' = 'x' }
        $result = Invoke-Tool -Target $target -Extra @('-AddPacks', 'knowledge')

        $result.Code | Should -Be 0 -Because $result.Output
        Get-ApmPack $target | Should -Be @('github', 'github-issues', 'knowledge')
        (Get-Content (Join-Path $target 'aisdlc.json') -Raw | ConvertFrom-Json).PSObject.Properties.Name | Should -Contain 'knowledge'
        $result.Output | Should -Match 'knowledge\.repository'
    }

    It 'adds the sonarcloud pack only when asked, and names the token variable' {
        $target = New-TargetRepo -Files @{ 'README.md' = 'x' }
        $result = Invoke-Tool -Target $target -Extra @('-AddPacks', 'sonarcloud')

        $result.Code | Should -Be 0 -Because $result.Output
        Get-ApmPack $target | Should -Be @('github', 'github-issues', 'sonarcloud')
        $result.Output | Should -Match 'sonarcloud\.projectKey'
        $result.Output | Should -Match 'AISDLC_SONAR_MCP_TOKEN'
    }

    It 'pins every package at the same ref' {
        $target = New-TargetRepo -Files @{ 'main.bicep' = '' }
        Invoke-Tool -Target $target | Out-Null

        $refs = @(Select-String -LiteralPath (Join-Path $target 'apm.yml') -Pattern '^\s+ref: (.+)$' | ForEach-Object { $_.Matches[0].Groups[1].Value })
        $refs.Count | Should -Be 4
        $refs | Select-Object -Unique | Should -Be 'v9.9.9'
    }

    It 'takes -Packs over the picked ones and keeps the pack order' {
        $target = New-TargetRepo -Files @{ 'App.sln' = '' }
        $result = Invoke-Tool -Target $target -Extra @('-Packs', 'github-issues,bicep', '-AddPacks', 'discovery')

        $result.Code | Should -Be 0 -Because $result.Output
        Get-ApmPack $target | Should -Be @('bicep', 'github-issues', 'discovery')
    }

    It 'refuses an unknown pack' {
        $target = New-TargetRepo
        $result = Invoke-Tool -Target $target -Extra @('-AddPacks', 'python')

        $result.Code | Should -Not -Be 0
        $result.Output | Should -Match 'Unknown pack'
    }

    It 'keeps no Install-AiSdlc.ps1 of its own and points the docs at the one in the core' {
        $target = New-TargetRepo
        Invoke-Tool -Target $target -Extra @('-ScriptFolder', 'scripts') | Out-Null

        Test-Path (Join-Path $target 'scripts' 'Install-AiSdlc.ps1') | Should -BeFalse
        Get-Content (Join-Path $target 'docs' 'setup.md') -Raw | Should -Match 'pwsh \.claude/skills/ai-sdlc-hooks/scripts/Install-AiSdlc\.ps1'
        (Get-Content (Join-Path $target 'aisdlc.json') -Raw | ConvertFrom-Json).paths.toolsFolder | Should -Be 'scripts'
    }

    It 'gives every repository a technical and a functional layer, and no model backend for the doc tools' {
        $target = New-TargetRepo
        $result = Invoke-Tool -Target $target

        $result.Code | Should -Be 0 -Because $result.Output
        $config = Get-Content (Join-Path $target 'aisdlc.json') -Raw | ConvertFrom-Json
        $config.paths.technicalDocs | Should -Be 'docs'
        $config.paths.functionalDocs | Should -Be 'docs-functional'
        $config.paths.docsRoots | Should -Be @('docs', 'docs-functional')
        $config.PSObject.Properties.Name | Should -Not -Contain 'docGenerator'
        Get-Content (Join-Path $target 'docs-functional' 'overview.md') -Raw | Should -Match '\[glossary\]\(glossary\.md\)'
        Get-Content (Join-Path $target 'docs-functional' 'glossary.md') -Raw | Should -Match '\[overview\]\(overview\.md\)'
    }

    It 'keeps the drafts of the doc tools out of git' {
        $target = New-TargetRepo -Files @{ '.gitignore' = 'bin/' }
        Invoke-Tool -Target $target | Out-Null

        $ignore = Get-Content (Join-Path $target '.gitignore') -Raw
        $ignore | Should -Match '(?m)^bin/'
        $ignore | Should -Match '(?m)^doc-candidates/'
    }

    It 'keeps the working files of the agents and the pre-flight receipts out of git' {
        $target = New-TargetRepo -Files @{ '.gitignore' = "bin/`ntemp/`n" }
        Invoke-Tool -Target $target | Out-Null
        $ignore = Get-Content (Join-Path $target '.gitignore') -Raw
        ([regex]::Matches($ignore, '(?m)^temp/')).Count | Should -Be 1 -Because 'a temp/ rule that is there already is not added twice'

        $fresh = New-TargetRepo -Files @{ '.gitignore' = 'bin/' }
        Invoke-Tool -Target $fresh | Out-Null
        Get-Content (Join-Path $fresh '.gitignore') -Raw | Should -Match '(?m)^temp/'
    }

    It 'keeps a receipt folder outside temp/ that paths.preflightReceipts names out of git, once' {
        $target = New-TargetRepo -Files @{
            '.gitignore'  = 'bin/'
            'aisdlc.json' = '{ "paths": { "preflightReceipts": "out/receipts" } }'
        }
        $result = Invoke-Tool -Target $target -Extra @('-Force')
        $result.Code | Should -Be 0 -Because $result.Output
        Invoke-Tool -Target $target -Extra @('-Force') | Out-Null

        $ignore = Get-Content (Join-Path $target '.gitignore') -Raw
        ([regex]::Matches($ignore, '(?m)^/out/receipts/')).Count | Should -Be 1
        $ignore | Should -Match '(?m)^temp/'
    }

    It 'anchors a one-part receipt folder at the root, so git does not ignore that name at every depth' {
        $target = New-TargetRepo -Files @{
            '.gitignore'  = 'bin/'
            'aisdlc.json' = '{ "paths": { "preflightReceipts": "out" } }'
        }
        $result = Invoke-Tool -Target $target -Extra @('-Force')
        $result.Code | Should -Be 0 -Because $result.Output

        Get-Content (Join-Path $target '.gitignore') -Raw | Should -Match '(?m)^/out/$'
        git -C $target check-ignore -q out/x.json
        $LASTEXITCODE | Should -Be 0
        git -C $target check-ignore -q src/out/x.json
        $LASTEXITCODE | Should -Be 1 -Because 'a folder named out deeper in the tree is not the receipt folder'
    }

    It 'writes a receipt folder given with a leading ./ as a rule git matches' {
        $target = New-TargetRepo -Files @{
            '.gitignore'  = 'bin/'
            'aisdlc.json' = '{ "paths": { "preflightReceipts": "./out/receipts" } }'
        }
        $result = Invoke-Tool -Target $target -Extra @('-Force')
        $result.Code | Should -Be 0 -Because $result.Output
        Invoke-Tool -Target $target -Extra @('-Force') | Out-Null

        $ignore = Get-Content (Join-Path $target '.gitignore') -Raw
        ([regex]::Matches($ignore, '(?m)^/out/receipts/')).Count | Should -Be 1
        $ignore | Should -Not -Match '(?m)^\./out'
    }

    It 'writes a receipt folder given with a leading / as a rule git matches' {
        $target = New-TargetRepo -Files @{
            '.gitignore'  = 'bin/'
            'aisdlc.json' = '{ "paths": { "preflightReceipts": "/out/receipts" } }'
        }
        $result = Invoke-Tool -Target $target -Extra @('-Force')
        $result.Code | Should -Be 0 -Because $result.Output

        Get-Content (Join-Path $target '.gitignore') -Raw | Should -Match '(?m)^/out/receipts/'
    }

    It 'keeps a functional layer the repository already has' {
        $target = New-TargetRepo -Files @{ 'docs-functional/overview.md' = '# Ours' }
        Invoke-Tool -Target $target | Out-Null

        (Get-Content (Join-Path $target 'docs-functional' 'overview.md') -Raw).Trim() | Should -Be '# Ours'
        Test-Path (Join-Path $target 'docs-functional' 'glossary.md') | Should -BeFalse
    }

    It 'writes AGENTS.md and the Claude import in .claude/CLAUDE.md only when they are missing' {
        $target = New-TargetRepo -Files @{ 'AGENTS.md' = '# Mine' }
        Invoke-Tool -Target $target | Out-Null

        (Get-Content (Join-Path $target 'AGENTS.md') -Raw).Trim() | Should -Be '# Mine'
        (Get-Content (Join-Path $target '.claude' 'CLAUDE.md') -Raw).Trim() | Should -Be '@../AGENTS.md'
        Test-Path (Join-Path $target 'CLAUDE.md') | Should -BeFalse -Because 'GitHub Copilot reads a root CLAUDE.md and its import, so it would load AGENTS.md twice'
    }

    It 'leaves a root CLAUDE.md the repository already has, and writes no second import' {
        $target = New-TargetRepo -Files @{ 'CLAUDE.md' = "# Ours`n@AGENTS.md" }
        Invoke-Tool -Target $target | Out-Null

        (Get-Content (Join-Path $target 'CLAUDE.md') -Raw).Trim() | Should -Be "# Ours`n@AGENTS.md"
        Test-Path (Join-Path $target '.claude' 'CLAUDE.md') | Should -BeFalse
    }

    It 'keeps LF endings on the git hooks and leaves the other .gitattributes lines alone' {
        $target = New-TargetRepo -Files @{ '.gitattributes' = '* text=auto' }
        Invoke-Tool -Target $target | Out-Null
        Invoke-Tool -Target $target -Extra @('-Force') | Out-Null

        $attributes = Get-Content (Join-Path $target '.gitattributes') -Raw
        $attributes | Should -Match '^\* text=auto'
        ([regex]::Matches($attributes, 'githooks/\*\* text eol=lf')).Count | Should -Be 1
    }

    It 'refuses to overwrite an existing aisdlc.json without -Force' {
        $target = New-TargetRepo -Files @{ 'aisdlc.json' = '{}' }
        $result = Invoke-Tool -Target $target

        $result.Code | Should -Not -Be 0
        $result.Output | Should -Match 'pass -Force'
        (Get-Content (Join-Path $target 'aisdlc.json') -Raw).Trim() | Should -Be '{}'

        (Invoke-Tool -Target $target -Extra @('-Force')).Code | Should -Be 0
    }

    It 'finds the .NET paths the dotnet gates read, and lists only the ones it cannot find' {
        $target = New-TargetRepo -Files @{ 'src/App.sln' = ''; 'src/Api/Api.csproj' = ''; 'tests/Api.Tests/Api.Tests.csproj' = ''; 'App.runsettings' = '<RunSettings />' }
        $result = Invoke-Tool -Target $target

        $paths = (Get-Content (Join-Path $target 'aisdlc.json') -Raw | ConvertFrom-Json).paths
        $paths.solution | Should -Be 'src/App.sln'
        $paths.sourceRoot | Should -Be 'src'
        $paths.testRoot | Should -Be 'tests'
        $paths.runSettings | Should -Be 'App.runsettings'
        $paths.PSObject.Properties.Name | Should -Not -Contain 'coverageBaseline'
        $result.Output | Should -Match 'paths\.coverageBaseline'
        $result.Output | Should -Not -Match 'paths\.sourceRoot'
    }

    It 'writes the starter workflow when the repository has none, with the composite action of the core' {
        $target = New-TargetRepo -Remote 'https://github.com/contoso/portal.git' -Files @{ 'main.bicep' = '' }
        $result = Invoke-Tool -Target $target

        $result.Code | Should -Be 0 -Because $result.Output
        $workflow = Get-Content (Join-Path $target '.github' 'workflows' 'pr.yml') -Raw
        $workflow | Should -Match '(?m)^      - uses: \./\.claude/skills/ai-sdlc-gates/assets/actions/ai-sdlc-pr\s*$'
        $workflow | Should -Match 'private-terms: \$\{\{ secrets\.AISDLC_PRIVATE_TERMS \}\}'
        $workflow | Should -Match '(?m)^    runs-on: ubuntu-24\.04\s*$'
        $workflow | Should -Match '(?m)^      - main\s*$'
        $workflow | Should -Match 'actions/checkout@[0-9a-f]{40} # v\d'
        $workflow | Should -Not -Match '\{\{[A-Z][A-Za-z]+\}\}'
        $workflow | Should -Not -Match 'setup-dotnet|coverage-file'
        $config = Get-Content (Join-Path $target 'aisdlc.json') -Raw | ConvertFrom-Json
        $config.paths.codeAnalysisPipeline | Should -Be '.github/workflows/pr.yml'
        $config.paths.pipelinesFolder | Should -Be '.github/workflows'
    }

    It 'writes a starter workflow that parses as YAML, with fetch-depth 0 and read-only permissions, whose action exists in the core' -Skip:(-not (Get-Module -ListAvailable powershell-yaml)) {
        Import-Module powershell-yaml
        $target = New-TargetRepo -Files @{ 'src/App.sln' = '' }
        Invoke-Tool -Target $target | Out-Null
        $yaml = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $target '.github' 'workflows' 'pr.yml') -Raw)

        $yaml.on.pull_request.branches | Should -Be @('main')
        $yaml.permissions.contents | Should -Be 'read'
        @($yaml.permissions.Values | Where-Object { $_ -ne 'read' }) | Should -BeNullOrEmpty
        $steps = $yaml.jobs['ai-sdlc'].steps
        $steps[0].with['fetch-depth'] | Should -Be 0
        $action = @($steps | Where-Object { $_.uses -like './.claude/*' })[0]
        $action.with['coverage-file'] | Should -Match 'coverage\.xml$'
        $source = $action.uses -replace '^\./\.claude/skills/', 'core/.apm/skills/'
        Test-Path (Join-Path $PSScriptRoot '..' $source 'action.yml') | Should -BeTrue -Because 'the consumer runs the composite action that the core installs'
    }

    It 'gives a .NET repository a test step that merges the coverage, and passes it to the action for the C04 ratchet' {
        $target = New-TargetRepo -Files @{ 'src/App.sln' = ''; 'App.runsettings' = '<RunSettings />' }
        $result = Invoke-Tool -Target $target
        $result.Code | Should -Be 0 -Because $result.Output

        $workflow = Get-Content (Join-Path $target '.github' 'workflows' 'pr.yml') -Raw
        $workflow | Should -Match 'actions/setup-dotnet@[0-9a-f]{40} # v\d'
        $workflow | Should -Match 'dotnet test src/App\.sln [^\r\n]*--collect "Code Coverage"'
        $workflow | Should -Match '--settings App\.runsettings'
        $workflow | Should -Match 'dotnet-coverage[^\r\n]* merge --output "\$\{\{ runner\.temp \}\}/coverage/coverage\.xml" --output-format xml'
        $workflow | Should -Match 'coverage-file: \$\{\{ runner\.temp \}\}/coverage/coverage\.xml'
        $workflow | Should -Not -Match '\{\{[A-Z][A-Za-z]+\}\}'
    }

    It 'leaves an existing pull request workflow alone and names the step to add' {
        $target = New-TargetRepo -Files @{ '.github/workflows/pr.yml' = 'on: pull_request' }
        $result = Invoke-Tool -Target $target

        (Get-Content (Join-Path $target '.github' 'workflows' 'pr.yml') -Raw).Trim() | Should -Be 'on: pull_request'
        $result.Output | Should -Match 'Add the shared AI-SDLC step'
    }

    It 'does not ask for the step again on a -Force rerun, when the workflow it wrote already holds it' {
        $target = New-TargetRepo -Files @{ 'src/App.sln' = '' }
        Invoke-Tool -Target $target | Out-Null
        $result = Invoke-Tool -Target $target -Extra @('-Force')

        $result.Code | Should -Be 0 -Because $result.Output
        $result.Output | Should -Not -Match 'Add the shared AI-SDLC step'
        (Get-Content -LiteralPath (Join-Path $target 'aisdlc.json') -Raw | ConvertFrom-Json).paths.codeAnalysisPipeline | Should -Be '.github/workflows/pr.yml'
    }

    It 'shows the ruleset step apart from the other steps, because without it no gate has to pass' {
        $target = New-TargetRepo -Remote 'https://github.com/contoso/portal.git'
        $result = Invoke-Tool -Target $target

        $result.Code | Should -Be 0 -Because $result.Output
        $result.Output | Should -Match '(?s)Without this step no gate has to pass on a pull request.*\n  >> After the first push, run the pull request workflow once and make its check required on main: pwsh \.claude/skills/github-pull-requests/scripts/Set-BranchRuleset\.ps1 -RequiredCheck "AI-SDLC gates".*Still to do by hand:'
        $list = ($result.Output -split 'Still to do by hand:')[1]
        $list | Should -Not -Match 'Set-BranchRuleset' -Because 'the step stands apart, not as one more numbered line'
        $list | Should -Match 'Switch on Issues'
        $list | Should -Match 'GitHub App'
    }

    It 'names the job of the starter workflow as the required check, read from the template' {
        $template = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'templates' 'workflows' 'pr.yml') -Raw
        $match = [regex]::Match($template, '(?m)^  ai-sdlc:\s*\n    name: (.+?)\s*$')
        $match.Success | Should -BeTrue
        $jobName = $match.Groups[1].Value
        $target = New-TargetRepo

        $result = Invoke-Tool -Target $target

        $result.Code | Should -Be 0 -Because $result.Output
        $result.Output | Should -Match ([regex]::Escape("Set-BranchRuleset.ps1 -RequiredCheck `"$jobName`""))
    }

    It 'names the job of an existing workflow that already runs the shared step' {
        $workflow = "on: pull_request`njobs:`n  build:`n    runs-on: ubuntu-24.04`n  checks:`n    name: 'Portal gates'`n    steps:`n      - uses: ./.claude/skills/ai-sdlc-gates/assets/actions/ai-sdlc-pr`n"
        $target = New-TargetRepo -Files @{ '.github/workflows/pr.yml' = $workflow }

        $result = Invoke-Tool -Target $target

        $result.Code | Should -Be 0 -Because $result.Output
        $result.Output | Should -Match ([regex]::Escape('Set-BranchRuleset.ps1 -RequiredCheck "Portal gates"'))
    }

    It 'still shows the gate step with -NoWorkflows, and says where the workflow comes from' {
        $target = New-TargetRepo
        $result = Invoke-Tool -Target $target -Extra @('-NoWorkflows')

        $result.Code | Should -Be 0 -Because $result.Output
        Test-Path (Join-Path $target '.github') | Should -BeFalse
        $result.Output | Should -Match '  >> This run wrote no workflow\. Add a pull request workflow with the shared AI-SDLC step \(start from tools/templates/workflows/pr\.yml in AI\.SDLC\)'
    }

    It 'keeps no consumer list and opens no pull request on AI.SDLC, because AI.SDLC does not know its consumers' {
        $target = New-TargetRepo -Remote 'https://github.com/contoso/portal.git'
        $result = Invoke-Tool -Target $target

        $result.Code | Should -Be 0 -Because $result.Output
        $result.Output | Should -Not -Match 'consumers\.json|consumer list|re-pin'
    }

    It 'writes the update workflow, which signs in as a GitHub App, and names the app setup as a step by hand' {
        $target = New-TargetRepo -Remote 'https://github.com/contoso/portal.git'
        $result = Invoke-Tool -Target $target

        $result.Code | Should -Be 0 -Because $result.Output
        $workflow = Get-Content (Join-Path $target '.github' 'workflows' 'ai-sdlc-update.yml') -Raw
        $workflow | Should -Match '(?m)^\s+- cron: '
        $workflow | Should -Match '(?m)^  workflow_dispatch:'
        $workflow | Should -Match 'actions/create-github-app-token@[0-9a-f]{40} # v\d'
        $workflow | Should -Match 'actions/checkout@[0-9a-f]{40} # v\d'
        $workflow | Should -Match 'vars\.AISDLC_UPDATE_APP_CLIENT_ID'
        $workflow | Should -Match 'secrets\.AISDLC_UPDATE_APP_PRIVATE_KEY'
        $workflow | Should -Match '(?m)^          ref: main\s*$'
        $workflow | Should -Match 'New-AiSdlcUpdatePullRequest\.ps1'
        $workflow | Should -Not -Match '\{\{[A-Z][A-Za-z]+\}\}'
        Test-Path (Join-Path $PSScriptRoot '..' 'core' '.apm' 'skills' 'ai-sdlc-hooks' 'scripts' 'New-AiSdlcUpdatePullRequest.ps1') | Should -BeTrue
        ($result.Output -split 'Still to do by hand:')[1] | Should -Match 'AISDLC_UPDATE_APP_CLIENT_ID'
    }

    It 'leaves an update workflow the repository already has, and writes neither workflow with -NoWorkflows' {
        $target = New-TargetRepo -Remote 'https://github.com/contoso/portal.git' -Files @{ '.github/workflows/ai-sdlc-update.yml' = 'name: mine' }
        Invoke-Tool -Target $target | Out-Null
        (Get-Content (Join-Path $target '.github' 'workflows' 'ai-sdlc-update.yml') -Raw).Trim() | Should -Be 'name: mine'

        $bare = New-TargetRepo
        Invoke-Tool -Target $bare -Extra @('-NoWorkflows') | Out-Null
        Test-Path (Join-Path $bare '.github' 'workflows' 'ai-sdlc-update.yml') | Should -BeFalse
    }

    It 'refuses a folder that is not a git repository' {
        $folder = Join-Path ([System.IO.Path]::GetTempPath()) ('aac-nogit-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $folder | Out-Null
        $result = Invoke-Tool -Target $folder

        $result.Code | Should -Not -Be 0
        $result.Output | Should -Match 'not a git repository'
    }

    It 'writes nothing with -WhatIf' {
        $target = New-TargetRepo -Remote 'https://github.com/contoso/portal.git' -Files @{ 'src/App.sln' = '' }
        $result = Invoke-Tool -Target $target -Extra @('-WhatIf')

        $result.Code | Should -Be 0 -Because $result.Output
        $result.Output | Should -Match 'What if'
        @(git -C $target status --porcelain --untracked-files=all) | Should -Be @('?? src/App.sln')
    }

    It 'merges into an existing aisdlc.json with -Force, so fields added by hand stay and an old packs field goes' {
        $target = New-TargetRepo -Remote 'https://github.com/contoso/portal.git'
        Invoke-Tool -Target $target | Out-Null
        $path = Join-Path $target 'aisdlc.json'
        $config = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        $config.repoGates = @([ordered]@{ script = 'tools/Check-Mine.ps1'; clause = 'REPO-01'; mode = 'Blocking' })
        $config.readingLevelRoots = @('docs', 'guides')
        $config.paths.coverageBaseline = 'coverage-baseline.json'
        $config.packs = @('github')
        [IO.File]::WriteAllText($path, ($config | ConvertTo-Json -Depth 10))

        $result = Invoke-Tool -Target $target -Extra @('-Force')

        $result.Code | Should -Be 0 -Because $result.Output
        $merged = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $merged.repoGates[0].script | Should -Be 'tools/Check-Mine.ps1'
        $merged.readingLevelRoots | Should -Be @('docs', 'guides')
        $merged.paths.coverageBaseline | Should -Be 'coverage-baseline.json'
        $merged.paths.toolsFolder | Should -Be 'tools'
        $merged.PSObject.Properties.Name | Should -Not -Contain 'packs'
        Get-ApmPack $target | Should -Be @('github', 'github-issues')
    }

    It 'goes on past a missing GitHub CLI login, because a public source needs no login' {
        $target = New-TargetRepo
        $fakes = Join-Path ([System.IO.Path]::GetTempPath()) ('aac-fakes-' + [guid]::NewGuid().ToString('n'))
        New-FakeCommand -Folder $fakes -Name 'apm' -ExitCode 0
        New-FakeCommand -Folder $fakes -Name 'gh' -ExitCode 1
        $result = Invoke-WithFakes -Folder $fakes -Script { Invoke-Tool -Target $target -Install }

        Test-Path -LiteralPath (Join-Path $target 'aisdlc.json') | Should -BeTrue -Because $result.Output
    }

    It 'moves an untracked root CLAUDE.md import into .claude/CLAUDE.md after the install, before it stages' {
        $target = New-TargetRepo -Files @{ 'CLAUDE.md' = '@AGENTS.md' }
        $gates = Join-Path $target '.claude' 'skills'
        New-Item -ItemType Directory -Path $gates -Force | Out-Null
        Copy-Item -Recurse -LiteralPath (Join-Path $PSScriptRoot '..' 'core' '.apm' 'skills' 'ai-sdlc-gates') -Destination $gates
        $fakes = Join-Path ([System.IO.Path]::GetTempPath()) ('aac-fakes-' + [guid]::NewGuid().ToString('n'))
        New-FakeCommand -Folder $fakes -Name 'apm' -ExitCode 0
        $result = Invoke-WithFakes -Folder $fakes -Script { Invoke-Tool -Target $target -Install -Extra @('-LocalSource', (Join-Path $PSScriptRoot '..')) }

        $result.Code | Should -Be 0 -Because $result.Output
        Test-Path (Join-Path $target 'CLAUDE.md') | Should -BeFalse
        (Get-Content (Join-Path $target '.claude' 'CLAUDE.md') -Raw).Trim() | Should -Be '@../AGENTS.md'
        git -C $target diff --cached --name-only | Should -Contain '.claude/CLAUDE.md'
        git -C $target diff --cached --name-only | Should -Contain 'AGENTS.md'
        git -C $target diff --cached --name-only | Should -Contain '.github/workflows/pr.yml'
    }

    It 'names the usual causes when apm install fails, with the shared hint' {
        $target = New-TargetRepo
        $fakes = Join-Path ([System.IO.Path]::GetTempPath()) ('aac-fakes-' + [guid]::NewGuid().ToString('n'))
        New-FakeCommand -Folder $fakes -Name 'apm' -ExitCode 3
        $result = Invoke-WithFakes -Folder $fakes -Script { Invoke-Tool -Target $target -Install -Extra @('-LocalSource', (Join-Path $PSScriptRoot '..')) }

        $result.Code | Should -Not -Be 0
        $flat = $result.Output -replace '[\s|]+', ' '
        $flat | Should -Match 'apm install failed with exit code 3'
        $flat | Should -Match 'WinError 206'
        $flat | Should -Match 'run this again with -Force'
    }
}
