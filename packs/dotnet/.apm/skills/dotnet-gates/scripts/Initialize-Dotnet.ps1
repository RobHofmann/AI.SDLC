#Requires -Version 7
<#
.SYNOPSIS
    The dotnet setup step of Initialize-AiSdlc.ps1: check the .NET SDK, install dotnet-coverage and
    restore the solution.

.DESCRIPTION
    Initialize-AiSdlc.ps1 in the ai-sdlc-hooks skill runs this script, because dotnet-gates/gates.json
    names it as the dotnet setup. It returns rows with Step, Status and Detail for the one summary table.

    It checks that a .NET SDK is installed. When global.json at the repository root names an SDK
    version, an installed SDK must match it the way the rollForward of global.json asks. Without
    rollForward, that is the same feature band, such as 10.0.1xx, at or above the asked version. The
    rollForward value is read without regard to capitals, as dotnet reads it. dotnet ignores a
    global.json whose version is not a full SDK version, or whose rollForward value it does not know,
    and then uses the newest SDK; the check does the same and says so. A preview SDK with the same
    number but another label is a WARN. It reports whether Azure
    Functions Core Tools are on PATH, and runs dotnet restore of the solution in paths.solution of
    aisdlc.json. -Minimal and -SkipRestore
    leave the restore out. It never installs the SDK: that is a machine-wide choice for the developer.

    The pre-flight merges the coverage files with the dotnet-coverage global tool, and fails its C04 row
    without it. So when dotnet-coverage is not on PATH, this script installs it with dotnet tool install
    --global dotnet-coverage and reports that in its row. -Minimal leaves the install out.

.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script.

.PARAMETER Minimal
    Check the SDK only; no dotnet-coverage install and no restore.

.PARAMETER SkipRestore
    Do not run dotnet restore.

.PARAMETER Plan
    Return the step this run would take, as text, and do nothing else.

.EXAMPLE
    pwsh .claude/skills/dotnet-gates/scripts/Initialize-Dotnet.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$RepoRoot,
    [switch]$Minimal,
    [switch]$SkipRestore,
    [switch]$Plan
)

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

$doRestore = -not ($Minimal -or $SkipRestore)
$needsCoverageTool = -not $Minimal -and -not (Get-Command dotnet-coverage -ErrorAction SilentlyContinue)
if ($Plan) {
    if ($needsCoverageTool) { 'dotnet tool install --global dotnet-coverage' }
    if ($doRestore) { 'dotnet restore' }
    return
}

function New-Row([string]$Step, [string]$Status, [string]$Detail) {
    [pscustomobject]@{ Step = $Step; Status = $Status; Detail = $Detail }
}

$hasDotnet = [bool](Get-Command dotnet -ErrorAction SilentlyContinue)
if ($hasDotnet) {
    $sdks = @(dotnet --list-sdks 2>$null)
    $globalJson = Join-Path $RepoRoot 'global.json'
    $wanted = $null
    $rollForward = ''
    $allowPrerelease = $true
    if (Test-Path -LiteralPath $globalJson -PathType Leaf) {
        try {
            $sdkJson = (Get-Content -LiteralPath $globalJson -Raw | ConvertFrom-Json).sdk
            $wanted = [string]$sdkJson.version
            $rollForward = [string]$sdkJson.rollForward
            if ($sdkJson.allowPrerelease -eq $false) { $allowPrerelease = $false }
        }
        catch { $wanted = $null }
    }
    # The scope of each rollForward value, from the global.json page of the .NET docs. Every value
    # rolls forward only, so an SDK below the asked version never counts. No rollForward means patch.
    # The non-latest values pick another SDK than their latest form, but they accept the same set.
    # dotnet reads the names without regard to capitals: LATESTMAJOR rolls forward like latestMajor.
    $scopes = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($pair in @(
            @('', 'band'), @('patch', 'band'), @('latestPatch', 'band'),
            @('feature', 'minor'), @('latestFeature', 'minor'),
            @('minor', 'major'), @('latestMinor', 'major'),
            @('major', 'any'), @('latestMajor', 'any'),
            @('disable', 'exact'))) { $scopes[$pair[0]] = $pair[1] }
    $versionPattern = '^(\d+)\.(\d+)\.(\d+)(-\S+)?'
    # dotnet ignores a global.json with a short version or an unknown rollForward value, and uses the
    # newest SDK. Checked with dotnet 10: rollForward "bogus" and version "8.0" both ran the newest SDK.
    $ignoredWhy = if ($wanted -and $wanted -notmatch "$versionPattern$") { "its version '$wanted' is not a full SDK version such as 10.0.100" }
    elseif ($wanted -and -not $scopes.ContainsKey($rollForward)) { "it does not know rollForward '$rollForward'" }
    if ($ignoredWhy) {
        $newest = @($sdks | ForEach-Object { ([string]$_ -split '\s+')[0] } | Where-Object { $_ -match $versionPattern } |
            Sort-Object -Property { [version]($_ -replace '-.*$', '') }, { -not ($_ -match '-') } | Select-Object -Last 1)
        if ($newest.Count -gt 0) { New-Row '.NET SDK' 'PASS' "dotnet ignores global.json, because $ignoredWhy; it uses the newest SDK, $($newest[0])" }
        else { New-Row '.NET SDK' 'WARN' "dotnet ignores global.json, because $ignoredWhy, and it lists no SDK to use instead" }
    }
    elseif ($wanted) {
        $scope = $scopes[$rollForward]
        $null = $wanted -match $versionPattern
        $w = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
        $wPre = [string]$Matches[4]
        $match = @($sdks | Where-Object {
                $sdkVersion = ([string]$_ -split '\s+')[0]
                if ($sdkVersion -notmatch $versionPattern) { return $false }
                $s = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
                $sPre = [string]$Matches[4]
                if ($scope -eq 'exact') { return $sdkVersion -eq $wanted }
                if ($sPre -and -not $allowPrerelease) { return $false }
                # Same scope: band is x.y.z with the same hundreds digit of z, minor is x.y, major is x.
                $inScope = switch ($scope) {
                    'band'  { $s[0] -eq $w[0] -and $s[1] -eq $w[1] -and [math]::Floor($s[2] / 100) -eq [math]::Floor($w[2] / 100) }
                    'minor' { $s[0] -eq $w[0] -and $s[1] -eq $w[1] }
                    'major' { $s[0] -eq $w[0] }
                    default { $true }
                }
                if (-not $inScope) { return $false }
                $order = [version]::new($s[0], $s[1], $s[2]).CompareTo([version]::new($w[0], $w[1], $w[2]))
                if ($order -ne 0) { return $order -gt 0 }
                # Same number: a release is above its own previews. Two previews must match exactly,
                # because this check does not order preview labels.
                if (-not $sPre) { return $true }
                return $sdkVersion -eq $wanted
            })
        if ($match.Count -gt 0) { New-Row '.NET SDK' 'PASS' "global.json asks for $wanted; a matching SDK is installed" }
        else { New-Row '.NET SDK' 'WARN' "global.json asks for $wanted; no installed SDK matches it under the rollForward of global.json. Installed: $($sdks -join '; ')" }
    }
    elseif ($sdks.Count -gt 0) { New-Row '.NET SDK' 'PASS' "$($sdks.Count) SDK(s) installed; no global.json names a version" }
    else { New-Row '.NET SDK' 'WARN' 'dotnet is on PATH, but it lists no SDK' }
}
else {
    New-Row '.NET SDK' 'FAIL' 'dotnet not on PATH; install the .NET SDK the projects target'
}

