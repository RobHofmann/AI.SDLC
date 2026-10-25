<#
.SYNOPSIS
    Create a gitleaks baseline file for the current repository.
.DESCRIPTION
    This script creates a gitleaks baseline file for the current repository with a pinned gitleaks rule set.

    It clones a fresh copy of the repository (remote.origin.url) into a temporary folder and scans that
    clone, so the baseline holds the history on the remote and nothing that exists only in this working
    copy. A gitleaks fingerprint names the commit, the file, the rule and the line, not the folder, so a
    baseline made from the clone matches a later scan of the working copy.

    The rule set is downloaded from a fixed commit or release tag, never from a branch head. The URL and
    the SHA-256 of each rule set are pinned in gitleaks-rules.json next to this script. A download whose
    SHA-256 does not match the pin is deleted, and the script exits 1 without a scan. To take newer
    rules, change the URL and the digest in gitleaks-rules.json together.
.NOTES
    This script requires Git and Gitleaks to be installed and available in the system PATH.
.LINK
    https://gitleaks.io/
    https://github.com/gitleaks/gitleaks
    https://github.com/JoostVoskuil/azure-devops-gitleaks

.PARAMETER BaselineFileName
    Name of the baseline file to create in the current folder. Default: gitleaks-baseline.json.

.PARAMETER gitleaksConfiguration
    The pinned rule set to use:
    - 'GitleaksUdmCombo' (default): the Microsoft Security DevOps rules and the original gitleaks rules
    - 'UDMSecretChecksv8': only the Microsoft Security DevOps rules (CSCAN*)
    - 'GitleaksOriginal': only the original gitleaks rules, at the release tag in gitleaks-rules.json

.PARAMETER tempDrive
    The folder that holds the temporary clone. Defaults to the temp folder of the system
    ([IO.Path]::GetTempPath()).

.PARAMETER tempDirectoryName
    The name of the temporary clone folder under tempDrive. Default: gitleaksbaseline.

.PARAMETER PinFile
    The file with the pinned URL and SHA-256 of each rule set. Defaults to gitleaks-rules.json next to
    this script.

.EXAMPLE
    .claude\skills\ai-sdlc-gates\scripts\Create-GitleaksBaseline.ps1
    Uses the pinned rule set that combines the Microsoft Security DevOps rules and the original gitleaks rules.
.EXAMPLE
    .claude\skills\ai-sdlc-gates\scripts\Create-GitleaksBaseline.ps1 -gitleaksConfiguration 'UDMSecretChecksv8'
    Uses the pinned rule set that holds only the Microsoft Security DevOps rules (CSCAN*).
.EXAMPLE
    .claude\skills\ai-sdlc-gates\scripts\Create-GitleaksBaseline.ps1 -gitleaksConfiguration 'GitleaksOriginal'
    Uses the original gitleaks rules at the pinned release tag.
#>
[CmdletBinding()]
param (
    [Parameter()]
    [string]
    $BaselineFileName = 'gitleaks-baseline.json',

    [ValidateSet("GitleaksUdmCombo", "UDMSecretChecksv8", "GitleaksOriginal")]
    [Parameter()]
    [string]
    $gitleaksConfiguration = 'GitleaksUdmCombo',

    [Parameter()]
    [string]
    $tempDrive = [IO.Path]::GetTempPath(),

    [Parameter()]
    [string]
    $tempDirectoryName = 'gitleaksbaseline',

    [Parameter()]
    [string]
    $PinFile = (Join-Path $PSScriptRoot 'gitleaks-rules.json')
)

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "Git is not installed or not available in the system PATH. Please install Git and try again."
    exit 1
}

if (-not (Get-Command gitleaks -ErrorAction SilentlyContinue)) {
    Write-Host "Gitleaks is not installed or not available in the system PATH. Please install Gitleaks and try again."
    exit 1
}

$pin = (Get-Content -LiteralPath $PinFile -Raw | ConvertFrom-Json).configurations.$gitleaksConfiguration
if (-not $pin -or -not $pin.url -or -not $pin.sha256) {
    Write-Host "No pinned URL and SHA-256 for $gitleaksConfiguration in $PinFile, so no rules were downloaded."
    exit 1
}

$remoteUrl = git config --get remote.origin.url
if (-not $remoteUrl) {
    Write-Host "This repository has no remote.origin.url, so there is nothing to clone and scan."
    exit 1
}
Write-Host "Remote URL: $remoteUrl"

$currentDirectory = (Get-Location).Path
$gitleaksBaselinePath = Join-Path $currentDirectory $BaselineFileName
$gitleakconfigurationFile = Join-Path $currentDirectory 'gitleaks.toml'

Write-Host "Current directory: $currentDirectory"
Write-Host "Downloading the $gitleaksConfiguration rules from $($pin.url)"
Invoke-WebRequest -Uri $pin.url -Method Get -OutFile $gitleakconfigurationFile

if (-not (Test-Path -LiteralPath $gitleakconfigurationFile)) {
    Write-Host "Failed to download the gitleaks rules from $($pin.url)"
    exit 1
}
$actual = (Get-FileHash -LiteralPath $gitleakconfigurationFile -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $pin.sha256.ToLowerInvariant()) {
    Remove-Item -LiteralPath $gitleakconfigurationFile -Force
    Write-Host "The downloaded $gitleaksConfiguration rules have SHA-256 $actual, but $PinFile pins $($pin.sha256). The file was deleted and nothing was scanned."
    exit 1
}

if (-not (Test-Path -LiteralPath $tempDrive)) {
    New-Item -Path $tempDrive -ItemType Directory | Out-Null
}
$tempDirectory = Join-Path $tempDrive $tempDirectoryName
if (Test-Path -LiteralPath $tempDirectory) {
    Remove-Item -LiteralPath $tempDirectory -Recurse -Force
}

$failed = $false
try {
    Write-Host "Clone a fresh copy of the repository to $tempDirectory"
    git clone --quiet $remoteUrl $tempDirectory
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tempDirectory)) { throw "git clone of $remoteUrl failed with exit code $LASTEXITCODE" }

    Write-Host "Running gitleaks on the clone to create baseline file: $gitleaksBaselinePath"
    gitleaks git $tempDirectory --config "$gitleakconfigurationFile" --report-format=json --redact --report-path "$gitleaksBaselinePath" --exit-code=99
    $scanExit = $LASTEXITCODE
    if ($scanExit -ne 0 -and $scanExit -ne 99) { throw "gitleaks failed with exit code $scanExit, so no baseline was written" }
}
catch {
    Write-Host "An error occurred: $_"
    $failed = $true
}
finally {
    Write-Host "Remove temp directory and config file"
    if (Test-Path -LiteralPath $tempDirectory) {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ProgressAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $gitleakconfigurationFile) {
        Remove-Item -LiteralPath $gitleakconfigurationFile -Force -ProgressAction SilentlyContinue
    }
}
if ($failed) { exit 1 }

Write-Host "Sort gitleaks baseline file on Fingerprint"
$baseline = Get-Content -LiteralPath $gitleaksBaselinePath | ConvertFrom-Json
ConvertTo-Json -InputObject @($baseline | Sort-Object -Property Fingerprint) -Depth 5 | Out-File -LiteralPath $gitleaksBaselinePath -Force

Write-Host "Gitleaks baseline file created at: $gitleaksBaselinePath"
