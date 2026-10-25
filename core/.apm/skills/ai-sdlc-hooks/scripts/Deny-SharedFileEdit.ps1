#Requires -Version 7
<#
.SYNOPSIS
    PreToolUse hook: stops an agent's edit to a file that APM installed from AI.SDLC, and names the
    file's source.

.DESCRIPTION
    Agents read skills from the installed folders, so they also try to edit them there. That edit is
    lost at the next apm install, and apm audit --ci fails the build on it. The change belongs in
    AI.SDLC. This hook reads apm.lock.yaml, and when the edited file is listed under deployed_files of a
    package, it denies the edit. The reason names the package, the file's path in AI.SDLC and the ref,
    and points at the handbook page on developing against a local clone.

    Any other file, a file outside the repository, a repository with no apm.lock.yaml, or a payload
    this script cannot read, is allowed through in silence. Every failure path exits 0 with no output,
    so a bug here can never turn every edit into an error.

    Wired from the core hooks with matcher Edit|Write. The file filter lives here, not in an `if`
    condition, because GitHub Copilot CLI reads the same entry and ignores `if`. HookPayload.psm1 reads
    the payload in every shape: tool_input (Claude Code), toolArgs (Copilot CLI, sometimes a JSON
    string), and the patch text of apply_patch, which a GPT model in Copilot CLI uses and which can
    touch several files. The edit is denied when any of those files is installed.

    Copilot CLI starts this script before every edit and runs the hooks one after another, so the common
    case stays cheap: the repository root is found by walking up to aisdlc.json, and the lock file is
    only parsed when it names one of the edited files.

.PARAMETER Payload
    The hook payload as JSON. Read from stdin when not supplied.

.PARAMETER RepoRoot
    The repository root. Defaults to the folder that holds aisdlc.json, found from the current location.

.PARAMETER LockFile
    The APM lock file. Defaults to <RepoRoot>/apm.lock.yaml.

.EXAMPLE
    '{"tool_name":"Edit","tool_input":{"file_path":".claude/skills/guide-me/SKILL.md"}}' | pwsh .claude/skills/ai-sdlc-hooks/scripts/Deny-SharedFileEdit.ps1
#>
[CmdletBinding()]
param(
    [string]$Payload,
    [string]$RepoRoot,
    [string]$LockFile
)

$ErrorActionPreference = 'Stop'

trap { exit 0 }

Import-Module (Join-Path $PSScriptRoot 'HookPayload.psm1') -Force

