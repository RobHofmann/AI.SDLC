#Requires -Version 7
<#
.SYNOPSIS
    Runs every Pester test file under the given folders, each in its own pwsh process, several at once.

.DESCRIPTION
    One Invoke-Pester over core, packs and tools runs the files one after another in a single process. That
    is slow, and it hides a test file that only passes because an earlier file loaded something for it. This
    script gives each test file a fresh process, so such a file fails here, and it runs as many files at once
    as the machine has cores.

    It lists the test files itself, with -Force. The shared scripts sit under .apm/ folders, which Linux and
    macOS treat as hidden, and Invoke-Pester -Path skips a hidden folder there in silence.

    Each run gives its test processes their own temp folder (TEMP, TMP and TMPDIR) and removes it at
    the end. A test that cleans up the temp folder by a name pattern then cannot delete the folders of
    another run on the same machine.

    The run fails (exit 1) when a test fails, when a file could not run, or when no test file is found. With
    -Ci each failure is also written as a GitHub Actions error annotation, so it shows on the run summary.

.PARAMETER Path
    The folders to search for *.Tests.ps1. Defaults to core, packs and tools under the repository root.

.PARAMETER RepoRoot
    The AI.SDLC repository root. Defaults to the folder above this script.

.PARAMETER ThrottleLimit
    How many test files run at once. Defaults to the number of processor cores.

.PARAMETER PesterVersion
    The Pester version each process imports, for example 5.7.1. Without it each process takes the newest
    Pester 5 it finds.

.PARAMETER Shards
    Split the test files into this many shares, so several workflow jobs can each run one share. Defaults
    to 1, all files.

.PARAMETER Shard
    Which share to run, from 1 to -Shards. A share takes every n-th file of the sorted list, so the shares
    together run each file once.

.PARAMETER CoverageFile
    Measure the code coverage and write it to this file, in the generic coverage format of SonarCloud.
    Each test file measures the scripts and modules in its own folder (tools/PesterCoverage.psm1). A
    line is covered when a test file of this run ran it. A script that a test starts in a child pwsh is
    not measured.

.PARAMETER TimingFile
    Where the run keeps the time each test file took, as JSON. Defaults to temp/pester-times.json under
    the repository root, which git ignores. The run starts the slowest files of the last run first, so
    a slow file does not start last and make the run longer. A file the timing file does not list
    starts before the known ones, in alphabetical order. Without the file, or with a file it cannot
    read, the order is alphabetical. The shares of -Shards are cut from the alphabetical list first, so
    the order never moves a file to another share.

.PARAMETER Changed
    Run only the test files of the scripts that changed against -Base, with the working tree and new
    files included. This is the quick run of a build loop; the pre-flight still runs every file once.
    A changed <Name>.Tests.ps1 runs itself, and a changed <Name>.ps1 runs the <Name>.Tests.ps1 next to
    it. Every test file runs when a changed script has no test file next to it, when a module (.psm1)
    changed, or when this runner changed. A file that is not a script, such as a page or a JSON file,
    maps to no test. When nothing maps, no test runs and the run passes.

.PARAMETER Base
    The ref that -Changed compares with, through the merge base. Defaults to origin/main.

.PARAMETER ListOnly
    Print the test files the run would start, in the order it would start them, one "Would run:" line
    each, and run none. Shows what -Changed, -Shards and the timing file choose.

.PARAMETER Ci
    Write each failure as a GitHub Actions error annotation.

.EXAMPLE
    pwsh tools/Invoke-PesterParallel.ps1 -Changed

.EXAMPLE
    pwsh tools/Invoke-PesterParallel.ps1

.EXAMPLE
    pwsh tools/Invoke-PesterParallel.ps1 -Path packs -PesterVersion 5.7.1 -Ci

.EXAMPLE
    pwsh tools/Invoke-PesterParallel.ps1 -Path core -Shards 3 -Shard 2

.EXAMPLE
    pwsh tools/Invoke-PesterParallel.ps1 -Path tools -CoverageFile out/coverage.xml
