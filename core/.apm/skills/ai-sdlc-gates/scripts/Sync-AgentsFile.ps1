#Requires -Version 7
<#
.SYNOPSIS
    Writes the shared parts of AGENTS.md from the installed packages, or checks that they match.

.DESCRIPTION
    Every agent reads AGENTS.md at the start of a session. Part of it is the same in every repository:
    the communication rules and the core clauses of the constitution, plus the clauses of each pack the
    repository uses. APM will not write into a hand-written AGENTS.md, so this script does it.

    Each installed package can ship its part as a markdown file named agents-<package>.md in the
    assets/ folder of one of its skills, for example ai-sdlc-gates/assets/agents-core.md. The script
    takes the core part and the part of every pack that apm.yml lists, in that order.

    Each part sits in AGENTS.md between two marker lines:

        <!-- ai-sdlc:<package>:start - installed from AI.SDLC; change it there, not here -->
        <!-- ai-sdlc:<package>:end -->

    Everything outside the markers belongs to the repository and is never changed. A part with no
    markers yet is placed after the last existing part, or, when there is none, before the first
    "## " heading. A marked part whose package is no longer installed is removed.

    When the root CLAUDE.md only imports AGENTS.md, a write also moves that import to .claude/CLAUDE.md
    as @../AGENTS.md, and stages the move. GitHub Copilot reads the root CLAUDE.md and follows its
    import, so it read AGENTS.md twice. The move is left alone, with a warning, when .claude/CLAUDE.md
    holds something else, when git ignores it, or when the root file has staged changes.

    With -Check it writes nothing. It exits 1 when AGENTS.md differs from what a write would produce,
    so the local gates and the pipeline catch a hand edit inside the markers or a stale part.

    Exit codes follow the gate contract: 0 in sync (or written), 1 out of sync, 2 could not check.

.PARAMETER RepoRoot
    The repository root. Defaults to the folder that holds aisdlc.json, found from the current location.

.PARAMETER SkillsRoot
    The folder the packages are installed in. Defaults to <RepoRoot>/.claude/skills.

.PARAMETER Check
    Compare only. Exit 1 when a write would change AGENTS.md.

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Sync-AgentsFile.ps1

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Sync-AgentsFile.ps1 -Check
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$SkillsRoot,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force

try {
    $config = Get-AiSdlcConfig -RepoRoot $RepoRoot
}
catch {
    Write-Host "Could not check: $($_.Exception.Message)" -ForegroundColor Yellow
    exit 2
}
$RepoRoot = $config.repoRoot
if (-not $SkillsRoot) { $SkillsRoot = Join-Path $RepoRoot '.claude' 'skills' }

$agentsPath = Join-Path $RepoRoot $config.paths.agentsFile
if (-not (Test-Path -LiteralPath $agentsPath -PathType Leaf)) {
    Write-Host "Could not check: $($config.paths.agentsFile) does not exist in $RepoRoot." -ForegroundColor Yellow
    exit 2
}

function Get-PartFile {
    param([string]$Package)
    $name = "agents-$Package.md"
    $found = @(Get-ChildItem -LiteralPath $SkillsRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'assets' $name } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($found.Count -gt 1) { throw "More than one installed skill ships $name`: $($found -join ', ')." }
    return $found | Select-Object -First 1
}

$packages = @('core') + @($config.packs)
$parts = [ordered]@{}
foreach ($package in $packages) {
    $file = Get-PartFile -Package $package
    if ($file) { $parts[$package] = ((Get-Content -LiteralPath $file -Raw) -replace "`r`n", "`n").TrimEnd("`n") }
}
if (-not $parts.Contains('core')) {
    Write-Host "Could not check: no installed skill ships assets/agents-core.md under $SkillsRoot. Run apm install first." -ForegroundColor Yellow
    exit 2
}

function Get-StartMarker { param([string]$Package) "<!-- ai-sdlc:$($Package):start - installed from AI.SDLC; change it there, not here -->" }
function Get-EndMarker { param([string]$Package) "<!-- ai-sdlc:$($Package):end -->" }

