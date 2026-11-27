<#
.SYNOPSIS
    Runs gitleaks using an existing baseline file to report only new findings.

.DESCRIPTION
    This script runs gitleaks using a baseline file that represents a known state of secrets
    in your repository. The baseline file is useful for:
    - Suppressing known/accepted findings in existing code
    - Focusing on new secrets introduced in future commits
    - Integrating gitleaks into CI/CD pipelines without breaking builds for historical issues
    
    The script downloads a specified gitleaks configuration (TOML format), runs gitleaks against the 
    current repository, and uses the baseline JSON file you specify to suppress known findings.

    It is the C03 gate in gates.json, so Invoke-LocalGates.ps1 runs it: in the shared pull request
    action (assets/actions/ai-sdlc-pr, after Install-Gitleaks.ps1 installs the pinned gitleaks), in the
    pre-push hook and in a local run. The pre-flight scans with the same pinned rule set, so a local
    scan and the CI scan agree. The scan extends the downloaded rules with the allowlist in
    GitleaksConfig.psm1, so the git blob hashes in sync-manifest.json do not read as keys. The rules
    are downloaded to the temp folder, never into the repository. A finding that the baseline does not
    hold exits 1 and prints a FIX line.

    In a local run, when files are staged and -LogOpts is not passed, a second scan reads the staged
    files (gitleaks git --staged), with the same rules, baseline and --redact. A secret that is staged
    but not committed is in no commit, so the commit scan misses it. A pipeline has no staged files, so
    it skips this scan. A finding in either scan exits 1, and the output names which one found it.

    In GitHub Actions (GITHUB_ACTIONS is true), a missing git or gitleaks, or a failed download, exits
    1, so the build fails and never passes without a scan. In a local run they exit 2 (could not
    check), so a machine without gitleaks can still push. A -RepoRoot that is not an existing folder
    follows the same rule. A download whose SHA-256 does not match the pin exits 1 everywhere.

.PARAMETER BaselineFileName
    Specifies the name of the baseline file to use in the current directory.
    When the file does not exist, gitleaks scans without a baseline, so every finding counts.
    Default: 'gitleaks-baseline.json'

.PARAMETER gitleaksConfiguration
    Specifies which predefined gitleaks configuration to use:
    - 'GitleaksUdmCombo' (Default): Combines Microsoft Security DevOps rules with original gitleaks rules
    - 'UDMSecretChecksv8': Uses only Microsoft Security DevOps rules (CSCAN* rules)
    - 'GitleaksOriginal': Uses only the original gitleaks rules, at the release tag in gitleaks-rules.json

    Every rule set comes from a fixed commit or release tag, never from a branch head. The URL and the
    SHA-256 of each one are pinned in gitleaks-rules.json next to this script. A download whose SHA-256
    does not match the pin is deleted, and the script exits 1 without a scan.

.PARAMETER PinFile
    The file with the pinned URL and SHA-256 of each rule set. Defaults to gitleaks-rules.json next to
    this script.

.PARAMETER LogOpts
    The git log range that gitleaks scans, passed as --log-opts. Without it the script picks the range.
    On a pull request in GitHub Actions (PR_BASE_SHA set by the shared action) it is <base sha>..HEAD,
    the commits the pull request adds, as the pre-flight scans <target>..HEAD. On any other workflow
    run it is the history of every branch and tag. In a local run it is <trunk>..HEAD, where the trunk is
    the first of origin/main, origin/master and origin/HEAD that exists, or the whole history when none
    does. An empty value scans the whole history. Passing -LogOpts, also an empty value, turns off the
    scan of the staged files.

.PARAMETER RepoRoot
    The repository to scan, where the baseline file is. Defaults to the current folder.
    Invoke-LocalGates.ps1 passes it.

.NOTES
    Prerequisites:
    - Git must be installed and available in the system PATH
    - Gitleaks must be installed and available in the system PATH
    
    Installation:
    - Git: https://git-scm.com/downloads
    - Gitleaks: https://github.com/gitleaks/gitleaks#installing
    
    The script will:
    1. Validate Git and Gitleaks are available
    2. Download the specified configuration file
    3. Run gitleaks against the repository using the baseline file
    4. Report only new findings not present in the baseline
    5. Clean up temporary configuration files

.LINK
    https://gitleaks.io/

.LINK
    https://github.com/gitleaks/gitleaks

.LINK
    https://github.com/JoostVoskuil/azure-devops-gitleaks

.EXAMPLE
    .claude\skills\ai-sdlc-gates\scripts\Test-GitleaksBaseline.ps1
    
    Runs gitleaks using the default 'GitleaksUdmCombo' configuration and the
    default baseline file name 'gitleaks-baseline.json'.

.EXAMPLE
    .claude\skills\ai-sdlc-gates\scripts\Test-GitleaksBaseline.ps1 -gitleaksConfiguration 'UDMSecretChecksv8'
    
    Runs gitleaks using only Microsoft Security DevOps rules (CSCAN* rules) and the
    baseline file 'gitleaks-baseline.json'.

