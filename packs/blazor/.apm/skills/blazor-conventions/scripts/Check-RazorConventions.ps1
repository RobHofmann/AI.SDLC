#Requires -Version 7
<#
.SYNOPSIS
    Enforces the mechanical portal component conventions in the portal-ui page of the blazor-conventions skill.

.DESCRIPTION
    Scans the source root (paths.sourceRoot in aisdlc.json) for the razor and component rules that a
    human reviewer had to teach by hand. No other gate reads a .razor file, so these had no
    enforcement at all.

    Three rules, all blocking, because the codebase has no existing violations of them, so they can
    only ever fire on new drift:

      1. No interface over a state class. A *State class is registered and injected as the concrete
         type, so an I*State interface adds nothing and cannot be kept in step. Tests arrange the
         real state object.
      2. No inline <style> block in a .razor file. Styles belong in the component's *.razor.css or a
         stylesheet under wwwroot, per the OWASP guidance the team follows, so no page depends on
         unsafe-inline in the content security policy.
      3. No <!DOCTYPE in a page component. The app component (dotnet.portalAppComponent in aisdlc.json) is the document root and is the only
         file allowed to declare it. A page that carries its own document is a second way of
         rendering a page alongside the router.

    Attribute placement is a fourth rule from the same convention, but it lives in
    Check-RazorAttributePlacement.ps1 because it carried a backlog and had to stay advisory while that
    was cleared (it blocks now, like this one). Invoke-Gate.ps1
    derives the CI signal from the exit code alone, so one script cannot report one rule as blocking
    and another as advisory: it either fails the step or shows it green. Folding an advisory rule in
    here made its findings print into a green step where nobody saw them, so severities are one per
    gate.

    Exits non-zero when any rule is violated.

.PARAMETER RepoRoot
    Repository root that contains the source root. Defaults to the folder that holds aisdlc.json, found from this script.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot
)

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

$ErrorActionPreference = 'Stop'

# The document root legitimately declares <!DOCTYPE; every other component must not.
$docTypeAllowList = @((Get-AiSdlcConfig -RepoRoot $RepoRoot).dotnet.portalAppComponent | Where-Object { $_ })
$srcRel = ([string](Get-AiSdlcConfig -RepoRoot $RepoRoot).paths.sourceRoot).TrimEnd('/')
if (-not $srcRel) {
    Write-Host 'Could not check: aisdlc.json names no paths.sourceRoot.' -ForegroundColor Yellow
    exit 2
}
$srcDir = Join-Path $RepoRoot $srcRel
$razorFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
$csharpFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
if (Test-Path $srcDir) {
    Get-ChildItem -Path $srcDir -Recurse -Filter *.razor -File | ForEach-Object { $razorFiles.Add($_) }
    Get-ChildItem -Path $srcDir -Recurse -Filter *.cs -File | ForEach-Object { $csharpFiles.Add($_) }
}

function Get-RelativePath {
    param([System.IO.FileInfo]$File)
    return [IO.Path]::GetRelativePath($RepoRoot, $File.FullName).Replace('\', '/')
}

$blocking = [System.Collections.Generic.List[object]]::new()

# Rule 1: no interface over a state class.
foreach ($file in $csharpFiles) {
    $rel = Get-RelativePath -File $file
    $n = 0
    foreach ($line in Get-Content -LiteralPath $file.FullName) {
        $n++
        if ($line -match '\binterface\s+I[A-Za-z0-9_]*State\b') {
            $blocking.Add([pscustomobject]@{
                    Rule = 'no interface over a state class'
                    File = $rel; Line = $n; Text = $line.Trim()
                })
        }
    }
}

# Rules 2 and 3: inline styles and stray document declarations in components.
foreach ($file in $razorFiles) {
    $rel = Get-RelativePath -File $file
    $n = 0
    foreach ($line in Get-Content -LiteralPath $file.FullName) {
        $n++
        if ($line -match '<style[\s>]') {
            $blocking.Add([pscustomobject]@{
                    Rule = 'no inline <style> in a razor component'
                    File = $rel; Line = $n; Text = $line.Trim()
                })
        }
        if ($line -match '<!DOCTYPE' -and $docTypeAllowList -notcontains $rel) {
            $blocking.Add([pscustomobject]@{
                    Rule = 'no <!DOCTYPE in a page component'
                    File = $rel; Line = $n; Text = $line.Trim()
                })
        }
    }
}

function Write-Violations {
    param([object[]]$Items, [string]$Colour)
    foreach ($group in ($Items | Group-Object Rule)) {
        Write-Host ("  {0}:" -f $group.Name) -ForegroundColor $Colour
        foreach ($v in $group.Group) { Write-Host ("    {0}:{1}  {2}" -f $v.File, $v.Line, $v.Text) }
    }
}

$failed = $false

if ($blocking.Count -gt 0) {
    Write-Host "Portal component convention violation (.claude/skills/blazor-conventions/references/portal-ui.md, Component conventions)." -ForegroundColor Red
    Write-Violations -Items $blocking -Colour Red
    Write-Host ("Found {0} violation(s) of the enforced component rules." -f $blocking.Count) -ForegroundColor Red
    $failed = $true
}

if ($failed) {
    Write-Host "FIX: Follow the component rules each finding names: no I*State interface over a state class, no inline style block, and no <!DOCTYPE outside the app component (.claude/skills/blazor-conventions/references/portal-ui.md)."
    exit 1
}

Write-Host "Portal component conventions OK: no violations under $srcRel/."
exit 0
