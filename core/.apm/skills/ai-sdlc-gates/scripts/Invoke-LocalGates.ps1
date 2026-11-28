#Requires -Version 7
<#
.SYNOPSIS
    Runs the gates of the installed AI-SDLC packages and of the repository locally, and prints a single
    pass/fail summary.

.DESCRIPTION
    A developer convenience: one command to check a change against every gate before pushing, instead
    of waiting for CI. Blocking gates (structure, docs, house-style) fail this run on a violation;
    advisory gates are reported but never fail the local run, matching CI behaviour.

    A gate reports through its exit code: 0 passed, 1 found a violation, 2 could not check, 3 not
    applicable. Any other code counts as 1. The summary shows PASS, FAIL, ADVISORY, UNVERIFIED (exit 2),
    N/A (exit 3), SKIP (not run) and CRASHED (the script stopped with an error). A gate that exits 3 is
    counted apart, writes no annotation and never blocks.

    The gates run side by side, one thread per processor core, because no gate depends on another.
    The output of each gate is printed after the run, in the order of the list, so two gates never mix
    their lines.

    The runner does not hold a list of gates itself. Each installed package declares its gates in a
    gates.json file in one of its skills, for example ai-sdlc-gates/gates.json for the core. The runner
    reads every <SkillsRoot>/*/gates.json and runs the gates of the core and of each pack that
    apm.yml lists. A pack that is installed but not listed runs no gate, and a repository with no
    .NET solution never runs a .NET gate. The repository's own gates come from "repoGates" in aisdlc.json.

    A gates.json entry names the script relative to its skill folder:

        { "package": "core", "gates": [
            { "name": "Docs hold no em-dash characters", "script": "scripts/Check-DocEmDashes.ps1",
              "clause": "C06", "mode": "Blocking", "args": { },
              "checks": "It reads the docs. It finds the em-dash character. Exit 2 means no doc layer exists, and exit 3 means no page.",
              "fix": "Replace each em-dash with a comma or a colon." } ] }

    The name is a short statement of what passes. It holds no clause, no owner prefix and no note in
    brackets, and it is unique among all gates, because the runner matches a result to its gate by name.
    A name used twice fails both entries as a blocking failure. The clause lives only in "clause": a core
    clause such as C06, a pack clause such as DOTNET-01, or AI-SDLC for a rule of the framework that no
    clause holds. The run header shows it after the name.

    "checks" and "fix" are required. A missing or empty value fails that gate as a blocking failure that
    names the field, and the gate is not run. "checks" is 2 to 4 short sentences: what the gate checks,
    the main thing it does not check, and what exit 2 and 3 mean for it. "fix" is one sentence. -List
    prints "checks" under each gate, and a run prints it before the output of a gate that failed, could
    not check or stopped. references/gate-catalog.md in this skill lists every gate of every package with
    both texts.

    A "repoGates" entry has the same fields, with the script relative to the repository root. An entry
    with "requires": "CoverageFile" runs only when -CoverageFile is passed, and gets it as an argument.

    "mode" is Blocking, Advisory or Off, in any case, and a missing mode means Blocking. An Off gate is
    checked like any entry, then not run: the summary shows it as OFF, it never fails the run, also when
    its script is missing, and -List says it runs nowhere. Any other mode is not run and fails the run
    as a blocking failure that names the value, so a typo never passes by being skipped.

    A repository can set the mode of a shared gate in "gateModes" in its own aisdlc.json, an object of
    gate names and modes: { "gateModes": { "Docs hold no em-dash characters": "Advisory" } }. The name
    matches in any case. A repository gate sets its mode in its own repoGates entry. The summary has a
    Source column that says where the mode comes from: package, or aisdlc.json; -List prints it on a
    "mode from:" line. A gateModes that sets a gate weaker than its package mode (Blocking, then
    Advisory, then Off) raises one warning for each such gate. The secret scan (Test-GitleaksBaseline.ps1)
    the private-terms gate (Check-PrivateTerms.ps1) and the sync manifest check (Check-SyncManifest.ps1)
    always run Blocking, whatever gateModes or a package entry says.

    A gateModes that cannot be used fails the run with one row, aisdlc.json gateModes, also with
    -BlockingOnly, and then no key of gateModes is used: a name that no shared gate that runs has, the
    name of a repository gate, a gate of a pack that apm.yml does not list, or a gateModes that is not
    an object. A value that is not allowed fails that gate, and the gate is not run.

    "inputs" is an optional list of path globs from the repository root, such as "**/*.md". A local run
    then runs the gate only when the change touches a file that matches one of them, or a file in the
    skill folder of the gate script (the tool folder for a repository gate). The change is what the
    branch committed since the merge base with origin/<github.trunk>, with the staged, edited and new
    files. When AISDLC_CHANGE_BASE names a commit, the change starts there instead; Invoke-Preflight.ps1
    sets it to the commit of the last green pre-flight. Every gate runs when the change deletes or moves
    a file, when it touches aisdlc.json, a gates.json or the skill folder of this runner, and when git
    cannot read the change. The files a tool writes (sync-manifest.json, skill-catalog.json and
    gate-catalog.md) do not count for the skill folder rules, because a gate without inputs checks them.
    A gate without "inputs" always runs. GitHub Actions (GITHUB_ACTIONS is true) and -All run every gate.
    A gate that did not run shows NOT TOUCHED: it checked nothing and never blocks. An "inputs" value that
    is not a list of one or more non-empty strings fails that gate as a blocking failure. ADR 0020 in
    AI.SDLC records why a local run checks only what the change touches.

    When AISDLC_PUSHED_COMMITS names commits, as the pre-push hook sets it, a gate counts as Off only
    when each of those commits holds the same aisdlc.json and gates.json files as the working tree, and
    git shows no uncommitted change to them. Otherwise an Off gate runs in its package mode, so an edit
    to Off counts only once it is committed and pushed.

    A gates.json can also name three hooks for the core scripts, each relative to its skill folder.
    The gate list may then be empty, for a package that only needs a hook:

        "setup": "scripts/Initialize-Dotnet.ps1"
            Initialize-AiSdlc.ps1 runs it for each package that runs.
        "preflight": "scripts/Invoke-DotnetPreflight.ps1"
            Invoke-Preflight.ps1 runs it for each package that runs, and folds its result rows into
            the same report and receipt decision.
        "postEdit": { "extensions": [".cs", ".razor"], "script": "scripts/Invoke-DotnetPostEdit.ps1" }
            Invoke-PostEditCheck.ps1 runs it for an edited file with one of those extensions.

    With -IncludeToolTests the runner runs the Pester tests in the scripts folder of every package
    that runs, and in the folder of each repository gate. An installed package holds no tests (ADR
    0015), so only a test consumer that tools/Test-Consumers.ps1 set up finds package tests there.

    Where a gate runs follows from its mode. The pre-push git hook runs the Blocking gates
    (-BlockingOnly), unless a passing pre-flight receipt covers the tip commit of each pushed ref. The
    shared pull request action (assets/actions/ai-sdlc-pr) runs every gate. A local run runs every gate
    whose inputs the change touches, and every gate with -All. An Advisory gate reports but never fails
    either one. -List prints this for each gate. A
    repository gate that runs Pester tests can use Invoke-PesterGate.ps1 from this folder as its script.

    In GitHub Actions (GITHUB_ACTIONS is true) the runner reports each gate the way Invoke-Gate.ps1
    does, through GateAnnotation.psm1: an error for a Blocking gate that failed, stopped or could not
    check (exit 2), and a warning for an Advisory gate that found issues, stopped or could not check.
    A blocking gate that could not check fails the job, because it proved nothing. In a local run the
    same gate is a warning (UNVERIFIED) and the run exits 0, because a missing token on a laptop is not
    a fault in the change. The runner also adds the summary table to the job summary
    ($GITHUB_STEP_SUMMARY). The result is the exit code: 1 when a Blocking gate failed, else 0. A
    Blocking gate script that stops with an error fails the run as a fault in the gate, in a local run
    too, instead of stopping the runner. An Advisory gate script that stops with an error is a warning.

