#Requires -Version 7
<#
.SYNOPSIS
    Writes the catalog of every skill and agent in every package of AI.SDLC, or checks it is current.

.DESCRIPTION
    A core skill may name a skill of a pack, for example the Next steps of a workflow skill. In a
    repository that did not install that pack, the named skill is not there, and the skill hygiene gate
    would report a broken reference. The catalog lists which package ships which skill and agent, so the
    gate can tell "belongs to a pack this repository did not install" from "does not exist anywhere".

    The catalog is written to core/.apm/skills/ai-sdlc-gates/skill-catalog.json, so every repository gets
    it with the core. With -Check the script writes nothing and exits 1 when the catalog is out of date.

.PARAMETER RepoRoot
    The AI.SDLC repository root. Defaults to the folder above this script.

.PARAMETER Check
    Compare only. Exit 1 when the catalog differs from the packages.

.EXAMPLE
    pwsh tools/Update-SkillCatalog.ps1

.EXAMPLE
    pwsh tools/Update-SkillCatalog.ps1 -Check
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'

$packages = [ordered]@{ core = Join-Path $RepoRoot 'core' }
foreach ($pack in Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'packs') -Directory | Sort-Object Name) {
    $packages[$pack.Name] = $pack.FullName
}

$catalog = [ordered]@{ skills = [ordered]@{}; agents = [ordered]@{} }
foreach ($name in $packages.Keys) {
    $apm = Join-Path $packages[$name] '.apm'
    $skills = @(Get-ChildItem -LiteralPath (Join-Path $apm 'skills') -Directory -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object Name)
    $agents = @(Get-ChildItem -LiteralPath (Join-Path $apm 'agents') -Filter '*.agent.md' -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { $_.Name -replace '\.agent\.md$', '' })
    $catalog.skills[$name] = $skills
    $catalog.agents[$name] = $agents
}

$duplicates = @($catalog.skills.Values | ForEach-Object { $_ } | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
if ($duplicates.Count -gt 0) {
    Write-Host ("Skill catalog: a skill name is shipped by more than one package: {0}." -f ($duplicates -join ', ')) -ForegroundColor Red
    exit 1
}

$json = ($catalog | ConvertTo-Json -Depth 5) -replace "`r`n", "`n"
$json += "`n"
$target = Join-Path $RepoRoot 'core' '.apm' 'skills' 'ai-sdlc-gates' 'skill-catalog.json'

$current = if (Test-Path -LiteralPath $target) { (Get-Content -LiteralPath $target -Raw) -replace "`r`n", "`n" } else { '' }
if ($current -ceq $json) {
    Write-Host ("Skill catalog OK: {0} package(s), {1} skill(s), {2} agent(s)." -f $packages.Count, @($catalog.skills.Values | ForEach-Object { $_ }).Count, @($catalog.agents.Values | ForEach-Object { $_ }).Count)
    exit 0
}

if ($Check) {
    Write-Host 'Skill catalog out of date: a skill or agent was added, moved or removed since the catalog was written.' -ForegroundColor Red
    Write-Host 'FIX: Run pwsh tools/Update-SkillCatalog.ps1 and commit the catalog.' -ForegroundColor Red
    Write-Host '  core/.apm/skills/ai-sdlc-gates/skill-catalog.json  differs from the packages'
    exit 1
}

New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
[IO.File]::WriteAllText($target, $json, [Text.UTF8Encoding]::new($false))
Write-Host "Skill catalog written: $target"
exit 0
