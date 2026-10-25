#Requires -Version 7
<#
.SYNOPSIS
    Brings existing docs up to the AI-SDLC wiki rules where a machine can do it safely, and reports what
    is left for a person or an agent.

.DESCRIPTION
    A repository that installs the AI-SDLC often has docs already. The doc gates then fail on pages that
    were fine before: no index, pages that nothing links to, em-dashes. This script fixes the part that
    needs no judgement, in every docs root that aisdlc.json names, and never deletes text:

    1. It replaces each em-dash (U+2014) with a hyphen between spaces (clause C06).
    2. It gives a page with no H1 a title made from its file name, because the index takes its entry
       title from the H1.
    3. It gives a page with no "## Related" section one: a link to the layer index and to up to three
       pages next to it (in the same folder, else at the top of the layer, else anywhere in it), each
       described by where it sits. That clears orphan and isolated pages (clause C05). It does not copy
       text from the other page: a copied sentence goes stale, and it would carry a line number or a
       hard word from that page into this one. Whoever rewrites the page later gives each link a
       better description.
    4. It writes the docs index with Build-DocsIndex.ps1.
    5. It runs the blocking gates and prints what is still failing: in practice the reading level,
       broken links and line-number citations, which need a person or the adopt-docs skill.

    Decision records (the ADR folder) are point-in-time records: they only get a Related section and an
    em-dash fix, never a new title.

.PARAMETER RepoRoot
    The repository root. Defaults to the folder that holds aisdlc.json.

.PARAMETER NoGates
    Skip step 5.

.EXAMPLE
    pwsh .claude/skills/adopt-docs/scripts/Repair-DocsWiki.ps1

.EXAMPLE
    pwsh .claude/skills/adopt-docs/scripts/Repair-DocsWiki.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$RepoRoot,
    [switch]$NoGates
)

$ErrorActionPreference = 'Stop'
$gates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
Import-Module (Join-Path $gates 'AiSdlcConfig.psm1') -Force
$config = Get-AiSdlcConfig -RepoRoot $RepoRoot
$RepoRoot = $config.repoRoot
$emDash = [string][char]0x2014
$adrFolder = [IO.Path]::GetFullPath((Join-Path $RepoRoot $config.paths.adrFolder))

function Get-Placement {
    param([System.IO.FileInfo]$Other, [string]$Folder, [string]$Layer)
    if ($Other.DirectoryName -eq $Folder) { return 'a page in the same folder.' }
    if ($Other.DirectoryName -eq $Layer) { return 'a page at the top of the docs.' }
    return "a page in $([IO.Path]::GetRelativePath($Layer, $Other.DirectoryName).Replace('\', '/'))."
}

function Get-Title {
    param([string]$Text, [string]$FileName)
    $m = [regex]::Match($Text, '(?m)^#\s+(.+?)\s*$')
    if ($m.Success) { return [regex]::Replace($m.Groups[1].Value, "\s*$emDash\s*", ' - ') }
    $name = [IO.Path]::GetFileNameWithoutExtension($FileName) -replace '[-_]+', ' '
    return (Get-Culture).TextInfo.ToTitleCase($name)
}

$changed = [System.Collections.Generic.List[string]]::new()
foreach ($root in @($config.paths.docsRoots)) {
    $layer = Join-Path $RepoRoot $root
    if (-not (Test-Path -LiteralPath $layer)) { continue }
    $pages = @(Get-ChildItem -LiteralPath $layer -Recurse -File -Filter '*.md' |
        Where-Object { $_.Name -notin 'index.md' -and $_.Name -notmatch '^0000-template' -and $_.FullName -notmatch '[\\/](node_modules|\.git)[\\/]' } |
        Sort-Object FullName)
    $texts = @{}
    foreach ($p in $pages) { $texts[$p.FullName] = (Get-Content -LiteralPath $p.FullName -Raw) -replace "`r`n", "`n" }
    $indexPath = Join-Path $layer 'index.md'

    foreach ($page in $pages) {
        $text = $texts[$page.FullName]
        $original = $text
        $isAdr = $page.FullName.StartsWith($adrFolder, [StringComparison]::OrdinalIgnoreCase)

        if ($text.Contains($emDash)) { $text = [regex]::Replace($text, "\s*$emDash\s*", ' - ') }

        if (-not $isAdr -and $text -notmatch '(?m)^#\s+\S') {
            $title = Get-Title -Text $text -FileName $page.Name
            if ($text -match '\A---\r?\n') { $text = [regex]::Replace($text, '\A(---\r?\n.*?\r?\n---\r?\n)', "`$1`n# $title`n`n", 'Singleline') }
            else { $text = "# $title`n`n" + $text }
        }

        if ($text -notmatch '(?m)^##\s+Related\s*$') {
            $folder = $page.DirectoryName
            $near = @($pages | Where-Object { $_.FullName -ne $page.FullName -and $_.DirectoryName -eq $folder })
            if ($near.Count -lt 1) { $near = @($pages | Where-Object { $_.FullName -ne $page.FullName -and $_.DirectoryName -eq $layer }) }
            if ($near.Count -lt 1) { $near = @($pages | Where-Object { $_.FullName -ne $page.FullName }) }
            $lines = [System.Collections.Generic.List[string]]::new()
            $lines.Add("- [Index]($([IO.Path]::GetRelativePath($folder, $indexPath).Replace('\', '/'))) - every page of this wiki.")
            foreach ($other in ($near | Select-Object -First 3)) {
                $lines.Add("- [$(Get-Title -Text $texts[$other.FullName] -FileName $other.Name)]($([IO.Path]::GetRelativePath($folder, $other.FullName).Replace('\', '/'))) - $(Get-Placement -Other $other -Folder $folder -Layer $layer)")
            }
            $text = $text.TrimEnd() + "`n`n## Related`n`n" + ($lines -join "`n") + "`n"
        }

        if ($text -ne $original -and $PSCmdlet.ShouldProcess([IO.Path]::GetRelativePath($RepoRoot, $page.FullName), 'bring up to the wiki rules')) {
            [IO.File]::WriteAllText($page.FullName, $text, [Text.UTF8Encoding]::new($false))
            $changed.Add([IO.Path]::GetRelativePath($RepoRoot, $page.FullName).Replace('\', '/'))
        }
    }
}

if ($PSCmdlet.ShouldProcess('docs index', 'write')) {
    pwsh -NoProfile -File (Join-Path $gates 'Build-DocsIndex.ps1') -RepoRoot $RepoRoot | Out-Null
}
Write-Host ("Docs brought up to the wiki rules: {0} page(s) changed." -f $changed.Count)
foreach ($c in $changed) { Write-Host "  $c" }

if ($NoGates -or $WhatIfPreference) { exit 0 }
Write-Host 'Running the blocking gates to see what is left...'
pwsh -NoProfile -File (Join-Path $gates 'Invoke-LocalGates.ps1') -RepoRoot $RepoRoot -BlockingOnly
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Some doc gates still fail. What is left needs judgement: run the adopt-docs skill to rewrite for the reading level, repair broken links and remove line-number citations.' -ForegroundColor Yellow
    exit 1
}
Write-Host 'All blocking gates pass.'
exit 0
