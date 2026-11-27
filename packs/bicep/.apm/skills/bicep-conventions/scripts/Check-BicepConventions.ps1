#Requires -Version 7
<#
.SYNOPSIS
    Checks two Bicep rules that a reviewer had to catch by hand: no module pinned to latest, and no role ID written inline.

.DESCRIPTION
    Two rules, each chosen with -Rule, both advisory in gates.json, so a finding never stops a push.

      ModuleTag (clause BICEP-01, the default) reads every .bicep and .bicepparam file. It reports a registry reference
        that ends in the tag latest, such as 'br/<alias>:<path>:latest' or 'br:<host>/<path>:latest'. It counts
        after module, test, import, from, extension and provider, after a using that starts its line, and at
        the start of a line, so the same text assigned to a variable or a property does not. The match
        ignores case. A tag
        that only starts with latest, such as latest-main, is fine. This rule never exits 2.
      RoleId (clause BICEP-02) reads every .bicep and .bicepparam file. aisdlc.json names the lookup
        files that hold the role IDs (bicep.roleLookupFiles, a list of paths from the repository root).
        The rule reports each line outside those files that holds a GUID which a lookup file holds, so a
        role ID comes from the lookup and is never typed again. The match ignores case. The key has no
        default, so a repository that sets none gets exit 3.

    The comments of a file are blanked before the lines are read, so a tag or a GUID inside a comment
    is not reported and each line keeps its number. The scan follows the Bicep rules for strings
    (Azure docs, Bicep data types, the sections Strings and Multi-line strings): a string ends at its
    closing single quote or at the end of its line, a backslash escapes the next character, and a
    string in three single quotes holds everything as it is, with no escapes. A // or /* inside a
    string is text, not a comment. One limit: a string nested inside a ${...} interpolation is not
    followed, so a // inside such a nested string can hide the rest of its line from the check.

    The folders .claude, .git, apm_modules and node_modules are skipped, matched on the path inside
    the repository. Each finding is one line of the form "path:line text". Exit codes follow the gate
    contract: 0 nothing found, 1 a rule is violated, 2 could not check (RoleId only: a lookup file is
    missing or holds no GUID), 3 not applicable (no Bicep file, or no bicep.roleLookupFiles).

.PARAMETER Rule
    ModuleTag or RoleId. Defaults to ModuleTag.

.PARAMETER RepoRoot
    Repository root to scan. Defaults to the folder that holds aisdlc.json, found from this script.

.EXAMPLE
    pwsh -NoProfile -File Check-BicepConventions.ps1 -Rule RoleId
#>
[CmdletBinding()]
param(
    [ValidateSet('ModuleTag', 'RoleId')]
    [string]$Rule = 'ModuleTag',
    [string]$RepoRoot
)

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$clausePage = '.claude/skills/bicep-conventions/references/clauses.md'
$latestReference = "(?:\b(?:module|test)\s+\S+\s+|\b(?:from|extension|provider|import)\s+|^\s*using\s+|^\s*)'br(?::[^'\s]+|/[^:'\s]+:[^'\s]+):latest'"
$guidPattern = '\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'
$rootFull = (Resolve-Path -LiteralPath $RepoRoot).Path

function Get-BlankedText {
    param([string]$Text)

    $length = $Text.Length
    $out = [System.Text.StringBuilder]::new($length)
    $i = 0
    while ($i -lt $length) {
        $c = $Text[$i]
        $next = if ($i + 1 -lt $length) { $Text[$i + 1] } else { [char]0 }
        if ($c -eq "'" -and [string]::CompareOrdinal($Text, $i, "'''", 0, 3) -eq 0) {
            $end = $Text.IndexOf("'''", $i + 3, [System.StringComparison]::Ordinal)
            $stop = if ($end -lt 0) { $length } else { $end + 3 }
            [void]$out.Append($Text, $i, $stop - $i)
            $i = $stop
        }
        elseif ($c -eq "'") {
            [void]$out.Append($c)
            $i++
            while ($i -lt $length -and $Text[$i] -ne "'" -and $Text[$i] -ne "`n") {
                if ($Text[$i] -eq '\' -and $i + 1 -lt $length -and $Text[$i + 1] -ne "`n") {
                    [void]$out.Append($Text[$i])
                    $i++
                }
                [void]$out.Append($Text[$i])
                $i++
            }
            if ($i -lt $length -and $Text[$i] -eq "'") {
                [void]$out.Append("'")
                $i++
            }
        }
        elseif ($c -eq '/' -and $next -eq '/') {
            while ($i -lt $length -and $Text[$i] -ne "`n" -and $Text[$i] -ne "`r") {
                [void]$out.Append(' ')
                $i++
            }
        }
        elseif ($c -eq '/' -and $next -eq '*') {
            $end = $Text.IndexOf('*/', $i + 2, [System.StringComparison]::Ordinal)
            $stop = if ($end -lt 0) { $length } else { $end + 2 }
            for ($k = $i; $k -lt $stop; $k++) {
                [void]$out.Append($(if ($Text[$k] -eq "`n" -or $Text[$k] -eq "`r") { $Text[$k] } else { ' ' }))
            }
            $i = $stop
        }
        else {
            [void]$out.Append($c)
            $i++
        }
    }
    return $out.ToString()
}

function Get-BicepFile {
    param([string[]]$Extension)

    $files = foreach ($ext in $Extension) {
        Get-ChildItem -LiteralPath $rootFull -Recurse -File -Filter "*$ext" | Where-Object { $_.Extension -ieq $ext }
    }
    return @($files | Where-Object { -not (Test-AiSdlcPathExcluded -RepoRoot $rootFull -FullName $_.FullName -Folder @('.claude', '.git', 'apm_modules', 'node_modules')) } | Sort-Object FullName)
}

