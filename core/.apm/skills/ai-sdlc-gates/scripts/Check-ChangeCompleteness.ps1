#Requires -Version 7
<#
.SYNOPSIS
    Gate: a change that alters behaviour also moves its tests and its documentation.
.DESCRIPTION
    The deterministic half of the wrap-up flow. It answers the only question that needs no
    judgement, "did source change while tests and docs stood still", so a model is never spent on
    detection and the answer is the same for every tool and every developer.

    The changed-file set holds the commits since the base ref, the staged and unstaged edits and the
    new files git does not ignore. wrap-up runs this check before it commits, so a new page counts.

    Two checks, both computed from that changed-file set:

      1. TESTS. A changed file under a source root that carries behaviour needs a changed test file
         in the test folder that mirrors it. A test change somewhere else does not count. The rule
         holds per area: a change in two projects needs a test change in both test projects. It is
         deliberately NOT a mirrored-test-per-file rule: a DTO, an interface, a record, generated code
         and application startup legitimately have no test of their own, and a gate that demanded one
         would fire on dozens of correct files and be answered with empty tests. Whether the tests that
         exist are good enough is a coverage question, which Check-Coverage.ps1 (C04) and the
         SonarCloud quality gate already answer.

         How a source file maps to its test folder:
           .NET layout      <sourceRoot>/<Project>/... maps to <testRoot>/<Project>.Tests/, or to a
                            project with one word before Tests, such as <Project>.IntegrationTests. A
                            file directly under the source root maps to any folder under the test root.
           Package layout   <package>/.apm/<path>/<file> maps to <package>/tests/<path>/, where
                            <package> is a source root or a folder right under one, such as core or
                            packs/<name>. This is the layout of ADR 0015.
         A test file is a file with a source extension in the mirror folder, outside bin and obj. A
         file under a test folder never carries behaviour.

      2. DOCUMENTATION. If a source area changed and neither its mapped documentation area nor an
         ADR that names the area moved, that is reported. An ADR is a changed .md file in
         paths.adrFolder, other than README.md and 0000-template.md, that exists on disk. It names an
         area when a path in it overlaps the area: every token with a slash counts, in the front
         matter and in the body. A named path overlaps an area when it starts with the source folder or
         a doc path of the area, or when it is a parent folder of one of them. So an ADR clears the
         areas it is about, and no other area.

    A file that the change deleted needs no test, because nothing is left to test. It still needs its
    documentation, because the page of its area may describe it. So a change that only deletes source
    files gets a DOCS finding when the doc area did not move and no ADR names the area.

    WAIVERS. A commit since the base may end with a trailer that git's own trailer parser reads:
    No-Test: <reason>: <why> or No-Docs: <reason>: <why>. The key matches without regard to case, and the
    reasons are lowercase from a closed list: no-behaviour-change (both trailers), existing-tests-cover-it
    (No-Test only) and no-doc-reader-affected (No-Docs only). An unknown reason, an empty why, a reason on
    the wrong trailer or a value with a control character (below 0x20 but tab, 0x7F to 0x9F, U+2028 or
    U+2029) clears nothing. The check reads each commit with its changed paths in one git log call,
    as raw UTF-8 split only on NUL, so a lone carriage return or a U+2028 in a trailer reaches the
    control character test as it is and never starts a second trailer.

    A waiver clears a finding only for the files of its own commit. A changed file is waived for a kind
    when at least one commit since the base changes it and every such commit carries a valid trailer of
    that kind. A later commit to the same file with no trailer makes it a finding again. A file that no
    commit changed, or that has an edit that is not committed yet, is never waived. The log is read with
    rename detection and the old names of a file are followed back, so a pure rename commit with a
    trailer cannot waive a file whose earlier commit has none. A merge commit is read with --cc, so a clean
    merge lists no file.

    The output says "Waiver used" with the commit and the files it cleared, "Waived:" with the text of
    each finding that is gone, "Waiver not used" with the cause for each trailer that is not valid, and
    "Waiver not needed" for a valid trailer that cleared no file of a finding. The printed why stops at
    200 characters and a control character prints as ?. When the caller passes the files (-ChangedFiles or
    CHANGED_FILES) there is no base to read commits from, so no trailer applies. A reviewer judges each
    reason; the check only reads its shape. Only wrap-up writes a trailer.

    ADVISORY by default: it reports and returns 0. Pass -Strict to make it fail, which is what the
    pre-push hook and CI use once the team has seen the false-positive rate. Every finding waived gives 0.

    Exit codes follow the gate contract: 0 checked and nothing found, or every finding waived; 1 a
    finding under -Strict; 2 could not check: the change cannot be listed (no git, or no merge base
    with the base ref), or CHANGED_FILES is set and git cannot run or HEAD cannot be read, so a deleted
    file cannot be told from a changed one; 3 not applicable: no changed or deleted file carries
    behaviour, so a documentation-only or pipeline-only change is never blocked by it.