.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from the current location.

.PARAMETER SkillsRoot
    Where the packages are installed. Defaults to <RepoRoot>/.claude/skills.

.PARAMETER CoverageFile
    Optional path to a merged coverage report, for the gates that need one.

.PARAMETER IncludeToolTests
    Also run the Pester tests next to the gate scripts of every package that runs. An installed package
    has none; tools/Test-Consumers.ps1 copies them in.

.PARAMETER SkipTests
    Leave out the gates that run Pester tests: a gate whose script is Invoke-PesterGate.ps1 or
    Invoke-PesterParallel.ps1. The summary lists them as SKIP. wrap-up uses it for its quick check,
    because the pre-flight runs those tests on the commit.

.PARAMETER SkipScript
    Leave out the gates whose script file has one of these names, such as Check-LocalPackages.ps1. The
    name is the file name only, with no folder, and the match ignores case. A comma-separated value
    counts as several names. The summary lists each as SKIP. A caller uses it when a gate cannot hold in
    its setup, and says why.

.PARAMETER All
    Run every gate, also a gate whose inputs the change does not touch. GitHub Actions always does.

.PARAMETER BlockingOnly
    Run only the blocking gates, as the pre-push hook does. A gate entry that is not valid stays in the
    run whatever its mode, also an Advisory entry without a checks or fix text, so the push fails on it.

