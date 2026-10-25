#Requires -Version 7
<#
.SYNOPSIS
    Enforces constitution clause DOTNET-01: the JSON wire format is PascalCase.

.DESCRIPTION
    Two static checks, both run from the repository source - no build, no running service.

    Part A - PascalCase wire names (the DOTNET-01 violation):
        Scans .cs files under the source root (paths.sourceRoot in aisdlc.json) for [JsonPropertyName("value")] attributes whose
        serialized value is snake_case or camelCase, i.e. NOT PascalCase. System.Text.Json
        serialises by property name (PascalCase) by default, so a [JsonPropertyName] that
        downgrades the wire name to snake_case or camelCase is the accidental slip DOTNET-01 forbids.

        An allowlist covers the legitimate reasons a wire name must differ from the property:
          - CosmosDB system fields:        id, ttl, _etag, _ts
          - other leading-underscore names (_*): treated as system/document metadata
          - dotted paths (a.b.c):          external projection / partition-key style keys
          - scoped partition keys:         a name that IS a Cosmos partition key path, exempt only
                                           in the one file that declares it, with the reason
                                           recorded next to it ($scopedAllowList). A partition key
                                           path cannot change once a container exists, so the wire
                                           name cannot either.
          - all-lowercase single words:    deliberate matches to an external contract
                                           (Slack: ok/ts/error; OpsGenie: message/tags/source).
                                           These cannot arise from an accidental PascalCase
                                           property being serialised verbatim, so they are not
                                           treated as DOTNET-01 violations.
        Everything else that is snake_case or camelCase is flagged. A PascalCase value that EQUALS the
        property name it decorates is also flagged as redundant: System.Text.Json already serialises by
        the PascalCase property name, so the attribute adds nothing (DOTNET-01: do not add it unnecessarily).
        A PascalCase value that DIFFERS from the property name is a deliberate rename and is allowed.
        The decorated member is found best-effort; when it cannot be determined the attribute is not
        flagged, to avoid false positives. Files under the external-integration paths
        (dotnet.externalContractPaths in aisdlc.json) are skipped entirely: their DTOs mirror
        third-party API wire names, which DOTNET-01 does not govern.

    Part B - spec well-formedness:
        If specs/ contains *.openapi.yaml or *.yaml files, each must parse as YAML and every
        schema property name under components.schemas.*.properties must be PascalCase. If specs/
        is absent or empty, this part is a no-op and reports "no specs yet". If specs exist but no
        YAML parser is installed, nothing read them, so the script exits 2 (could not check) rather
        than reporting a violation for a missing module.

    OUT OF SCOPE - code-vs-spec drift:
        This script does NOT verify that an OpenAPI document matches the wire format the running
        API actually emits. True drift detection requires generating the OpenAPI from the build
        (Swagger/Swashbuckle) and diffing it against the committed spec; that is a separate,
        larger pipeline step. Do not assume this static check covers drift - it does not.

    Sibling of Check-DocLineCitations.ps1 (clause C02) and Check-DocEmDashes.ps1 (clause C06):
    same shape (param/help/exit codes, "file:line text" output) so the CI gate treats them alike.

.PARAMETER YamlParserAvailableForTest
    Test seam only: stands in for "is a YAML parser installed", so the could-not-check path can be
    exercised on a machine that has one. Never set in CI.

.PARAMETER RepoRoot
    Repository root that contains the source root and (optionally) specs/. Defaults to the folder that
    holds aisdlc.json, found from this script.

.EXAMPLE
    pwsh .claude/skills/dotnet-gates/scripts/Check-ApiPascalCase.ps1
    Runs both checks against the repository and exits 0 (clean) or 1 (violations found).
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [bool]$YamlParserAvailableForTest
)

$aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
Import-Module (Join-Path $aiSdlcGates 'AiSdlcConfig.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }

$ErrorActionPreference = 'Stop'

$exactAllowList = @('id', 'ttl', '_etag', '_ts')

# Names that must differ for a reason that is specific to ONE declaring file, so the exemption is
# scoped to that file rather than opening the name repository-wide. Every entry carries the reason
# it cannot be renamed; an entry without one is not an exemption, it is unrecorded debt.
$aiSdlc = Get-AiSdlcConfig -RepoRoot $RepoRoot
$scopedAllowList = @($aiSdlc.dotnet.wireNameAllowlist | Where-Object { $_ } | ForEach-Object {
        @{ Name = $_.name; File = $_.file; Reason = $_.reason }
    })

# External-integration libraries whose DTOs deserialize third-party APIs (for example an address or asset
# system); their wire names are dictated by those APIs, not our own surface, so DOTNET-01 does not apply.
# Excluded wholesale here; a future inline opt-out marker on individual DTOs would be more precise.
$externalIntegrationPaths = @($aiSdlc.dotnet.externalContractPaths | Where-Object { $_ })

function Test-IsPascalCase {
    param([string]$Name)
    return $Name -cmatch '^[A-Z][A-Za-z0-9]*$'
}

function Get-ScopedAllowListReason {
    param([string]$Name, [string]$File)

    foreach ($entry in $scopedAllowList) {
        if ($entry.Name -ceq $Name -and $entry.File -eq $File) { return $entry.Reason }
    }
    return $null
}

function Get-WireNameClassification {
    param([string]$Name, [string]$File)

    if (Get-ScopedAllowListReason -Name $Name -File $File) { return 'allow-partition-key' }
    if ($exactAllowList -contains $Name) { return 'allow-system' }
    if ($Name.StartsWith('_')) { return 'allow-system' }
    if ($Name.Contains('.')) { return 'allow-path' }
    if (Test-IsPascalCase $Name) { return 'pascal' }
    if ($Name -cmatch '^[a-z0-9]+$') { return 'allow-lowercase' }
    if ($Name.Contains('_')) { return 'snake_case' }
    if ($Name -cmatch '^[a-z][A-Za-z0-9]*$' -and $Name -cmatch '[A-Z]') { return 'camelCase' }
    return 'other'
}

# Pull the member identifier out of a declaration fragment: the name before `{`/`=>` (property) or
# before `;`/`=` (field). Returns $null when neither shape matches.
function Get-MemberNameFromText {
    param([string]$Text)

    $patterns = @(
        '(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*(\{|=>)',
        '(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*(;|=)'
    )
    foreach ($rx in $patterns) {
        $m = [regex]::Match($Text, $rx)
        if ($m.Success) { return $m.Groups['name'].Value }
    }
    return $null
}

# Best-effort: find the member identifier the attribute decorates, so a [JsonPropertyName] whose value
# equals the property name (redundant, DOTNET-01) can be told apart from a genuine PascalCase rename. Returns
# $null when the member cannot be determined; callers must not flag on a null (avoid false positives).
function Get-DecoratedMemberName {
    param(
        [string[]]$Lines,
        [int]$AttrIndex,
        [string]$RemainderAfterAttr
    )

    if ($RemainderAfterAttr -and $RemainderAfterAttr.Trim()) {
        $name = Get-MemberNameFromText $RemainderAfterAttr
        if ($name) { return $name }
    }

    for ($j = $AttrIndex + 1; $j -lt $Lines.Count -and $j -le $AttrIndex + 6; $j++) {
        $t = $Lines[$j].Trim()
        if ($t -eq '' -or $t.StartsWith('[')) { continue }
        return Get-MemberNameFromText $t
    }
    return $null
}

# Decide which bucket a [JsonPropertyName] value falls into: a wire-name 'violation' (snake/camel/other),
# a 'redundant' attribute (PascalCase value equal to the property name), or 'allowed'.
function Get-WireNameBucket {
    param(
        [string]$Class,
        [string]$Value,
        [string[]]$Lines,
        [int]$AttrIndex,
        [string]$Remainder
    )

    if ($Class -in @('snake_case', 'camelCase', 'other')) { return 'violation' }
    if ($Class -ne 'pascal') { return 'allowed' }

    $member = Get-DecoratedMemberName -Lines $Lines -AttrIndex $AttrIndex -RemainderAfterAttr $Remainder
    if ($member -and ($member -ceq $Value)) { return 'redundant' }
    return 'allowed'
}

# Scan one file's lines for [JsonPropertyName] attributes and return one entry per match, each carrying
# the display record and its bucket. Keeps the per-file scan out of the top-level Part A loop.
function Get-FileWireNameRecords {
    param(
        [string]$Rel,
        [string[]]$Lines,
        [string]$AttrRegex
    )

    $records = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        foreach ($m in [regex]::Matches($line, $AttrRegex)) {
            $value = $m.Groups['value'].Value
            $class = Get-WireNameClassification -Name $value -File $Rel
            $remainder = $line.Substring($m.Index + $m.Length)
            $records.Add([pscustomobject]@{
                    Record = [pscustomobject]@{ File = $Rel; Line = $i + 1; Value = $value; Class = $class; Text = $line.Trim() }
                    Bucket = Get-WireNameBucket -Class $class -Value $value -Lines $Lines -AttrIndex $i -Remainder $remainder
                })
        }
    }
    return $records
}

