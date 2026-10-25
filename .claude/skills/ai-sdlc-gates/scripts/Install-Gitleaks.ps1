#Requires -Version 7
<#
.SYNOPSIS
    Installs the pinned gitleaks release for this machine, and refuses it when its SHA-256 does not match.

.DESCRIPTION
    The shared pull request action (assets/actions/ai-sdlc-pr) scans the repository for secrets with
    gitleaks, and a hosted runner has no gitleaks. An unpinned install takes whatever version is newest. So this script
    downloads one release asset of the pinned version over HTTPS, compares its SHA-256 with the digest
    pinned in gitleaks-version.json next to it, and only then unpacks it. It works like Install-Apm.ps1.

    The asset follows the machine: linux-x86_64, linux-arm64, darwin-x86_64, darwin-arm64 or
    windows-x86_64. The script puts gitleaks on the PATH of the current process. In GitHub Actions it
    also puts gitleaks on the PATH of the later steps, through $GITHUB_PATH.

    To take a new gitleaks version, change the version and the digest of every asset in
    gitleaks-version.json. The digests are in the checksums file of the gitleaks release
    (gitleaks_<version>_checksums.txt). Move the GitleaksOriginal rules in gitleaks-rules.json to the
    same tag, so the rules and the binary match.

.PARAMETER Prefix
    Where gitleaks is unpacked. Defaults to $HOME/.local/gitleaks.

.PARAMETER Platform
    The release asset to take, for example linux-x86_64 or windows-x86_64. Defaults to this machine.

.PARAMETER SourceFile
    Test seam: a local archive to use instead of the download.

.PARAMETER PinFile
    The pin file. Defaults to gitleaks-version.json next to this script.

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Install-Gitleaks.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Prefix = (Join-Path $HOME '.local' 'gitleaks'),
    [string]$Platform,
    [string]$SourceFile,
    [string]$PinFile = (Join-Path $PSScriptRoot 'gitleaks-version.json')
)

$ErrorActionPreference = 'Stop'

function Get-GitleaksPlatform {
    $arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
        'X64' { 'x86_64' }
        'Arm64' { 'arm64' }
        default { [string]$_ }
    }
    $os = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'darwin' } else { 'linux' }
    return "$os-$arch"
}

if (-not $Platform) { $Platform = Get-GitleaksPlatform }
$pin = Get-Content -LiteralPath $PinFile -Raw | ConvertFrom-Json
$expected = $null
if ($pin.PSObject.Properties['assets'] -and $pin.assets.PSObject.Properties[$Platform]) { $expected = [string]$pin.assets.$Platform }
if (-not $expected) {
    throw "gitleaks-version.json pins no gitleaks $($pin.version) asset for $Platform, so nothing was installed. Add its digest from the checksums file of the release, or install gitleaks $($pin.version) by hand."
}

# The release names its assets gitleaks_<version without v>_<os>_<arch>, with x64 for x86_64.
$os, $arch = $Platform -split '-', 2
$isZip = $os -eq 'windows'
$asset = 'gitleaks_{0}_{1}_{2}.{3}' -f $pin.version.TrimStart('v'), $os, ($arch -replace '^x86_64$', 'x64'), $(if ($isZip) { 'zip' } else { 'tar.gz' })
$exeName = if ($isZip) { 'gitleaks.exe' } else { 'gitleaks' }
$bin = Join-Path $Prefix "gitleaks-$($pin.version)-$Platform"

if (-not $PSCmdlet.ShouldProcess($bin, "install gitleaks $($pin.version) ($asset)")) { return }

$archive = Join-Path ([IO.Path]::GetTempPath()) ("gitleaks-" + [guid]::NewGuid().ToString('n') + $(if ($isZip) { '.zip' } else { '.tar.gz' }))
try {
    if ($SourceFile) {
        Copy-Item -LiteralPath $SourceFile -Destination $archive
    }
    else {
        $uri = "https://github.com/gitleaks/gitleaks/releases/download/$($pin.version)/$asset"
        Invoke-WebRequest -Uri $uri -OutFile $archive -UseBasicParsing
    }

    $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected.ToLowerInvariant()) {
        throw "gitleaks $($pin.version) did not match its pinned SHA-256 for ${Platform}: expected $expected, got $actual. Nothing was installed."
    }

    if (Test-Path -LiteralPath $bin) { Remove-Item -LiteralPath $bin -Recurse -Force }
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    if ($isZip) {
        Expand-Archive -LiteralPath $archive -DestinationPath $bin -Force
    }
    else {
        # tar gets a name relative to the folder: GNU tar reads C:\ in a full Windows path as a remote host.
        $local = Join-Path $bin $asset
        Move-Item -LiteralPath $archive -Destination $local -Force
        $archive = $local
        Push-Location $bin
        try { tar -xzf $asset }
        finally { Pop-Location }
        if ($LASTEXITCODE -ne 0) { throw "Unpacking $asset failed with exit code $LASTEXITCODE." }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $bin $exeName) -PathType Leaf)) {
        throw "The gitleaks $($pin.version) archive for $Platform holds no $exeName, so gitleaks is not installed."
    }
}
finally {
    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
}

$separator = [IO.Path]::PathSeparator
if (@($env:PATH -split [regex]::Escape($separator)) -notcontains $bin) { $env:PATH = "$bin$separator$env:PATH" }
if ($env:GITHUB_PATH) { Add-Content -LiteralPath $env:GITHUB_PATH -Value $bin -Encoding utf8 }

Write-Output "gitleaks $($pin.version) installed in $bin (SHA-256 checked)."