if (Get-Command func -ErrorAction SilentlyContinue) {
    New-Row 'Azure Functions Core Tools' 'PASS' 'an Azure Functions project can run locally'
}
else {
    New-Row 'Azure Functions Core Tools' 'OPTIONAL' 'needed only to run an Azure Functions project locally'
}

# The pre-flight needs dotnet-coverage to merge the coverage files for the C04 ratchet.
if (-not $Minimal) {
    $coverageStep = 'dotnet-coverage'
    if (-not $needsCoverageTool) {
        New-Row $coverageStep 'PASS' 'on PATH; the pre-flight merges the coverage with it for the C04 ratchet'
    }
    elseif (-not $hasDotnet) {
        New-Row $coverageStep 'SKIP' 'dotnet not on PATH, so dotnet-coverage cannot be installed'
    }
    elseif ($PSCmdlet.ShouldProcess('dotnet-coverage', 'dotnet tool install --global')) {
        Write-Host "dotnet tool install --global dotnet-coverage..." -ForegroundColor Cyan
        & dotnet tool install --global dotnet-coverage | Out-Host
        if ($LASTEXITCODE -eq 0) { New-Row $coverageStep 'SET' 'installed as a global .NET tool for the C04 ratchet of the pre-flight; open a new terminal when it is not on PATH yet' }
        else { New-Row $coverageStep 'WARN' "the install exited $LASTEXITCODE; run dotnet tool install --global dotnet-coverage by hand, or the pre-flight fails its C04 row" }
    }
    else {
        New-Row $coverageStep 'WHATIF' 'would run dotnet tool install --global dotnet-coverage'
    }
}

if ($doRestore) {
    Write-Host "dotnet restore..." -ForegroundColor Cyan
    $solutionRel = (Get-AiSdlcConfig -RepoRoot $RepoRoot).paths.solution
    $sln = if ($solutionRel) { Join-Path $RepoRoot $solutionRel } else { $null }
    if (-not $sln) {
        New-Row 'dotnet restore' 'SKIP' 'aisdlc.json names no paths.solution'
    }
    elseif (-not $hasDotnet) {
        New-Row 'dotnet restore' 'SKIP' 'dotnet not on PATH'
    }
    elseif ($PSCmdlet.ShouldProcess($sln, 'dotnet restore')) {
        & dotnet restore $sln | Out-Host
        if ($LASTEXITCODE -eq 0) { New-Row 'dotnet restore' 'PASS' 'packages restored' }
        else { New-Row 'dotnet restore' 'FAIL' "dotnet restore exited $LASTEXITCODE; check the package feed access" }
    }
    else {
        New-Row 'dotnet restore' 'WHATIF' "would restore $solutionRel"
    }
}