function Get-RelativePath {
    param([string]$FullName)
    return [IO.Path]::GetRelativePath($rootFull, $FullName).Replace('\', '/')
}

function Get-CodeText {
    param([string]$FullName, [string]$Text)

    if (-not $Text) { return '' }
    if ($FullName -match '\.bicep(param)?$') { return Get-BlankedText -Text $Text }
    return $Text
}

function Find-Line {
    param([string]$FullName, [scriptblock]$Test)

    $raw = Get-Content -LiteralPath $FullName -Raw
    $original = @($raw -split "`r?`n")
    $code = @((Get-CodeText -FullName $FullName -Text $raw) -split "`r?`n")
    $relative = Get-RelativePath -FullName $FullName
    for ($n = 0; $n -lt $code.Count; $n++) {
        if (& $Test $code[$n]) {
            [pscustomobject]@{ File = $relative; Line = $n + 1; Text = $original[$n].Trim() }
        }
    }
}

function Write-Violation {
    param([object[]]$Items)
    foreach ($v in $Items) { Write-Host ("  {0}:{1} {2}" -f $v.File, $v.Line, $v.Text) }
}

function Get-LookupGuid {
    param([string[]]$FullName)

    $guids = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($file in $FullName) {
        foreach ($m in [regex]::Matches((Get-CodeText -FullName $file -Text (Get-Content -LiteralPath $file -Raw)),$guidPattern, 'IgnoreCase')) { [void]$guids.Add($m.Value.ToLowerInvariant()) }
    }
    return , $guids
}

function Invoke-ModuleTagRule {
    param([object[]]$Files)

    $found = @($Files | ForEach-Object { Find-Line -FullName $_.FullName -Test { param($line) $line -match $latestReference } })
    if ($found.Count -gt 0) {
        Write-Host "A registry module is pinned to the tag latest ($clausePage, BICEP-01)." -ForegroundColor Red
        Write-Violation -Items $found
        Write-Host ("Found {0} reference(s) to a module tag latest." -f $found.Count) -ForegroundColor Red
        Write-Host 'FIX: Pin each registry module to a dated tag, such as 2026.01.01.1-main, and never to latest.' -ForegroundColor Red
        exit 1
    }
    Write-Host ("Module tags OK: {0} Bicep file(s) hold no registry module pinned to latest." -f $Files.Count)
    exit 0
}

function Invoke-RoleIdRule {
    param([object[]]$Files, [object]$Config)

    $section = $Config.PSObject.Properties['bicep']
    $setting = if ($section -and $section.Value) { $section.Value['roleLookupFiles'] } else { $null }
    $lookups = @($setting | Where-Object { $_ } | ForEach-Object { "$_" })
    if ($lookups.Count -eq 0) {
        Write-Host 'Not applicable: aisdlc.json sets no bicep.roleLookupFiles, so there is no lookup file to compare role IDs with.'
        exit 3
    }
    $lookupFull = @($lookups | ForEach-Object { [IO.Path]::GetFullPath($_, $rootFull) })
    foreach ($i in 0..($lookups.Count - 1)) {
        if (-not (Test-Path -LiteralPath $lookupFull[$i] -PathType Leaf)) {
            Write-Host "Could not check: the lookup file $($lookups[$i]) from bicep.roleLookupFiles does not exist."
            Write-Host "FIX: Correct the path $($lookups[$i]) in bicep.roleLookupFiles in aisdlc.json, or add the file, then run this check again." -ForegroundColor Yellow
            exit 2
        }
    }
    $guids = Get-LookupGuid -FullName $lookupFull
    if ($guids.Count -eq 0) {
        Write-Host 'Could not check: the lookup files of bicep.roleLookupFiles hold no role ID (a GUID outside a comment).'
        Write-Host 'FIX: Point bicep.roleLookupFiles in aisdlc.json at the file that holds the role IDs, then run this check again.' -ForegroundColor Yellow
        exit 2
    }
    $lookupSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$lookupFull,[System.StringComparer]::OrdinalIgnoreCase)
    $others = @($Files | Where-Object { -not $lookupSet.Contains($_.FullName) })
    $found = @($others | ForEach-Object {
            Find-Line -FullName $_.FullName -Test {
                param($line)
                foreach ($m in [regex]::Matches($line, $guidPattern, 'IgnoreCase')) { if ($guids.Contains($m.Value.ToLowerInvariant())) { return $true } }
                return $false
            }
        })
    if ($found.Count -gt 0) {
        Write-Host "A role ID is written inline instead of read from a lookup file ($clausePage, BICEP-02)." -ForegroundColor Red
        Write-Violation -Items $found
        Write-Host ("Found {0} line(s) with an inline role ID." -f $found.Count) -ForegroundColor Red
        Write-Host 'FIX: Read each role ID from the lookup file that bicep.roleLookupFiles names, and never type the GUID again.' -ForegroundColor Red
        exit 1
    }
    Write-Host ("Role IDs OK: {0} Bicep file(s) outside the lookup file(s) hold none of the {1} role ID(s) of the lookup." -f $others.Count, $guids.Count)
    exit 0
}

$extensions = @('.bicep', '.bicepparam')
$files = @(Get-BicepFile -Extension $extensions)
if ($files.Count -eq 0) {
    Write-Host "Not applicable: the repository holds no Bicep file ($($extensions -join ', ')), so there is nothing to check."
    exit 3
}

if ($Rule -eq 'ModuleTag') { Invoke-ModuleTagRule -Files $files }
Invoke-RoleIdRule -Files $files -Config (Get-AiSdlcConfig -RepoRoot $RepoRoot)
