#Requires -Version 7
<#
.SYNOPSIS
    A gate that runs the Pester tests under the paths it is given, so a repository can list its own
    script tests as a gate in aisdlc.json.

.DESCRIPTION
    Invoke-LocalGates.ps1 runs the "repoGates" of aisdlc.json next to the gates of the packages. A
    repository whose own scripts carry Pester tests points a repository gate at this script and names
    the folders or files in args.Path, relative to the repository root:

        "repoGates": [
          { "name": "Repository script tests", "script": ".claude/skills/ai-sdlc-gates/scripts/Invoke-PesterGate.ps1",
            "clause": "C04", "mode": "Blocking", "args": { "Path": [ "tools" ] } }
        ]

    The tests then run in the pre-push hook (for a Blocking gate), in the pull request pipeline and in a
    local run, like every other gate. It prints each failed test indented as "file:line  name", which is
    the shape Invoke-Gate.ps1 and GateAnnotation.psm1 raise as a finding on the file.

    In each folder it finds every file whose name ends in .tests.ps1 in any letter case, also under
    hidden folders such as .claude. It hands those files to Pester by name, because the folder search
    of Pester finds only *.Tests.ps1 and misses Get-BicepGuid.tests.ps1 on Linux. A file in the path
    goes to Pester as it is.

    Exit codes follow the gate contract: 0 every test passed, 1 a test failed, 2 could not check (Pester 5
    is missing, a path does not exist, or the paths hold no test).

.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from the current location.

.PARAMETER Path
    One or more folders or test files, relative to the repository root.

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-PesterGate.ps1 -Path tools
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [Parameter(Mandatory)][string[]]$Path
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath (Get-Location).Path }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$pester = Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version.Major -ge 5 } | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) {
    Write-Host 'Pester tests: Pester 5 is not installed, so NOTHING WAS CHECKED.'
    Write-Host 'FIX: Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser, then run the gate again.'
    exit 2
}

$full = foreach ($p in $Path) {
    $candidate = Join-Path $RepoRoot $p
    if (-not (Test-Path -LiteralPath $candidate)) {
        Write-Host "Pester tests: the path $p does not exist under $RepoRoot, so NOTHING WAS CHECKED."
        Write-Host 'FIX: Point args.Path of this gate in aisdlc.json at folders or test files that exist.'
        exit 2
    }
    (Resolve-Path -LiteralPath $candidate).Path
}

$found = foreach ($item in $full) {
    if (Test-Path -LiteralPath $item -PathType Container) {
        Get-ChildItem -LiteralPath $item -Recurse -File -Force | Where-Object { $_.Name.EndsWith('.tests.ps1', [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object FullName
    }
    else { $item }
}
$files = @($found | Select-Object -Unique)

$result = $null
if ($files.Count -gt 0) {
    Import-Module $pester.Path -Force
    $configuration = New-PesterConfiguration
    $configuration.Run.Path = @($files)
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = 'Normal'
    $result = Invoke-Pester -Configuration $configuration
}

if (-not $result -or $result.TotalCount -eq 0) {
    Write-Host "Pester tests: no test found under $($Path -join ', '), so NOTHING WAS CHECKED."
    Write-Host 'FIX: Name each test file <Script>.Tests.ps1 next to its script, or point args.Path at the folder that holds them.'
    exit 2
}

if ($result.FailedCount -gt 0 -or $result.FailedContainersCount -gt 0) {
    Write-Host 'Pester tests failed:'
    foreach ($test in $result.Failed) {
        $file = $test.ScriptBlock.File
        $where = if ($file) { '{0}:{1}' -f [IO.Path]::GetRelativePath($RepoRoot, $file).Replace('\', '/'), $test.ScriptBlock.StartPosition.StartLine } else { $test.ExpandedPath }
        Write-Host ("  {0}  {1}" -f $where, $test.ExpandedPath)
    }
    foreach ($container in $result.FailedContainers) {
        Write-Host ("  {0}  the test file did not run: {1}" -f $container.Item, $container.ErrorRecord.Exception.Message)
    }
    Write-Host 'FIX: Make the failing tests pass, or fix the script they test; run Invoke-Pester on the file to see the whole failure.'
    Write-Host ("{0} of {1} test(s) failed." -f $result.FailedCount, $result.TotalCount)
    exit 1
}

Write-Host ("Pester tests OK: {0} test(s) passed under {1}." -f $result.PassedCount, ($Path -join ', '))
exit 0
