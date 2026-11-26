#requires -Version 7.4

Describe 'Invoke-BicepPreflight' {
    BeforeAll {
        $script:Script = Join-Path $PSScriptRoot 'Invoke-BicepPreflight.ps1'

        function New-BicepRepo {
            param([string[]]$Templates)
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value '{}'
            foreach ($rel in $Templates) {
                $full = Join-Path $root $rel
                New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
                Set-Content -LiteralPath $full -Value "targetScope = 'subscription'"
            }
            return $root
        }

        $script:GitHubActionsOutside = $env:GITHUB_ACTIONS
        $env:GITHUB_ACTIONS = $null
    }

    AfterAll { $env:GITHUB_ACTIONS = $script:GitHubActionsOutside }

    It 'passes when every template builds' {
        $root = New-BicepRepo -Templates @('building-blocks/a/main-a.bicep', 'building-blocks/b/main-b.bicep')

        $row = & $script:Script -RepoRoot $root -Builder { param($Path) $true }

        $row.Status | Should -Be 'PASS'
        $row.Detail | Should -Match '2 template\(s\) build'
    }

    It 'fails and names each template that does not build' {
        $root = New-BicepRepo -Templates @('building-blocks/a/main-a.bicep', 'building-blocks/b/broken.bicep')

        $row = & $script:Script -RepoRoot $root -Builder { param($Path) $Path -notmatch 'broken' }

        $row.Status | Should -Be 'FAIL'
        $row.Detail | Should -Match 'building-blocks/b/broken\.bicep'
        $row.Detail | Should -Not -Match 'main-a'
    }

    It 'leaves out templates under .claude and apm_modules' {
        $root = New-BicepRepo -Templates @('main.bicep', '.claude/skills/x/sample.bicep', 'apm_modules/pkg/sample.bicep')
        $global:BicepSeen = [System.Collections.Generic.List[string]]::new()

        & $script:Script -RepoRoot $root -Builder { param($Path) $global:BicepSeen.Add($Path); $true } | Out-Null

        $global:BicepSeen | Should -HaveCount 1
        $global:BicepSeen[0] | Should -Match 'main\.bicep$'
    }

    Context 'the build errors and the exit code, for a workflow that calls it directly' {
        BeforeAll {
            $script:ErrorBuilder = { param($Path) [pscustomobject]@{ Success = $Path -notmatch 'broken'; Output = @("$Path(3,7) : Error BCP057: The name ""x"" does not exist.") } }
            $script:ErrorBuilderText = $script:ErrorBuilder.ToString()

            function Invoke-AsProcess {
                param([string]$Root, [string[]]$Extra = @(), [switch]$InPipeline)
                $command = "& '$script:Script' -RepoRoot '$Root' -Builder { $script:ErrorBuilderText } $($Extra -join ' ')"
                $saved = $env:GITHUB_ACTIONS
                $env:GITHUB_ACTIONS = if ($InPipeline) { 'true' } else { $null }
                try { $out = & pwsh -NoProfile -Command $command 2>&1 | Out-String }
                finally { $env:GITHUB_ACTIONS = $saved }
                return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out }
            }
        }

        BeforeEach {
            $script:SavedGitHubActions = $env:GITHUB_ACTIONS
            $env:GITHUB_ACTIONS = $null
        }

        AfterEach { $env:GITHUB_ACTIONS = $script:SavedGitHubActions }

        It 'keeps the build errors out of a local pre-flight run by default' {
            $root = New-BicepRepo -Templates @('broken.bicep')

            $written = & { & $script:Script -RepoRoot $root -Builder $script:ErrorBuilder | Out-Null } 6>&1 | Out-String

            $written | Should -Not -Match 'BCP057'
        }

        It 'prints the build errors of each failing template with -ShowErrors' {
            $root = New-BicepRepo -Templates @('ok.bicep', 'broken.bicep')

            $written = & { & $script:Script -RepoRoot $root -Builder $script:ErrorBuilder -ShowErrors | Out-Null } 6>&1 | Out-String

            $written | Should -Match 'Bicep build failed: broken\.bicep'
            $written | Should -Match 'Error BCP057'
            $written | Should -Not -Match 'failed: ok\.bicep'
        }

        It 'prints the errors and an error annotation in GitHub Actions without being asked' {
            $root = New-BicepRepo -Templates @('broken.bicep')
            $env:GITHUB_ACTIONS = 'true'

            $written = & { & $script:Script -RepoRoot $root -Builder $script:ErrorBuilder | Out-Null } 6>&1 | Out-String

            $written | Should -Match 'Error BCP057'
            $written | Should -Match '::error file=broken\.bicep,title=Bicep build::Bicep build failed: .*BCP057'
        }

        It 'still returns the row and exits 0 without -FailOnError, for Invoke-Preflight' {
            $root = New-BicepRepo -Templates @('broken.bicep')

            $r = Invoke-AsProcess -Root $root

            $r.Code | Should -Be 0
            $r.Output | Should -Match 'FAIL'
        }

        It 'exits 1 with -FailOnError when a template does not build' {
            $root = New-BicepRepo -Templates @('broken.bicep')

            $r = Invoke-AsProcess -Root $root -Extra @('-FailOnError') -InPipeline

            $r.Code | Should -Be 1
            $r.Output | Should -Match 'Error BCP057'
        }

        It 'exits 0 with -FailOnError when every template builds' {
            $root = New-BicepRepo -Templates @('ok.bicep')

            $r = Invoke-AsProcess -Root $root -Extra @('-FailOnError')

            $r.Code | Should -Be 0
        }
    }

    Context 'a Bicep CLI with build --pattern' {
        BeforeAll {
            $script:FakeBicep = Join-Path $TestDrive 'fake-bicep' 'bicep.ps1'
            New-Item -ItemType Directory -Path (Split-Path $script:FakeBicep -Parent) -Force | Out-Null
            Set-Content -LiteralPath $script:FakeBicep -Value @'
$folder = Split-Path $PSCommandPath -Parent
Add-Content -LiteralPath (Join-Path $folder 'calls.txt') -Value ($args -join ' ')
if ($args[1] -eq '--help') {
    if (Test-Path -LiteralPath (Join-Path $folder 'old')) { 'Usage: bicep build <file>' } else { '  --pattern <pattern>  Builds all files matching the specified glob pattern.' }
    exit 0
}
if ($args[1] -eq '--pattern') {
    $files = @(Get-ChildItem -LiteralPath $args[2].Split('/')[0] -Recurse -File -Filter '*.bicep')
    if (@($files | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'crash' }).Count -gt 0) { 'Unhandled exception.'; exit 1 }
    $code = 0
    foreach ($file in $files) {
        $text = Get-Content -LiteralPath $file.FullName -Raw
        if ($text -match 'warn') { "$($file.FullName)(1,1) : Warning no-unused-params: Parameter is declared but never used." }
        if ($text -match 'broken') { "$($file.FullName)(3,7) : Error BCP057: The name ""x"" does not exist."; $code = 1 }
        if ($text -match 'silent') { $code = 1 }
    }
    exit $code
}
if ((Get-Content -LiteralPath $args[1] -Raw) -match 'broken|silent|crash') { "$($args[1])(3,7) : Error BCP057: The name ""x"" does not exist."; exit 1 }
exit 0
'@

            function New-TemplateRepo {
                param([hashtable]$Templates)
                $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
                New-Item -ItemType Directory -Path $root -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value '{}'
                foreach ($rel in $Templates.Keys) {
                    $full = Join-Path $root $rel
                    New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
                    Set-Content -LiteralPath $full -Value $Templates[$rel]
                }
                return $root
            }

            function Get-FakeCall {
                $log = Join-Path (Split-Path $script:FakeBicep -Parent) 'calls.txt'
                if (Test-Path -LiteralPath $log) { @(Get-Content -LiteralPath $log | Where-Object { $_ -notmatch '--help' }) } else { @() }
            }
        }

        BeforeEach {
            Remove-Item -LiteralPath (Join-Path (Split-Path $script:FakeBicep -Parent) 'calls.txt') -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Join-Path (Split-Path $script:FakeBicep -Parent) 'old') -Force -ErrorAction SilentlyContinue
        }

        It 'builds every template of a top-level folder in one call' {
            $root = New-TemplateRepo -Templates @{ 'building-blocks/a/main.bicep' = 'ok'; 'building-blocks/b/main.bicep' = 'ok'; 'modules/m.bicep' = 'ok' }

            $row = & $script:Script -RepoRoot $root -BicepPath $script:FakeBicep

            $row.Status | Should -Be 'PASS'
            $row.Detail | Should -Match '3 template\(s\) build'
            $calls = Get-FakeCall
            $calls | Should -HaveCount 2
            @($calls | Where-Object { $_ -like 'build --pattern building-blocks/`*`*/`*.bicep --outdir *' }) | Should -HaveCount 1
            @($calls | Where-Object { $_ -like 'build --pattern modules/`*`*/`*.bicep --outdir *' }) | Should -HaveCount 1
        }

        It 'fails only the template an Error line names, and a warning fails nothing' {
            $root = New-TemplateRepo -Templates @{ 'building-blocks/a/main.bicep' = 'broken'; 'building-blocks/b/main.bicep' = 'warn' }

            $row = & $script:Script -RepoRoot $root -BicepPath $script:FakeBicep

            $row.Status | Should -Be 'FAIL'
            $row.Detail | Should -Match '1 of 2 template\(s\) do not build: building-blocks/a/main\.bicep$'
        }

        It 'prints the Error line of the failing template with -ShowErrors' {
            $root = New-TemplateRepo -Templates @{ 'building-blocks/a/main.bicep' = 'broken'; 'building-blocks/b/main.bicep' = 'ok' }

            $written = & { & $script:Script -RepoRoot $root -BicepPath $script:FakeBicep -ShowErrors | Out-Null } 6>&1 | Out-String

            $written | Should -Match 'Bicep build failed: building-blocks/a/main\.bicep'
            $written | Should -Match 'Error BCP057'
            $written | Should -Not -Match 'failed: building-blocks/b'
        }

        It 'builds each template of the folder one at a time when the folder build fails with no Error line' {
            $root = New-TemplateRepo -Templates @{ 'building-blocks/a/main.bicep' = 'crash'; 'building-blocks/b/main.bicep' = 'ok'; 'modules/m.bicep' = 'ok' }

            $row = & $script:Script -RepoRoot $root -BicepPath $script:FakeBicep

            $row.Status | Should -Be 'FAIL'
            $row.Detail | Should -Match '1 of 3 template\(s\) do not build: building-blocks/a/main\.bicep$'
            @(Get-FakeCall | Where-Object { $_ -match '^build .*building-blocks.b.main\.bicep --outfile' }) | Should -HaveCount 1 -Because 'the folder build failed, so each template of it is built again'
            @(Get-FakeCall | Where-Object { $_ -match '^build .*m\.bicep --outfile' }) | Should -BeNullOrEmpty -Because 'the modules folder built clean'
        }

        It 'fails both templates when two fail and the output names only one' {
            $root = New-TemplateRepo -Templates @{ 'building-blocks/a/main.bicep' = 'broken'; 'building-blocks/b/main.bicep' = 'silent'; 'building-blocks/c/main.bicep' = 'ok' }

            $row = & $script:Script -RepoRoot $root -BicepPath $script:FakeBicep

            $row.Status | Should -Be 'FAIL'
            $row.Detail | Should -Match '2 of 3 template\(s\) do not build'
            $row.Detail | Should -Match 'building-blocks/a/main\.bicep'
            $row.Detail | Should -Match 'building-blocks/b/main\.bicep'
            $row.Detail | Should -Not -Match 'building-blocks/c/main\.bicep'
        }

        It 'builds a template at the root, and a folder with a skipped folder inside, one file at a time' {
            $root = New-TemplateRepo -Templates @{ 'main.bicep' = 'ok'; 'infra/main.bicep' = 'broken'; 'infra/node_modules/pkg/x.bicep' = 'ok' }

            $row = & $script:Script -RepoRoot $root -BicepPath $script:FakeBicep

            $row.Status | Should -Be 'FAIL'
            $row.Detail | Should -Match '1 of 2 template\(s\) do not build: infra/main\.bicep$'
            $calls = Get-FakeCall
            $calls | Should -HaveCount 2
            @($calls | Where-Object { $_ -match '--pattern' }) | Should -HaveCount 0
        }

        It 'builds one file at a time with a CLI that has no --pattern' {
            $root = New-TemplateRepo -Templates @{ 'building-blocks/a/main.bicep' = 'ok'; 'building-blocks/b/main.bicep' = 'broken' }
            Set-Content -LiteralPath (Join-Path (Split-Path $script:FakeBicep -Parent) 'old') -Value ''

            $row = & $script:Script -RepoRoot $root -BicepPath $script:FakeBicep

            $row.Status | Should -Be 'FAIL'
            $row.Detail | Should -Match 'building-blocks/b/main\.bicep$'
            $calls = Get-FakeCall
            $calls | Should -HaveCount 2
            @($calls | Where-Object { $_ -match '--pattern' }) | Should -HaveCount 0
        }
    }

    Context 'which Bicep tool it picks, the way az bicep does' {
        BeforeAll {
            function New-FakeTool {
                param([string]$Folder, [string]$Name, [string]$Log)
                New-Item -ItemType Directory -Path $Folder -Force | Out-Null
                if ($IsWindows) {
                    Set-Content -LiteralPath (Join-Path $Folder "$Name.cmd") -Value "@echo off`r`necho $Name %*>>`"$Log`"`r`nexit /b 0"
                }
                else {
                    $path = Join-Path $Folder $Name
                    Set-Content -LiteralPath $path -Value "#!/bin/sh`necho `"$Name `$*`" >> '$Log'`nexit 0"
                    chmod +x $path
                }
            }
        }

        BeforeEach {
            $script:Saved = @{ PATH = $env:PATH; AZURE_CONFIG_DIR = $env:AZURE_CONFIG_DIR; GITHUB_ACTIONS = $env:GITHUB_ACTIONS }
            $script:Work = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
            $script:Log = Join-Path $script:Work 'calls.txt'
            $env:AZURE_CONFIG_DIR = Join-Path $script:Work 'azconfig'
            New-Item -ItemType Directory -Path $env:AZURE_CONFIG_DIR -Force | Out-Null
            $env:GITHUB_ACTIONS = $null
            $script:Root = Join-Path $script:Work 'repo'
            New-Item -ItemType Directory -Path (Join-Path $script:Root 'infra') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $script:Root 'aisdlc.json') -Value '{}'
            Set-Content -LiteralPath (Join-Path $script:Root 'infra' 'main.bicep') -Value "targetScope = 'subscription'"
        }

        AfterEach { foreach ($k in $script:Saved.Keys) { Set-Item -Path "Env:$k" -Value $script:Saved[$k] } }

        It 'builds with az bicep build when no Bicep CLI is installed, and never skips' {
            $bin = Join-Path $script:Work 'bin'
            New-FakeTool -Folder $bin -Name 'az' -Log $script:Log
            $env:PATH = $bin
            $env:GITHUB_ACTIONS = $null

            $row = & $script:Script -RepoRoot $script:Root -ShowErrors:$false

            $row.Status | Should -Be 'PASS'
            @(Get-Content -LiteralPath $script:Log) | Should -HaveCount 1
            (Get-Content -LiteralPath $script:Log) | Should -Match '^az bicep build --file .*main\.bicep'
        }

        It 'uses the Bicep CLI on the PATH in a workflow, as az bicep does there' {
            $bin = Join-Path $script:Work 'bin'
            New-FakeTool -Folder $bin -Name 'bicep' -Log $script:Log
            New-FakeTool -Folder $bin -Name 'az' -Log $script:Log
            $env:PATH = $bin
            $env:GITHUB_ACTIONS = 'true'

            $row = & $script:Script -RepoRoot $script:Root -ShowErrors:$false

            $row.Status | Should -Be 'PASS'
            @(Get-Content -LiteralPath $script:Log | Where-Object { $_ -match '^az ' }) | Should -BeNullOrEmpty
            @(Get-Content -LiteralPath $script:Log | Where-Object { $_ -match '^bicep build' }) | Should -Not -BeNullOrEmpty
        }
    }

    It 'passes with a clear detail when the repository has no template' {
        $root = New-BicepRepo -Templates @()

        $row = & $script:Script -RepoRoot $root -Builder { param($Path) $true }

        $row.Status | Should -Be 'PASS'
        $row.Detail | Should -Match 'no \.bicep file'
    }
}
