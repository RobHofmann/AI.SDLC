#Requires -Version 7
<#
.SYNOPSIS
    House-style doc lint: documentation should not name internal team members.

.DESCRIPTION
    Naming an internal contributor in a durable document (an ADR, a wiki page) is a data-protection
    concern and is not load-bearing: who reviewed a change or caught a bug belongs in the pull-request
    history, referenced by PR number, not in permanent prose. A durable page records the state,
    not the process.

    Detection uses the highest-precision signal the repository already owns: its own commit-author
    roster. The gate derives a set of contributor name tokens from `git log`, then scans AGENTS.md and
    the documentation wiki layers (docs/ and docs-functional/) for any of those tokens as whole words.
    Because the match set is the repo's own committers, an external author cited legitimately (for
    example a book author in a reference) is not a committer and is therefore not flagged.

    A token is a FULL NAME ("First Last") and nothing else. The gate used to add the bare surname as a
    token too, whenever it ran to four or more characters and was absent from a hand-kept list of
    twenty common words. That is what made the gate unsafe to block on, because its input is the git
    roster rather than the change being built: the day a committer surnamed Post arrives, the
    case-insensitive word-boundary match fires on POST in every API page and fails a build nobody
    caused. Berg, Kamp, Veld and Hart are the same shape. Matching full names only removes that class
    outright, needs no curated word list, and still catches what clause C08 was written for, a
    contributor named in permanent prose. The cost is a surname-only mention ("as Sample noted"),
    which is both rarer and the shape most likely to collide with an ordinary word.

    The gate blocks: it reports findings and exits non-zero, and the CI wrapper (Invoke-LocalGates.ps1, through
    GateAnnotation.psm1) fails the build. Intentional, lawful exceptions (a name that must stand with consent) go in the
    allow-list file (default docs/.person-name-allowlist), one token per line, '#' for comments.

    Sibling of Check-DocEmDashes.ps1 (C06) and Check-DocLineCitations.ps1 (C02): a shared doc-lint, run
    locally by Invoke-LocalGates.ps1 and the pre-push hook, and by the pull request job, so the rule lives in
    one place.

.PARAMETER RepoRoot
    Repository root that contains AGENTS.md, docs/, and docs-functional/. Defaults to the folder that holds
    aisdlc.json, found from this script.

.PARAMETER AllowListPath
    Path to the allow-list file. Defaults to docs/.person-name-allowlist under RepoRoot. A missing file
    means no exceptions.

.PARAMETER GitAuthorProvider
    Test seam. A scriptblock that receives RepoRoot and returns the raw author display-name strings.
    When omitted, `git log --all` author and committer names are used.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$AllowListPath,
    [scriptblock]$GitAuthorProvider
)

Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

$ErrorActionPreference = 'Stop'

$config = Get-AiSdlcConfig -RepoRoot $RepoRoot
$layers = @(Get-AiSdlcPath -Name docsRoots -RepoRoot $RepoRoot -Relative)
if (-not $AllowListPath) { $AllowListPath = Join-Path $RepoRoot $config.paths.personNameAllowlist }

function Get-RawAuthor {
    param([string]$Root, [scriptblock]$Provider)
    if ($Provider) { return @(& $Provider $Root) }
    try {
        $out = & git -C $Root log --all --format='%an%n%cn' 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $out) { return @() }
        return @($out)
    }
    catch { return @() }
}

