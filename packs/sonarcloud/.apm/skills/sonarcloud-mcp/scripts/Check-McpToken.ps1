#Requires -Version 7
<#
.SYNOPSIS
    Gate: the SonarQube MCP server sends `Bearer ${AISDLC_SONAR_MCP_TOKEN}`, never a token value, and
    `${AISDLC_SONAR_ORG}`, never a written-out organization.

.DESCRIPTION
    The sonarcloud pack ships the `sonarqube` MCP server with the header
    `Authorization: Bearer ${AISDLC_SONAR_MCP_TOKEN}`. Each person sets AISDLC_SONAR_MCP_TOKEN on their
    own machine, and the tool fills it in when it starts the server. But apm install fills it in too:
    when the variable is set in the shell that runs the install, APM writes the real token into
    .mcp.json. A commit after an update then puts that token in the repository.

    This gate reads the MCP files a tool loads from the repository: .mcp.json, .github/mcp.json and
    .vscode/mcp.json. A file that git ignores is skipped, because it never reaches the repository. In
    each file, the `sonarqube` server must send exactly `Bearer ${AISDLC_SONAR_MCP_TOKEN}`. Another
    variable name fails too, because the name is shared: one rename makes every person in the repository
    change theirs. SONAR_TOKEN gets its own reason: Claude Code holds it on a list of secret variable
    names, and fills it in as an empty value in an MCP config.
    The `SONARQUBE_ORG` header, when the server has one, must be exactly `${AISDLC_SONAR_ORG}`. A
    written-out organization fails the same way, because apm install writes the value of
    AISDLC_SONAR_ORG into .mcp.json too, and the organization name does not belong in a shared file.
    When AISDLC_SONAR_MCP_TOKEN or SONAR_TOKEN is set, the gate also fails on its value anywhere in
    those files. The SonarCloud scanner reads SONAR_TOKEN, and a person often holds the same token in both.

    The output never shows a token value. Exit 0 when every file is clean, 1 on a finding, 2 when a
    file could not be read, or could not be parsed as JSON, so nothing could be checked.

.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script.

.PARAMETER Fix
    Write `Bearer ${AISDLC_SONAR_MCP_TOKEN}` and `${AISDLC_SONAR_ORG}` back into each finding, and the
    placeholder of each variable in place of its value. Your token stays in the environment variable; the tools read it from there.

.EXAMPLE
    pwsh .claude/skills/sonarcloud-mcp/scripts/Check-McpToken.ps1 -Fix
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [switch]$Fix
)

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

$ErrorActionPreference = 'Stop'

$variable = 'AISDLC_SONAR_MCP_TOKEN'
$placeholder = 'Bearer ${AISDLC_SONAR_MCP_TOKEN}'
$orgHeader = 'SONARQUBE_ORG'
$orgPlaceholder = '${AISDLC_SONAR_ORG}'
# The variables whose value must never stand in an MCP file.
$tokenVariables = @($variable, 'SONAR_TOKEN')
$serverName = 'sonarqube'
$mcpFiles = @('.mcp.json', '.github/mcp.json', '.vscode/mcp.json')
# A token shorter than this is no real token, and would match by chance.
$minTokenLength = 8

function Test-GitIgnored {
    param([string]$Root, [string]$RelativePath)
    & git -C $Root check-ignore -q -- $RelativePath 2>$null
    return $LASTEXITCODE -eq 0
}

function Get-ServerTable {
    # Claude Code and the Copilot CLI use mcpServers; VS Code uses servers.
    param([hashtable]$Json)
    foreach ($key in 'mcpServers', 'servers') {
        if ($Json[$key] -is [hashtable]) { return $Json[$key] }
    }
    return $null
}

function Get-AuthorizationKey {
    param([hashtable]$Headers)
    return @($Headers.Keys | Where-Object { $_ -ieq 'Authorization' })[0]
}

function Get-HeaderProblem {
    param($Server)
    if ($Server -isnot [hashtable]) { return 'is not a JSON object' }
    $headers = $Server['headers']
    $key = if ($headers -is [hashtable]) { Get-AuthorizationKey $headers } else { $null }
    if (-not $key) { return 'has no Authorization header' }
    $value = [string]$headers[$key]
    if ($value -ceq $placeholder) { return $null }
    if ($value -ceq 'Bearer ${SONAR_TOKEN}') { return "uses the variable SONAR_TOKEN, which Claude Code fills in as an empty value in an MCP config. Use $variable" }
    if ($value -match '^Bearer \$\{(\w+)\}$') { return "uses the variable $($matches[1]), not $variable" }
    return 'holds a value, not the placeholder'
}

function Get-OrgKey {
    param([hashtable]$Headers)
    return @($Headers.Keys | Where-Object { $_ -ieq $orgHeader })[0]
}

