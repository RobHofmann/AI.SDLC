#Requires -Version 7
<#
.SYNOPSIS
    Installs the pinned APM release for this machine, and refuses it when its SHA-256 does not match.

.DESCRIPTION
    A workflow needs APM to run apm audit --ci and apm install --frozen, and a clone needs it to install
    the shared AI-SDLC. Piping an install script from the internet into a shell runs code nobody checked,
    and an unpinned package manager install takes whatever version is newest. So this script downloads
    one release asset of the pinned version over HTTPS, compares its SHA-256 with the digest pinned in
    apm-version.json next to it, and only then unpacks it.

    The asset follows the machine: linux-x86_64, linux-arm64, darwin-x86_64, darwin-arm64 or
    windows-x86_64. The script puts APM on the PATH of the current process. In GitHub Actions it also
    puts APM on the PATH of the later steps, through $GITHUB_PATH. With -AddToPath it keeps APM on the PATH for later
    terminals: on Windows in the user PATH, elsewhere as a link in $HOME/.local/bin.

    To take a new APM version, change the version and the digest of every asset in apm-version.json. The
    digests are on the release page of the APM repository. The top-level "sha256" is the linux-x86_64
    digest, kept for older copies of this script.

.PARAMETER Prefix
    Where APM is unpacked. Defaults to $HOME/.local/apm.

.PARAMETER Platform
    The release asset to take, for example linux-x86_64 or windows-x86_64. Defaults to this machine.

.PARAMETER AddToPath
    Keep APM on the PATH for later terminals, not only for this process.

.PARAMETER SourceFile
    Test seam: a local archive to use instead of the download.

.PARAMETER PinFile
    The pin file. Defaults to apm-version.json next to this script.

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Install-Apm.ps1

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Install-Apm.ps1 -AddToPath
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Prefix = (Join-Path $HOME '.local' 'apm'),
    [string]$Platform,
    [switch]$AddToPath,
    [string]$SourceFile,
    [string]$PinFile = (Join-Path $PSScriptRoot 'apm-version.json')
)

$ErrorActionPreference = 'Stop'

function Get-ApmPlatform {
    $arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
        'X64' { 'x86_64' }
        'Arm64' { 'arm64' }
        default { [string]$_ }
    }
    $os = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'darwin' } else { 'linux' }
    return "$os-$arch"
}

if (-not $Platform) { $Platform = Get-ApmPlatform }
$pin = Get-Content -LiteralPath $PinFile -Raw | ConvertFrom-Json
$expected = $null
if ($pin.PSObject.Properties['assets'] -and $pin.assets.PSObject.Properties[$Platform]) { $expected = [string]$pin.assets.$Platform }
elseif ($Platform -eq 'linux-x86_64' -and $pin.PSObject.Properties['sha256']) { $expected = [string]$pin.sha256 }
if (-not $expected) {
    throw "apm-version.json pins no APM $($pin.version) asset for $Platform, so nothing was installed. Add its digest from the APM release page, or install APM $($pin.version) by hand."
}

$isZip = $Platform -like 'windows-*'
$asset = if ($isZip) { "apm-$Platform.zip" } else { "apm-$Platform.tar.gz" }
$exeName = if ($isZip) { 'apm.exe' } else { 'apm' }
$bin = Join-Path $Prefix "apm-$Platform"

if (-not $PSCmdlet.ShouldProcess($bin, "install APM $($pin.version) ($asset)")) { return }

$archive = Join-Path ([IO.Path]::GetTempPath()) ("apm-" + [guid]::NewGuid().ToString('n') + $(if ($isZip) { '.zip' } else { '.tar.gz' }))
try {
    if ($SourceFile) {
        Copy-Item -LiteralPath $SourceFile -Destination $archive
    }
    else {
        $uri = "https://github.com/microsoft/apm/releases/download/$($pin.version)/$asset"
        Invoke-WebRequest -Uri $uri -OutFile $archive -UseBasicParsing
    }

    $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected.ToLowerInvariant()) {
        throw "APM $($pin.version) did not match its pinned SHA-256 for ${Platform}: expected $expected, got $actual. Nothing was installed."
    }

    New-Item -ItemType Directory -Path $Prefix -Force | Out-Null
    if (Test-Path -LiteralPath $bin) { Remove-Item -LiteralPath $bin -Recurse -Force }
    if ($isZip) {
        Expand-Archive -LiteralPath $archive -DestinationPath $Prefix -Force
    }
    else {
        $local = Join-Path $Prefix $asset
        Move-Item -LiteralPath $archive -Destination $local -Force
        $archive = $local
        Push-Location $Prefix
        try { tar -xzf $asset }
        finally { Pop-Location }
        if ($LASTEXITCODE -ne 0) { throw "Unpacking $asset failed with exit code $LASTEXITCODE." }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $bin $exeName) -PathType Leaf)) {
        throw "The APM $($pin.version) archive for $Platform holds no apm-$Platform/$exeName, so APM is not installed."
    }
}
finally {
    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
}

$separator = [IO.Path]::PathSeparator
if (@($env:PATH -split [regex]::Escape($separator)) -notcontains $bin) { $env:PATH = "$bin$separator$env:PATH" }
if ($env:GITHUB_PATH) { Add-Content -LiteralPath $env:GITHUB_PATH -Value $bin -Encoding utf8 }

if ($AddToPath) {
    if ($IsWindows) {
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $parts = @($userPath -split ';' | Where-Object { $_ })
        if ($parts -notcontains $bin) { [Environment]::SetEnvironmentVariable('Path', (@($bin) + $parts) -join ';', 'User') }
        Write-Output "Added $bin to the user PATH; a new terminal finds apm there."
    }
    else {
        $linkFolder = Join-Path $HOME '.local' 'bin'
        New-Item -ItemType Directory -Path $linkFolder -Force | Out-Null
        $link = Join-Path $linkFolder 'apm'
        if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force }
        New-Item -ItemType SymbolicLink -Path $link -Target (Join-Path $bin $exeName) | Out-Null
        Write-Output "Linked $link to APM. Put $linkFolder on the PATH if a new terminal does not find apm."
    }
}

Write-Output "APM $($pin.version) installed in $bin (SHA-256 checked)."
