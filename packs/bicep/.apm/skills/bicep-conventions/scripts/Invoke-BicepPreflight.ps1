#Requires -Version 7
<#
.SYNOPSIS
    The pre-flight step of the bicep pack: builds every Bicep template in the repository, so a template
    that does not compile is caught before the push and not in the pull request build.

.DESCRIPTION
    Invoke-Preflight.ps1 runs this script for a repository whose apm.yml lists the bicep pack. It
    finds every .bicep file outside .claude/, .git/ and apm_modules/ and builds it into a temporary
    folder, never to stdout: the Azure CLI crashes on Windows when a compiled template holds a character
    the console encoding cannot print. It returns one pre-flight row: PASS when every template builds,
    FAIL with the templates that do not, and NOT-AVAIL when no Bicep tool is installed.

    It picks the Bicep CLI the way az bicep does by default, so a laptop and a hosted agent build with
    the same version as az would. In a workflow (GITHUB_ACTIONS set) that is the CLI on the PATH. Else it
    is the one az installed under AZURE_CONFIG_DIR/bin (~/.azure/bin), then the one on the PATH. A CLI
    with build --pattern builds all templates of one top-level folder in one process, which takes
    seconds where one process per template took minutes. A template at the root, or a folder that also
    holds a skipped folder, is built one file at a time. A template that fails is named from the Error
    lines of the output. When the folder build fails, every template of that folder without an Error
    line is built again one file at a time, and that result counts, so no template passes by accident.
    Without a Bicep CLI it builds each template with az bicep build.

    A workflow can call it directly. -ShowErrors prints the build errors of each template that fails,
    and is on by default in GitHub Actions (GITHUB_ACTIONS is true), where each failing template also
    gets an error annotation. -FailOnError sets the exit code from the row: 0 for PASS, 1 for FAIL and 2 for
    NOT-AVAIL (could not check). Without it the script keeps the pre-flight contract and only returns
    the row.

.PARAMETER RepoRoot
    The repository root. Defaults to the folder that holds aisdlc.json.

.PARAMETER ChangedFiles
    Accepted for the pre-flight contract; every template is built, because a module change can break a
    template that did not change.

.PARAMETER ShowErrors
    Print the build output of each template that does not build. Defaults to on when GITHUB_ACTIONS is
    true; pass -ShowErrors:$false to keep a workflow log short.

.PARAMETER FailOnError
    Exit 1 when a template does not build, and 2 when no Bicep tool is installed.

.PARAMETER Builder
    Test seam: a scriptblock that takes a template path and returns $true when it builds, or an object
    with Success and Output.

.PARAMETER BicepPath
    Test seam: the Bicep CLI to use instead of the one on the PATH or under ~/.azure/bin.

.EXAMPLE
    pwsh .claude/skills/bicep-conventions/scripts/Invoke-BicepPreflight.ps1

.EXAMPLE
    pwsh .claude/skills/bicep-conventions/scripts/Invoke-BicepPreflight.ps1 -FailOnError
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string[]]$ChangedFiles = @(),
    [switch]$ShowErrors,
    [switch]$FailOnError,
    [scriptblock]$Builder,
    [string]$BicepPath
)

$ErrorActionPreference = 'Stop'
$gates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $gates)) { $gates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $gates 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }
$show = if ($PSBoundParameters.ContainsKey('ShowErrors')) { [bool]$ShowErrors } else { ($env:GITHUB_ACTIONS -eq 'true') }

$check = 'Bicep build (every template)'

function Show-PreflightResult {
    param($Row)

    if (-not $FailOnError) { return $Row }
    Write-Host ("{0}: {1} - {2}" -f $Row.Check, $Row.Status, $Row.Detail)
    $code = switch ($Row.Status) { 'PASS' { 0 } 'NOT-AVAIL' { 2 } default { 1 } }
    exit $code
}

$outFile = Join-Path ([IO.Path]::GetTempPath()) ('bicep-preflight-' + [guid]::NewGuid().ToString('n') + '.json')
$outDir = Join-Path ([IO.Path]::GetTempPath()) ('bicep-preflight-' + [guid]::NewGuid().ToString('n'))
$cli = $null
if (-not $Builder) {
    $azConfig = if ($env:AZURE_CONFIG_DIR) { $env:AZURE_CONFIG_DIR } else { Join-Path $HOME '.azure' }
    $azBicep = Join-Path $azConfig 'bin' $(if ($IsWindows) { 'bicep.exe' } else { 'bicep' })
    $onPath = Get-Command bicep -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $inCi = [bool]$env:GITHUB_ACTIONS
    $cli = if ($BicepPath) { $BicepPath }
           elseif ($inCi -and $onPath) { $onPath.Source }
           elseif (Test-Path -LiteralPath $azBicep) { $azBicep }
           elseif ($onPath) { $onPath.Source }
    if ($cli) {
        $Builder = { param($Path) $out = @(& $cli build $Path --outfile $outFile 2>&1 | ForEach-Object { "$_" }); [pscustomobject]@{ Success = $LASTEXITCODE -eq 0; Output = $out } }
    }
    elseif (Get-Command az -ErrorAction SilentlyContinue) {
        $Builder = { param($Path) $out = @(az bicep build --file $Path --outfile $outFile 2>&1 | ForEach-Object { "$_" }); [pscustomobject]@{ Success = $LASTEXITCODE -eq 0; Output = $out } }
    }
    else {
        Show-PreflightResult ([pscustomobject]@{ Check = $check; Status = 'NOT-AVAIL'; Detail = 'install the Bicep CLI or the Azure CLI (az bicep install)' })
        return
    }
}