$original = (Get-Content -LiteralPath $agentsPath -Raw) -replace "`r`n", "`n"
$lines = [System.Collections.Generic.List[string]]::new([string[]]($original.TrimEnd("`n") -split "`n"))

$markerPattern = '^<!-- ai-sdlc:(?<package>[a-z0-9-]+):(?<edge>start|end)\b.*-->\s*$'
$blocks = [System.Collections.Generic.List[object]]::new()
$open = $null
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match $markerPattern) {
        if ($Matches.edge -eq 'start') {
            if ($open) { Write-Host "Could not check: the ai-sdlc:$($open.Package) part has no end marker before line $($i + 1)." -ForegroundColor Yellow; exit 2 }
            $open = [pscustomobject]@{ Package = $Matches.package; Start = $i; End = -1 }
        }
        else {
            if (-not $open -or $open.Package -ne $Matches.package) { Write-Host "Could not check: an end marker for ai-sdlc:$($Matches.package) on line $($i + 1) has no matching start." -ForegroundColor Yellow; exit 2 }
            $open.End = $i
            $blocks.Add($open)
            $open = $null
        }
    }
}
if ($open) { Write-Host "Could not check: the ai-sdlc:$($open.Package) part has no end marker." -ForegroundColor Yellow; exit 2 }

for ($b = $blocks.Count - 1; $b -ge 0; $b--) {
    $block = $blocks[$b]
    $lines.RemoveRange($block.Start, $block.End - $block.Start + 1)
    if ($parts.Contains($block.Package)) {
        $lines.Insert($block.Start, "@@part:$($block.Package)")
    }
    elseif ($block.Start -lt $lines.Count -and $lines[$block.Start] -eq '' -and $block.Start -gt 0 -and $lines[$block.Start - 1] -eq '') {
        $lines.RemoveAt($block.Start)
    }
}

foreach ($package in $parts.Keys) {
    if ($lines.Contains("@@part:$package")) { continue }
    $last = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].StartsWith('@@part:')) { $last = $i } }
    if ($last -ge 0) {
        $lines.InsertRange($last + 1, [string[]]@('', "@@part:$package"))
    }
    else {
        $heading = -1
        for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].StartsWith('## ')) { $heading = $i; break } }
        if ($heading -lt 0) { $lines.AddRange([string[]]@('', "@@part:$package")) }
        else { $lines.InsertRange($heading, [string[]]@("@@part:$package", '')) }
    }
}

$out = [System.Collections.Generic.List[string]]::new()
foreach ($line in $lines) {
    if ($line.StartsWith('@@part:')) {
        $package = $line.Substring(7)
        $out.Add((Get-StartMarker -Package $package))
        $out.AddRange([string[]]($parts[$package] -split "`n"))
        $out.Add((Get-EndMarker -Package $package))
    }
    else {
        $out.Add($line)
    }
}
$updated = ($out -join "`n") + "`n"

# A root CLAUDE.md that only imports AGENTS.md moves to .claude/CLAUDE.md. Claude Code reads both places;
# GitHub Copilot reads the root one and follows its import, so it loaded AGENTS.md twice. The move lives
# here and not in Update-AiSdlc.ps1: a consumer takes a new version with the Update-AiSdlc.ps1 of its old
# version, and that one calls the Sync-AgentsFile.ps1 of the new version. The move stages itself, because
# that old Update-AiSdlc.ps1 stages only AGENTS.md after this script.

# The git checks before the move. Returns $null when the import must stay where it is, else whether the
# root is a git repository and whether git tracks the root CLAUDE.md.
function Get-RootClaudeGitState {
    param([string]$Root)
    git -C $Root rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ InGit = $false; Tracked = $false } }
    git -C $Root check-ignore --quiet -- .claude/CLAUDE.md *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Host 'CLAUDE.md only imports AGENTS.md, but .gitignore ignores .claude/CLAUDE.md, so the import cannot move there. Stop ignoring .claude/CLAUDE.md, then run this script again.' -ForegroundColor Yellow
        return $null
    }
    git -C $Root diff --cached --quiet -- CLAUDE.md *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'CLAUDE.md only imports AGENTS.md, but it has staged changes, so it is left in place. Commit or unstage them, then run this script again.' -ForegroundColor Yellow
        return $null
    }
    git -C $Root ls-files --error-unmatch -- CLAUDE.md *> $null
    return [pscustomobject]@{ InGit = $true; Tracked = ($LASTEXITCODE -eq 0) }
}