function Find-RepoRootFast {
    param([string]$StartPath)

    $dir = $StartPath
    while ($dir) {
        if (Test-Path -LiteralPath (Join-Path $dir 'aisdlc.json') -PathType Leaf) { return $dir }
        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts' 'AiSdlcConfig.psm1') -Force
    return Find-AiSdlcRepoRoot -StartPath $StartPath
}

function Update-PackageField {
    param([hashtable]$Package, [string]$Line)

    $fields = @{ name = 'Name'; virtual_path = 'VirtualPath'; resolved_ref = 'Ref' }
    if ($Line -notmatch '^  (?<key>name|virtual_path|resolved_ref):\s*(?<v>.+)$') { return $false }
    $Package[$fields[$Matches.key]] = $Matches.v.Trim()
    return $true
}

function Read-DeployedFiles {
    param([string]$Path)

    $map = @{}
    $current = $null
    $inList = $false
    foreach ($line in [IO.File]::ReadLines($Path)) {
        if ($line -match '^- repo_url:\s*(?<v>.+)$') {
            $current = @{ Repo = $Matches.v.Trim(); Name = ''; VirtualPath = ''; Ref = '' }
            $inList = $false
        }
        elseif ($current -and $inList -and $line -match '^  - (?<v>.+)$') {
            $map[$Matches.v.Trim().Replace('\', '/')] = $current
        }
        elseif ($current) {
            $inList = $line -match '^  deployed_files:\s*$'
            [void](Update-PackageField -Package $current -Line $line)
        }
    }
    return $map
}

function Get-SourcePath {
    param([string]$Relative, [hashtable]$Package)

    $prefix = if ($Package.VirtualPath) { "$($Package.VirtualPath)/" }
    elseif ($Package.Name -eq 'ai-sdlc-core') { 'core/' }
    elseif ($Package.Name -like 'ai-sdlc-*') { "packs/$($Package.Name.Substring(8))/" }
    else { '' }
    if ($Relative -match '^\.claude/skills/(?<rest>.+)$') { return "$prefix.apm/skills/$($Matches.rest)" }
    if ($Relative -match '^\.claude/agents/(?<name>[^/]+)\.md$') { return "$prefix.apm/agents/$($Matches.name).agent.md" }
    return "$prefix$Relative"
}

if (-not $PSBoundParameters.ContainsKey('Payload')) {
    $Payload = if ([Console]::IsInputRedirected) { [Console]::In.ReadToEnd() } else { '' }
}

$files = @(Get-HookEditedFile -Json $Payload)
if ($files.Count -eq 0) { exit 0 }

if (-not $RepoRoot) { $RepoRoot = Find-RepoRootFast -StartPath (Get-Location).Path }
if (-not $RepoRoot) { exit 0 }
if (-not $LockFile) { $LockFile = Join-Path $RepoRoot 'apm.lock.yaml' }
if (-not (Test-Path -LiteralPath $LockFile -PathType Leaf)) { exit 0 }

$rootFull = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
$relatives = foreach ($file in $files) {
    $full = if ([IO.Path]::IsPathRooted($file)) { $file } else { Join-Path $RepoRoot $file }
    $full = [IO.Path]::GetFullPath($full)
    if ($full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { $full.Substring($rootFull.Length).Replace('\', '/') }
}
$relatives = @($relatives | Select-Object -Unique)
if ($relatives.Count -eq 0) { exit 0 }

$lockText = [IO.File]::ReadAllText($LockFile)
if (-not @($relatives | Where-Object { $lockText.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 })) { exit 0 }

$deployed = Read-DeployedFiles -Path $LockFile
$inRepo = $false
$reasons = foreach ($relative in $relatives) {
    $package = $deployed[$relative]
    if (-not $package) {
        $match = $deployed.Keys | Where-Object { $_.Equals($relative, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
        if ($match) { $package = $deployed[$match] }
    }
    if (-not $package) { continue }

    $source = Get-SourcePath -Relative $relative -Package $package
    if ($package.Repo -like '_local/*' -and (Test-Path -LiteralPath (Join-Path $RepoRoot $source))) {
        $inRepo = $true
        "$relative is installed from $source in this repository, so an edit here is lost at the next apm install. Change $source instead."
        continue
    }
    $ref = if ($package.Ref) { " at $($package.Ref)" } else { '' }
    ("$relative is installed from AI.SDLC (package $($package.Name)$ref), so an edit here is lost at the next " +
        "apm install and fails apm audit --ci. Change $source in AI.SDLC instead, through a pull request there.")
}
$reasons = @($reasons)
if ($reasons.Count -eq 0) { exit 0 }

$reason = if ($inRepo) {
    ($reasons -join ' ') + ' Then run tools/Update-SyncManifest.ps1 and apm install, so the installed copy follows.'
}
else {
    (($reasons -join ' ') + ' To try the change in this repository first, point apm.yml at a local clone of AI.SDLC: see ' +
        ".claude/skills/ai-sdlc-handbook/references/layout.md, section 'Developing against a local clone'.")
}

@{
    permissionDecision       = 'deny'
    permissionDecisionReason = $reason
    hookSpecificOutput       = @{
        hookEventName            = 'PreToolUse'
        permissionDecision       = 'deny'
        permissionDecisionReason = $reason
    }
} | ConvertTo-Json -Depth 5 -Compress | Write-Output
exit 0
