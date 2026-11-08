#Requires -Version 7
<#
.SYNOPSIS
    Writes the gitleaks configuration that the AI-SDLC secret scans use: a rule set plus the allowlist of
    the files the AI-SDLC itself ships that only look like secrets.

.DESCRIPTION
    sync-manifest.json in the ai-sdlc-gates skill lists the git blob hash of every shipped file. Next to a
    file name such as accessible.md or api.md, a 40-character hash matches the generic-api-key rule of
    gitleaks. The hashes change with every release, so a baseline cannot hold them, and every update pull
    request of a consumer would fail its secret scan. The allowlist here skips that one file, in the
    shared pull request job (Test-GitleaksBaseline.ps1) and in the pre-flight (Invoke-Preflight.ps1).

    A repository can name more paths in secretScan.allowPaths of aisdlc.json: files that hold secrets
    on purpose, because the application needs them there. With -RepoRoot, New-GitleaksConfig adds
    them as a second allowlist. Without the field, the config is the same as without -RepoRoot.

    New-GitleaksConfig writes a small TOML file that extends a rule set and adds the allowlist. With
    -RulesPath it extends that file, for example a pinned rule set from gitleaks-rules.json. Without it,
    it extends the default rules that gitleaks carries.

    The CI scan (Test-GitleaksBaseline.ps1) and the pre-flight (Invoke-Preflight.ps1) scan with the same
    pinned rule set. Get-GitleaksRulesPin reads its URL and SHA-256 from gitleaks-rules.json, and
    Test-GitleaksRulesFile checks a downloaded file against that SHA-256. GitleaksUdmCombo is the
    default rule set of both.

.EXAMPLE
    Import-Module .claude/skills/ai-sdlc-gates/scripts/GitleaksConfig.psm1
    New-GitleaksConfig -Path $tmp -RulesPath ./gitleaks.toml

.EXAMPLE
    $pin = Get-GitleaksRulesPin
    Invoke-WebRequest -Uri $pin.Url -OutFile $file
    Test-GitleaksRulesFile -Path $file -Pin $pin
#>

Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1')

# Each entry is a regular expression on the path of a file, relative to the scanned folder.
$script:AllowedPaths = @(
    '(^|/)skills/ai-sdlc-gates/sync-manifest\.json$'
)

$script:DefaultRules = 'GitleaksUdmCombo'

function Get-GitleaksRulesPin {
    [CmdletBinding()]
    param(
        [string]$Configuration = $script:DefaultRules,
        [string]$PinFile = (Join-Path $PSScriptRoot 'gitleaks-rules.json')
    )

    $pin = (Get-Content -LiteralPath $PinFile -Raw | ConvertFrom-Json).configurations.$Configuration
    if (-not $pin -or -not $pin.url -or -not $pin.sha256) { return $null }
    return [pscustomobject]@{ Name = $Configuration; Url = [string]$pin.url; Sha256 = ([string]$pin.sha256).ToLowerInvariant() }
}

function Test-GitleaksRulesFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Pin
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -eq $Pin.Sha256
}

function Get-GitleaksAllowedPath {
    [CmdletBinding()]
    param()

    return $script:AllowedPaths
}

function Get-GitleaksRepoAllowedPath {
    # The paths a repository names in secretScan.allowPaths of aisdlc.json: files that hold secrets on
    # purpose, such as the secrets file of an application. A scan never reads them.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $config = Get-AiSdlcConfig -RepoRoot $RepoRoot
    $patterns = @($config.secretScan.allowPaths | Where-Object { $_ })
    # Which paths to skip is the choice of the repository. The check only stops a pattern that would
    # break the TOML file or that gitleaks cannot read: a quote, a control character, or a bad regex.
    foreach ($pattern in $patterns) {
        $reason = if ($pattern -isnot [string]) { 'is not a string' }
        elseif ($pattern -match "['`"\p{Cc}]") { 'holds a quote or a control character' }
        else {
            try { $null = [regex]::new($pattern) }
            catch { 'is not a valid regular expression' }
        }
        if ($reason) { throw "secretScan.allowPaths in aisdlc.json: the pattern '$pattern' $reason. Nothing was scanned." }
    }
    return $patterns
}

function New-GitleaksConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$RulesPath,
        [string]$RepoRoot
    )

    $extend = if ($RulesPath) {
        # A TOML literal string takes the path as it is; forward slashes keep it one form on every OS.
        "path = '$(([IO.Path]::GetFullPath($RulesPath)).Replace('\', '/'))'"
    }
    else { 'useDefault = true' }
    $paths = ($script:AllowedPaths | ForEach-Object { "  '''$_'''" }) -join ",`n"
    $toml = @(
        '# Written by GitleaksConfig.psm1 of the AI-SDLC for one scan, then deleted.'
        '[extend]'
        $extend
        ''
        '[[allowlists]]'
        'description = "Files the AI-SDLC ships that only look like secrets, such as the git blob hashes in sync-manifest.json."'
        'paths = ['
        $paths
        ']'
        ''
    )
    $repoPaths = if ($RepoRoot) { @(Get-GitleaksRepoAllowedPath -RepoRoot $RepoRoot) } else { @() }
    if ($repoPaths.Count -gt 0) {
        Write-Host "The secret scan skips the paths in secretScan.allowPaths of aisdlc.json: $($repoPaths -join ', ')"
        $toml += @(
            '[[allowlists]]'
            'description = "Paths the repository holds secrets in on purpose: secretScan.allowPaths in aisdlc.json."'
            'paths = ['
            (($repoPaths | ForEach-Object { "  '''$_'''" }) -join ",`n")
            ']'
            ''
        )
    }
    $toml = $toml -join "`n"
    [IO.File]::WriteAllText($Path, $toml, [Text.UTF8Encoding]::new($false))
    return $Path
}

Export-ModuleMember -Function Get-GitleaksAllowedPath, Get-GitleaksRepoAllowedPath, New-GitleaksConfig, Get-GitleaksRulesPin, Test-GitleaksRulesFile