.PARAMETER List
    Print the gates that would run, with their package, mode and clause, what each one checks and where
    each one runs (pre-push, pull request, local run), and run none. It also lists a gate that needs
    -CoverageFile.

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1 -IncludeToolTests
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$SkillsRoot,
    [string]$CoverageFile,
    [switch]$IncludeToolTests,
    [switch]$BlockingOnly,
    [switch]$SkipTests,
    [string[]]$SkipScript,
    [switch]$All,
    [switch]$List
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'GateAnnotation.psm1') -Force

$config = Get-AiSdlcConfig -RepoRoot $RepoRoot -StartPath (Get-Location).Path
$RepoRoot = $config.repoRoot
if (-not $SkillsRoot) { $SkillsRoot = Join-Path $RepoRoot '.claude' 'skills' }
$inPipeline = $env:GITHUB_ACTIONS -eq 'true'

$gates = [System.Collections.Generic.List[object]]::new()
$testFolders = [System.Collections.Generic.List[string]]::new()

function Add-Gate {
    param($Entry, [string]$Package, [string]$Base)

    $needsCoverage = $Entry.requires -eq 'CoverageFile'
    if ($needsCoverage -and -not $CoverageFile -and -not $List) { return }
    $problems = [System.Collections.Generic.List[string]]::new()
    $usable = if ($gateModeSetting.Problem.Count -eq 0) { $gateModeSetting } else { $null }
    $resolved = Resolve-AiSdlcGateMode -Entry $Entry -Package $Package -Setting $usable
    $mode = $resolved.Mode
    if ($resolved.Problem) { $problems.Add($resolved.Problem) }
    $packageMode = if ($Package -eq 'repo') { $null } else { Get-AiSdlcGateMode -Entry $Entry }
    if ($mode -eq 'Off' -and -not $offCounts) {
        $mode = if ($packageMode -and $packageMode -ne 'Off') { $packageMode } else { 'Blocking' }
        $offNote = $true
    }
    else { $offNote = $false }
    $viaModes = if ($packageMode) { "aisdlc.json (gateModes), package mode $packageMode" } else { 'aisdlc.json (gateModes)' }
    $modeFrom = if ($Package -eq 'repo') { 'aisdlc.json (repoGates)' } elseif ($resolved.Source -eq 'aisdlc.json') { $viaModes } else { 'package' }
    $inputs = @()
    $hasInputs = if ($Entry -is [System.Collections.IDictionary]) { $Entry.Contains('inputs') } else { [bool]$Entry.PSObject.Properties['inputs'] }
    if ($hasInputs) {
        $list = @($Entry.inputs)
        $good = ($Entry.inputs -is [System.Collections.IList]) -and $list.Count -gt 0 -and @($list | Where-Object { -not ($_ -is [string]) -or [string]::IsNullOrWhiteSpace($_) }).Count -eq 0
        if ($good) { $inputs = @($list | ForEach-Object { $_.Trim() }) }
        else { $problems.Add(("inputs is '{0}', and it must be a list of one or more path globs" -f ($Entry.inputs | ConvertTo-Json -Compress -Depth 2))) }
    }
    foreach ($field in @('checks', 'fix')) {
        $value = $Entry.$field
        if (-not ($value -is [string]) -or [string]::IsNullOrWhiteSpace($value)) { $problems.Add(("{0} is missing or empty, and every gate needs a {0} text" -f $field)) }
    }
    $gateArgs = @{ RepoRoot = $RepoRoot }
    if ($Entry.args) { foreach ($key in $Entry.args.Keys) { $gateArgs[$key] = $Entry.args[$key] } }
    if ($needsCoverage -and $CoverageFile) { $gateArgs['CoverageFile'] = $CoverageFile }
    $gates.Add([pscustomobject]@{
            Name          = $Entry.name
            Package       = $Package
            Script        = Join-Path $Base $Entry.script
            Args          = $gateArgs
            Mode          = $mode
            PackageMode   = $packageMode
            Source        = $resolved.Source
            ModeFrom      = $modeFrom
            OffNotCounted = $offNote
            Clause        = if ($Entry.clause) { [string]$Entry.clause } else { $Package }
            Checks        = if ($Entry.checks -is [string]) { $Entry.checks.Trim() } else { '' }
            Inputs        = $inputs
            Home          = $(
                $scriptFull = Join-Path $Base $Entry.script
                if ((Split-Path -Leaf (Split-Path -Parent $scriptFull)) -eq 'scripts') { Split-Path -Parent (Split-Path -Parent $scriptFull) } else { Split-Path -Parent $scriptFull }
            )
            NeedsCoverage = $needsCoverage
            Invalid       = if ($problems.Count -gt 0) { ("Invalid gate entry '{0}': {1}. The gate was not run." -f $Entry.name, ($problems -join '; ')) } else { $null }
        })
}