.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script. The source
    roots, the test root, the source file types and the map from source areas to doc areas come from
    paths.sourceRoots (a list) and paths.sourceRoot (one folder; both are read), paths.testRoot,
    paths.sourceExtensions and paths.sourceDocMap in aisdlc.json. With no source root configured,
    nothing counts as behaviour and the check is not applicable (exit 3).
.PARAMETER BaseRef
    The ref the change is measured against. Defaults to origin/<github.trunk> from aisdlc.json (Get-AiSdlcMainBranch), origin/main unless the repository names another trunk.
.PARAMETER ChangedFiles
    Explicit repo-relative paths, bypassing git. Used by the tests. Falls back to the newline-separated
    CHANGED_FILES environment variable, which the pipeline sets from the pull request diff, because a
    CI checkout has no base branch to diff against.
.PARAMETER Strict
    Report the finding through the exit code (1) instead of only printing it. The pre-push deny hook,
    Invoke-LocalGates and the CI step all pass it; whether a finding then blocks is decided by the
    caller, which for CI is Invoke-LocalGates.ps1 (through GateAnnotation.psm1) in Advisory or Blocking
    mode.
.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Check-ChangeCompleteness.ps1
.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Check-ChangeCompleteness.ps1 -Strict -BaseRef origin/main
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$BaseRef,
    [string[]]$ChangedFiles,
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ChangedFiles.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }
if (-not $BaseRef) { $BaseRef = Get-AiSdlcMainBranch -RepoRoot $RepoRoot }

