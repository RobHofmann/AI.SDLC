#Requires -Version 7
<#
.SYNOPSIS
    Gate: no shared file of AI.SDLC writes a closing keyword followed by a bare issue number.

.DESCRIPTION
    GitHub closes an issue when a merged pull request or a commit on the main branch writes a closing
    keyword (close, fix or resolve, in any of their forms) and then a number after a hash sign. An
    example in a skill or a page is often quoted into a commit or a pull request. When the example
    holds a real-looking number, the quote closes the real issue with that number in the repository
    where it lands. That happened once in AI.SDLC (#99).

    So every example after a closing keyword uses the placeholder `#n`, which GitHub never links. This
    gate reads the shared files and fails on a closing keyword, with an optional colon, followed by a
    hash sign and digits. A bare mention of an issue only links it and closes nothing, so it passes.
    A branch name that starts with a number passes too.

    Skipped on purpose: CHANGELOG.md, because its entries are history; the sync manifest, because a
    script writes it; and every test file (a `tests` folder or a `*.Tests.ps1` file), because a test
    passes a real number to the parser it tests.

    Exit codes follow the gate contract: 0 nothing found, 1 a finding, 2 a file could not be read, 3 no
    file is left to read. A path that is missing is skipped.

.PARAMETER RepoRoot
    The AI.SDLC repository root. Defaults to the folder above this script.

.PARAMETER Path
    The folders and files to scan, relative to RepoRoot. Defaults to core, packs, tools, config,
    test-consumers, .github, docs, docs-functional, README.md and AGENTS.md. All of them are public.

.EXAMPLE
    pwsh tools/Check-ClosingKeywordExamples.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string[]]$Path = @('core', 'packs', 'tools', 'config', 'test-consumers', '.github', 'docs', 'docs-functional', 'README.md', 'AGENTS.md')
)

$ErrorActionPreference = 'Stop'

# The nine closing keywords of GitHub, in any case, then an optional colon, then a hash sign and digits.
$regex = [regex]::new('(?<![A-Za-z0-9_-])(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)[ \t]*:?[ \t]+#[0-9]+(?![A-Za-z0-9_])', 'IgnoreCase')

$files = foreach ($p in $Path) {
    $full = Join-Path $RepoRoot $p
    if (Test-Path -LiteralPath $full -PathType Leaf) { Get-Item -LiteralPath $full -Force }
    elseif (Test-Path -LiteralPath $full) { Get-ChildItem -LiteralPath $full -Recurse -File -Force }
}
$files = @($files | Where-Object {
        $rel = [IO.Path]::GetRelativePath($RepoRoot, $_.FullName).Replace('\', '/')
        $_.Name -ne 'sync-manifest.json' -and $_.Name -ne 'CHANGELOG.md' -and
        $_.Name -notlike '*.Tests.ps1' -and ('/' + $rel) -notmatch '/tests/'
    })

if ($files.Count -eq 0) {
    Write-Host 'Not applicable: no file is left to read under the folders to scan.'
    exit 3
}

$findings = [System.Collections.Generic.List[object]]::new()
foreach ($file in $files) {
    $rel = [IO.Path]::GetRelativePath($RepoRoot, $file.FullName).Replace('\', '/')
    try { $lines = [IO.File]::ReadAllLines($file.FullName) }
    catch {
        Write-Host "Could not check: $rel cannot be read ($($_.Exception.Message))." -ForegroundColor Yellow
        Write-Host 'FIX: Make the file readable, or remove it from the folders to scan.' -ForegroundColor Yellow
        exit 2
    }
    $n = 0
    foreach ($line in $lines) {
        $n++
        foreach ($m in $regex.Matches($line)) {
            $findings.Add([pscustomobject]@{ File = $rel; Line = $n; Text = $m.Value })
        }
    }
}

if ($findings.Count -gt 0) {
    Write-Host 'Closing keyword examples: these lines write a closing keyword with a real-looking issue number.' -ForegroundColor Red
    Write-Host 'FIX: Write the number as the placeholder #n, which GitHub never links, so a quote closes no issue.' -ForegroundColor Red
    foreach ($f in $findings) { Write-Host ("  {0}:{1}  {2}" -f $f.File, $f.Line, $f.Text) }
    Write-Host ("Found {0} closing keyword example(s) with a number." -f $findings.Count) -ForegroundColor Red
    exit 1
}

Write-Host ("Closing keyword examples OK: {0} file(s) checked." -f $files.Count)
exit 0