function Get-GateStage {
    param($Gate)

    if ($Gate.Mode -eq 'Off') { return 'OFF: the gate runs nowhere; no hook, pull request action or local run starts it' }
    if ($Gate.NeedsCoverage) { return 'only with -CoverageFile: the dotnet pre-flight, and the pull request action with coverage-file' }
    if ($Gate.Mode -eq 'Blocking') { return 'pre-push, pull request, local run' }
    return 'pull request (as a warning), local run'
}

$manifests = @(Get-AiSdlcPackage -RepoRoot $RepoRoot -SkillsRoot $SkillsRoot -All)
$gateModeSetting = Get-AiSdlcGateModeSetting -Config $config -Package $manifests
$offCounts = $true
if ($env:AISDLC_PUSHED_COMMITS) {
    $status = @(git -C $RepoRoot status --porcelain 2>$null)
    if ($LASTEXITCODE -ne 0 -or @($status | Where-Object { $_ -match '(?:^|[\s"/>])(?:\.claude/skills/.*gates\.json|aisdlc\.json)' }).Count -gt 0) { $offCounts = $false }
    foreach ($sha in @($env:AISDLC_PUSHED_COMMITS -split '[,\s]+' | Where-Object { $_ -and $_ -notmatch '^0+$' })) {
        git -C $RepoRoot diff --quiet $sha -- aisdlc.json ':(glob).claude/skills/**/gates.json' 2>$null
        if ($LASTEXITCODE -ne 0) { $offCounts = $false }
    }
    $global:LASTEXITCODE = 0
}

foreach ($manifest in @($manifests | Where-Object { $_.Runs })) {
    foreach ($entry in $manifest.Gates) { Add-Gate -Entry $entry -Package $manifest.Package -Base $manifest.SkillFolder }
    $scripts = Join-Path $manifest.SkillFolder 'scripts'
    if (Test-Path -LiteralPath $scripts) { $testFolders.Add([IO.Path]::GetFullPath($scripts)) }
}

foreach ($entry in @($config.repoGates)) {
    if (-not $entry) { continue }
    Add-Gate -Entry $entry -Package 'repo' -Base $RepoRoot
    $folder = [IO.Path]::GetFullPath((Split-Path (Join-Path $RepoRoot $entry.script) -Parent))
    if ((Test-Path -LiteralPath $folder) -and -not $testFolders.Contains($folder)) { $testFolders.Add($folder) }
}

