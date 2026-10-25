#Requires -Version 7
<#
.SYNOPSIS
    One-time setup of the AI-SDLC in a fresh clone: the git hooks wired, the core tools checked, and the
    setup step of every installed pack run, with one table saying what is ready and what is missing.

.DESCRIPTION
    core.hooksPath lives in .git/config, so the committed git hooks are inert until each clone points at
    them. This script sets core.hooksPath to .claude/skills/ai-sdlc-hooks/githooks, the folder the core
    package ships, and marks the hooks executable on Linux and macOS. The pre-push hook there also
    covers a push from a terminal and from any tool that does not run the agent hooks.

    The pre-flight writes its receipts under temp/, unless paths.preflightReceipts names another folder.
    When no ignore rule covers temp/, this script adds temp/ to .git/info/exclude of the clone, so no
    repository has to change its .gitignore by hand. It does the same for a receipt folder outside temp/,
    with a rule that starts at the root, such as /out/, so git does not ignore that name at every depth.

    It then checks the core tools (PowerShell 7, pwsh on PATH, Pester 5, gitleaks) and runs the "setup"
    script of each package that runs: the core and every pack that apm.yml lists. A pack names its
    setup script in its gates.json, for example the dotnet pack restores the solution and installs
    dotnet-coverage and the pinned Graphify CLI, and the azure-devops pack sets the git credential type. A setup script takes
    the switches it needs from -RepoRoot, -Minimal, -SkipRestore, -SkipGraphify and -SkipGlobalGitConfig,
    honours -WhatIf, returns rows with Step, Status and Detail, and answers -Plan with the steps it
    would take.

    Then it runs Sync-AllowRules.ps1 from the ai-sdlc-gates skill, which writes the allow rules that the
    installed packages list in their gates.json into .claude/settings.json. Last, it runs
    Sync-AgentsFile.ps1, which writes the shared parts of AGENTS.md from the installed packages. -WhatIf
    skips both steps.

    It is safe to re-run: every step is idempotent and reports "already set" when there is nothing to
    do. Every run prints what it is about to do before it does it, and -WhatIf shows it without acting.

    Bypass the hook for a single push with: git push --no-verify
    Disable the hook again with:            git config --unset core.hooksPath

.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script.

.PARAMETER SkillsRoot
    Where the packages are installed. Defaults to <RepoRoot>/.claude/skills.

.PARAMETER SkipGlobalGitConfig
    Leave machine-wide git settings alone. Passed to each setup script that changes one.

.PARAMETER Minimal
    Apply the git wiring and report prerequisites. Each pack setup still runs but skips its
    installs, and the shared parts of AGENTS.md are still written.

.PARAMETER SkipRestore
    Passed to the setup scripts: do not restore packages.

.PARAMETER SkipGraphify
    Passed to the setup scripts: do not install the Graphify CLI and do not build the code graph.

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-hooks/scripts/Initialize-AiSdlc.ps1

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-hooks/scripts/Initialize-AiSdlc.ps1 -Minimal

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-hooks/scripts/Initialize-AiSdlc.ps1 -SkipGlobalGitConfig -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$RepoRoot,
    [string]$SkillsRoot,
    [switch]$SkipGlobalGitConfig,
    [switch]$Minimal,
    [switch]$SkipRestore,
    [switch]$SkipGraphify
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts' 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }
if (-not $SkillsRoot) { $SkillsRoot = Join-Path $RepoRoot '.claude' 'skills' }

$hooksPath = '.claude/skills/ai-sdlc-hooks/githooks'
$syncScript = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts' 'Sync-AgentsFile.ps1'
$allowScript = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts' 'Sync-AllowRules.ps1'

$packageArgs = @{
    RepoRoot            = $RepoRoot
    Minimal             = [bool]$Minimal
    SkipRestore         = [bool]$SkipRestore
    SkipGraphify        = [bool]$SkipGraphify
    SkipGlobalGitConfig = [bool]$SkipGlobalGitConfig
}

function Get-SetupArgument {
    param([string]$Script, [hashtable]$Extra = @{})

    $accepted = (Get-Command -Name $Script).Parameters.Keys
    $callArgs = @{}
    foreach ($key in $packageArgs.Keys) { if ($accepted -contains $key) { $callArgs[$key] = $packageArgs[$key] } }
    foreach ($key in $Extra.Keys) { if ($accepted -contains $key) { $callArgs[$key] = $Extra[$key] } }
    return $callArgs
}

$setups = @()
if (Test-Path -LiteralPath (Join-Path $RepoRoot '.git')) {
    $setups = @(Get-AiSdlcPackage -RepoRoot $RepoRoot -SkillsRoot $SkillsRoot | Where-Object { $_.Setup -and (Test-Path -LiteralPath $_.Setup) })
}