$script:Config = Get-AiSdlcConfig -RepoRoot $RepoRoot
$script:SourceRoots = @(@($script:Config.paths['sourceRoots']) + @($script:Config.paths['sourceRoot']) | Where-Object { $_ } | ForEach-Object { ([string]$_).Replace('\', '/').Trim('/') } | Where-Object { $_ } | Select-Object -Unique)
$script:TestPrefix = if ($script:Config.paths.testRoot) { $script:Config.paths.testRoot.TrimEnd('/') + '/' } else { $null }
$script:SourceExtensions = @($script:Config.paths.sourceExtensions | Where-Object { $_ })
$script:DocPrefixes = @($script:Config.paths.docsRoots | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('/') + '/' })
$script:AdrPrefix = $script:Config.paths.adrFolder.TrimEnd('/') + '/'
$script:DocMap = @($script:Config.paths.sourceDocMap | Where-Object { $_ } | ForEach-Object { @{ Source = $_.source; Docs = @($_.docs) } })
$script:RootPattern = ($script:SourceRoots | ForEach-Object { [regex]::Escape($_) }) -join '|'
$script:PackageTestPattern = if ($script:RootPattern) { '^(?:' + $script:RootPattern + ')(?:/[^/]+)?/tests/' } else { $null }
$script:PackageSourcePattern = if ($script:RootPattern) { '^(?<pkg>(?:' + $script:RootPattern + ')(?:/[^/]+)?)/\.apm/(?<rel>.+)/[^/]+$' } else { $null }
# A path token: a run of name characters with at least one slash, not glued to a longer token.
$script:PathToken = '(?<![\w/.:@-])(?:\.{1,2}/)*[\w.@-]+(?:/[\w.@-]*)+'

$script:TestExempt = @(
    'Program.cs'
    'GlobalUsings.cs'
    '.Designer.cs'
    '.g.cs'
    '.razor.css'
)

$script:TestExemptFolders = @(
    '/Models/'
    '/Contracts/'
    '/Dtos/'
    '/Migrations/'
)

function Get-DirtyPath {
    param([string]$Root)

    $edited = @(& git -C $Root -c core.quotepath=off diff --name-only HEAD 2>$null)
    $new = @(& git -C $Root -c core.quotepath=off ls-files --others --exclude-standard 2>$null)
    $global:LASTEXITCODE = 0
    return @($edited + $new | Where-Object { $_ })
}

function Get-GitRaw {
    param([string]$Root, [string[]]$Argument)

    $info = [System.Diagnostics.ProcessStartInfo]::new('git')
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.UseShellExecute = $false
    $info.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    foreach ($item in (@('-C', $Root) + $Argument)) { $info.ArgumentList.Add($item) }
    $process = [System.Diagnostics.Process]::Start($info)
    $errors = $process.StandardError.ReadToEndAsync()
    $text = $process.StandardOutput.ReadToEnd()
    $process.WaitForExit()
    [void]$errors.Result
    if ($process.ExitCode -ne 0) { return $null }
    return $text
}

function ConvertTo-PrintableText {
    param([string]$Text, [int]$Max = 200)

    $clean = [regex]::Replace($Text, '[\x00-\x1F\x7F-\x9F  ]', '?')
    if ($clean.Length -gt $Max) { return $clean.Substring(0, $Max) + '...' }
    return $clean
}

function Get-WaiverTrailer {
    param([string]$Root, [string]$Base)

    $unreadable = { [pscustomobject]@{ Items = @(); Commits = @(); Renames = @{} } }
    if (-not $Base) { return & $unreadable }
    $listed = @(& git -C $Root rev-list "$Base..HEAD" 2>$null)
    if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0; return & $unreadable }
    $known = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($hash in $listed) { [void]$known.Add(([string]$hash).Trim()) }
    $raw = Get-GitRaw -Root $Root -Argument @('-c', 'core.quotepath=off', 'log', "$Base..HEAD", '--cc', '-M', '--name-status', '--encoding=UTF-8', '--format=%x00%H%x00%(trailers:key=No-Test,key=No-Docs,unfold)%x00')
    if ($null -eq $raw) { return & $unreadable }

    $parts = $raw -split [string][char]0
    $items = [System.Collections.Generic.List[object]]::new()
    $commits = [System.Collections.Generic.List[object]]::new()
    $renames = @{}
    for ($i = 1; $i + 2 -lt $parts.Count; $i += 3) {
        $hash = $parts[$i]
        if ($hash -cnotmatch '^[0-9a-f]{40}$' -or -not $known.Contains($hash)) { continue }
        $files = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($row in ($parts[$i + 2] -split '\n')) {
            $fields = $row.TrimEnd("`r") -split "`t"
            if ($fields.Count -lt 2) { continue }
            foreach ($path in $fields[1..($fields.Count - 1)]) {
                if ($path) { [void]$files.Add($path) }
            }
            if ($fields[0].StartsWith('R', [StringComparison]::Ordinal) -and $fields.Count -ge 3) {
                $current = $fields[$fields.Count - 1]
                if (-not $renames.ContainsKey($current)) { $renames[$current] = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal) }
                foreach ($old in $fields[1..($fields.Count - 2)]) { [void]$renames[$current].Add($old) }
            }
        }
        $valid = [System.Collections.Generic.List[string]]::new()
        foreach ($line in ($parts[$i + 1] -split '\r?\n')) {
            if ($line -notmatch '^(?<key>No-Test|No-Docs)\s*:\s*(?<value>.*)$') { continue }
            $kind = if ($Matches.key -ieq 'No-Test') { 'No-Test' } else { 'No-Docs' }
            $value = $Matches.value
            $colon = $value.IndexOf(':')
            $reason = if ($colon -lt 0) { $value.Trim() } else { $value.Substring(0, $colon).Trim() }
            $why = if ($colon -lt 0) { '' } else { $value.Substring($colon + 1).Trim() }

            $problem = $null
            if ($value -match '[\x00-\x08\x0A-\x1F\x7F-\x9F  ]') { $problem = 'it holds a control character' }
            else {
                switch -CaseSensitive ($reason) {
                    'no-behaviour-change' { }
                    'existing-tests-cover-it' { if ($kind -ne 'No-Test') { $problem = 'existing-tests-cover-it is for No-Test only' } }
                    'no-doc-reader-affected' { if ($kind -ne 'No-Docs') { $problem = 'no-doc-reader-affected is for No-Docs only' } }
                    default { $problem = 'the reason is not one of no-behaviour-change, existing-tests-cover-it (No-Test only) and no-doc-reader-affected (No-Docs only), in lowercase' }
                }
                if (-not $problem -and -not $why) { $problem = "it gives no why after the reason, as in $kind`: <reason>`: <why>" }
            }
            if (-not $problem) { $valid.Add($kind) }

            $shownReason = ConvertTo-PrintableText -Text $reason
            $shownWhy = ConvertTo-PrintableText -Text $why
            $items.Add([pscustomobject]@{
                    Kind    = $kind
                    Finding = if ($kind -ceq 'No-Test') { 'TESTS' } else { 'DOCS' }
                    Text    = if ($why) { "${kind}: ${shownReason}: $shownWhy" } else { "${kind}: $shownReason" }
                    Commit  = $hash.Substring(0, 12)
                    Files   = $files
                    Problem = $problem
                })
        }
        $commits.Add([pscustomobject]@{ Hash = $hash; Files = $files; Valid = $valid.ToArray() })
    }
    return [pscustomobject]@{ Items = $items.ToArray(); Commits = $commits.ToArray(); Renames = $renames }
}

