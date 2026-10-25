#Requires -Version 7
<#
.SYNOPSIS
    Component attributes belong on their own line above the member they decorate.

.DESCRIPTION
    Scans the source root (paths.sourceRoot in aisdlc.json) for a component attribute sharing a line with the member it decorates, for
    example "[Parameter] public RenderFragment ChildContent { get; set; }". The convention is in
    .claude/skills/blazor-conventions/references/portal-ui.md under Component conventions.

    Split out from Check-RazorConventions.ps1 rather than living inside it, because this rule carried
    a backlog while that gate's other rules did not. Invoke-Gate.ps1 derives the CI signal from the
    exit code alone, so a single script cannot report one rule as blocking and another as advisory:
    it either fails the step or shows it green, and a rule folded into the wrong script goes silent.
    One severity per gate is what kept these findings visible while the backlog was being cleared.

    Exits non-zero when any violation is found. It is registered Blocking, so a new shared-line
    attribute fails the build rather than warning.

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

$attributeNames = 'Parameter|CascadingParameter|Inject|SupplyParameterFromQuery|EditorRequired'

$srcRel = ([string](Get-AiSdlcConfig -RepoRoot $RepoRoot).paths.sourceRoot).TrimEnd('/')
if (-not $srcRel) {
    Write-Host 'Could not check: aisdlc.json names no paths.sourceRoot.' -ForegroundColor Yellow
    exit 2
}
$srcDir = Join-Path $RepoRoot $srcRel
$targets = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
if (Test-Path $srcDir) {
    Get-ChildItem -Path $srcDir -Recurse -Include *.razor, *.cs -File | ForEach-Object { $targets.Add($_) }
}

$violations = [System.Collections.Generic.List[object]]::new()
foreach ($file in $targets) {
    $rel = [IO.Path]::GetRelativePath($RepoRoot, $file.FullName).Replace('\', '/')
    $n = 0
    foreach ($line in Get-Content -LiteralPath $file.FullName) {
        $n++
        if ($line -match "\[\s*($attributeNames)\b[^\]]*\]\s*(public|private|protected|internal)\s") {
            $violations.Add([pscustomobject]@{ File = $rel; Line = $n; Text = $line.Trim() })
        }
    }
}

if ($violations.Count -gt 0) {
    Write-Host "Component attribute placement: put the attribute on its own line above the member." -ForegroundColor Yellow
    Write-Host "FIX: Put [Parameter] and [CascadingParameter] on their own line above the member (.claude/skills/blazor-conventions/references/portal-ui.md, Component conventions)." -ForegroundColor Yellow
    foreach ($v in $violations) { Write-Host ("  {0}:{1}  {2}" -f $v.File, $v.Line, $v.Text) }
    Write-Host ("Found {0} attribute(s) sharing a line with the member they decorate." -f $violations.Count) -ForegroundColor Yellow
    exit 1
}

Write-Host "Attribute placement OK: no component attribute shares a line with its member under $srcRel/."
exit 0