function Get-OrgProblem {
    param($Server)
    if ($Server -isnot [hashtable] -or $Server['headers'] -isnot [hashtable]) { return $null }
    $key = Get-OrgKey $Server['headers']
    if (-not $key) { return $null }
    if ([string]$Server['headers'][$key] -ceq $orgPlaceholder) { return $null }
    return "sends a written-out organization in $orgHeader, not $orgPlaceholder"
}

$tokens = [ordered]@{}
foreach ($name in $tokenVariables) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ($value -and $value.Length -ge $minTokenLength) { $tokens[$name] = $value }
}
$findings = [System.Collections.Generic.List[string]]::new()
$unreadable = [System.Collections.Generic.List[string]]::new()
$checked = 0

foreach ($relative in $mcpFiles) {
    $path = Join-Path $RepoRoot $relative
    if (-not (Test-Path -LiteralPath $path)) { continue }
    if (Test-GitIgnored -Root $RepoRoot -RelativePath $relative) { continue }

    try { $text = Get-Content -LiteralPath $path -Raw -Encoding utf8 }
    catch { $unreadable.Add("${relative} could not be checked: it could not be read."); continue }
    try { $json = $text | ConvertFrom-Json -AsHashtable }
    catch { $unreadable.Add("${relative} could not be checked: it is not valid JSON."); continue }
    $checked++

    $fileFindings = [System.Collections.Generic.List[string]]::new()
    $servers = if ($json -is [hashtable]) { Get-ServerTable $json } else { $null }
    if ($servers -and $servers.ContainsKey($serverName)) {
        $problem = Get-HeaderProblem $servers[$serverName]
        if ($problem) { $fileFindings.Add("${relative}: the $serverName server $problem.") }
        $orgProblem = Get-OrgProblem $servers[$serverName]
        if ($orgProblem) { $fileFindings.Add("${relative}: the $serverName server $orgProblem.") }
    }
    $leakedNames = @($tokens.Keys | Where-Object { $text.Contains($tokens[$_]) })
    foreach ($name in $leakedNames) { $fileFindings.Add("${relative}: holds the value of $name.") }
    if ($fileFindings.Count -eq 0) { continue }

    if (-not $Fix) { $findings.AddRange($fileFindings); continue }

    if ($leakedNames.Count -gt 0) {
        foreach ($name in $leakedNames) { $text = $text.Replace($tokens[$name], "`${$name}") }
        $json = $text | ConvertFrom-Json -AsHashtable
    }
    $servers = Get-ServerTable $json
    $serverFixed = $false
    if ($servers -and $servers.ContainsKey($serverName)) {
        $server = $servers[$serverName]
        if ($server -is [hashtable]) {
            if (-not ($server['headers'] -is [hashtable])) { $server['headers'] = [ordered]@{} }
            $key = Get-AuthorizationKey $server['headers']
            $server['headers'][$(if ($key) { $key } else { 'Authorization' })] = $placeholder
            $orgKey = Get-OrgKey $server['headers']
            if ($orgKey) { $server['headers'][$orgKey] = $orgPlaceholder }
            $serverFixed = $true
        }
        else { $findings.Add("${relative}: the $serverName server is not a JSON object and could not be fixed.") }
    }
    if (-not $serverFixed -and $leakedNames.Count -eq 0) { continue }
    $out = ($json | ConvertTo-Json -Depth 32) -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($path, "$out`n", [System.Text.UTF8Encoding]::new($false))
    if ($serverFixed) { Write-Host "Fixed ${relative}: the $serverName server sends $placeholder and $orgPlaceholder again." }
    else { Write-Host "Fixed ${relative}: the token value is replaced by its placeholder." }
}

foreach ($reason in $unreadable) {
    Write-Output "::warning::$reason"
}

if ($findings.Count -gt 0) {
    foreach ($finding in $findings) { Write-Host $finding -ForegroundColor Red }
    $manual = @($findings | Where-Object { $_ -match 'is not a JSON object' }).Count
    if ($findings.Count -gt $manual) {
        Write-Host "FIX: Run pwsh .claude/skills/sonarcloud-mcp/scripts/Check-McpToken.ps1 -Fix. It writes $placeholder and $orgPlaceholder back. Your token stays in the variable $variable and your organization in AISDLC_SONAR_ORG, where the tools read them." -ForegroundColor Red
    }
    if ($manual -gt 0) {
        Write-Host "FIX: Replace the $serverName server with a JSON object by hand. -Fix cannot change it." -ForegroundColor Red
    }
    Write-Host 'If a token was committed or pushed, revoke it in SonarCloud (My Account, Security) and make a new one.' -ForegroundColor Red
    exit 1
}
if ($unreadable.Count -gt 0) { exit 2 }

if ($checked -eq 0) { Write-Host 'SonarCloud MCP token OK: no MCP file in the repository to check.' }
else { Write-Host "SonarCloud MCP token OK: $checked MCP file(s) send $placeholder or no $serverName server." }
exit 0
