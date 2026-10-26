#Requires -Version 7
<#
.SYNOPSIS
    Defines Enable-WindowsLongPath: switches Windows long paths on when they are off, with one
    administrator prompt, and returns a problem line when they are still off afterwards.

.DESCRIPTION
    APM stages files in deep folders, so apm install fails with WinError 206 or WinError 3 while
    Windows long paths are off. Install-AiSdlc.ps1 and Update-AiSdlc.ps1 both dot-source this file, so
    the rule lives in one place. The function does nothing off Windows, never asks in a pipeline
    (GITHUB_ACTIONS or CI set), leaves the setting alone with -Skip, and honours -WhatIf.

.EXAMPLE
    . (Join-Path $PSScriptRoot 'WindowsLongPaths.ps1')
    $problem = Enable-WindowsLongPath
#>

function Enable-WindowsLongPath {
    [CmdletBinding(SupportsShouldProcess)]
    param([switch]$Skip)

    if (-not $IsWindows) { return $null }
    $fileSystemKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
    $longPaths = (Get-ItemProperty -Path $fileSystemKey -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled
    $inPipeline = $env:GITHUB_ACTIONS -or $env:CI
    if ($longPaths -ne 1 -and -not $Skip -and -not $inPipeline -and $PSCmdlet.ShouldProcess('Windows long paths', 'switch on (needs administrator approval)')) {
        $setCommand = "Set-ItemProperty -Path '$fileSystemKey' -Name LongPathsEnabled -Value 1 -Type DWord"
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        Write-Host 'Switching Windows long paths on, because apm install needs them; approve the administrator prompt.'
        try {
            if ($isAdmin) { Set-ItemProperty -Path $fileSystemKey -Name LongPathsEnabled -Value 1 -Type DWord }
            else { Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-Command', $setCommand) -Verb RunAs -Wait }
        }
        catch { Write-Host "The switch did not run: $($_.Exception.Message)" -ForegroundColor Yellow }
        $longPaths = (Get-ItemProperty -Path $fileSystemKey -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled
        if ($longPaths -eq 1) { Write-Host 'Windows long paths are on now. If apm install still fails on a long path, open a new terminal and run this again.' }
    }
    if ($longPaths -ne 1) {
        return 'Windows long paths are off, so apm install in this repository fails with WinError 206 or WinError 3. Run this script again and approve the administrator prompt, or set LongPathsEnabled to 1 under HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem as administrator.'
    }
    return $null
}
