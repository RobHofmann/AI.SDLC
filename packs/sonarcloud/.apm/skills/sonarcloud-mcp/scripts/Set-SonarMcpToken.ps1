#Requires -Version 7
<#
.SYNOPSIS
    Store your SonarCloud token once, so the sonarqube MCP server can sign in.

.DESCRIPTION
    Run this in your own terminal, not in an agent shell. It asks for the token without echo, checks it
    against SonarCloud (GET https://sonarcloud.io/api/users/current) and only then stores it. It never
    writes the token to a repository file, a log or the output (ADR 0018).

    - On Windows it stores the token in your user variable AISDLC_SONAR_MCP_TOKEN.
    - On macOS and Linux it writes the file ai-sdlc/sonar-mcp-token in your config folder
      (XDG_CONFIG_HOME, else ~/.config), with mode 600 in a folder with mode 700. It then prints the one
      line your shell profile needs to read that file into AISDLC_SONAR_MCP_TOKEN. The line holds no token.
      On macOS, an app that is not started from a terminal does not read the shell profile, so start Claude Code or
      VS Code from a terminal.

    The script takes no parameters, so a token never stands on a command line or in a shell history. It
    stops with exit 1 before any prompt when input is redirected (an agent shell, a pipe), because a
    prompt would hang there.

    When a token is already stored, it asks before it replaces it. Your terminal and your tool read the
    variable when they start, so restart your terminal and Claude Code or VS Code after it stores one.

    Exit 0 when a token is stored or kept. Exit 1 when input is redirected, the token is empty, or
    SonarCloud does not accept it. Nothing is stored in those cases.

.EXAMPLE
    pwsh .claude/skills/sonarcloud-mcp/scripts/Set-SonarMcpToken.ps1
#>
[CmdletBinding()]
param()

Import-Module (Join-Path $PSScriptRoot 'SonarMcpToken.psm1') -Force

$script:Variable = 'AISDLC_SONAR_MCP_TOKEN'

function Test-InputRedirected {
    return [Console]::IsInputRedirected
}

function Read-TokenInput {
    return Read-Host -Prompt 'SonarCloud token (input is hidden)' -AsSecureString
}

function Read-ReplaceAnswer {
    return Read-Host -Prompt 'A token is already stored. Replace it? (y/N)'
}

function Invoke-SonarCurrentUser {
    param([Parameter(Mandatory)][securestring]$Token)

    try {
        $body = Invoke-RestMethod -Uri 'https://sonarcloud.io/api/users/current' -Authentication Bearer -Token $Token -SkipHttpErrorCheck -TimeoutSec 15 -StatusCodeVariable 'status' -ErrorAction Stop
        $loggedIn = $status -eq 200 -and $null -ne $body -and $null -ne $body.PSObject.Properties['isLoggedIn'] -and $body.isLoggedIn -eq $true
        return [pscustomobject]@{ StatusCode = [int]$status; IsLoggedIn = [bool]$loggedIn }
    }
    catch {
        return [pscustomobject]@{ StatusCode = 0; IsLoggedIn = $false }
    }
}

function Write-TokenFile {
    # The file is created with mode 600 and its folder with mode 700 before any byte of the token is
    # written, so no other user can read it at any moment. An existing file gets mode 600 first.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Value)

    $folder = Split-Path -Parent $Path
    $onUnix = -not [OperatingSystem]::IsWindows()
    if (-not (Test-Path -LiteralPath $folder)) {
        if ($onUnix) { [IO.Directory]::CreateDirectory($folder, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute') | Out-Null }
        else { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    }
    $options = [IO.FileStreamOptions]::new()
    $options.Mode = [IO.FileMode]::Create
    $options.Access = [IO.FileAccess]::Write
    if ($onUnix) {
        $options.UnixCreateMode = [IO.UnixFileMode]'UserRead, UserWrite'
        if (Test-Path -LiteralPath $Path) { [IO.File]::SetUnixFileMode($Path, [IO.UnixFileMode]'UserRead, UserWrite') }
    }
    $stream = [IO.FileStream]::new($Path, $options)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
        $stream.Write($bytes, 0, $bytes.Length)
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
    finally { $stream.Dispose() }
}

function Set-StoredToken {
    param([Parameter(Mandatory)][securestring]$Token)

    $pointer = [IntPtr]::Zero
    $plain = $null
    try {
        $pointer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Token)
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        if (Test-IsWindows) { [Environment]::SetEnvironmentVariable($script:Variable, $plain, 'User') }
        else { Write-TokenFile -Path (Get-SonarMcpTokenFile) -Value $plain }
    }
    finally {
        $plain = $null
        if ($pointer -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    }
}

function Invoke-SetSonarMcpToken {
    if (Test-InputRedirected) {
        Write-Host 'This script asks for a secret, and input is redirected here, so it would hang. Please run this in your own terminal: pwsh .claude/skills/sonarcloud-mcp/scripts/Set-SonarMcpToken.ps1'
        return 1
    }
    if (Test-TokenStored) {
        $answer = Read-ReplaceAnswer
        if ($answer -notmatch '^\s*(y|yes)\s*$') {
            Write-Host 'The stored token is kept. Nothing changed.'
            return 0
        }
    }

    $token = Read-TokenInput
    if ($null -eq $token -or $token.Length -eq 0) {
        Write-Host 'No token was entered. Nothing stored.'
        return 1
    }

    $check = Invoke-SonarCurrentUser -Token $token
    if ($check.StatusCode -eq 0) {
        Write-Host 'Could not reach SonarCloud; nothing stored.'
        return 1
    }
    if (-not ($check.StatusCode -eq 200 -and $check.IsLoggedIn)) {
        Write-Host "SonarCloud did not accept the token: HTTP $($check.StatusCode); nothing stored."
        return 1
    }

    Set-StoredToken -Token $token
    if (Test-IsWindows) {
        Write-Host "The token is stored in your user variable $script:Variable. Now restart your terminal and Claude Code or VS Code so they read the variable."
        return 0
    }
    Write-Host "The token is stored in $(Get-SonarMcpTokenFile), which only you can read."
    Write-Host 'Add this line to your shell profile (~/.zshrc or ~/.bashrc), if it is not there yet:'
    Write-Host "  $(Get-SonarMcpProfileLine)"
    Write-Host 'Then restart your terminal, and start Claude Code or VS Code from it so they read the variable.'
    return 0
}

if ($MyInvocation.InvocationName -eq '.') { return }

exit (Invoke-SetSonarMcpToken)
