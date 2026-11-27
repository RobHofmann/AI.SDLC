#Requires -Version 7
<#
.SYNOPSIS
    Gate: PSScriptAnalyzer finds nothing on the PowerShell lines that a change adds (clause C13).
.DESCRIPTION
    The team asked for PSScriptAnalyzer with its default rules, as a warning first
    (.claude/skills/powershell-conventions/references/house-style.md, section "PSScriptAnalyzer reports
    style breaks as a warning"). So a reviewer no longer writes the same comment by hand.

    The gate runs Invoke-ScriptAnalyzer with its default rules on each .ps1 and .psm1 file of the change.
    It leaves out PSAvoidUsingWriteHost, because the house style asks for Write-Host.
    It always passes settings of its own, so a PSScriptAnalyzerSettings.psd1 in the repository is never
    read. Such a file could load a custom rule module, which runs code, or switch rules off. A listed path
    that is rooted, a UNC path or holds a .. part is named as outside the repository before it is joined.
    It reports only a finding on a line that the change adds or changes (Get-AiSdlcLineChange in
    ChangedFiles.psm1), so the older code of a touched file does not fail anyone. The files that
    apm.lock.yaml at the base lists under deployed_files are skipped: the install wrote them, and the
    repository must not edit them. A file under .claude/ that apm.lock.yaml at HEAD lists with its right
    SHA-256 hash is skipped too, because a change that installs a new version adds its own files to the
    lock. A symbolic link or junction is named as not checked, so
    the analyzer never reads a file outside the repository through it.

    PSScriptAnalyzer is a module that the machine must have, at version 1.21.0 or newer. When it is
    missing, the gate says NOTHING WAS CHECKED and exits 2. It never installs the module.

    It fails closed. Exit codes follow ADR 0019: 0 checked and clean, 1 a finding on an added line, 2 the
    change could not be read, the module is missing, or a script does not parse, so it was not checked,
    3 the change adds no line to a .ps1 or .psm1 file. A file on which the analyzer fails is named as not checked.
.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script.
.PARAMETER BaseRef
    The ref the change is measured against. Defaults to the main branch of the repository
    (Get-AiSdlcMainBranch in AiSdlcConfig.psm1). The pull request build passes HEAD^1.
.PARAMETER ChangedFiles
    Repo-relative paths to read instead of asking git for the change. Without a base, every line of a
    listed file counts as added. Used by the tests.
.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Check-ScriptAnalyzer.ps1
.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Check-ScriptAnalyzer.ps1 -BaseRef HEAD~3
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$BaseRef,
    [string[]]$ChangedFiles
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$minimumAnalyzerVersion = [version]'1.21.0'
$analyzerSettings = @{
    IncludeDefaultRules = $true
    Severity            = @('Error', 'Warning', 'Information')
    ExcludeRules        = @('PSAvoidUsingWriteHost')
}
$pathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }

function Write-NotChecked {
    param([string]$Reason, [string]$Fix)
    Write-Host "Script analyzer: $Reason, so NOTHING WAS CHECKED." -ForegroundColor Yellow
    Write-Host "FIX: $Fix" -ForegroundColor Yellow
    exit 2
}

function Get-ChangedScript {
    param([string]$Root)
    $changeArgs = @{
        RepoRoot = $Root
        BaseRef  = $BaseRef
        Explicit = $ChangedFiles
    }
    $change = Get-AiSdlcChange @changeArgs
    if (-not $change.Readable) {
        $fixProperty = $change.PSObject.Properties['Fix']
        $fix = if ($fixProperty -and $fixProperty.Value) { $fixProperty.Value } else { 'Fetch the base branch (git fetch origin <branch>), or pass -BaseRef with a ref that exists, then run this check again.' }
        Write-NotChecked -Reason "the change could not be read ($($change.Reason))" -Fix $fix
    }
    $installed = Get-AiSdlcInstalledPath -RepoRoot $Root -Base $change.Base -WithHeadInstall
    if (-not $installed.Readable) {
        Write-NotChecked -Reason "the list of installed files could not be read ($($installed.Reason))" -Fix 'Fetch the base branch (git fetch origin <branch>), or pass -BaseRef with a commit that exists, then run this check again.'
    }
    $scripts = @($change.Files | Where-Object {
            $_ -match '\.(ps1|psm1)$' -and -not $installed.Paths.Contains($_) -and @($change.Deleted) -notcontains $_
        })
    return [pscustomobject]@{ Base = $change.Base; Scripts = $scripts }
}