$plan = @('git wiring', 'prerequisite check')
foreach ($setup in $setups) {
    $planArgs = Get-SetupArgument -Script $setup.Setup -Extra @{ Plan = $true }
    $plan += @(& $setup.Setup @planArgs | Where-Object { $_ -is [string] })
}
if (-not $WhatIfPreference) { $plan += 'allow rules', 'AGENTS.md shared parts' }

Write-Host "This run will do: $($plan -join ', ')." -ForegroundColor Cyan
if ($Minimal -or $SkipRestore -or $SkipGraphify) {
    Write-Host "Run without switches for the full setup." -ForegroundColor DarkGray
}

$results = [System.Collections.Generic.List[object]]::new()
function Add-Result([string]$Step, [string]$Status, [string]$Detail) {
    $results.Add([pscustomobject]@{ Step = $Step; Status = $Status; Detail = $Detail })
}

function Test-Tool([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

Push-Location $RepoRoot
try {
    git rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "$RepoRoot is not inside a git working tree; nothing to initialise." -ForegroundColor Red
        exit 1
    }

    Write-Host "`n[1] Git hooks (core.hooksPath)..." -ForegroundColor Cyan
    $hookFolder = Join-Path $RepoRoot $hooksPath
    $hookFile = Join-Path $hookFolder 'pre-push'
    $currentHooksPath = (git config --local core.hooksPath 2>$null)
    if (-not (Test-Path $hookFile)) {
        Add-Result 'Git hooks' 'FAIL' "no $hooksPath/pre-push found under $RepoRoot; nothing to enable"
    }
    elseif ($currentHooksPath -eq $hooksPath) {
        Add-Result 'Git hooks' 'ALREADY' "core.hooksPath is already $hooksPath"
        Write-Host "core.hooksPath is already $hooksPath"
    }
    elseif ($PSCmdlet.ShouldProcess('core.hooksPath', "set to $hooksPath")) {
        git config core.hooksPath $hooksPath
        if (-not $IsWindows) {
            Get-ChildItem -LiteralPath $hookFolder -File | ForEach-Object { chmod +x $_.FullName }
        }
        Add-Result 'Git hooks' 'SET' "core.hooksPath = $hooksPath; pre-push gate now runs"
        Write-Host "Enabled git hooks: core.hooksPath = $hooksPath"
        Write-Host "Bypass a single push with: git push --no-verify"
        Write-Host "Disable again with:        git config --unset core.hooksPath"
    }
    else {
        Add-Result 'Git hooks' 'WHATIF' "would set core.hooksPath = $hooksPath"
    }

    # The receipts of the pre-flight live under temp/, or in the folder paths.preflightReceipts names,
    # and must never be committed. .git/info/exclude is local to the clone, so this needs no change to
    # the .gitignore of the repository. A receipt folder under temp/ needs no rule of its own.
    # A leading ./ or / is dropped: git matches no rule that starts with ./, and the receipts land under the repository either way.
    # The rule for the receipt folder starts with /, so git matches it at the root only: a plain out/ would
    # also ignore every folder named out deeper in the tree.
    $receiptDir = (([string]((Get-AiSdlcConfig -RepoRoot $RepoRoot).paths.preflightReceipts) -replace '\\', '/').Trim() -replace '^(\.?/)+', '').TrimEnd('/')
    $ignoreFolders = @('temp')
    if ($receiptDir -and -not [System.IO.Path]::IsPathRooted($receiptDir) -and $receiptDir -ne 'temp' -and -not $receiptDir.StartsWith('temp/')) {
        $ignoreFolders += $receiptDir
    }
    # --git-path gives a path relative to the root in a plain clone and an absolute one in a worktree.
    $excludeFile = [System.IO.Path]::GetFullPath(([string](git rev-parse --git-path info/exclude 2>$null)).Trim(), $RepoRoot)
    foreach ($folder in $ignoreFolders) {
        $step = "$folder/ ignored"
        $probe = if ($folder -eq 'temp') { 'temp/preflight/receipt.json' } else { "$folder/receipt.json" }
        git check-ignore -q $probe *> $null
        $ignoreExit = $LASTEXITCODE
        if ($ignoreExit -eq 0) {
            Add-Result $step 'ALREADY' "an ignore rule already covers $folder/"
        }
        elseif ($ignoreExit -ne 1) {
            Add-Result $step 'WARN' "git check-ignore exited $ignoreExit; add $folder/ to .gitignore by hand"
        }
        elseif ($PSCmdlet.ShouldProcess($excludeFile, "add $folder/")) {
            New-Item -ItemType Directory -Path (Split-Path $excludeFile -Parent) -Force | Out-Null
            $existing = if (Test-Path -LiteralPath $excludeFile) { [System.IO.File]::ReadAllText($excludeFile) } else { '' }
            $lead = if ($existing -and -not $existing.EndsWith("`n")) { "`n" } else { '' }
            $rule = if ($folder -eq 'temp') { 'temp/' } else { "/$folder/" }
            [System.IO.File]::AppendAllText($excludeFile, "${lead}$rule`n")
            Add-Result $step 'SET' "added $rule to .git/info/exclude, so a pre-flight receipt is never committed"
        }
        else {
            Add-Result $step 'WHATIF' "would add $(if ($folder -eq 'temp') { 'temp/' } else { "/$folder/" }) to .git/info/exclude"
        }
    }

    Write-Host "`n[2] Prerequisites..." -ForegroundColor Cyan

    Add-Result 'PowerShell 7' 'PASS' "$($PSVersionTable.PSVersion) running this script"

    if (Test-Tool 'pwsh') {
        Add-Result 'pwsh on PATH' 'PASS' 'the pre-push hook can invoke the gates'
    }
    else {
        Add-Result 'pwsh on PATH' 'WARN' 'pre-push hook will warn and allow pushes until pwsh is on PATH'
    }

    $pester = @(Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version.Major -ge 5 })
    if ($pester.Count -gt 0) {
        Add-Result 'Pester 5+' 'PASS' "v$($pester[0].Version) for the tools tests"
    }
    else {
        Add-Result 'Pester 5+' 'OPTIONAL' 'Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser'
    }

    if (Test-Tool 'gitleaks') {
        Add-Result 'gitleaks' 'PASS' 'secret scan runs in the local pre-flight'
    }
    else {
        Add-Result 'gitleaks' 'OPTIONAL' 'winget install gitleaks (pre-flight reports it as skipped without it)'
    }

    foreach ($setup in $setups) {
        Write-Host "`n[$($setup.Skill)] Setup of the $($setup.Package) package..." -ForegroundColor Cyan
        $callArgs = Get-SetupArgument -Script $setup.Setup
        if ($WhatIfPreference) { $callArgs['WhatIf'] = $true }
        foreach ($row in @(& $setup.Setup @callArgs)) {
            if ($row -and $row.PSObject.Properties['Step'] -and $row.PSObject.Properties['Status']) { Add-Result $row.Step $row.Status $row.Detail }
        }
    }

    Write-Host "`n[3] Allow rules of the installed packages..." -ForegroundColor Cyan
    if ($WhatIfPreference) {
        Add-Result 'Allow rules' 'WHATIF' 'would write the allow rules of the installed packages with Sync-AllowRules.ps1'
    }
    elseif (-not (Test-Path -LiteralPath $allowScript -PathType Leaf)) {
        Add-Result 'Allow rules' 'WARN' "Sync-AllowRules.ps1 is not installed at $allowScript"
    }
    else {
        $allowOutput = & pwsh -NoProfile -File $allowScript -RepoRoot $RepoRoot -SkillsRoot $SkillsRoot 2>&1 | Out-String
        $allowExit = $LASTEXITCODE
        Write-Host $allowOutput.TrimEnd()
        if ($allowExit -eq 0) { Add-Result 'Allow rules' 'SET' '.claude/settings.json holds the allow rules of the installed packages; commit it when it changed' }
        else { Add-Result 'Allow rules' 'WARN' "Sync-AllowRules.ps1 exited $allowExit; see its message above" }
    }

    Write-Host "`n[4] AGENTS.md shared parts..." -ForegroundColor Cyan
    if ($WhatIfPreference) {
        Add-Result 'AGENTS.md' 'WHATIF' 'would write the shared parts with Sync-AgentsFile.ps1'
    }
    elseif (-not (Test-Path -LiteralPath $syncScript -PathType Leaf)) {
        Add-Result 'AGENTS.md' 'WARN' "Sync-AgentsFile.ps1 is not installed at $syncScript"
    }
    else {
        $syncOutput = & pwsh -NoProfile -File $syncScript -RepoRoot $RepoRoot -SkillsRoot $SkillsRoot 2>&1 | Out-String
        $syncExit = $LASTEXITCODE
        Write-Host $syncOutput.TrimEnd()
        if ($syncExit -eq 0) { Add-Result 'AGENTS.md' 'SET' 'the shared parts match the installed packages' }
        else { Add-Result 'AGENTS.md' 'WARN' "Sync-AgentsFile.ps1 exited $syncExit; see its message above" }
    }
}
finally {
    Pop-Location
}

Write-Host "`n===== Repository initialisation =====" -ForegroundColor Cyan
$results | Format-Table -AutoSize -Wrap | Out-String | Write-Host

$failed = @($results | Where-Object { $_.Status -eq 'FAIL' })
if ($failed.Count -gt 0) {
    Write-Host "$($failed.Count) required step(s) failed. Fix them, then re-run this script." -ForegroundColor Red
    exit 1
}

$warned = @($results | Where-Object { $_.Status -eq 'WARN' })
if ($warned.Count -gt 0) {
    Write-Host "Wiring is in place. $($warned.Count) recommended item(s) need attention; see the WARN rows above." -ForegroundColor Yellow
}
else {
    Write-Host "Wiring is in place and every recommended prerequisite is present." -ForegroundColor Green
}
Write-Host "Next: pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1 to check a change before pushing."
exit 0