# Removes the root CLAUDE.md: with git rm when git tracks it, so the removal is staged. Returns $false when git rm fails.
function Remove-RootClaude {
    param([string]$Root, [bool]$Tracked)
    if (-not $Tracked) { Remove-Item -LiteralPath (Join-Path $Root 'CLAUDE.md'); return $true }
    git -C $Root rm --quiet --force -- CLAUDE.md *> $null
    return $LASTEXITCODE -eq 0
}

function Move-RootClaudeImport {
    param([string]$Root)
    $rootClaude = Join-Path $Root 'CLAUDE.md'
    if (-not (Test-Path -LiteralPath $rootClaude -PathType Leaf)) { return }
    if ([IO.File]::ReadAllText($rootClaude).Trim() -ne '@AGENTS.md') { return }
    $dotClaude = Join-Path $Root '.claude' 'CLAUDE.md'
    $dotExists = Test-Path -LiteralPath $dotClaude -PathType Leaf
    if ($dotExists -and [IO.File]::ReadAllText($dotClaude).Trim() -ne '@../AGENTS.md') {
        Write-Host 'CLAUDE.md only imports AGENTS.md, and .claude/CLAUDE.md exists too, so GitHub Copilot reads AGENTS.md twice. Add @../AGENTS.md to .claude/CLAUDE.md when it lacks it, then delete the root CLAUDE.md.' -ForegroundColor Yellow
        return
    }
    $git = Get-RootClaudeGitState -Root $Root
    if (-not $git) { return }

    if (-not $dotExists) {
        New-Item -ItemType Directory -Path (Split-Path $dotClaude -Parent) -Force | Out-Null
        [IO.File]::WriteAllText($dotClaude, "@../AGENTS.md`n", [Text.UTF8Encoding]::new($false))
    }
    if (-not (Remove-RootClaude -Root $Root -Tracked $git.Tracked)) {
        if (-not $dotExists) { Remove-Item -LiteralPath $dotClaude }
        Write-Host 'CLAUDE.md only imports AGENTS.md, but git rm could not remove it, so nothing moved. Move the import to .claude/CLAUDE.md as @../AGENTS.md by hand.' -ForegroundColor Yellow
        return
    }
    if ($git.InGit) {
        git -C $Root add -- .claude/CLAUDE.md *> $null
        if ($LASTEXITCODE -ne 0) { Write-Host 'Moved the import, but git add .claude/CLAUDE.md failed. Stage .claude/CLAUDE.md by hand.' -ForegroundColor Yellow; return }
    }
    Write-Host 'Moved the import of AGENTS.md from CLAUDE.md to .claude/CLAUDE.md, so GitHub Copilot reads AGENTS.md once.'
}

if (-not $Check) { Move-RootClaudeImport -Root $RepoRoot }

if ($updated -ceq $original) {
    Write-Host ("AGENTS.md in sync: {0} shared part(s) ({1}) match the installed packages." -f $parts.Count, ($parts.Keys -join ', '))
    exit 0
}

$relative = [IO.Path]::GetRelativePath($RepoRoot, $agentsPath).Replace('\', '/')
if ($Check) {
    Write-Host "AGENTS.md out of sync: a shared part differs from the installed packages, or one is missing or stale." -ForegroundColor Red
    Write-Host "FIX: Run pwsh .claude/skills/ai-sdlc-gates/scripts/Sync-AgentsFile.ps1 and commit the result. To change the shared text itself, change it in AI.SDLC." -ForegroundColor Red
    Write-Host ("  {0}  shared parts expected: {1}" -f $relative, ($parts.Keys -join ', '))
    exit 1
}

[IO.File]::WriteAllText($agentsPath, $updated, [Text.UTF8Encoding]::new($false))
Write-Host ("AGENTS.md written: {0} shared part(s) ({1}) from the installed packages." -f $parts.Count, ($parts.Keys -join ', '))
exit 0
