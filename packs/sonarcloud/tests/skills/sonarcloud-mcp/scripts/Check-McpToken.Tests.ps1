#requires -Version 7.4

Describe 'Check-McpToken' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Check-McpToken.ps1'
        $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
        if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
        Import-Module (Join-Path $aiSdlcGates 'DocToolTestHarness.psm1') -Force
        $script:SavedTokens = @{ AISDLC_SONAR_MCP_TOKEN = $env:AISDLC_SONAR_MCP_TOKEN; SONAR_TOKEN = $env:SONAR_TOKEN }

        function Invoke-Gate {
            param([hashtable]$Extra = @{})
            $out = & $script:ScriptUnderTest -RepoRoot $script:Root @Extra *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }

        function Set-McpFile {
            param([string]$Path = '.mcp.json', [string]$Authorization = 'Bearer ${AISDLC_SONAR_MCP_TOKEN}', [string]$Key = 'mcpServers', [hashtable]$Extra = @{}, [string]$Org = '${AISDLC_SONAR_ORG}')
            $servers = [ordered]@{ sonarqube = [ordered]@{ type = 'http'; url = 'https://api.sonarcloud.io/mcp'; headers = [ordered]@{ Authorization = $Authorization; SONARQUBE_ORG = $Org } } }
            foreach ($name in $Extra.Keys) { $servers[$name] = $Extra[$name] }
            $file = Join-Path $script:Root $Path
            New-Item -ItemType Directory -Path (Split-Path $file) -Force | Out-Null
            Set-Content -LiteralPath $file -Value ([ordered]@{ $Key = $servers } | ConvertTo-Json -Depth 10) -Encoding utf8
            return $file
        }
    }

    AfterAll {
        $env:AISDLC_SONAR_MCP_TOKEN = $script:SavedTokens.AISDLC_SONAR_MCP_TOKEN
        $env:SONAR_TOKEN = $script:SavedTokens.SONAR_TOKEN
    }

    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        git -C $script:Root init -q
        Set-AiSdlcTestConfig -Root $script:Root
        $env:AISDLC_SONAR_MCP_TOKEN = $null
        $env:SONAR_TOKEN = $null
    }

    It 'passes a sonarqube server that sends the placeholder' {
        Set-McpFile | Out-Null

        $r = Invoke-Gate

        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'token OK: 1 MCP file'
    }

    It 'fails a token value in the header and never shows it' {
        Set-McpFile -Authorization 'Bearer squ_0123456789abcdef' | Out-Null

        $r = Invoke-Gate

        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match '\.mcp\.json: the sonarqube server holds a value, not the placeholder'
        $r.Output | Should -Match 'FIX: Run pwsh .claude/skills/sonarcloud-mcp/scripts/Check-McpToken.ps1 -Fix'
        $r.Output | Should -Not -Match 'squ_0123456789abcdef'
    }

    It 'fails another variable name, because the name is shared by everyone in the repository' {
        Set-McpFile -Authorization 'Bearer ${SONARQUBE_TOKEN}' | Out-Null

        $r = Invoke-Gate

        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'uses the variable SONARQUBE_TOKEN, not AISDLC_SONAR_MCP_TOKEN'
    }

    It 'fails SONAR_TOKEN and says why: Claude Code fills it in as an empty value' {
        Set-McpFile -Authorization 'Bearer ${SONAR_TOKEN}' | Out-Null

        $r = Invoke-Gate

        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'uses the variable SONAR_TOKEN, which Claude Code fills in as an empty value in an MCP config\. Use AISDLC_SONAR_MCP_TOKEN'
    }

    It 'writes the new placeholder over SONAR_TOKEN with -Fix' {
        $file = Set-McpFile -Authorization 'Bearer ${SONAR_TOKEN}'

        $r = Invoke-Gate -Extra @{ Fix = $true }

        $r.ExitCode | Should -Be 0
        (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable).mcpServers.sonarqube.headers.Authorization | Should -BeExactly 'Bearer ${AISDLC_SONAR_MCP_TOKEN}'
    }

    It 'fails a written-out organization in SONARQUBE_ORG, like a token value' {
        Set-McpFile -Org 'contoso' | Out-Null

        $r = Invoke-Gate

        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'sends a written-out organization in SONARQUBE_ORG, not \$\{AISDLC_SONAR_ORG\}'
        $r.Output | Should -Not -Match 'contoso'
    }

    It 'writes the organization placeholder back with -Fix' {
        $file = Set-McpFile -Org 'contoso'

        $r = Invoke-Gate -Extra @{ Fix = $true }

        $r.ExitCode | Should -Be 0
        (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable).mcpServers.sonarqube.headers.SONARQUBE_ORG | Should -BeExactly '${AISDLC_SONAR_ORG}'
    }

    It 'fails a sonarqube server with no Authorization header' {
        $file = Join-Path $script:Root '.mcp.json'
        Set-Content -LiteralPath $file -Value '{"mcpServers":{"sonarqube":{"type":"http","url":"https://api.sonarcloud.io/mcp"}}}' -Encoding utf8

        $r = Invoke-Gate

        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'has no Authorization header'
    }

    It 'fails the value of AISDLC_SONAR_MCP_TOKEN in any server, and never shows it' {
        $env:AISDLC_SONAR_MCP_TOKEN = 'squ_secretvalue42'
        Set-McpFile -Extra @{ other = [ordered]@{ type = 'http'; url = 'https://example.org/mcp?key=squ_secretvalue42' } } | Out-Null

        $r = Invoke-Gate

        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match '\.mcp\.json: holds the value of AISDLC_SONAR_MCP_TOKEN'
        $r.Output | Should -Not -Match 'squ_secretvalue42'
    }

    It 'fails the value of SONAR_TOKEN too, because a person often holds the same token there, and never shows it' {
        $env:SONAR_TOKEN = 'squ_scannervalue42'
        Set-McpFile -Extra @{ other = [ordered]@{ type = 'http'; url = 'https://example.org/mcp?key=squ_scannervalue42' } } | Out-Null

        $r = Invoke-Gate

        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match '\.mcp\.json: holds the value of SONAR_TOKEN'
        $r.Output | Should -Not -Match 'squ_scannervalue42'
    }

    It 'checks .github/mcp.json and the servers key of .vscode/mcp.json too' {
        Set-McpFile -Path '.github/mcp.json' | Out-Null
        Set-McpFile -Path '.vscode/mcp.json' -Key 'servers' -Authorization 'Bearer squ_0123456789abcdef' | Out-Null

        $r = Invoke-Gate

        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match '\.vscode/mcp\.json: the sonarqube server holds a value'
        $r.Output | Should -Not -Match '\.github/mcp\.json:'
    }

    It 'skips a file that git ignores, because it never reaches the repository' {
        Set-McpFile -Path '.vscode/mcp.json' -Key 'servers' -Authorization 'Bearer squ_0123456789abcdef' | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Root '.gitignore') -Value '.vscode/' -Encoding utf8

        $r = Invoke-Gate

        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'no MCP file in the repository to check'
    }

    It 'fixes the header and the token value with -Fix, keeps the other servers, and then passes' {
        $env:AISDLC_SONAR_MCP_TOKEN = 'squ_secretvalue42'
        $file = Set-McpFile -Authorization 'Bearer squ_secretvalue42' -Extra @{ other = [ordered]@{ type = 'http'; url = 'https://example.org/mcp' } }

        $r = Invoke-Gate -Extra @{ Fix = $true }

        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Fixed \.mcp\.json'
        $json = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
        $json.mcpServers.sonarqube.headers.Authorization | Should -BeExactly 'Bearer ${AISDLC_SONAR_MCP_TOKEN}'
        $json.mcpServers.sonarqube.headers.SONARQUBE_ORG | Should -BeExactly '${AISDLC_SONAR_ORG}'
        $json.mcpServers.other.url | Should -Be 'https://example.org/mcp'
        Get-Content -LiteralPath $file -Raw | Should -Not -Match 'squ_secretvalue42'
        (Invoke-Gate).ExitCode | Should -Be 0
    }

    It 'passes a repository with no MCP file' {
        $r = Invoke-Gate

        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'no MCP file in the repository to check'
    }

    It 'reports that it could not check a file that is not valid JSON (exit 2)' {
        Set-Content -LiteralPath (Join-Path $script:Root '.mcp.json') -Value '{ not json' -Encoding utf8

        $r = Invoke-Gate

        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match '\.mcp\.json could not be checked: it is not valid JSON'
    }

    It 'reports that it could not check a file it cannot read (exit 2) instead of crashing' {
        New-Item -ItemType Directory -Path (Join-Path $script:Root '.mcp.json') | Out-Null

        $r = Invoke-Gate

        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match '\.mcp\.json could not be checked: it could not be read'
        $r.Output | Should -Not -Match 'not valid JSON'
    }

    It 'reports a sonarqube server that is not a JSON object, with and without -Fix, instead of crashing' -ForEach @(
        @{ Extra = @{} }
        @{ Extra = @{ Fix = $true } }
    ) {
        $file = Join-Path $script:Root '.mcp.json'
        Set-Content -LiteralPath $file -Value '{"mcpServers":{"sonarqube":"disabled"}}' -Encoding utf8

        $r = Invoke-Gate -Extra $Extra

        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'the sonarqube server is not a JSON object'
        $r.Output | Should -Not -Match 'has no Authorization header'
        $r.Output | Should -Match 'FIX: Replace the sonarqube server with a JSON object by hand'
        $r.Output | Should -Not -Match 'FIX: Run pwsh'
        if ($Extra.Fix) {
            $r.Output | Should -Match 'is not a JSON object and could not be fixed'
            (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable).mcpServers.sonarqube | Should -Be 'disabled'
        }
    }

    It 'still replaces a token value with -Fix when the sonarqube server is not a JSON object' {
        $env:AISDLC_SONAR_MCP_TOKEN = 'squ_secretvalue42'
        $file = Join-Path $script:Root '.mcp.json'
        Set-Content -LiteralPath $file -Value '{"mcpServers":{"sonarqube":"disabled","other":{"url":"https://example.org/mcp?key=squ_secretvalue42"}}}' -Encoding utf8

        $r = Invoke-Gate -Extra @{ Fix = $true }

        $r.ExitCode | Should -Be 1
        Get-Content -LiteralPath $file -Raw | Should -Not -Match 'squ_secretvalue42'
    }
}
