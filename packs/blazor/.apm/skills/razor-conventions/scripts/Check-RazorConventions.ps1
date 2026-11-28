#Requires -Version 7
<#
.SYNOPSIS
    Enforces the mechanical component conventions in the razor page of the razor-conventions skill.

.DESCRIPTION
    Scans the source root (paths.sourceRoot in aisdlc.json) for the razor and component rules that a
    human reviewer had to teach by hand. No other gate reads a .razor file, so these had no
    enforcement at all.

    Four rules, all blocking, because the codebase has no existing violations of them, so they can
    only ever fire on new drift:

      1. No interface over a state class. A *State class is registered and injected as the concrete
         type, so an I*State interface adds nothing and cannot be kept in step. Tests arrange the
         real state object.
      2. No inline <style> block in a .razor file. Styles belong in the component's *.razor.css or a
         stylesheet under wwwroot, per the OWASP guidance the team follows, so no page depends on
         unsafe-inline in the content security policy.
      3. No <!DOCTYPE in a page component. The app component (dotnet.appComponent in aisdlc.json) is
         the document root and is the only file allowed to declare it. When the key is empty, the
         document root is any file named App.razor. A page that carries its own document is a second
         way of rendering a page alongside the router.
      4. A component attribute goes on its own line above its member, in every .razor and .cs file.
         One fault must fail one gate, so this rule lives here and not in a gate of its own.

    The old key dotnet.portalAppComponent is not read any more. While aisdlc.json still holds it, the
    gate exits 2 and names the new key, so a stale setting cannot hide a document root.

    Exit codes: 0 clean, 1 when a rule is violated, 2 when aisdlc.json names no paths.sourceRoot or
    still holds the old key dotnet.portalAppComponent, 3 when the source folder does not exist or holds
    no .razor and no .cs file.

.PARAMETER RepoRoot
    Repository root that contains the source root. Defaults to the folder that holds aisdlc.json, found from this script.

.EXAMPLE
    pwsh .claude/skills/razor-conventions/scripts/Check-RazorConventions.ps1
    Checks the components under paths.sourceRoot of the repository that holds this script.
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

# Rule 4 matches an attribute, any further attributes and modifiers, then a member (type and name).
$attributeNames = 'Parameter|CascadingParameter|Inject|SupplyParameterFromQuery|EditorRequired'
$memberModifiers = 'public|private|protected|internal|required|static|virtual|override|sealed|abstract|readonly|new'
$memberAfterAttribute = "\[\s*($attributeNames)\b[^\]]*\]\s*(\[[^\]]*\]\s*)*((?:$memberModifiers)\s+)*[A-Za-z_][\w.]*(<[^>]*>)?[?\[\]]*\s+[A-Za-z_]\w*\s*[{=;(]"

try { $config = Get-AiSdlcConfig -RepoRoot $RepoRoot }
catch {
    Write-Host "Could not check: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host 'FIX: Make aisdlc.json valid, with paths.sourceRoot set to a folder inside the repository, then run this check again.' -ForegroundColor Yellow
    exit 2
}
if ($config.dotnet.Contains('portalAppComponent')) {
    Write-Host 'Could not check: aisdlc.json still has the key dotnet.portalAppComponent, which this gate no longer reads.' -ForegroundColor Yellow
    Write-Host 'FIX: Rename the key dotnet.portalAppComponent to dotnet.appComponent in aisdlc.json, then run this check again.' -ForegroundColor Yellow
    exit 2
}

# The document root legitimately declares <!DOCTYPE; every other component must not.
$docTypeAllowList = @($config.dotnet.appComponent | Where-Object { $_ })
$srcRel = ([string]$config.paths.sourceRoot).TrimEnd('/')
if (-not $srcRel) {
    Write-Host 'Could not check: aisdlc.json names no paths.sourceRoot.' -ForegroundColor Yellow
    Write-Host 'FIX: Set paths.sourceRoot in aisdlc.json to the folder that holds the Razor components, then run this check again.' -ForegroundColor Yellow
    exit 2
}
$srcDir = Join-Path $RepoRoot $srcRel
if (-not (Test-Path -LiteralPath $srcDir -PathType Container)) {
    Write-Host "Not applicable: $srcRel/ does not exist, so there is no component to check."
    exit 3
}
$razorFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
$csharpFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
Get-ChildItem -Path $srcDir -Recurse -Filter *.razor -File | ForEach-Object { $razorFiles.Add($_) }
Get-ChildItem -Path $srcDir -Recurse -Filter *.cs -File | ForEach-Object { $csharpFiles.Add($_) }

if ($razorFiles.Count -eq 0 -and $csharpFiles.Count -eq 0) {
    Write-Host "Not applicable: $srcRel/ holds no .razor and no .cs file, so there is no component to check."
    exit 3
}

function Get-RelativePath {
    param([System.IO.FileInfo]$File)
    return [IO.Path]::GetRelativePath($RepoRoot, $File.FullName).Replace('\', '/')
}

$blocking = [System.Collections.Generic.List[object]]::new()
$attributeRule = 'a component attribute goes on its own line above its member'

# Rules 1 and 4: no interface over a state class, and attributes above their members.
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
        if ($line -match $memberAfterAttribute) {
            $blocking.Add([pscustomobject]@{ Rule = $attributeRule; File = $rel; Line = $n; Text = $line.Trim() })
        }
    }
}

# Rules 2, 3 and 4: inline styles, stray document declarations and attribute placement in components.
foreach ($file in $razorFiles) {
    $rel = Get-RelativePath -File $file
    $isDocumentRoot = if ($docTypeAllowList.Count -gt 0) { $docTypeAllowList -contains $rel } else { $file.Name -eq 'App.razor' }
    $n = 0
    foreach ($line in Get-Content -LiteralPath $file.FullName) {
        $n++
        if ($line -match '<style[\s>]') {
            $blocking.Add([pscustomobject]@{
                    Rule = 'no inline <style> in a razor component'
                    File = $rel; Line = $n; Text = $line.Trim()
                })
        }
        if ($line -match '<!DOCTYPE' -and -not $isDocumentRoot) {
            $blocking.Add([pscustomobject]@{
                    Rule = 'no <!DOCTYPE in a page component'
                    File = $rel; Line = $n; Text = $line.Trim()
                })
        }
        if ($line -match $memberAfterAttribute) {
            $blocking.Add([pscustomobject]@{ Rule = $attributeRule; File = $rel; Line = $n; Text = $line.Trim() })
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

if ($blocking.Count -gt 0) {
    Write-Host 'Component convention violation (.claude/skills/razor-conventions/references/razor.md, Component conventions).' -ForegroundColor Red
    Write-Violations -Items $blocking -Colour Red
    Write-Host ("Found {0} violation(s) of the enforced component rules." -f $blocking.Count) -ForegroundColor Red
    Write-Host 'FIX: Follow the component rule each finding names: no I*State interface over a state class, no inline style block, no <!DOCTYPE outside the app component, and each component attribute on its own line above its member (.claude/skills/razor-conventions/references/razor.md).'
    exit 1
}

Write-Host ("Component conventions OK: {0} .razor and {1} .cs file(s) under {2}/ hold no I*State interface, inline style, stray <!DOCTYPE or attribute that shares a line with its member." -f $razorFiles.Count, $csharpFiles.Count, $srcRel)
exit 0