# --- Part A: PascalCase wire names under the source root ---

$srcRel = ([string]$aiSdlc.paths.sourceRoot).TrimEnd('/')
if (-not $srcRel) {
    Write-Host 'Could not check: aisdlc.json names no paths.sourceRoot.' -ForegroundColor Yellow
    exit 2
}
$srcDir = Join-Path $RepoRoot $srcRel
$attrRegex = '\[JsonPropertyName\("(?<value>[^"]*)"\)\]'

$violations = [System.Collections.Generic.List[object]]::new()
$redundant = [System.Collections.Generic.List[object]]::new()
$allowed = [System.Collections.Generic.List[object]]::new()

if (Test-Path $srcDir) {
    $csFiles = Get-ChildItem -Path $srcDir -Recurse -Filter *.cs -File
    foreach ($file in $csFiles) {
        $rel = [IO.Path]::GetRelativePath($RepoRoot, $file.FullName).Replace('\', '/')
        if ($externalIntegrationPaths.Where({ $rel.StartsWith($_) }, 'First')) { continue }
        $lines = @(Get-Content -LiteralPath $file.FullName)
        foreach ($entry in (Get-FileWireNameRecords -Rel $rel -Lines $lines -AttrRegex $attrRegex)) {
            switch ($entry.Bucket) {
                'violation' { $violations.Add($entry.Record) }
                'redundant' { $redundant.Add($entry.Record) }
                default { $allowed.Add($entry.Record) }
            }
        }
    }
}
else {
    Write-Host ("Note: source directory not found at {0}; skipping Part A." -f $srcDir) -ForegroundColor Yellow
}

# --- Part B: spec well-formedness under specs/ ---

$specsDir = Join-Path $RepoRoot $aiSdlc.paths.specsRoot
$specViolations = [System.Collections.Generic.List[object]]::new()
$specUnchecked = $false
$specFiles = @()
if (Test-Path $specsDir) {
    $specFiles = @(Get-ChildItem -Path $specsDir -Recurse -Include *.openapi.yaml, *.yaml, *.yml -File)
}

$yamlAvailable = if ($PSBoundParameters.ContainsKey('YamlParserAvailableForTest')) { $YamlParserAvailableForTest } else { $null -ne (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue) }

if ($specFiles.Count -gt 0) {
    if (-not $yamlAvailable) {
        $specUnchecked = $true
    }
    else {
        foreach ($file in $specFiles) {
            $rel = [IO.Path]::GetRelativePath($RepoRoot, $file.FullName).Replace('\', '/')
            $doc = $null
            try {
                $raw = Get-Content -LiteralPath $file.FullName -Raw
                $doc = ConvertFrom-Yaml $raw
            }
            catch {
                $specViolations.Add([pscustomobject]@{ File = $rel; Detail = ("does not parse as YAML: {0}" -f $_.Exception.Message) })
                continue
            }

            $schemas = $doc.components.schemas
            if ($null -eq $schemas) { continue }
            foreach ($schemaName in $schemas.Keys) {
                $props = $schemas[$schemaName].properties
                if ($null -eq $props) { continue }
                foreach ($propName in $props.Keys) {
                    if (-not (Test-IsPascalCase $propName)) {
                        $specViolations.Add([pscustomobject]@{
                                File   = $rel
                                Detail = ("components.schemas.{0}.properties.{1} is not PascalCase" -f $schemaName, $propName)
                            })
                    }
                }
            }
        }
    }
}

# --- Report ---

$failed = $false

Write-Host "DOTNET-01 - JSON wire format is PascalCase" -ForegroundColor Cyan

if ($allowed.Count -gt 0) {
    Write-Host ("Part A: {0} allowlisted [JsonPropertyName] value(s) (system field, leading-underscore, dotted path, scoped partition key, or external lowercase contract) - not flagged:" -f $allowed.Count)
    foreach ($a in ($allowed | Sort-Object Value, File)) {
        Write-Host ("  [{0}] {1}:{2}  {3}" -f $a.Class, $a.File, $a.Line, $a.Value)
        $reason = Get-ScopedAllowListReason -Name $a.Value -File $a.File
        if ($reason) { Write-Host ("        reason: {0}" -f $reason) }
    }
}

if ($violations.Count -gt 0) {
    $failed = $true
    Write-Host "Part A FAILED: [JsonPropertyName] values that are not PascalCase (DOTNET-01 violation)." -ForegroundColor Red
    Write-Host "FIX: Remove the attribute and let System.Text.Json use the PascalCase property name. Keep it only when the wire name really must differ (clause DOTNET-01)." -ForegroundColor Red
    foreach ($v in ($violations | Sort-Object File, Line)) {
        Write-Host ("  {0}:{1}  [{2}] {3}" -f $v.File, $v.Line, $v.Class, $v.Text)
    }
    Write-Host ("Found {0} non-PascalCase wire name(s)." -f $violations.Count) -ForegroundColor Red
}

if ($redundant.Count -gt 0) {
    $failed = $true
    Write-Host "Part A FAILED: redundant [JsonPropertyName] whose value equals the property name (DOTNET-01 violation)." -ForegroundColor Red
    Write-Host "Remove the attribute; System.Text.Json already serialises by the PascalCase property name. Only keep it when the wire name must differ (see .claude/skills/api-contract-conventions/references/api.md, clause DOTNET-01)." -ForegroundColor Red
    foreach ($r in ($redundant | Sort-Object File, Line)) {
        Write-Host ("  {0}:{1}  {2}" -f $r.File, $r.Line, $r.Text)
    }
    Write-Host ("Found {0} redundant [JsonPropertyName] attribute(s)." -f $redundant.Count) -ForegroundColor Red
}

if ($violations.Count -eq 0 -and $redundant.Count -eq 0) {
    Write-Host "Part A OK: every non-allowlisted [JsonPropertyName] under $srcRel/ is PascalCase and none is redundant."
}

if ($specFiles.Count -eq 0) {
    Write-Host "Part B: no specs yet (specs/ is absent or contains no YAML); skipping spec well-formedness check."
}
elseif ($specUnchecked) {
    Write-Host ("Part B COULD NOT BE CHECKED: {0} spec file(s) under specs/ were read by nothing, because this machine has no YAML parser." -f $specFiles.Count) -ForegroundColor Yellow
    Write-Host "  Install one with: Install-Module powershell-yaml -Scope CurrentUser" -ForegroundColor Yellow
    Write-Host "  The specs are not reported as correct and not as wrong; nothing looked at them." -ForegroundColor Yellow
}
elseif ($specViolations.Count -gt 0) {
    $failed = $true
    Write-Host ("Part B FAILED: {0} spec issue(s) under specs/." -f $specViolations.Count) -ForegroundColor Red
    foreach ($s in $specViolations) {
        Write-Host ("  {0}  {1}" -f $s.File, $s.Detail) -ForegroundColor Red
    }
}
else {
    Write-Host ("Part B OK: {0} spec file(s) parsed and all components.schemas.*.properties names are PascalCase." -f $specFiles.Count)
}

if ($failed) { exit 1 }

if ($specUnchecked) {
    Write-Host "DOTNET-01: Part A passed; Part B could not run without a YAML parser, so the specs were not checked."
    exit 2
}

Write-Host "DOTNET-01 OK: wire-name and spec checks passed."
exit 0
