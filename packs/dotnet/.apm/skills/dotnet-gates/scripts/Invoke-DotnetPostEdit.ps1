#Requires -Version 7
<#
.SYNOPSIS
    The dotnet part of the post-edit hook: build the project that owns an edited C# or Razor file,
    and report the errors while the file is still open.

.DESCRIPTION
    Invoke-PostEditCheck.ps1 in the ai-sdlc-hooks skill runs this script for an edited file whose
    extension the postEdit entry of dotnet-gates/gates.json names (.cs and .razor). It finds the
    nearest .csproj above each file and builds each project once, so an analyzer error or a broken
    reference is reported at once rather than at the pull request. A patch over many files of one
    project costs one build.

    It writes nothing when the build passes or when no project owns the file. When a build fails
    it writes the feedback text, and the core hook hands that text to the agent. It never blocks the
    edit.

.PARAMETER File
    The full paths of the edited files.

.PARAMETER Relative
    The same files relative to the repository root, in the same order, used in the message.

.PARAMETER RepoRoot
    The repository root. Defaults to the folder that holds aisdlc.json, found from this script. The
    search for a project stops here.

.PARAMETER BuildTool
    The command that builds a project. Defaults to dotnet; the tests pass a script that stands in for it.

.EXAMPLE
    pwsh .claude/skills/dotnet-gates/scripts/Invoke-DotnetPostEdit.ps1 -File C:/src/repo/src/App/Thing.cs -Relative src/App/Thing.cs
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$File,
    [string[]]$Relative,
    [string]$RepoRoot,
    [string]$BuildTool = 'dotnet'
)

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }
if (-not $Relative -or $Relative.Count -ne $File.Count) { $Relative = @($File | ForEach-Object { [IO.Path]::GetRelativePath($RepoRoot, $_).Replace('\', '/') }) }

function Find-OwningProject {
    param([string]$Path, [string]$Root)

    $dir = Split-Path -Parent $Path
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    while ($dir -and $dir.Length -ge $rootFull.Length) {
        $project = @(Get-ChildItem -LiteralPath $dir -Filter '*.csproj' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($project.Count -gt 0) { return $project[0].FullName }
        if ($dir.TrimEnd('\', '/') -eq $rootFull) { break }
        $dir = Split-Path -Parent $dir
    }
    return $null
}

$byProject = [ordered]@{}
for ($i = 0; $i -lt $File.Count; $i++) {
    $project = Find-OwningProject -Path $File[$i] -Root $RepoRoot
    if (-not $project) { continue }
    if (-not $byProject.Contains($project)) { $byProject[$project] = [System.Collections.Generic.List[string]]::new() }
    $byProject[$project].Add($Relative[$i])
}

$ErrorActionPreference = 'Continue'
$reports = [System.Collections.Generic.List[string]]::new()
foreach ($project in $byProject.Keys) {
    $output = & $BuildTool build $project --no-restore -nologo -v q 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) { continue }

    $projectName = [IO.Path]::GetFileName($project)
    $errors = @($output -split "`r?`n" | Where-Object { $_ -match '(?i)\berror\b' } | Select-Object -Unique -First 40)
    if ($errors.Count -eq 0) { $errors = @($output -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 20) }
    $reports.Add("$projectName no longer builds after the edit to $($byProject[$project] -join ', '). Fix these before the next step:`n" + ($errors -join "`n"))
}

if ($reports.Count -gt 0) { Write-Output ($reports -join "`n`n") }
exit 0