if ($gateModeSetting.Problem.Count -gt 0) {
    $gates.Add([pscustomobject]@{
            Name          = 'aisdlc.json gateModes'
            Package       = 'repo'
            Script        = Join-Path $RepoRoot 'aisdlc.json'
            Args          = @{}
            Mode          = 'Blocking'
            PackageMode   = $null
            Source        = 'aisdlc.json'
            ModeFrom      = 'aisdlc.json (gateModes)'
            OffNotCounted = $false
            Clause        = 'AI-SDLC'
            Checks        = ''
            Inputs        = @()
            Home          = $RepoRoot
            NeedsCoverage = $false
            Invalid       = ("Invalid gateModes in aisdlc.json: {0}. No key of gateModes was used." -f (@($gateModeSetting.Problem | ForEach-Object { $_.Text }) -join '; '))
        })
}

$byName = $gates | Group-Object Name | Where-Object Count -GT 1
foreach ($duplicate in $byName) {
    foreach ($g in $duplicate.Group) {
        $note = ("Invalid gate entry '{0}': the name is used by {1} gates, and the runner matches a result to its gate by name, so every name must be unique. The gate was not run." -f $g.Name, $duplicate.Count)
        $g.Invalid = if ($g.Invalid) { $g.Invalid + ' ' + $note } else { $note }
    }
}

if ($BlockingOnly) {
    $kept = @($gates | Where-Object { $_.Mode -eq 'Blocking' -or $_.Invalid })
    $gates.Clear()
    foreach ($g in $kept) { $gates.Add($g) }
}

if ($List) {
    Write-Host 'Where a gate runs: the pre-push git hook runs the Blocking gates (Invoke-LocalGates.ps1 -BlockingOnly).'
    Write-Host 'The pull request action (ai-sdlc-pr) and a local run run all of them; an Advisory gate never fails either one.'
    Write-Host ''
    foreach ($g in $gates) {
        Write-Host ("{0,-13} {1,-9} {2,-12} {3}" -f $g.Package, $g.Mode, $g.Clause, $g.Name)
        Write-Host ("{0,-13} runs in: {1}" -f '', (Get-GateStage -Gate $g))
        Write-Host ("{0,-13} mode from: {1}" -f '', $g.ModeFrom)
        if ($g.Inputs.Count -gt 0) { Write-Host ("{0,-13} runs when a change touches: {1}, or its own skill or tool folder; always with -All and in GitHub Actions" -f '', ($g.Inputs -join ', ')) }
        if ($g.Checks) { Write-Host ("{0,-13} checks: {1}" -f '', $g.Checks) }
        if ($g.Invalid) { Write-Host ("{0,-13} {1}" -f '', $g.Invalid) }
    }
    Write-Host ''
    Write-Host ("{0} gate(s) from {1} package manifest(s), apm.yml and aisdlc.json." -f $gates.Count, $manifests.Count)
    exit 0
}

$modeRank = @{ Blocking = 2; Advisory = 1; Off = 0 }
foreach ($g in @($gates | Where-Object { -not $_.Invalid -and $_.Source -eq 'aisdlc.json' -and $_.PackageMode -and $modeRank[$_.Mode] -lt $modeRank[$_.PackageMode] })) {
    $text = ("the gate '{0}' has the package mode {1}, but gateModes in aisdlc.json sets it to {2}, so it checks less than the package intends." -f $g.Name, $g.PackageMode, $g.Mode)
    if ($inPipeline) { Write-GateCommand -Type warning -Title $g.Name -Message ("AI-SDLC: {0}" -f $text) }
    else { Write-Host ("AI-SDLC: {0}" -f $text) -ForegroundColor Yellow }
}
foreach ($g in @($gates | Where-Object { $_.OffNotCounted })) {
    Write-Host ("AI-SDLC: the gate '{0}' is Off in the working tree, but not in every pushed commit, so it runs as {1}." -f $g.Name, $g.Mode) -ForegroundColor Yellow
}

