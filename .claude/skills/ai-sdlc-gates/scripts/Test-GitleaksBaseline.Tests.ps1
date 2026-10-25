#requires -Version 7.4

Describe 'Test-GitleaksBaseline' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path $PSScriptRoot 'Test-GitleaksBaseline.ps1'
        $script:SavedEnv = @{ GITHUB_ACTIONS = $env:GITHUB_ACTIONS; PR_BASE_SHA = $env:PR_BASE_SHA }

        function gitleaks { }

        function New-GitRepo {
            $repo = Join-Path $TestDrive ('repo-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $repo -Force | Out-Null
            git -C $repo init --quiet -b main
            git -C $repo config user.email probe@example.invalid
            git -C $repo config user.name probe
            Set-Content -LiteralPath (Join-Path $repo 'readme.txt') -Value 'base'
            git -C $repo add -A; git -C $repo commit --quiet -m base
            return $repo
        }

        $rulesHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('# rules'))).ToLowerInvariant()
        $script:PinFile = Join-Path $TestDrive 'gitleaks-rules.json'
        @{ configurations = [ordered]@{
                GitleaksUdmCombo  = @{ url = 'https://example.invalid/rules/0123abc/GitleaksUdmCombo.toml'; sha256 = $rulesHash }
                UDMSecretChecksv8 = @{ url = 'https://example.invalid/rules/0123abc/UDMSecretChecksv8.toml'; sha256 = $rulesHash }
                GitleaksOriginal  = @{ url = 'https://example.invalid/gitleaks/gitleaks/v8.30.1/config/gitleaks.toml'; sha256 = $rulesHash }
            }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:PinFile

        function Invoke-Scan {
            param([hashtable]$Options = @{}, [switch]$NoBaseline)
            $work = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $work -Force | Out-Null
            if (-not $NoBaseline) {
                $name = if ($Options.ContainsKey('BaselineFileName')) { $Options['BaselineFileName'] } else { 'gitleaks-baseline.json' }
                Set-Content -LiteralPath (Join-Path $work $name) -Value '[]'
            }
            Push-Location $work
            try {
                if (-not $Options.ContainsKey('PinFile')) { $Options['PinFile'] = $script:PinFile }
                $out = & $script:ScriptUnderTest @Options *>&1 | Out-String
                return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out; Work = $work }
            }
            finally { Pop-Location }
        }
    }

    BeforeEach {
        Remove-Item Env:GITHUB_ACTIONS, Env:PR_BASE_SHA -ErrorAction SilentlyContinue
        $global:LASTEXITCODE = 0
        Mock Invoke-WebRequest { Set-Content -LiteralPath $OutFile -Value '# rules' -NoNewline }
        $global:GitleaksConfigSeen = $null
        Mock gitleaks {
            $at = [array]::IndexOf($args, '--config')
            if ($at -ge 0 -and (Test-Path -LiteralPath $args[$at + 1])) { $global:GitleaksConfigSeen = Get-Content -LiteralPath $args[$at + 1] -Raw }
            $global:LASTEXITCODE = 0
        }
    }

    AfterAll {
        Remove-Variable -Name GitleaksConfigSeen -Scope Global -ErrorAction SilentlyContinue
        foreach ($name in $script:SavedEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $script:SavedEnv[$name]) }
    }

    It 'pins every shipped rule set to a fixed commit or tag with a SHA-256' {
        $shipped = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'gitleaks-rules.json') -Raw | ConvertFrom-Json).configurations

        foreach ($name in 'GitleaksUdmCombo', 'UDMSecretChecksv8', 'GitleaksOriginal') {
            $shipped.$name.url | Should -Match '^https://'
            $shipped.$name.url | Should -Not -Match 'refs/heads|/(main|master)/'
            $shipped.$name.sha256 | Should -Match '^[0-9a-f]{64}$'
        }
    }

    It 'exits 1, deletes the download and scans nothing when its SHA-256 does not match the pin' {
        Mock Invoke-WebRequest { Set-Content -LiteralPath $OutFile -Value '# changed rules' -NoNewline }

        $r = Invoke-Scan

        $r.Code | Should -Be 1
        $r.Output | Should -Match 'SHA-256'
        @(Get-ChildItem -LiteralPath $r.Work -Filter '*.toml') | Should -HaveCount 0
        Should -Invoke gitleaks -Times 0 -Exactly
    }

    It 'scans the current folder against the default baseline with the downloaded rules' {
        $r = Invoke-Scan

        Should -Invoke gitleaks -Times 1 -Exactly -ParameterFilter {
            $line = $args -join ' '
            $args[0] -eq 'detect' -and $line -match ('--baseline-path ' + [regex]::Escape((Join-Path $r.Work 'gitleaks-baseline.json'))) -and $line -match '--config ' -and ($args -contains '--redact') -and $line -match [regex]::Escape("--source=$($r.Work)")
        }
    }

    It 'extends the downloaded rules with the allowlist of the AI-SDLC, so the hashes of the sync manifest pass' {
        $r = Invoke-Scan

        $global:GitleaksConfigSeen | Should -Match "path = '[^']*gitleaks-rules-[0-9a-f]{32}\.toml'" -Because 'the rules go to the temp folder, not into the repository'
        $global:GitleaksConfigSeen | Should -Not -Match ([regex]::Escape($r.Work.Replace('\', '/')))
        $global:GitleaksConfigSeen | Should -Match 'sync-manifest'
    }

    It 'scans without a baseline, and says how to make one, when the baseline file is missing' {
        $r = Invoke-Scan -NoBaseline

        $r.Code | Should -Be 0
        $r.Output | Should -Match 'Create-GitleaksBaseline\.ps1'
        Should -Invoke gitleaks -Times 1 -Exactly -ParameterFilter { $args[0] -eq 'detect' -and ($args -notcontains '--baseline-path') }
    }

    It 'names the fix when it finds a secret' {
        Mock gitleaks { $global:LASTEXITCODE = 99 }

        $r = Invoke-Scan

        $r.Output | Should -Match '(?m)^FIX: '
    }

    It 'scans only the range in -LogOpts, so a pull request build reads only its own commits' {
        Invoke-Scan -Options @{ LogOpts = 'HEAD^1..HEAD' } | Out-Null

        Should -Invoke gitleaks -Times 1 -Exactly -ParameterFilter { $args -contains '--log-opts=HEAD^1..HEAD' }
    }

    It 'passes no --log-opts without -LogOpts, so the default scan is the whole history' {
        Invoke-Scan | Out-Null

        Should -Invoke gitleaks -Times 1 -Exactly -ParameterFilter { -not ($args -match '^--log-opts') }
    }

    It 'uses the baseline named in -BaselineFileName' {
        Invoke-Scan -Options @{ BaselineFileName = 'custom.json' } | Out-Null

        Should -Invoke gitleaks -Times 1 -Exactly -ParameterFilter { ($args -join ' ') -match '--baseline-path \S*custom\.json' }
    }

    It 'exits 0 when gitleaks finds nothing new' {
        $r = Invoke-Scan

        $r.Code | Should -Be 0
    }

    It 'exits 1 when gitleaks finds a secret that the baseline does not hold' {
        Mock gitleaks { $global:LASTEXITCODE = 99 }

        $r = Invoke-Scan

        $r.Code | Should -Be 1
    }

    It 'exits 1 when gitleaks itself fails' {
        Mock gitleaks { $global:LASTEXITCODE = 3 }

        $r = Invoke-Scan

        $r.Code | Should -Be 1
    }

    It 'removes the downloaded configuration and the allowlist afterwards' {
        $r = Invoke-Scan

        @(Get-ChildItem -LiteralPath $r.Work -Filter '*.toml') | Should -HaveCount 0
        @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'gitleaks-ai-sdlc-*.toml' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-1) -and (Get-Content -LiteralPath $_.FullName -Raw) -match [regex]::Escape($r.Work.Replace('\', '/')) }) | Should -HaveCount 0
    }

    It 'downloads the rule set that <Configuration> names' -ForEach @(
        @{ Configuration = 'GitleaksUdmCombo'; Pattern = 'GitleaksUdmCombo\.toml$' }
        @{ Configuration = 'UDMSecretChecksv8'; Pattern = 'UDMSecretChecksv8\.toml$' }
        @{ Configuration = 'GitleaksOriginal'; Pattern = 'gitleaks/gitleaks/v8\.30\.1/config/gitleaks\.toml$' }
    ) {
        Invoke-Scan -Options @{ gitleaksConfiguration = $Configuration } | Out-Null

        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -match $Pattern }
    }

    It 'exits <Code> and scans nothing when gitleaks is not installed, <Where>' -ForEach @(
        @{ Where = 'in GitHub Actions, so the build fails'; Pipeline = $true; Code = 1 }
        @{ Where = 'in a local run, as a check that could not run'; Pipeline = $false; Code = 2 }
    ) {
        if ($Pipeline) { $env:GITHUB_ACTIONS = 'true' }
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'gitleaks' }

        $r = Invoke-Scan

        $r.Code | Should -Be $Code
        Should -Invoke gitleaks -Times 0 -Exactly
    }

    It 'exits <Code> and scans nothing when the configuration could not be downloaded, <Where>' -ForEach @(
        @{ Where = 'in GitHub Actions, so the build fails'; Pipeline = $true; Code = 1 }
        @{ Where = 'in a local run, as a check that could not run'; Pipeline = $false; Code = 2 }
    ) {
        if ($Pipeline) { $env:GITHUB_ACTIONS = 'true' }
        Mock Invoke-WebRequest { throw 'no network' }

        $r = Invoke-Scan

        $r.Code | Should -Be $Code
        Should -Invoke gitleaks -Times 0 -Exactly
    }

    It 'exits 2 in a local run when a failed download leaves a partial file, and removes that file' {
        $global:PartialRules = $null
        Mock Invoke-WebRequest { Set-Content -LiteralPath $OutFile -Value '# half of the ru' -NoNewline; $global:PartialRules = $OutFile; throw 'connection reset' }

        $r = Invoke-Scan

        $r.Code | Should -Be 2 -Because $r.Output
        $r.Output | Should -Not -Match 'SHA-256'
        Test-Path -LiteralPath $global:PartialRules | Should -BeFalse
        Should -Invoke gitleaks -Times 0 -Exactly
        Remove-Variable -Name PartialRules -Scope Global -ErrorAction SilentlyContinue
    }

    It 'scans the commits of the pull request in GitHub Actions: PR_BASE_SHA..HEAD' {
        $env:GITHUB_ACTIONS = 'true'; $env:PR_BASE_SHA = '0123456789abcdef0123456789abcdef01234567'

        Invoke-Scan | Out-Null

        Should -Invoke gitleaks -Times 1 -Exactly -ParameterFilter { $args -contains '--log-opts=0123456789abcdef0123456789abcdef01234567..HEAD' }
    }

    It 'scans the whole history on a workflow run that is not a pull request, and ignores PR_BASE_SHA outside GitHub Actions' -ForEach @(
        @{ Actions = 'true'; Base = $null }
        @{ Actions = $null; Base = '0123456789abcdef0123456789abcdef01234567' }
    ) {
        $env:GITHUB_ACTIONS = $Actions; $env:PR_BASE_SHA = $Base

        Invoke-Scan | Out-Null

        Should -Invoke gitleaks -Times 1 -Exactly -ParameterFilter { -not ($args -match '^--log-opts') }
    }

    It 'scans origin/main..HEAD of the repository in -RepoRoot in a local run, as the pre-push hook needs' {
        $repo = New-GitRepo
        git -C $repo update-ref refs/remotes/origin/main HEAD
        Set-Content -LiteralPath (Join-Path $repo 'gitleaks-baseline.json') -Value '[]'

        & $script:ScriptUnderTest -RepoRoot $repo -PinFile $script:PinFile *> $null

        $LASTEXITCODE | Should -Be 0
        Should -Invoke gitleaks -Times 1 -Exactly -ParameterFilter {
            ($args -contains '--log-opts=origin/main..HEAD') -and ($args -contains "--source=$((Resolve-Path -LiteralPath $repo).Path)")
        }
    }

    It 'is the blocking C03 gate of the core, so Invoke-LocalGates.ps1 runs it everywhere' {
        $entry = @((Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'gates.json') -Raw | ConvertFrom-Json).gates | Where-Object { $_.script -eq 'scripts/Test-GitleaksBaseline.ps1' })

        $entry | Should -HaveCount 1
        $entry[0].mode | Should -Be 'Blocking'
        $entry[0].clause | Should -Be 'C03'
    }

    It 'runs once in the shared action: as a gate, after the gitleaks install, and not as a step of its own' {
        $action = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'assets' 'actions' 'ai-sdlc-pr' 'action.yml') -Raw
        $code = (($action -split "`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"

        $code | Should -Not -Match 'Test-GitleaksBaseline\.ps1'
        $code | Should -Not -Match 'Invoke-Gate\.ps1' -Because 'the gate step runs every gate through Invoke-LocalGates.ps1'
        $action | Should -Match 'Install-Gitleaks\.ps1'
        $action.IndexOf('Install-Gitleaks.ps1') | Should -BeLessThan $action.IndexOf("'../../../scripts/Invoke-LocalGates.ps1'")
    }
}

Describe 'Test-GitleaksBaseline with the real gitleaks, as a pull request run in GitHub Actions runs it' -Skip:(-not (Get-Command gitleaks -ErrorAction SilentlyContinue)) {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path $PSScriptRoot 'Test-GitleaksBaseline.ps1'
        $script:Pwsh = Join-Path $PSHOME ($IsWindows ? 'pwsh.exe' : 'pwsh')

        function New-PullRequestMerge {
            param([string]$Content)
            $repo = Join-Path $TestDrive ('pr-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $repo -Force | Out-Null
            git -C $repo init --quiet -b main
            git -C $repo config user.email probe@example.invalid
            git -C $repo config user.name probe
            Set-Content -LiteralPath (Join-Path $repo 'readme.txt') -Value 'base'
            Set-Content -LiteralPath (Join-Path $repo 'gitleaks-baseline.json') -Value '[]'
            git -C $repo add -A; git -C $repo commit --quiet -m base
            $base = (git -C $repo rev-parse HEAD).Trim()
            git -C $repo switch --quiet -c feature
            Set-Content -LiteralPath (Join-Path $repo 'deploy.txt') -Value $Content
            git -C $repo add -A; git -C $repo commit --quiet -m 'the change'
            git -C $repo switch --quiet main
            git -C $repo merge --quiet --no-ff -m 'Merge pull request' feature
            return [pscustomobject]@{ Repo = $repo; Base = $base }
        }

        function Invoke-AsPullRequestRun {
            param([object]$Merge)
            $saved = @{ GITHUB_ACTIONS = $env:GITHUB_ACTIONS; PR_BASE_SHA = $env:PR_BASE_SHA }
            try {
                $env:GITHUB_ACTIONS = 'true'; $env:PR_BASE_SHA = $Merge.Base
                $out = & $script:Pwsh -NoProfile -File $script:ScriptUnderTest -RepoRoot $Merge.Repo 2>&1 | Out-String
                [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out }
            }
            finally { foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) } }
        }

        $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
        $script:FakeKey = 'AK' + 'IA' + -join (1..16 | ForEach-Object { $alphabet[(Get-Random -Maximum $alphabet.Length)] })
    }

    It 'fails the run when a commit of the pull request adds a fake access key' {
        $merge = New-PullRequestMerge -Content "aws_access_key_id = $script:FakeKey"
        $r = Invoke-AsPullRequestRun -Merge $merge

        $r.Output | Should -Match ([regex]::Escape("Scanning the commits in $($merge.Base)..HEAD"))
        $r.Output | Should -Match 'Gitleaks found a secret that the baseline does not hold' -Because $r.Output
        $r.Code | Should -Be 1
    }

    It 'passes the same pull request without the key' {
        $merge = New-PullRequestMerge -Content 'nothing secret here'
        $r = Invoke-AsPullRequestRun -Merge $merge

        $r.Output | Should -Match ([regex]::Escape("Scanning the commits in $($merge.Base)..HEAD"))
        $r.Code | Should -Be 0 -Because $r.Output
    }
}
