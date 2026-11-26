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
    macOS treat as hidden, and Invoke-Pester -Path skips a hidden folder there in silence. The tests of the
    shared scripts sit under <package>/tests/skills/<skill>/scripts, which APM does not install.

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
    Each test file measures the scripts and modules it tests (tools/PesterCoverage.psm1): those in its
    own folder, or for a test under <package>/tests/skills/<skill>/scripts those in the .apm folder of
    the skill. A
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
    Run only the test files that the change can reach, against -Base, with the working tree and new
    files included. This is the quick run of a build loop; the pull request build runs every file.
    A changed <Name>.Tests.ps1 runs itself. A changed <Name>.ps1 under <package>/.apm/skills/<skill>/scripts
    runs the <Name>.Tests.ps1 in <package>/tests/skills/<skill>/scripts, and any other changed <Name>.ps1
    runs the <Name>.Tests.ps1 next to it; a changed script with no such test file runs every test file.
    A changed module (.psm1) or data file (such as JSON or YAML) runs the tests of every script and test
    that names it, and a module follows on through the scripts and modules that import it. A change
    under core/ or packs/ also runs SharedWiring.Tests.ps1. A page, a file a tool writes (apm.lock.yaml,
    sync-manifest.json, skill-catalog.json, gate-catalog.md), a copy under .claude/ and an apm.yml that
    changes only its version map to no test. When nothing maps, no test runs and the run exits 3 (not
    applicable). Every test file runs when this runner changed or git cannot read the change.

.PARAMETER ChangedOutsideCi
    Act as -Changed outside GitHub Actions, and run every test file inside it (GITHUB_ACTIONS is true).
    commands.testChanged in aisdlc.json uses it, so a scoped pre-flight runs only the reached tests.

.PARAMETER Base
    The ref that -Changed compares with, through the merge base. Defaults to AISDLC_CHANGE_BASE when it is
    a commit in the history of HEAD (the last green pre-flight), else to origin/<github.trunk> from
    aisdlc.json (Get-AiSdlcMainBranch in AiSdlcConfig.psm1), which is origin/main unless the repository
    names another trunk.

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
    [switch]$ChangedOutsideCi,
    [string]$Base,
    [switch]$ListOnly,
    [switch]$Ci
)

$ErrorActionPreference = 'Stop'
if ($ChangedOutsideCi -and $env:GITHUB_ACTIONS -ne 'true') { $Changed = [switch]$true }
if (-not $Path) { $Path = @('core', 'packs', 'tools') }
$coverageModule = Join-Path $PSScriptRoot 'PesterCoverage.psm1'
Import-Module $coverageModule -Force
$folders = foreach ($p in $Path) { if ([IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $RepoRoot $p } }
$missing = @($folders | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Container) })
if ($missing) { Write-Host "No such folder: $($missing -join ', ')" -ForegroundColor Red; exit 1 }