$skip = '[\\/](\.claude|\.git|apm_modules|node_modules)[\\/]'
$templates = @(Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -Filter '*.bicep' | Where-Object { $_.FullName -notmatch $skip })
if ($templates.Count -eq 0) {
    Show-PreflightResult ([pscustomobject]@{ Check = $check; Status = 'PASS'; Detail = 'no .bicep file in the repository' })
    return
}

if ($cli -and ((& $cli build --help 2>&1 | Out-String) -match '--pattern')) {
    $results = @{}
    $perFile = $Builder
    $groups = $templates | Group-Object { $rel = [IO.Path]::GetRelativePath($RepoRoot, $_.FullName).Replace('\', '/'); if ($rel.Contains('/')) { $rel.Split('/')[0] } else { '' } }
    foreach ($group in $groups) {
        $inFolder = if ($group.Name) { @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot $group.Name) -Recurse -File -Filter '*.bicep').Count } else { -1 }
        if ($inFolder -ne $group.Count) {
            foreach ($template in $group.Group) { $results[$template.FullName] = & $perFile $template.FullName }
            continue
        }
        Push-Location -LiteralPath $RepoRoot
        try { $out = @(& $cli build --pattern "$($group.Name)/**/*.bicep" --outdir (Join-Path $outDir $group.Name) 2>&1 | ForEach-Object { "$_" }) }
        finally { Pop-Location }
        $code = $LASTEXITCODE
        $errors = @{}
        foreach ($line in $out) {
            if ($line -match '^(?<file>.+?\.bicep)\(\d+,\d+\)\s*:\s*Error\b') {
                $full = [IO.Path]::GetFullPath($Matches.file, $RepoRoot)
                if (-not $errors.ContainsKey($full)) { $errors[$full] = [System.Collections.Generic.List[string]]::new() }
                $errors[$full].Add($line)
            }
        }
        foreach ($template in $group.Group) {
            $results[$template.FullName] = if ($errors.ContainsKey($template.FullName)) { [pscustomobject]@{ Success = $false; Output = @($errors[$template.FullName]) } }
                                           elseif ($code -ne 0) { & $perFile $template.FullName }
                                           else { [pscustomobject]@{ Success = $true; Output = @() } }
        }
    }
    Remove-Item -LiteralPath $outDir -Recurse -Force -ErrorAction SilentlyContinue
    $Builder = { param($Path) $results[$Path] }
}

$failed = [System.Collections.Generic.List[string]]::new()
foreach ($template in $templates) {
    $result = & $Builder $template.FullName
    $built = if ($result -is [bool]) { $result } else { [bool]$result.Success }
    if ($built) { continue }
    $relative = [IO.Path]::GetRelativePath($RepoRoot, $template.FullName).Replace('\', '/')
    $failed.Add($relative)
    if (-not $show) { continue }
    $output = if ($result -is [bool]) { @() } else { @($result.Output | Where-Object { "$_".Trim() }) }
    Write-Host "Bicep build failed: $relative"
    foreach ($line in $output) { Write-Host "  $line" }
    if ($env:GITHUB_ACTIONS -eq 'true') {
        $first = @($output | Where-Object { $_ -match '\bError\b' } | Select-Object -First 1)
        $reason = if ($first) { ($first[0] -replace '\s+', ' ').Trim() } else { 'the build failed; its output is in the log above' }
        Write-Host "::error file=$relative,title=Bicep build::Bicep build failed: $reason"
    }
}

Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue

if ($failed.Count -gt 0) {
    Show-PreflightResult ([pscustomobject]@{ Check = $check; Status = 'FAIL'; Detail = ("{0} of {1} template(s) do not build: {2}" -f $failed.Count, $templates.Count, ($failed -join ', ')) })
    return
}
Show-PreflightResult ([pscustomobject]@{ Check = $check; Status = 'PASS'; Detail = ("{0} template(s) build" -f $templates.Count) })