function ConvertTo-NameToken {
    param([string[]]$RawAuthors)
    $tokens = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($raw in $RawAuthors) {
        if (-not $raw) { continue }
        $s = $raw.Trim()
        if (-not $s) { continue }

        if ($s -notmatch '\s' -and ($s -match '[_@]' -or $s -ceq $s.ToLowerInvariant())) { continue }

        if ($s -match '^[A-Za-z]{2,5}_[A-Za-z0-9]+\s*-\s*(.+)$') { $s = $Matches[1].Trim() }
        if ($s -notmatch '\s' -and $s -match '[_@0-9]') { continue }

        $first = $null
        $last = $null
        if ($s.Contains(',')) {
            $parts = $s.Split(',', 2)
            $lastWords = @($parts[0].Trim() -split '\s+' | Where-Object { $_ -and $_ -ne '-' })
            $firstWords = @($parts[1].Trim() -split '\s+' | Where-Object { $_ -and $_ -ne '-' })
            if ($lastWords.Count) { $last = $lastWords[-1] }
            if ($firstWords.Count) { $first = $firstWords[0] }
        }
        else {
            $words = @($s -split '\s+' | Where-Object { $_ -and $_ -ne '-' })
            if ($words.Count -ge 2) { $first = $words[0]; $last = $words[-1] }
        }

        if (-not $first -or -not $last) { continue }
        if ($first -notmatch "^[\p{L}][\p{L}\-']*$" -or $last -notmatch "^[\p{L}][\p{L}\-']*$") { continue }

        [void]$tokens.Add("$first $last")
    }
    return @($tokens)
}

$raw = Get-RawAuthor -Root $RepoRoot -Provider $GitAuthorProvider
$tokens = ConvertTo-NameToken -RawAuthors $raw

$allow = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
if (Test-Path -LiteralPath $AllowListPath) {
    foreach ($line in Get-Content -LiteralPath $AllowListPath) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        [void]$allow.Add($t)
    }
}

$matchTokens = @($tokens | Where-Object { -not $allow.Contains($_) })

if ($matchTokens.Count -eq 0) {
    Write-Host "Person-name OK: no contributor names to check (empty roster or all allow-listed)."
    exit 0
}

$escaped = $matchTokens | Sort-Object -Property Length -Descending | ForEach-Object { [regex]::Escape($_) }
$pattern = '\b(' + ($escaped -join '|') + ')\b'
$rx = [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

$targets = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
if (-not @($layers | Where-Object { Test-Path (Join-Path $RepoRoot $_) })) {
    Write-Host ("Could not check: none of the doc layers in aisdlc.json exists ({0})." -f ($layers -join ', ')) -ForegroundColor Yellow
    exit 2
}$agents = Join-Path $RepoRoot $config.paths.agentsFile
if (Test-Path $agents) { $targets.Add((Get-Item $agents)) }
foreach ($layer in $layers) {
    $dir = Join-Path $RepoRoot $layer
    if (Test-Path $dir) {
        Get-ChildItem -Path $dir -Recurse -Include *.md, *.markdown -File | ForEach-Object { $targets.Add($_) }
    }
}

$violations = [System.Collections.Generic.List[object]]::new()
foreach ($file in $targets) {
    $rel = [IO.Path]::GetRelativePath($RepoRoot, $file.FullName).Replace('\', '/')
    $n = 0
    foreach ($line in Get-Content -LiteralPath $file.FullName) {
        $n++
        foreach ($m in $rx.Matches($line)) {
            $violations.Add([pscustomobject]@{ File = $rel; Line = $n; Name = $m.Value; Text = $line.Trim() })
        }
    }
}

if ($violations.Count -gt 0) {
    Write-Host "Doc house-style: documentation should not name internal team members (data-protection, and not load-bearing)." -ForegroundColor Red
    Write-Host "FIX: Name the pull request by number instead of the person, or add the name to $AllowListPath when it is a lawful exception." -ForegroundColor Red
    foreach ($v in $violations) { Write-Host ("  {0}:{1}  [{2}]  {3}" -f $v.File, $v.Line, $v.Name, $v.Text) }
    Write-Host ("Found {0} reference(s) to an internal contributor's name." -f $violations.Count) -ForegroundColor Red
    exit 1
}

Write-Host ("Person-name OK: no internal contributor names in {0}." -f ((@($config.paths.agentsFile) + @($layers | ForEach-Object { "$_/" })) -join ', '))
exit 0