.EXAMPLE
    .claude\skills\ai-sdlc-gates\scripts\Test-GitleaksBaseline.ps1 -gitleaksConfiguration 'GitleaksOriginal'
    
    Runs gitleaks using only the original gitleaks rules at the pinned release tag and
    the baseline file 'gitleaks-baseline.json'.

.EXAMPLE
    .claude\skills\ai-sdlc-gates\scripts\Test-GitleaksBaseline.ps1 -BaselineFileName 'custom-baseline.json'
    
    Runs gitleaks using a custom baseline filename instead of the default 'gitleaks-baseline.json'.
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
    $PinFile = (Join-Path $PSScriptRoot 'gitleaks-rules.json'),

    [Parameter()]
    [string]
    $LogOpts = '',

    [Parameter()]
    [string]
    $RepoRoot
)

$inPipeline = $env:GITHUB_ACTIONS -eq 'true'
$notChecked = if ($inPipeline) { 1 } else { 2 }
$logOptsGiven = $PSBoundParameters.ContainsKey('LogOpts')
# Without this stop, Resolve-Path fails without ending the script, and gitleaks then scans the current
# folder, so a pass would speak for another repository than the one named (#32).
if ($PSBoundParameters.ContainsKey('RepoRoot') -and (-not $RepoRoot -or -not (Test-Path -LiteralPath $RepoRoot -PathType Container))) {
    Write-Host "The repository root '$RepoRoot' is not an existing folder, so no secret scan ran. Pass -RepoRoot with the folder of the repository."
    Write-Host 'FIX: Pass -RepoRoot with the folder of the repository, or run the gate from inside it.'
    exit $notChecked
}
# ProviderPath: .Path keeps the FileSystem:: prefix on a UNC path, and git cannot read that (#29).
$currentDirectory = if ($RepoRoot) { (Resolve-Path -LiteralPath $RepoRoot).ProviderPath } else { (Get-Location).ProviderPath }

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "Git is not installed or not available in the system PATH. Please install Git and try again."
    Write-Host 'FIX: Install git and put it on the PATH.'
    exit $notChecked
}

if (-not (Get-Command gitleaks -ErrorAction SilentlyContinue)) {
    Write-Host "Gitleaks is not installed or not available in the system PATH, so no secret scan ran. Install the pinned release with Install-Gitleaks.ps1 and put its folder on the PATH."
    Write-Host 'FIX: Run Install-Gitleaks.ps1 (in this skill folder) and put the gitleaks folder on the PATH.'
    exit $notChecked
}

# Gitleaks reads the commits through git. When git refuses the repository, for example as "dubious
# ownership" in a checkout whose git data is on a share, gitleaks scans 0 commits and reports no leaks.
# So a folder that git cannot read is "could not check", never a pass.
$null = git -C $currentDirectory rev-parse --verify --quiet HEAD 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "git cannot read the repository in $currentDirectory (for example 'dubious ownership'), so gitleaks would scan 0 commits. No secret scan ran."
    Write-Host 'FIX: Run the gate in a repository that has a commit and that git can read. For dubious ownership, add the folder to safe.directory in the git config.'
    exit $notChecked
}

if (-not $logOptsGiven) {
    if ($inPipeline -and $env:PR_BASE_SHA) { $LogOpts = "$($env:PR_BASE_SHA)..HEAD" }
    elseif (-not $inPipeline) {
        # The trunk of the remote: github.trunk in aisdlc.json, else main, master or whatever origin/HEAD
        # names (Get-AiSdlcMainBranch). A repository whose trunk is master had no origin/main, so the
        # scan read the whole history; on a share that took very long.
        Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
        $trunk = Get-AiSdlcMainBranch -RepoRoot $currentDirectory
        $null = git -C $currentDirectory rev-parse --verify --quiet $trunk 2>$null
        if ($LASTEXITCODE -eq 0) { $LogOpts = "$trunk..HEAD" }
    }
}

Import-Module (Join-Path $PSScriptRoot 'GitleaksConfig.psm1') -Force
$pin = Get-GitleaksRulesPin -Configuration $gitleaksConfiguration -PinFile $PinFile
if (-not $pin) {
    Write-Host "No pinned URL and SHA-256 for $gitleaksConfiguration in $PinFile, so no rules were downloaded."
    exit 1
}

$gitleakconfigurationFile = Join-Path ([IO.Path]::GetTempPath()) ('gitleaks-rules-' + [guid]::NewGuid().ToString('n') + '.toml')

Write-Host "Current directory: $currentDirectory"
Write-Host "Downloading the $gitleaksConfiguration rules from $($pin.Url)"
try { Invoke-WebRequest -Uri $pin.Url -Method Get -OutFile $gitleakconfigurationFile }
catch { Write-Host "The download failed: $($_.Exception.Message)"; Remove-Item -LiteralPath $gitleakconfigurationFile -Force -ErrorAction SilentlyContinue }