if ($Shard -gt $Shards) { Write-Host "-Shard $Shard is above -Shards $Shards." -ForegroundColor Red; exit 1 }
$all = @($folders | ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -Force -File -Filter '*.Tests.ps1' } | ForEach-Object FullName | Sort-Object -Unique)
if ($Changed) {
    if (-not $Base -and $env:AISDLC_CHANGE_BASE) {
        $candidate = [string]$env:AISDLC_CHANGE_BASE
        git -C $RepoRoot merge-base --is-ancestor $candidate HEAD *>$null
        if ($candidate -match '^[0-9a-f]{40}$' -and $LASTEXITCODE -eq 0) { $Base = $candidate }
        else { Write-Host 'AISDLC_CHANGE_BASE is not a commit in the history of HEAD, so -Changed starts at the merge base.' -ForegroundColor DarkGray }
    }
    if (-not $Base) {
        Import-Module (Join-Path $PSScriptRoot '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' 'AiSdlcConfig.psm1') -Force
        $Base = Get-AiSdlcMainBranch -RepoRoot $RepoRoot
    }
    $runAll = $null
    $picked = [System.Collections.Generic.List[string]]::new()
    $wiringTest = [IO.Path]::GetFullPath((Join-Path $RepoRoot 'core/tests/skills/ai-sdlc-gates/scripts/SharedWiring.Tests.ps1'))
    $packageScope = (Test-Path -LiteralPath $wiringTest) -and [bool]@($folders | Where-Object { (Split-Path -Leaf ([IO.Path]::GetFullPath($_).TrimEnd([char]92, [char]47))) -in 'core', 'packs' })
    $mergeBase = [string](git -C $RepoRoot merge-base $Base HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $mergeBase.Trim()) { $runAll = "git finds no merge base with $Base" }
    else {
        $mergeBase = $mergeBase.Trim()
        $changedPaths = @(git -C $RepoRoot diff --name-only $mergeBase)
        if ($LASTEXITCODE -ne 0) { $runAll = 'git cannot list the changed files' }
        $changedPaths += @(git -C $RepoRoot ls-files --others --exclude-standard)
        if ($LASTEXITCODE -ne 0) { $runAll = 'git cannot list the untracked files' }
        $roots = @($folders | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar })
        # The scripts and tests that name a file read it: a module, a data file or another script.
        # The map follows a module to the scripts that import it, and on to their tests.
        $script:sources = $null
        $script:sourcesFailed = $false
        $readers = {
            param([string]$Name)
            if ($null -eq $script:sources) {
                $script:sources = @(git -C $RepoRoot ls-files --cached --others --exclude-standard -- '*.ps1' '*.psm1' | Where-Object { $_ -and -not $_.StartsWith('.claude/') } |
                    ForEach-Object { [IO.Path]::GetFullPath((Join-Path $RepoRoot $_)) } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                    ForEach-Object { [pscustomobject]@{ Full = $_; Text = [IO.File]::ReadAllText($_) } })
                if ($LASTEXITCODE -ne 0) { $script:sourcesFailed = $true }
            }
            @($script:sources | Where-Object { $_.Text.Contains($Name, [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object Full)
        }
        $addReader = {
            param([string]$Full)
            $leaf = Split-Path -Leaf $Full
            if ($leaf -like '*.Tests.ps1') { $picked.Add($Full); return }
            if ($leaf -like '*.psm1' -and -not $seenModules.Contains($leaf)) { $modules.Enqueue($leaf) }
            $test = Get-TestFileOfScript -ScriptFile ($Full -replace '\.psm1$', '.ps1')
            if (Test-Path -LiteralPath $test) { $picked.Add($test) }
        }
        $modules = [System.Collections.Generic.Queue[string]]::new()
        $seenModules = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $generated = @('apm.lock.yaml', 'sync-manifest.json', 'skill-catalog.json', 'gate-catalog.md')
        foreach ($rel in ($changedPaths | Where-Object { $_ } | Sort-Object -Unique)) {
            if ($rel -match '^(core|packs)/' -and $packageScope) { $picked.Add($wiringTest) }
            $full = [IO.Path]::GetFullPath((Join-Path $RepoRoot $rel))
            $name = Split-Path -Leaf $full
            $inRoot = [bool]@($roots | Where-Object { $full.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) })
            if ($name -in 'Invoke-PesterParallel.ps1', 'PesterCoverage.psm1') { $runAll = "$rel is the test runner"; break }
            if ($name -like '*.psm1') {
                if (-not $rel.StartsWith('.claude/')) { & $addReader $full }
                continue
            }
            if ($name -like '*.ps1') {
                if (-not $inRoot) { continue }
                if ($name -like '*.Tests.ps1') { if (Test-Path -LiteralPath $full) { $picked.Add($full) }; continue }
                $test = Get-TestFileOfScript -ScriptFile $full
                if (Test-Path -LiteralPath $test) { $picked.Add($test) } else { $runAll = "$rel has no test file next to it"; break }
                continue
            }
            if ($name -like '*.md' -or $name -in $generated -or $rel.StartsWith('.claude/')) { continue }
            if ($name -eq 'apm.yml') {
                $diff = @(git -C $RepoRoot diff --unified=0 --no-color $mergeBase -- $rel)
                if ($LASTEXITCODE -ne 0) { $runAll = "git cannot read the change of $rel"; break }
                $lines = @($diff | Where-Object { $_ -match '^[+-]' -and $_ -notmatch '^(\+\+\+|---)' })
                if ($lines.Count -and -not @($lines | Where-Object { $_ -notmatch '^[+-]\s*version:' })) { continue }
            }
            foreach ($reader in (& $readers $name)) { & $addReader $reader }
        }
        while (-not $runAll -and $modules.Count -gt 0) {
            $module = $modules.Dequeue()
            if (-not $seenModules.Add($module)) { continue }
            foreach ($reader in (& $readers $module)) { & $addReader $reader }
        }
        if ($script:sourcesFailed) { $runAll = 'git cannot list the scripts that may read the change' }
        $inScope = { param($f) [bool]@($roots | Where-Object { $f.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }) }
        $kept = @($picked | Where-Object { (& $inScope $_) -or $_ -eq $wiringTest })
        $picked.Clear()
        foreach ($f in $kept) { $picked.Add($f) }
    }
    if ($runAll) {
        Write-Host "Running every test file, because $runAll."
        if ($packageScope) { $all = @(@($all) + $wiringTest | Sort-Object -Unique) }
    }
    else {
        $all = @($picked | ForEach-Object { [IO.Path]::GetFullPath($_) } | Sort-Object -Unique)
        if ($all.Count -eq 0) { Write-Host "Not applicable: no changed script maps to a test file against $Base, so no test runs."; exit 3 }
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
    # With -CoverageFile the process measures the scripts its test file tests, with the profiler, and
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