function Test-ReparsePoint {
    param([string]$Root, [string]$Path)
    $rootTrimmed = $Root.TrimEnd('\', '/')
    for ($current = $Path; $current -and $current.Length -ge $Root.Length; $current = [System.IO.Path]::GetDirectoryName($current)) {
        if ([string]::Equals($current.TrimEnd('\', '/'), $rootTrimmed, $pathComparison)) { break }
        $item = Get-Item -LiteralPath $current -Force
        if ($item.LinkType -in 'SymbolicLink', 'Junction') { return $true }
    }
    return $false
}

function Test-UnsafePath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path) -or $Path -match '^([\\/]{2}|[A-Za-z]:)') { return $true }
    return (@($Path -split '[\\/]') -contains '..')
}

function Get-ScriptToRead {
    param([string]$Root, [string]$Base, [string]$Path)
    if (Test-UnsafePath -Path $Path) {
        return [pscustomobject]@{ Full = $null; Added = $null; Problem = 'the path is outside the repository' }
    }
    $rootPrefix = $Root.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $full = [System.IO.Path]::GetFullPath((Join-Path $Root $Path))
    $problem = switch ($true) {
        { -not $full.StartsWith($rootPrefix, $pathComparison) } { 'the path is outside the repository'; break }
        { -not (Test-Path -LiteralPath $full -PathType Leaf) } { 'the file is not on disk'; break }
        { Test-ReparsePoint -Root $Root -Path $full } { 'the path goes through a symbolic link or junction'; break }
        default { $null }
    }
    if ($problem) { return [pscustomobject]@{ Full = $full; Added = $null; Problem = $problem } }

    $lineChange = Get-AiSdlcLineChange -RepoRoot $Root -Base $Base -Path $Path -AssumeNew:([bool]$ChangedFiles)
    if ($null -eq $lineChange) {
        return [pscustomobject]@{ Full = $full; Added = $null; Problem = 'git could not list the lines this change adds' }
    }
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        return [pscustomobject]@{ Full = $full; Added = $null; Problem = 'the file does not parse' }
    }
    $added = [System.Collections.Generic.HashSet[int]]::new([int[]]@($lineChange.Added))
    return [pscustomobject]@{ Full = $full; Added = $added; Problem = $null }
}

function Import-Analyzer {
    $available = Get-Module -ListAvailable -Name PSScriptAnalyzer |
        Where-Object { $_.Version -ge $minimumAnalyzerVersion } |
        Sort-Object -Property Version -Descending |
        Select-Object -First 1
    if (-not $available) {
        $fix = "Install the module on this machine or build agent with Install-PSResource -Name PSScriptAnalyzer -Version '[$minimumAnalyzerVersion,)', then run this check again."
        Write-NotChecked -Reason "the PSScriptAnalyzer module at version $minimumAnalyzerVersion or newer is not installed" -Fix $fix
    }
    Import-Module -Name $available.Path -Force
    return $available.Version
}

function Invoke-ScriptAnalyzerGate {
    if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }
    $root = (Resolve-Path -LiteralPath $RepoRoot).Path
    if (-not $BaseRef) { $script:BaseRef = Get-AiSdlcMainBranch -RepoRoot $root }

    $changed = Get-ChangedScript -Root $root
    $toRead = [System.Collections.Generic.List[object]]::new()
    $unchecked = [System.Collections.Generic.List[string]]::new()
    foreach ($path in $changed.Scripts) {
        $target = Get-ScriptToRead -Root $root -Base $changed.Base -Path $path
        if ($target.Problem) { $unchecked.Add("$path : $($target.Problem)"); continue }
        if ($target.Added.Count -eq 0) { continue }
        $toRead.Add([pscustomobject]@{ Path = $path; Full = $target.Full; Added = $target.Added })
    }

    if ($toRead.Count -eq 0 -and $unchecked.Count -eq 0) {
        Write-Host 'Not applicable: the change adds no line to a .ps1 or .psm1 file, so there is nothing for PSScriptAnalyzer to read.'
        exit 3
    }

    $version = if ($toRead.Count -gt 0) { Import-Analyzer } else { $null }
    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($target in $toRead) {
        # The analyzer can fail on one file with a non-terminating error and still return a part of the
        # findings. Such a file was not read whole, so it must never count as clean.
        $analyzerError = $null
        $records = @(Invoke-ScriptAnalyzer -Path $target.Full -Settings $analyzerSettings -ErrorVariable analyzerError -ErrorAction SilentlyContinue)
        if (@($analyzerError).Count -gt 0) {
            $unchecked.Add("$($target.Path) : PSScriptAnalyzer failed on the file ($(@($analyzerError)[0].Exception.Message))")
        }
        foreach ($record in $records) {
            if (-not $target.Added.Contains([int]$record.Line)) { continue }
            $findings.Add([pscustomobject]@{ File = $target.Path; Line = $record.Line; Rule = $record.RuleName; Severity = $record.Severity; Message = $record.Message })
        }
    }

    if ($findings.Count -gt 0) {
        Write-Host ("Script analyzer (clause C13): PSScriptAnalyzer {0} with its default rules finds style breaks on lines this change adds. A finding is a warning and never stops a push." -f $version) -ForegroundColor Yellow
        Write-Host 'FIX: Change each line named below as the rule asks, following .claude/skills/powershell-conventions/references/house-style.md, or say in the pull request why the rule does not fit.' -ForegroundColor Yellow
        foreach ($f in $findings) { Write-Host ("  {0}:{1}  {2} ({3}): {4}" -f $f.File, $f.Line, $f.Rule, $f.Severity, $f.Message) }
        Write-Host ("Found {0} finding(s) in {1} file(s)." -f $findings.Count, @($findings | Select-Object -ExpandProperty File -Unique).Count) -ForegroundColor Yellow
    }
    if ($unchecked.Count -gt 0) {
        Write-Host 'Script analyzer: NOTHING WAS CHECKED in these file(s):' -ForegroundColor Yellow
        foreach ($u in $unchecked) { Write-Host "  $u" }
        Write-Host 'FIX: Fix the syntax error that pwsh reports for each file named above, or run the check inside the git clone of the change, then run it again. When the analyzer itself failed on a file, change that file or report the failure to the PSScriptAnalyzer project.' -ForegroundColor Yellow
    }
    if ($findings.Count -gt 0) { exit 1 }
    if ($unchecked.Count -gt 0) { exit 2 }

    Write-Host ("Script analyzer OK: PSScriptAnalyzer {0} read {1} PowerShell file(s) and finds nothing on the lines this change adds." -f $version, $toRead.Count)
    exit 0
}

Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ChangedFiles.psm1') -Force
Invoke-ScriptAnalyzerGate