$results = [System.Collections.Generic.List[object]]::new()
$off = @($gates | Where-Object { -not $_.Invalid -and $_.Mode -eq 'Off' })
$kept = @($gates | Where-Object { $_.Invalid -or $_.Mode -ne 'Off' })
$gates.Clear()
foreach ($g in $kept) { $gates.Add($g) }
$testGates = @('Invoke-PesterGate.ps1', 'Invoke-PesterParallel.ps1')
$skipped = @()
if ($SkipTests) {
    $skipped = @($gates | Where-Object { -not $_.Invalid -and (Split-Path -Leaf $_.Script) -in $testGates })
    $kept = @($gates | Where-Object { $_.Invalid -or (Split-Path -Leaf $_.Script) -notin $testGates })
    $gates.Clear()
    foreach ($g in $kept) { $gates.Add($g) }
}
if ($SkipScript) {
    $names = @($SkipScript | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $skipped += @($gates | Where-Object { -not $_.Invalid -and (Split-Path -Leaf $_.Script) -in $names })
    $kept = @($gates | Where-Object { $_.Invalid -or (Split-Path -Leaf $_.Script) -notin $names })
    $gates.Clear()
    foreach ($g in $kept) { $gates.Add($g) }
}

$untouched = @()
$scoped = @($gates | Where-Object { -not $_.Invalid -and $_.Inputs.Count -gt 0 })
if (-not $All -and -not $inPipeline -and $scoped.Count -gt 0) {
    Import-Module (Join-Path $PSScriptRoot 'ChangedFiles.psm1') -Force
    $changeBase = Get-AiSdlcChangeBase -RepoRoot $RepoRoot
    if ($changeBase.Reason) { Write-Host ("The change starts at the merge base, because {0}." -f $changeBase.Reason) -ForegroundColor DarkGray }
    $baseRef = if ($changeBase.Base) { $changeBase.Base } else { Get-AiSdlcMainBranch -RepoRoot $RepoRoot }
    $change = Get-AiSdlcChange -RepoRoot $RepoRoot -BaseRef $baseRef -IncludeWorkingTree
    $relativeTo = { param([string]$Full) [IO.Path]::GetRelativePath($RepoRoot, $Full).Replace('\', '/').TrimEnd('/') + '/' }
    $runnerHome = & $relativeTo (Split-Path -Parent $PSScriptRoot)
    $everything = @('aisdlc.json', '**/gates.json')
    $written = @('sync-manifest.json', 'skill-catalog.json', 'gate-catalog.md')
    $handMade = @($change.Files | Where-Object { (Split-Path -Leaf $_) -notin $written })
    $why = if (-not $change.Readable) { "the change cannot be read ($($change.Reason))" }
    elseif (@($change.Deleted).Count -gt 0) { 'the change deletes or moves a file, which any gate may refer to' }
    elseif (@($handMade | Where-Object { (Test-AiSdlcPathGlob -Path $_ -Glob $everything) -or $_.StartsWith($runnerHome, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { 'the change touches the gate setup: aisdlc.json, a gates.json or the skill folder of this runner' }
    else { $null }
    if ($why) { Write-Host ("Every gate runs, because {0}." -f $why) -ForegroundColor DarkGray }
    else {
        $untouched = @($scoped | Where-Object {
                $g = $_
                $gateHome = & $relativeTo $g.Home
                @($change.Files | Where-Object { (Test-AiSdlcPathGlob -Path $_ -Glob $g.Inputs) -or ($_ -in $handMade -and $_.StartsWith($gateHome, [StringComparison]::OrdinalIgnoreCase)) }).Count -eq 0
            })
        $kept = @($gates | Where-Object { $_ -notin $untouched })
        $gates.Clear()
        foreach ($g in $kept) { $gates.Add($g) }
    }
}

$runs = @($gates | Where-Object { -not $_.Invalid } | ForEach-Object -ThrottleLimit ([Math]::Max(1, [Environment]::ProcessorCount)) -Parallel {
        $ErrorActionPreference = 'Stop'
        $g = $_
        $run = [pscustomobject]@{ Name = $g.Name; Lines = [System.Collections.Generic.List[object]]::new(); Code = 0; Error = $null }
        if (Test-Path -LiteralPath $g.Script -PathType Leaf) {
            $gateArgs = $g.Args
            $global:LASTEXITCODE = 0
            try {
                & $g.Script @gateArgs *>&1 | ForEach-Object { $run.Lines.Add($_) }
                $run.Code = $LASTEXITCODE
            }
            catch { $run.Error = $_ }
        }
        $run
    })

foreach ($g in $gates) {
    Write-Host ""
    Write-Host ("===== {0} ({1}, {2}, {3}) =====" -f $g.Name, $g.Package, $g.Mode, $g.Clause) -ForegroundColor Cyan
    if ($g.Invalid) {
        Write-Host $g.Invalid -ForegroundColor Red
        if ($inPipeline) { Write-GateCommand -Type error -Title $g.Name -Message ("AI-SDLC: {0}" -f $g.Invalid) }
        $results.Add([pscustomobject]@{ Gate = $g.Name; Mode = 'Blocking'; Status = 'FAIL'; Source = $g.Source })
        continue
    }
    $howToRepeat = Get-GateRepeatCommand -Script $g.Script -RepoRoot $RepoRoot
    $run = @($runs | Where-Object Name -EQ $g.Name)[0]
    $aboutGate = ("What this gate checks: {0}" -f $g.Checks)
    if (-not (Test-Path -LiteralPath $g.Script -PathType Leaf)) {
        Write-Host $aboutGate -ForegroundColor DarkGray
        Write-Host ("Could not check: the gate script {0} does not exist." -f $g.Script) -ForegroundColor Yellow
        if ($inPipeline) {
            Write-GateAnnotation -Lines @("The gate script $($g.Script) does not exist; install the package that ships it.") -ExitCode 2 -Clause $g.Clause -What $g.Name -Mode $g.Mode -HowToRepeat $howToRepeat | Out-Null
        }
        $results.Add([pscustomobject]@{ Gate = $g.Name; Mode = $g.Mode; Status = 'UNVERIFIED'; Source = $g.Source })
        continue
    }
    $lines = @($run.Lines)
    if ($run.Error -or ($run.Code -ne 0 -and $run.Code -ne 3)) { Write-Host $aboutGate -ForegroundColor DarkGray }
    $lines | ForEach-Object { Write-Host $_ }
    if ($run.Error) {
        Write-Host ("The gate script stopped before it could report, so nothing was checked: {0}" -f $run.Error.Exception.Message) -ForegroundColor Red
        if ($inPipeline) { Write-GateCrashAnnotation -Clause $g.Clause -Script $g.Script -ErrorRecord $run.Error -HowToRepeat $howToRepeat -Mode $g.Mode | Out-Null }
        $results.Add([pscustomobject]@{ Gate = $g.Name; Mode = $g.Mode; Status = 'CRASHED'; Source = $g.Source })
        continue
    }
    $code = $run.Code
    $status = if ($code -eq 0) { 'PASS' } elseif ($code -eq 2) { 'UNVERIFIED' } elseif ($code -eq 3) { 'N/A' } elseif ($g.Mode -eq 'Advisory') { 'ADVISORY' } else { 'FAIL' }
    if ($inPipeline) { Write-GateAnnotation -Lines $lines -ExitCode $code -Clause $g.Clause -What $g.Name -Mode $g.Mode -HowToRepeat $howToRepeat | Out-Null }
    $results.Add([pscustomobject]@{ Gate = $g.Name; Mode = $g.Mode; Status = $status; Source = $g.Source })
}

foreach ($g in $skipped) { $results.Add([pscustomobject]@{ Gate = $g.Name; Mode = $g.Mode; Status = 'SKIP'; Source = $g.Source }) }
foreach ($g in $untouched) { $results.Add([pscustomobject]@{ Gate = $g.Name; Mode = $g.Mode; Status = 'NOT TOUCHED'; Source = $g.Source }) }
foreach ($g in $off) { $results.Add([pscustomobject]@{ Gate = $g.Name; Mode = 'Off'; Status = 'OFF'; Source = $g.Source }) }

$toolTestsFailed = $false
if ($IncludeToolTests -and $testFolders.Count -gt 0) {
    Write-Host ""
    Write-Host "===== Gate-script Pester tests =====" -ForegroundColor Cyan
    $pester = Invoke-Pester -Path $testFolders.ToArray() -PassThru -Output Detailed
    if ($pester.FailedCount -gt 0) { $toolTestsFailed = $true }
    $results.Add([pscustomobject]@{ Gate = "Gate-script tests ($($pester.PassedCount)/$($pester.TotalCount))"; Mode = 'Blocking'; Status = $(if ($toolTestsFailed) { 'FAIL' } else { 'PASS' }); Source = 'package' })
    if ($toolTestsFailed -and $inPipeline) { Write-GateCommand -Type error -Title 'Gate-script tests' -Message ("AI-SDLC: {0} of the {1} gate-script tests failed." -f $pester.FailedCount, $pester.TotalCount) }
}

Write-Host ""
Write-Host "===== Summary =====" -ForegroundColor Cyan
$results | Format-Table -AutoSize | Out-String -Width 4096 | Write-Host
if ($inPipeline -and $env:GITHUB_STEP_SUMMARY) {
    $table = @('### AI-SDLC gates', '', '| Gate | Mode | Status | Source |', '| --- | --- | --- | --- |') +
        @($results | ForEach-Object { '| {0} | {1} | {2} | {3} |' -f ($_.Gate -replace '\|', '/'), $_.Mode, $_.Status, $_.Source })
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value (($table + '') -join "`n") -Encoding utf8
}

$blockingFailures = @($results | Where-Object {
        $_.Status -eq 'FAIL' -or
        ($_.Status -eq 'CRASHED' -and $_.Mode -eq 'Blocking') -or
        ($_.Status -eq 'UNVERIFIED' -and $_.Mode -eq 'Blocking' -and $inPipeline)
    })
$unverified = @($results | Where-Object { $_.Status -eq 'UNVERIFIED' })
$notApplicable = @($results | Where-Object { $_.Status -eq 'N/A' })
$advisoryCrashes = @($results | Where-Object { $_.Status -eq 'CRASHED' -and $_.Mode -ne 'Blocking' })

if ($notApplicable.Count -gt 0) {
    Write-Host ("{0} gate(s) not applicable here (exit 3). They checked nothing and never block." -f $notApplicable.Count)
}
if ($untouched.Count -gt 0) {
    Write-Host ("{0} gate(s) did not run, because the change touches none of their inputs (NOT TOUCHED). They checked nothing; the pull request action runs them, and -All runs them here." -f $untouched.Count)
}
if ($off.Count -gt 0) {
    Write-Host ("{0} gate(s) are Off (OFF). They did not run and checked nothing." -f $off.Count)
}

if ($blockingFailures.Count -gt 0) {
    $crashed = @($blockingFailures | Where-Object { $_.Status -eq 'CRASHED' }).Count
    $couldNotCheck = @($blockingFailures | Where-Object { $_.Status -eq 'UNVERIFIED' }).Count
    $detail = if ($crashed) { " ($crashed of them stopped before they could report)" } else { '' }
    Write-Host ("{0} blocking gate(s) failed{1}." -f $blockingFailures.Count, $detail) -ForegroundColor Red
    if ($couldNotCheck) {
        Write-Host ("{0} of them could not check (exit 2). In a pull request build a blocking gate that could not check fails the job." -f $couldNotCheck) -ForegroundColor Red
    }
    exit 1
}

if ($unverified.Count -gt 0) {
    $where = if ($inPipeline) { 'They are warnings because they are advisory.' } else { 'Run locally they are warnings; in a pull request build a blocking gate that could not check fails the job.' }
    Write-Host ("{0} gate(s) could not check at all (exit 2). That is neither a pass nor a violation; read the reason each one printed. {1}" -f $unverified.Count, $where) -ForegroundColor Yellow
}

$advisories = @($results | Where-Object { $_.Status -eq 'ADVISORY' })
if ($advisories.Count -gt 0) {
    Write-Host ("All blocking gates pass. {0} advisory gate(s) reported issues (not blocking)." -f $advisories.Count) -ForegroundColor Yellow
}
elseif ($unverified.Count -eq 0 -and $advisoryCrashes.Count -eq 0) {
    Write-Host "All gates pass." -ForegroundColor Green
}
if ($advisoryCrashes.Count -gt 0) {
    Write-Host ("{0} advisory gate(s) stopped before they could report. They are warnings; nothing was checked." -f $advisoryCrashes.Count) -ForegroundColor Yellow
}
exit 0