function Get-PathAlias {
    param($Rename, [string]$Path)

    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $queue = [System.Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($Path)
    while ($queue.Count -gt 0) {
        $name = $queue.Dequeue()
        if (-not $seen.Add($name)) { continue }
        if ($Rename.ContainsKey($name)) {
            foreach ($old in $Rename[$name]) { $queue.Enqueue($old) }
        }
    }
    return , $seen
}

function Get-WaivedPath {
    param($Waiver, [string]$Kind, [string[]]$Path, [string[]]$Dirty = @())

    foreach ($item in $Path) {
        if ($item -cin $Dirty) { continue }
        $names = Get-PathAlias -Rename $Waiver.Renames -Path $item
        $touching = @($Waiver.Commits | Where-Object { $files = $_.Files; $names | Where-Object { $files.Contains($_) } })
        if ($touching.Count -gt 0 -and -not ($touching | Where-Object { $Kind -cnotin $_.Valid })) { $item }
    }
}

function Test-InTestFolder {
    param([string]$Path)

    if ($script:TestPrefix -and $Path.StartsWith($script:TestPrefix)) { return $true }
    return [bool]($script:PackageTestPattern -and $Path -cmatch $script:PackageTestPattern)
}

function Test-CarriesBehaviour {
    param([string]$Path)

    if (-not ($script:SourceRoots | Where-Object { $Path.StartsWith("$_/") })) { return $false }
    if (Test-InTestFolder $Path) { return $false }
    if (-not ($script:SourceExtensions | Where-Object { $Path.EndsWith($_) })) { return $false }

    foreach ($suffix in $script:TestExempt) {
        if ($Path.EndsWith($suffix)) { return $false }
    }
    foreach ($folder in $script:TestExemptFolders) {
        if ($Path.Contains($folder)) { return $false }
    }

    return $true
}

function Get-TestMirror {
    param([string]$Path)

    $package = if ($script:PackageSourcePattern) { [regex]::Match($Path, $script:PackageSourcePattern) } else { $null }
    if ($package -and $package.Success) {
        $area = "$($package.Groups['pkg'].Value)/tests/$($package.Groups['rel'].Value)/"
        return [pscustomobject]@{ Area = $area; Pattern = '^' + [regex]::Escape($area) }
    }
    if (-not $script:TestPrefix) { return $null }

    $root = $script:SourceRoots | Where-Object { $Path.StartsWith("$_/") } | Select-Object -First 1
    $rest = $Path.Substring($root.Length + 1)
    if (-not $rest.Contains('/')) {
        return [pscustomobject]@{ Area = $script:TestPrefix; Pattern = '^' + [regex]::Escape($script:TestPrefix) }
    }
    $project = $rest.Substring(0, $rest.IndexOf('/'))
    return [pscustomobject]@{
        Area    = "$($script:TestPrefix)$project.Tests/"
        Pattern = '^' + [regex]::Escape($script:TestPrefix) + [regex]::Escape($project) + '\.\w*Tests/'
    }
}

function Test-TestFile {
    param([string]$Path)

    if (-not ($script:SourceExtensions | Where-Object { $Path.EndsWith($_) })) { return $false }
    return $Path -notmatch '(^|/)(bin|obj)/'
}

function Test-PathOverlap {
    param([string]$Named, [string]$Area)

    if ($Named.StartsWith($Area, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $Area.StartsWith($Named.TrimEnd('/') + '/', [StringComparison]::OrdinalIgnoreCase)
}

function Get-AdrNamedPath {
    param([string[]]$Changed)

    $adrs = @($Changed | Where-Object { $_.StartsWith($script:AdrPrefix) -and $_.EndsWith('.md') -and ($_.Substring($script:AdrPrefix.Length) -notmatch '^(?:README|0000-template)\.md$') })
    foreach ($adr in $adrs) {
        $full = Join-Path $RepoRoot $adr
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        foreach ($match in [regex]::Matches((Get-Content -LiteralPath $full -Raw), $script:PathToken)) {
            $named = ($match.Value -replace '^(?:\.{1,2}/)+', '').TrimEnd('.')
            if ($named.Contains('/')) { $named }
        }
    }
}

function Get-MissingDoc {
    param([string[]]$Changed)

    $docsMoved = @($Changed | Where-Object { $path = $_; $script:DocPrefixes | Where-Object { $path.StartsWith($_) } })
    $named = @(Get-AdrNamedPath -Changed $Changed | Select-Object -Unique)

    $missing = @()
    foreach ($entry in $script:DocMap) {
        $touched = @($Changed | Where-Object { $_.StartsWith($entry.Source) -and (Test-CarriesBehaviour $_) })
        if ($touched.Count -eq 0) { continue }

        $covered = $false
        foreach ($docPrefix in $entry.Docs) {
            if ($docsMoved | Where-Object { $_.StartsWith($docPrefix) }) { $covered = $true; break }
        }
        if (-not $covered) {
            $areaPaths = @($entry.Source) + @($entry.Docs)
            foreach ($path in $named) {
                if ($areaPaths | Where-Object { Test-PathOverlap -Named $path -Area $_ }) { $covered = $true; break }
            }
        }

        if (-not $covered) {
            $missing += [pscustomobject]@{
                Source = $entry.Source
                Docs = ($entry.Docs -join ', ')
                Files = $touched.Count
                Paths = $touched
            }
        }
    }

    return $missing
}

function Get-TestFinding {
    param([string[]]$Behaviour, [string[]]$Changed)

    $groups = [ordered]@{}
    foreach ($path in $Behaviour) {
        $mirror = Get-TestMirror $path
        $key = if ($mirror) { $mirror.Area } else { '' }
        if (-not $groups.Contains($key)) { $groups[$key] = [pscustomobject]@{ Area = $key; Pattern = if ($mirror) { $mirror.Pattern } else { $null }; Paths = [System.Collections.Generic.List[string]]::new() } }
        $groups[$key].Paths.Add($path)
    }

    foreach ($group in $groups.Values) {
        $moved = if ($group.Pattern) { @($Changed | Where-Object { $_ -cmatch $group.Pattern -and (Test-TestFile $_) }) } else { @() }
        if ($moved.Count -gt 0) { continue }
        $text = if ($group.Area) {
            "TESTS: $($group.Paths.Count) source file(s) carry behaviour and no test file changed under $($group.Area), the test folder that mirrors them. Add the tests. Only wrap-up writes a No-Test commit trailer, after test-analyzer agrees with the reason."
        }
        else {
            "TESTS: $($group.Paths.Count) source file(s) carry behaviour, and aisdlc.json maps no test folder for them (paths.testRoot), so no test change can count. Map a test folder, or let wrap-up write a No-Test commit trailer after test-analyzer agrees with the reason."
        }
        # The key is the mirror area, so a waiver for one area never hides the finding of another.
        [pscustomobject]@{ Kind = 'TESTS'; Key = [string]$group.Area; Text = $text; Paths = $group.Paths.ToArray() }
    }
}

function Get-DocFinding {
    param([string[]]$Changed)

    foreach ($gap in (Get-MissingDoc -Changed $Changed)) {
        [pscustomobject]@{
            Kind  = 'DOCS'
            Key   = [string]$gap.Source
            Text  = "DOCS: $($gap.Files) changed file(s) under $($gap.Source) with nothing moved under $($gap.Docs) and no ADR in this change that names a path under them. Add the docs. Only wrap-up writes a No-Docs commit trailer, after docs-reviewer agrees with the reason."
            Paths = @($gap.Paths)
        }
    }
}

function Invoke-ChangeCompletenessCheck {
    param([string[]]$Changed, [string]$Base, [string[]]$Dirty = @(), [string[]]$Deleted = @())

    $carriers = @($Changed | Where-Object { Test-CarriesBehaviour $_ })
    # A deleted file has nothing left to test, but the page of its area may still describe it.
    $behaviour = @($carriers | Where-Object { $_ -cnotin $Deleted })
    $waiver = Get-WaiverTrailer -Root $RepoRoot -Base $Base

    if ($carriers.Count -eq 0) {
        return [pscustomobject]@{ NoOp = $true; Findings = @(); Waived = @(); Cleared = @{ 'No-Test' = @(); 'No-Docs' = @() }; Waiver = $waiver }
    }

    $noTest = @(Get-WaivedPath -Waiver $waiver -Kind 'No-Test' -Path $behaviour -Dirty $Dirty)
    $noDocs = @(Get-WaivedPath -Waiver $waiver -Kind 'No-Docs' -Path $carriers -Dirty $Dirty)

    # A deleted test file is not a test change, so only the files that are still there count as tests.
    $present = @($Changed | Where-Object { $_ -cnotin $Deleted })
    $all = @(Get-TestFinding -Behaviour $behaviour -Changed $present) + @(Get-DocFinding -Changed $Changed)
    $open = @(Get-TestFinding -Behaviour @($behaviour | Where-Object { $_ -cnotin $noTest }) -Changed $present) +
        @(Get-DocFinding -Changed @($Changed | Where-Object { $_ -cnotin $noDocs }))
    $openKeys = @($open | ForEach-Object { "$($_.Kind)|$($_.Key)" })
    $waived = @($all | Where-Object { "$($_.Kind)|$($_.Key)" -cnotin $openKeys })

    $cleared = @{}
    foreach ($entry in @(@{ Kind = 'No-Test'; Finding = 'TESTS'; Paths = $noTest }, @{ Kind = 'No-Docs'; Finding = 'DOCS'; Paths = $noDocs })) {
        $inFinding = @($all | Where-Object { $_.Kind -ceq $entry.Finding } | ForEach-Object { $_.Paths })
        $cleared[$entry.Kind] = @($entry.Paths | Where-Object { $_ -cin $inFinding })
    }

    return [pscustomobject]@{ NoOp = $false; Findings = $open; Waived = $waived; Cleared = $cleared; Waiver = $waiver }
}

if ($MyInvocation.InvocationName -eq '.') { return }

$change = Get-AiSdlcChange -RepoRoot $RepoRoot -BaseRef $BaseRef -Explicit $ChangedFiles -IncludeWorkingTree
if (-not $change.Readable) {
    Write-Host "Could not check: $($change.Reason), so the change cannot be listed." -ForegroundColor Yellow
    Write-Host 'FIX: Fetch the base branch, or pass -BaseRef with a ref that exists. When CHANGED_FILES is set, run the gate in a checkout that has git and its HEAD commit.' -ForegroundColor Yellow
    exit 2
}
# A waiver reads commits, so it needs a base that git found. A list the caller passes has none.
$base = $null
$dirty = @()
if (-not $ChangedFiles -and -not $env:CHANGED_FILES) {
    $base = $change.Base
    if ($base) { $dirty = Get-DirtyPath -Root $RepoRoot }
}
$result = Invoke-ChangeCompletenessCheck -Changed $change.Files -Base $base -Dirty $dirty -Deleted $change.Deleted

foreach ($item in $result.Waiver.Items) {
    if ($item.Problem) {
        Write-Host "Waiver not used: $($item.Text) (commit $($item.Commit)) because $($item.Problem)."
        continue
    }
    $files = @($item.Files | Where-Object { $_ -cin $result.Cleared[$item.Kind] } | Sort-Object)
    if ($files.Count -eq 0) {
        Write-Host "Waiver not needed: $($item.Text) (commit $($item.Commit)) because it cleared no $($item.Finding) finding."
        continue
    }
    $shown = @($files | Select-Object -First 10 | ForEach-Object { ConvertTo-PrintableText -Text $_ })
    $more = if ($files.Count -gt 10) { " and $($files.Count - 10) more" } else { '' }
    Write-Host "Waiver used: $($item.Text) (commit $($item.Commit)) cleared: $($shown -join ', ')$more"
}

if ($result.NoOp) {
    Write-Host "Change completeness: not applicable, no behaviour change to check."
    exit 3
}

foreach ($finding in $result.Waived) {
    Write-Host "Waived: $($finding.Text)"
}

if ($result.Findings.Count -eq 0) {
    if ($result.Waived.Count -gt 0) {
        Write-Host "Change completeness: every finding is waived by a commit trailer. A reviewer judges each reason."
    }
    else {
        Write-Host "Change completeness: tests and documentation moved with the code. Each changed source file that carries behaviour has a changed test file in its mirrored test folder, and each changed area has a changed doc area or an ADR that names it."
    }
    exit 0
}

foreach ($finding in $result.Findings) {
    Write-Host "Change completeness: $($finding.Text)"
}

Write-Host "FIX: Run the wrap-up skill, which brings the tests and both documentation layers up to what the code now does. Only wrap-up writes a No-Test or No-Docs commit trailer, after test-analyzer or docs-reviewer agrees with the reason. An agent never adds or amends a trailer outside wrap-up."

if ($Strict) { exit 1 }

exit 0