if (-not (Test-Path -LiteralPath $gitleakconfigurationFile)) {
    Write-Host "Failed to download gitleaks configuration file from $($pin.Url)"
    Write-Host 'FIX: Check the network access to the pinned rules URL, then run the gate again.'
    exit $notChecked
}
if (-not (Test-GitleaksRulesFile -Path $gitleakconfigurationFile -Pin $pin)) {
    $actual = (Get-FileHash -LiteralPath $gitleakconfigurationFile -Algorithm SHA256).Hash.ToLowerInvariant()
    Remove-Item -LiteralPath $gitleakconfigurationFile -Force
    Write-Host "The downloaded $gitleaksConfiguration rules have SHA-256 $actual, but $PinFile pins $($pin.Sha256). The file was deleted and nothing was scanned."
    exit 1
}

# The pinned rules plus the allowlist of the AI-SDLC: the blob hashes in sync-manifest.json look like keys.
$scanConfig = Join-Path ([IO.Path]::GetTempPath()) ('gitleaks-ai-sdlc-' + [guid]::NewGuid().ToString('n') + '.toml')
$null = New-GitleaksConfig -Path $scanConfig -RulesPath $gitleakconfigurationFile -RepoRoot $currentDirectory

# A repository without a baseline is scanned in full: every finding counts.
$gitleaksArgs = @('detect', "--source=$currentDirectory", '--config', $scanConfig, '--redact', '--exit-code=99')
if ($LogOpts) {
    $gitleaksArgs += "--log-opts=$LogOpts"
    Write-Host "Scanning the commits in $LogOpts"
}
$gitleaksBaselinePath = Join-Path -Path $currentDirectory -ChildPath $BaselineFileName
if (Test-Path -LiteralPath $gitleaksBaselinePath -PathType Leaf) {
    $gitleaksArgs += @('--baseline-path', $gitleaksBaselinePath)
    Write-Host "Running gitleaks against the current repository using baseline file: $BaselineFileName"
}
else {
    Write-Host "No baseline file $BaselineFileName, so gitleaks scans without one and every finding counts. To accept old findings that are not secrets, make one with Create-GitleaksBaseline.ps1 and commit it."
}

$scanExit = 1
$stagedExit = 0
$stagedCount = 0
try {
    gitleaks @gitleaksArgs
    $scanExit = $LASTEXITCODE

    # A secret that is staged but not committed is in no commit, so the range scan above cannot see it.
    # A pipeline has no staged files, and -LogOpts asks for one exact range, so both skip this scan.
    if (-not $inPipeline -and -not $logOptsGiven) {
        $staged = @(git -C $currentDirectory diff --cached --name-only 2>$null)
        if ($LASTEXITCODE -ne 0) {
            # Without the list, a staged secret could pass unseen, so this is never a pass.
            Write-Host 'git could not list the staged files, so the staged files were not scanned.'
            Write-Host 'FIX: Run git diff --cached --name-only to see the git error, fix it, then run the gate again.'
            exit $notChecked
        }
        if ($staged.Count -gt 0) {
            $stagedCount = $staged.Count
            Write-Host "Scanning the $stagedCount staged file(s)"
            $stagedArgs = @('git', '--staged', '--config', $scanConfig, '--redact', '--exit-code=99')
            if (Test-Path -LiteralPath $gitleaksBaselinePath -PathType Leaf) { $stagedArgs += @('--baseline-path', $gitleaksBaselinePath) }
            gitleaks @stagedArgs $currentDirectory
            $stagedExit = $LASTEXITCODE
        }
    }
}
catch {
    Write-Host "An error occurred: $_"
    exit 1
}
finally {
    Remove-Item -Path $gitleakconfigurationFile -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $scanConfig -ErrorAction SilentlyContinue
}

$scanned = if ($stagedCount -gt 0) { "the commits and the $stagedCount staged file(s)" } else { 'the commits' }
Write-Host "Gitleaks scan completed ($scanned)$(if (Test-Path -LiteralPath $gitleaksBaselinePath -PathType Leaf) { " using baseline file: $gitleaksBaselinePath" } else { ' without a baseline' })"
if ($scanExit -eq 99 -or $stagedExit -eq 99) {
    $where = @(if ($scanExit -eq 99) { 'the commits' }; if ($stagedExit -eq 99) { 'the staged files' }) -join ' and in '
    Write-Host "Gitleaks found a secret that the baseline does not hold, in $where."
    Write-Host 'FIX: Remove the secret from the change. When it is only staged, unstage it with git restore --staged <file> first. Rotate it when it is real. Add a finding to the baseline (Create-GitleaksBaseline.ps1) only when it is a false positive.'
    exit 1
}
if ($scanExit -ne 0 -or $stagedExit -ne 0) {
    Write-Host "Gitleaks failed with exit code $(if ($scanExit -ne 0) { $scanExit } else { $stagedExit }), so the scan did not finish."
    exit 1
}
exit 0
