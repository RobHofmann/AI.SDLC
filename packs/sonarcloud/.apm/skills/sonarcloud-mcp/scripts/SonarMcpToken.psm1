#Requires -Version 7
<#
.SYNOPSIS
    Where a person's SonarCloud MCP token is set: in this process, stored for the user only, or nowhere.

.DESCRIPTION
    The sonarqube MCP server sends the header `Bearer ${AISDLC_SONAR_MCP_TOKEN}`, so the tool that
    starts the server must see the variable AISDLC_SONAR_MCP_TOKEN. This module answers three questions
    about it, and it never returns or prints the token value. It only asks whether a non-empty value is set.

    The token is stored in one place per system (ADR 0018). On Windows that is the user scope of the
    environment. On macOS and Linux it is a file in the home folder, outside every repository, with mode
    600; a line in the shell profile reads it into the variable.

    The state is one of Process (the process holds the token), Stored (the user store holds it, but this
    process did not read it) or Missing (neither holds it).

    Initialize-SonarCloud.ps1, Set-SonarMcpToken.ps1 and Invoke-SonarTokenHook.ps1 import this module.
#>

$script:Variable = 'AISDLC_SONAR_MCP_TOKEN'
$script:SetCommand = 'pwsh .claude/skills/sonarcloud-mcp/scripts/Set-SonarMcpToken.ps1'
$script:RestartText = 'restart your terminal and Claude Code or VS Code so they read the variable'

function Test-IsWindows {
    <#
    .SYNOPSIS
        True on Windows, where the user scope of the environment holds the token.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    return [bool]$IsWindows
}

function Get-SonarMcpTokenFile {
    <#
    .SYNOPSIS
        The file that holds the token on macOS and Linux: ai-sdlc/sonar-mcp-token in the user config folder.

    .DESCRIPTION
        The config folder is XDG_CONFIG_HOME when it is set, else ~/.config. The file sits outside every
        repository, so no commit can pick it up.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $config = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
    return (Join-Path $config 'ai-sdlc' 'sonar-mcp-token')
}

function Get-SonarMcpProfileLine {
    <#
    .SYNOPSIS
        The shell profile line that reads the token file into AISDLC_SONAR_MCP_TOKEN. It holds no token.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return ('export {0}="$(cat "${{XDG_CONFIG_HOME:-$HOME/.config}}/ai-sdlc/sonar-mcp-token" 2>/dev/null)"' -f $script:Variable)
}

function Test-TokenInProcess {
    <#
    .SYNOPSIS
        True when AISDLC_SONAR_MCP_TOKEN is set to a non-empty value in this process. The value is not returned or shown.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    return -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($script:Variable, 'Process'))
}

function Test-TokenStored {
    <#
    .SYNOPSIS
        True when the user store holds a token: the Windows user scope, or the token file elsewhere. False on any error.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        if (Test-IsWindows) { return -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($script:Variable, 'User')) }
        $file = Get-SonarMcpTokenFile
        return (Test-Path -LiteralPath $file -PathType Leaf) -and ((Get-Item -LiteralPath $file).Length -gt 0)
    }
    catch { return $false }
}

function Get-SonarMcpTokenState {
    <#
    .SYNOPSIS
        Returns Process, Stored or Missing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (Test-TokenInProcess) { return 'Process' }
    if (Test-TokenStored) { return 'Stored' }
    return 'Missing'
}

function Get-SonarMcpTokenAdvice {
    <#
    .SYNOPSIS
        Returns one line that says what to do for a state, or nothing when the state needs no action.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateSet('Process', 'Stored', 'Missing')][string]$State
    )

    $profileStep = if (Test-IsWindows) { '' } else { "Your shell profile needs the line that $script:SetCommand prints. " }
    switch ($State) {
        'Stored' { return "The SonarCloud MCP token is stored for your user, but this session did not read it. $($profileStep)Then $script:RestartText." }
        'Missing' { return "The SonarCloud MCP token is not set. Run $script:SetCommand in your own terminal, then $script:RestartText." }
    }
}

Export-ModuleMember -Function Test-IsWindows, Get-SonarMcpTokenFile, Get-SonarMcpProfileLine, Test-TokenInProcess, Test-TokenStored, Get-SonarMcpTokenState, Get-SonarMcpTokenAdvice