#>
[CmdletBinding()]
param(
    [string[]]$Path,
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [int]$ThrottleLimit = [Environment]::ProcessorCount,
    [string]$PesterVersion,
    [ValidateRange(1, 100)][int]$Shards = 1,
    [ValidateRange(1, 100)][int]$Shard = 1,
    [string]$CoverageFile,
    [string]$TimingFile,
    [switch]$Changed,
    [string]$Base = 'origin/main',
    [switch]$ListOnly,
    [switch]$Ci
)

$ErrorActionPreference = 'Stop'
if (-not $Path) { $Path = @('core', 'packs', 'tools') }
$folders = foreach ($p in $Path) { if ([IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $RepoRoot $p } }
$missing = @($folders | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Container) })
if ($missing) { Write-Host "No such folder: $($missing -join ', ')" -ForegroundColor Red; exit 1 }

if ($Shard -gt $Shards) { Write-Host "-Shard $Shard is above -Shards $Shards." -ForegroundColor Red; exit 1 }
$all = @($folders | ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -Force -File -Filter '*.Tests.ps1' } | ForEach-Object FullName | Sort-Object -Unique)
if ($Changed) {
    $runAll = $null
    $picked = [System.Collections.Generic.List[string]]::new()
    $mergeBase = [string](git -C $RepoRoot merge-base $Base HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $mergeBase.Trim()) { $runAll = "git finds no merge base with $Base" }
    else {
        $changedPaths = @(git -C $RepoRoot diff --name-only $mergeBase.Trim()) + @(git -C $RepoRoot ls-files --others --exclude-standard)
        $roots = @($folders | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar })
        foreach ($rel in ($changedPaths | Where-Object { $_ } | Sort-Object -Unique)) {
            $full = [IO.Path]::GetFullPath((Join-Path $RepoRoot $rel))
            if (-not @($roots | Where-Object { $full.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) })) { continue }
            $name = Split-Path -Leaf $full
            if ($name -like '*.Tests.ps1') { if (Test-Path -LiteralPath $full) { $picked.Add($full) }; continue }
            if ($name -in 'Invoke-PesterParallel.ps1', 'PesterCoverage.psm1' -or $name -like '*.psm1') { $runAll = "$rel is a module or the test runner"; break }
            if ($name -notlike '*.ps1') { continue }
            $test = Join-Path (Split-Path -Parent $full) ($name -replace '\.ps1$', '.Tests.ps1')
            if (Test-Path -LiteralPath $test) { $picked.Add($test) } else { $runAll = "$rel has no test file next to it"; break }
        }
    }
    if ($runAll) { Write-Host "Running every test file, because $runAll." }
    else {
        $all = @($picked | ForEach-Object { [IO.Path]::GetFullPath($_) } | Sort-Object -Unique)
        if ($all.Count -eq 0) { Write-Host "No changed script maps to a test file against $Base, so no test runs."; exit 0 }
        Write-Host "Running the $($all.Count) test file(s) of the changed scripts against $Base."
    }
}
$files =@(for ($i = $Shard - 1; $i -lt $all.Count; $i += $Shards) { $all[$i] })
if ($files.Count -eq 0) {
    $message = "No test file found under $($Path -join ', ')."
    if ($Ci) { Write-Host "::error title=Pester::$message" }
    Write-Host $message -ForegroundColor Red
    exit 1
}
if (-not $TimingFile) { $TimingFile = Join-Path $RepoRoot 'temp' 'pester-times.json' }
$relative = { param($full) [IO.Path]::GetRelativePath($RepoRoot, $full).Replace('\', '/') }
$times = @{}
if (Test-Path -LiteralPath $TimingFile -PathType Leaf) {
    try { $times = Get-Content -LiteralPath $TimingFile -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { Write-Host "The timing file $TimingFile cannot be read, so the files run in alphabetical order." -ForegroundColor Yellow }
    if ($times -isnot [hashtable]) { $times = @{} }
}
$unknown = @($files | Where-Object { -not $times.ContainsKey((& $relative $_)) })
$known = @($files | Where-Object { $times.ContainsKey((& $relative $_)) } | Sort-Object -Property @{ Expression = { [double]$times[(& $relative $_)] }; Descending = $true }, @{ Expression = { $_ } })
$files = @($unknown) + @($known)
if ($ListOnly) {
    foreach ($f in $files) { Write-Host "Would run: $(& $relative $f)" }
    exit 0
}
$shareText = if ($Shards -gt 1) { " (share $Shard of $Shards, from $($all.Count) files)" } else { '' }
Write-Host "Running $($files.Count) test file(s)$shareText, $ThrottleLimit at a time, each in its own process."

$coverageModule = Join-Path $PSScriptRoot 'PesterCoverage.psm1'
$runTemp = Join-Path ([IO.Path]::GetTempPath()) ('pester-run-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $runTemp -Force | Out-Null
$started = [Diagnostics.Stopwatch]::StartNew()
$results = $files | ForEach-Object -ThrottleLimit ([Math]::Max(1, $ThrottleLimit)) -Parallel {
    $file = $_
    $quoted = $file.Replace("'", "''")
    $moduleQuoted = $using:coverageModule
    $moduleQuoted = $moduleQuoted.Replace("'", "''")
    $rootQuoted = $using:RepoRoot
    $rootQuoted = $rootQuoted.Replace("'", "''")
    $tempQuoted = $using:runTemp
    $tempQuoted = $tempQuoted.Replace("'", "''")
    $import = if ($using:PesterVersion) { "Import-Module Pester -RequiredVersion '$($using:PesterVersion)'" } else { "Import-Module Pester -MinimumVersion 5.0" }
    # With -CoverageFile the process measures the scripts next to its test file, with the profiler, and
    # hands back its lines; Pester's own report goes to a temporary file that is removed.
    $coverage = if ($using:CoverageFile) {
        @"
Import-Module '$moduleQuoted'
`$targets = @(Get-CoverageTarget -TestFile '$quoted')
if (`$targets.Count -gt 0) {
    `$c.CodeCoverage.Enabled = `$true
    `$c.CodeCoverage.Path = `$targets
    `$c.CodeCoverage.UseBreakpoints = `$false
    `$pesterReport = [IO.Path]::GetTempFileName()
    `$c.CodeCoverage.OutputPath = `$pesterReport
}
"@
    } else { '' }
    $command = @"
`$ErrorActionPreference = 'Stop'
`$env:TEMP = '$tempQuoted'; `$env:TMP = '$tempQuoted'; `$env:TMPDIR = '$tempQuoted'
$import
`$c = New-PesterConfiguration
`$c.Run.Path = '$quoted'
`$c.Run.PassThru = `$true
`$c.Output.Verbosity = 'None'
$coverage
`$r = Invoke-Pester -Configuration `$c
`$lines = @()
if (`$c.CodeCoverage.Enabled.Value) { `$lines = @(ConvertTo-CoverageLine -CodeCoverage `$r.CodeCoverage -RepoRoot '$rootQuoted'); Remove-Item -LiteralPath `$pesterReport -ErrorAction SilentlyContinue }
[pscustomobject]@{
    Coverage = `$lines
    Passed  = `$r.PassedCount
    Failed  = `$r.FailedCount
    Skipped = `$r.SkippedCount
    Total   = `$r.TotalCount
    Broken  = `$r.FailedContainersCount + `$r.FailedBlocksCount
    Errors  = @(
        @(`$r.Failed | ForEach-Object { '{0} :: {1}' -f `$_.ExpandedPath, ((`$_.ErrorRecord | Select-Object -First 1).Exception.Message -split "``n" | Where-Object { `$_.Trim() } | Select-Object -First 1) })
        @(`$r.Containers | Where-Object Result -eq 'Failed' | ForEach-Object { 'the file did not load :: {0}' -f ((`$_.ErrorRecord | Select-Object -First 1).Exception.Message -split "``n" | Where-Object { `$_.Trim() } | Select-Object -First 1) })
        @(`$r.FailedBlocks | ForEach-Object { '{0} :: a setup block failed: {1}' -f `$_.ExpandedPath, ((`$_.ErrorRecord | Select-Object -First 1).Exception.Message -split "``n" | Where-Object { `$_.Trim() } | Select-Object -First 1) })
    )
} | ConvertTo-Json -Compress -Depth 3
"@
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $output = & pwsh -NoProfile -NonInteractive -Command $command 2>&1
    $code = $LASTEXITCODE
    $watch.Stop()
    $summary = $null
    $last = @($output | ForEach-Object { "$_" } | Where-Object { $_ -match '^\{.*\}$' }) | Select-Object -Last 1
    if ($last) { try { $summary = $last | ConvertFrom-Json } catch { $summary = $null } }
    if (-not $summary) {
        $tail = (@($output | ForEach-Object { "$_" }) | Select-Object -Last 3) -join ' '
        $summary = [pscustomobject]@{ Passed = 0; Failed = 0; Skipped = 0; Total = 0; Broken = 1; Errors = @("the file could not run (exit $code): $tail") }
    }
    [pscustomobject]@{
        File    = $file
        Passed  = [int]$summary.Passed
        Failed  = [int]$summary.Failed
        Skipped = [int]$summary.Skipped
        Total   = [int]$summary.Total
        Errors  = @($summary.Errors)
        Broken  = ([int]$summary.Broken -gt 0)
        Seconds = [Math]::Round($watch.Elapsed.TotalSeconds, 1)
        Coverage = @($summary.Coverage | Where-Object { $_ })
    }
}
$started.Stop()
Remove-Item -LiteralPath $runTemp -Recurse -Force -ErrorAction SilentlyContinue

if ($CoverageFile) {
    Import-Module $coverageModule -Force
    $lines = @(Merge-CoverageLine -Line @($results | ForEach-Object { $_.Coverage }))
    $target = if ([IO.Path]::IsPathRooted($CoverageFile)) { $CoverageFile } else { Join-Path (Get-Location) $CoverageFile }
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    [IO.File]::WriteAllText($target, (ConvertTo-SonarCoverageXml -Line $lines), [Text.UTF8Encoding]::new($false))
    $covered = @($lines | Where-Object Covered).Count
    $percent = if ($lines.Count) { 100 * $covered / $lines.Count } else { 0 }
    Write-Host ("Coverage: {0} of {1} line(s) covered ({2:n1}%), in {3} file(s); written to {4}." -f $covered, $lines.Count, $percent, @($lines.File | Sort-Object -Unique).Count, $target)
}

foreach ($r in $results) { $times[(& $relative $r.File)] = $r.Seconds }
try {
    New-Item -ItemType Directory -Path (Split-Path -Parent $TimingFile) -Force | Out-Null
    $sorted = [ordered]@{}
    foreach ($key in ($times.Keys | Sort-Object)) { $sorted[$key] = $times[$key] }
    [IO.File]::WriteAllText($TimingFile, ($sorted | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
}
catch { Write-Host "The times of this run could not be written to $($TimingFile): $($_.Exception.Message)" -ForegroundColor Yellow }

$passed = ($results | Measure-Object Passed -Sum).Sum
$failed = ($results | Measure-Object Failed -Sum).Sum
$skipped = ($results | Measure-Object Skipped -Sum).Sum
$empty = @($results | Where-Object { $_.Total -eq 0 -and -not $_.Broken })
$broken = @($results | Where-Object Broken)

foreach ($r in ($results | Where-Object { $_.Failed -gt 0 -or $_.Broken })) {
    foreach ($e in $r.Errors) {
        $line = "$(& $relative $r.File): $e"
        if ($Ci) { Write-Host ("::error file={0},title=Pester::{1}" -f (& $relative $r.File), ($line -replace '%', '%25' -replace "`r", '%0D' -replace "`n", '%0A')) }
        Write-Host "FAILED $line" -ForegroundColor Red
    }
}
foreach ($r in $empty) { Write-Host "No test in $(& $relative $r.File)" -ForegroundColor Yellow }

Write-Host 'Slowest files:'
$results | Sort-Object Seconds -Descending | Select-Object -First 5 | ForEach-Object { Write-Host ("  {0,6:n1}s  {1}" -f $_.Seconds, (& $relative $_.File)) }
Write-Host ("Pester: {0} passed, {1} failed, {2} skipped, in {3} file(s), {4} of them could not run; {5:n0}s." -f $passed, $failed, $skipped, $files.Count, $broken.Count, $started.Elapsed.TotalSeconds)

if ($failed -gt 0 -or $broken.Count -gt 0 -or ($passed + $skipped) -eq 0) { exit 1 }
exit 0
