#Requires -Version 7
<#
.SYNOPSIS
    Reads the payload of an agent hook the same way for Claude Code and GitHub Copilot CLI, and writes
    hook context in a shape both tools take.

.DESCRIPTION
    The hook scripts of ai-sdlc-hooks get one JSON payload on stdin. Its shape depends on the tool:

      - Claude Code sends `tool_input` as an object, such as { "file_path": "docs/a.md" }.
      - Copilot CLI sends `tool_input` (PascalCase events) or `toolArgs` (camelCase events). Its edit and
        create tools use the field `path`. The arguments are sometimes a JSON string, not an object.
      - A GPT model in Copilot CLI edits through `apply_patch`. Copilot reports that call as `Edit`, and
        `tool_input` is then the patch text itself, with one `*** Update File: <path>` line per file.

    Get-HookEditedFile returns every file one payload touches, from any of those shapes, so a guard
    cannot miss a file because the model chose another edit tool.

    New-HookContextOutput writes additionalContext twice in one object: at the top level, which Copilot
    CLI reads for UserPromptSubmit and PostToolUse, and inside hookSpecificOutput, which Claude Code
    reads. Copilot drops the nested form for those two events, and Claude ignores the top-level field.

    Every function returns nothing rather than throwing on input it cannot read, because a hook script
    must fail open (ai-sdlc-hooks skill).
#>

$script:PathFields = @('file_path', 'filePath', 'path', 'notebook_path')
$script:PatchFileLine = '(?m)^\*\*\*[ \t]+(?:Update File|Add File|Delete File|Move to):[ \t]*(?<path>.+?)[ \t]*\r?$'

function ConvertFrom-HookJson {
    param([string]$Json)

    if ([string]::IsNullOrWhiteSpace($Json)) { return $null }
    try { return $Json | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
}

function Get-PatchFilePath {
    <#
    .SYNOPSIS
        Returns every file path an apply_patch text names, in the order it names them.
    #>
    [CmdletBinding()]
    param([string]$Patch)

    if ([string]::IsNullOrWhiteSpace($Patch) -or $Patch -notmatch '\*\*\*[ \t]+Begin Patch') { return @() }
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches($Patch, $script:PatchFileLine)) {
        $path = $match.Groups['path'].Value.Trim('"', "'")
        if ($path -and -not $paths.Contains($path)) { $paths.Add($path) }
    }
    return @($paths)
}

function Get-HookToolArgument {
    <#
    .SYNOPSIS
        Returns the tool arguments of a hook payload: an object, a patch text, or nothing.
    #>
    [CmdletBinding()]
    param([object]$Hook)

    if (-not $Hook) { return $null }
    foreach ($name in 'tool_input', 'toolArgs', 'tool_args') {
        $property = $Hook.PSObject.Properties[$name]
        if (-not $property -or $null -eq $property.Value) { continue }
        $value = $property.Value
        if ($value -is [string]) {
            if ($value -match '^\s*\*\*\*[ \t]+Begin Patch') { return $value }
            $parsed = ConvertFrom-HookJson -Json $value
            if ($null -ne $parsed) { return $parsed }
            continue
        }
        return $value
    }
    return $null
}

function Get-HookEditedFile {
    <#
    .SYNOPSIS
        Returns every file path the tool call of a hook payload edits or writes, or an empty array.
    #>
    [CmdletBinding()]
    param([string]$Json)

    $arguments = Get-HookToolArgument -Hook (ConvertFrom-HookJson -Json $Json)
    if ($null -eq $arguments) { return @() }
    if ($arguments -is [string]) { return @(Get-PatchFilePath -Patch $arguments) }

    foreach ($field in $script:PathFields) {
        $property = $arguments.PSObject.Properties[$field]
        if ($property -and $property.Value -is [string] -and $property.Value) { return @([string]$property.Value) }
    }
    foreach ($field in 'input', 'patch') {
        $property = $arguments.PSObject.Properties[$field]
        if ($property -and $property.Value -is [string]) {
            $paths = @(Get-PatchFilePath -Patch $property.Value)
            if ($paths.Count -gt 0) { return $paths }
        }
    }
    return @()
}

function New-HookContextOutput {
    <#
    .SYNOPSIS
        Returns the compact JSON that hands a text to the agent as additionalContext, in both tool shapes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EventName,
        [Parameter(Mandatory)][string]$Text
    )

    return ([ordered]@{
            additionalContext  = $Text
            hookSpecificOutput = [ordered]@{
                hookEventName     = $EventName
                additionalContext = $Text
            }
        } | ConvertTo-Json -Depth 5 -Compress)
}

Export-ModuleMember -Function Get-PatchFilePath, Get-HookToolArgument, Get-HookEditedFile, New-HookContextOutput
