#Requires -Version 7
<#
.SYNOPSIS
    Turns the result of one gate into GitHub Actions annotations, so Invoke-Gate.ps1 and
    Invoke-LocalGates.ps1 report a gate in a workflow the same way.

.DESCRIPTION
    A gate reports through its exit code: 0 passed, 1 found a violation, 2 could not check. This module
    reads the output of the gate and writes workflow commands that say what is wrong, where it is, why
    it is wrong and how to fix it:

        ::error file=<path>,line=<n>,title=<gate>::<message>

    An Advisory gate writes ::warning instead of ::error. At most five findings of one gate get their
    own annotation. The rules for reading the output are described in Invoke-Gate.ps1.

    The commands are written only when GITHUB_ACTIONS is true. Outside GitHub Actions the same text is
    printed as plain lines that start with ERROR or WARNING, so a local run shows the same advice.

    Each Write function returns the result the gate earns (Succeeded, SucceededWithIssues or Failed)
    and a one-line summary. The caller turns the result into its exit code; the module never exits.

.EXAMPLE
    Import-Module ./GateAnnotation.psm1
    $lines = & ./Check-DocEmDashes.ps1 *>&1
    $outcome = Write-GateAnnotation -Lines $lines -ExitCode $LASTEXITCODE -Clause C06 -What 'no em-dash characters' -Mode Blocking -HowToRepeat 'pwsh ./Check-DocEmDashes.ps1'
    if ($outcome.Result -eq 'Failed') { exit 1 }
#>

$script:WithLine = '^(?<path>[A-Za-z0-9_.\\/-]+\.[A-Za-z0-9]{1,10}):(?<line>\d+)\s*(?<rest>.*)$'
$script:WithoutLine = '^(?<path>[A-Za-z0-9_.\\/-]+\.[A-Za-z0-9]{1,10})\s+:\s+(?<rest>.+)$'
$script:FixMarker = '^\s*FIX:\s*(?<fix>\S.*)$'

function Format-GateMessage {
    param([string]$Text, [int]$Max = 400)

    $clean = ($Text -replace '^\s*::(error|warning)::', '') -replace '\s+', ' '
    $clean = $clean.Trim()
    if ($clean.Length -gt $Max) { $clean = $clean.Substring(0, $Max) + '...' }
    return $clean
}

function ConvertTo-WorkflowData {
    param([string]$Text, [switch]$Property)

    $escaped = $Text.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
    if ($Property) { $escaped = $escaped.Replace(':', '%3A').Replace(',', '%2C') }
    return $escaped
}

function Write-GateCommand {
    param(
        [ValidateSet('error', 'warning')][string]$Type,
        [string]$Message,
        [string]$Title,
        [string]$File,
        [string]$Line
    )

    if ($env:GITHUB_ACTIONS -eq 'true') {
        $properties = @()
        if ($File) { $properties += 'file=' + (ConvertTo-WorkflowData $File -Property) }
        if ($File -and $Line) { $properties += 'line=' + (ConvertTo-WorkflowData $Line -Property) }
        if ($Title) { $properties += 'title=' + (ConvertTo-WorkflowData $Title -Property) }
        $head = if ($properties) { "::$Type " + ($properties -join ',') } else { "::$Type" }
        Write-Host ("{0}::{1}" -f $head, (ConvertTo-WorkflowData $Message))
        return
    }
    $where = if ($File -and $Line) { "$File`:$Line - " } elseif ($File) { "$File - " } else { '' }
    Write-Host ("{0} {1}{2}" -f $Type.ToUpperInvariant(), $where, $Message)
}

function Get-GateFixLine {
    param([string[]]$Lines)

    foreach ($line in @($Lines | ForEach-Object { "$_" })) {
        if ($line -match $script:FixMarker) { return Format-GateMessage $Matches['fix'] }
    }
    return $null
}

function Remove-GateFixLine {
    param([string[]]$Lines)

    return @($Lines | ForEach-Object { "$_" } | Where-Object { $_ -notmatch $script:FixMarker })
}

function Get-GateFindingBoundary {
    param([string[]]$Text)

    for ($i = 0; $i -lt $Text.Count; $i++) {
        if ($Text[$i] -notmatch '^\s{2,}\S') { continue }
        $body = $Text[$i].Trim()
        if ($body -match $script:WithLine -or $body -match $script:WithoutLine) { return $i }
    }
    for ($i = 0; $i -lt $Text.Count; $i++) {
        if ($Text[$i] -match '^\s{2,}\S') { return $i }
    }
    return -1
}

function Get-GateRuleLine {
    param([string[]]$Lines)

    $text = Remove-GateFixLine -Lines $Lines
    $boundary = Get-GateFindingBoundary -Text $text

    if ($boundary -gt 0) {
        $above = @($text[0..($boundary - 1)] | Where-Object { $_.Trim() -and $_ -notmatch '^\s' })
        if ($above.Count -gt 0) { return Format-GateMessage $above[-1] }
    }

    $plain = @($text | Where-Object { $_.Trim() -and $_ -notmatch '^\s' })
    if ($plain.Count -gt 0) { return Format-GateMessage $plain[0] }

    $any = @($text | Where-Object { $_.Trim() })
    if ($any.Count -gt 0) { return Format-GateMessage $any[0] }
    return 'the gate printed nothing'
}

function Get-GateFinding {
    param([string[]]$Lines)

    $indented = @(Remove-GateFixLine -Lines $Lines | Where-Object { $_ -match '^\s{2,}\S' })
    $located = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $indented) {
        $body = $line.Trim()
        if ($body -match $script:WithLine) {
            $located.Add([pscustomobject]@{ Path = $Matches['path']; Line = $Matches['line']; Text = $Matches['rest'] })
        }
        elseif ($body -match $script:WithoutLine) {
            $located.Add([pscustomobject]@{ Path = $Matches['path']; Line = $null; Text = $Matches['rest'] })
        }
    }
    if ($located.Count -gt 0) { return $located.ToArray() }

    return @($indented | ForEach-Object { [pscustomobject]@{ Path = $null; Line = $null; Text = $_.Trim() } })
}

function Show-GateFinding {
    param([object[]]$Findings, [string]$Type, [string]$Clause, [string]$Title, [int]$Max = 5)

    foreach ($finding in ($Findings | Select-Object -First $Max)) {
        $path = if ($finding.Path) { ([string]$finding.Path).Replace('\', '/') } else { $null }
        Write-GateCommand -Type $Type -Title $Title -File $path -Line $finding.Line -Message ("{0}: {1}" -f $Clause, (Format-GateMessage $finding.Text))
    }
}

function Get-GateRepeatCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Script, [string]$RepoRoot)

    $scriptFull = [IO.Path]::GetFullPath($Script)
    $repeatRoot = if ($RepoRoot) { [IO.Path]::GetFullPath($RepoRoot) }
    elseif (Test-Path -LiteralPath $scriptFull) {
        Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1')
        Find-AiSdlcRepoRoot -StartPath (Split-Path -Parent $scriptFull)
    }
    $repeatPath = if ($repeatRoot) { [IO.Path]::GetRelativePath($repeatRoot, $scriptFull).Replace('\', '/') } else { $Script.Replace('\', '/') }
    if ($repeatPath.StartsWith('..')) { $repeatPath = $Script.Replace('\', '/') }
    return "pwsh $repeatPath"
}

function Write-GateAnnotation {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Lines,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][string]$Clause,
        [Parameter(Mandatory)][string]$What,
        [ValidateSet('Advisory', 'Blocking')][string]$Mode = 'Advisory',
        [Parameter(Mandatory)][string]$HowToRepeat
    )

    $text = @($Lines | ForEach-Object { "$_" })

    if ($ExitCode -eq 0) { return [pscustomobject]@{ Result = 'Succeeded'; Summary = "${Clause}: $What passed" } }

    if ($ExitCode -eq 2) {
        $why = Get-GateRuleLine -Lines $text
        $fix = Get-GateFixLine -Lines $text
        $howToFix = if ($fix) { " Fix: $fix" } else { ' Nobody on this pull request can fix it by changing the code; it needs whatever the reason names.' }
        Write-GateCommand -Type warning -Title $What -Message ("{0}: {1} COULD NOT BE CHECKED, so this is neither a pass nor a violation. Why: {2}{3} Repeat it locally with: {4}" -f $Clause, $What, $why, $howToFix, $HowToRepeat)
        return [pscustomobject]@{ Result = 'SucceededWithIssues'; Summary = "${Clause}: $What could not be checked" }
    }

    $nonEmpty = @(Remove-GateFixLine -Lines $text | Where-Object { $_.Trim() })
    $rule = Get-GateRuleLine -Lines $text
    $summary = if ($nonEmpty.Count -gt 0) { Format-GateMessage $nonEmpty[-1] } else { 'the gate reported no summary line' }
    if ($summary -eq $rule) { $summary = '' }
    $fix = Get-GateFixLine -Lines $text
    $howToFix = if ($fix) { " Fix: $fix" } else { '' }

    $findings = @(Get-GateFinding -Lines $text)
    $type = if ($Mode -eq 'Blocking') { 'error' } else { 'warning' }
    Show-GateFinding -Findings $findings -Type $type -Clause $Clause -Title $What

    $shown = [Math]::Min($findings.Count, 5)
    $rest = if ($findings.Count -gt $shown) { " {0} more are in the log above." -f ($findings.Count - $shown) }
    elseif ($findings.Count -eq 0) { ' The gate named no single place; its whole output is in the log above.' }
    else { '' }

    if ($Mode -eq 'Blocking') {
        Write-GateCommand -Type error -Title $What -Message ("{0}: {1} FAILED. Why: {2} {3}{4}{5} This gate blocks the build. Repeat it locally with: {6}" -f $Clause, $What, $rule, $summary, $rest, $howToFix, $HowToRepeat)
        return [pscustomobject]@{ Result = 'Failed'; Summary = "${Clause}: $What failed" }
    }
    Write-GateCommand -Type warning -Title $What -Message ("{0} advisory: {1} found issues. Why: {2} {3}{4}{5} Not blocking yet; this is tracked debt to clear before the gate turns blocking. Repeat it locally with: {6}" -f $Clause, $What, $rule, $summary, $rest, $howToFix, $HowToRepeat)
    return [pscustomobject]@{ Result = 'SucceededWithIssues'; Summary = "$Clause advisory: issues found" }
}

function Write-GateCrashAnnotation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Clause,
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [Parameter(Mandatory)][string]$HowToRepeat
    )

    $leaf = Split-Path -Leaf $Script
    $where = if ($ErrorRecord.InvocationInfo -and $ErrorRecord.InvocationInfo.ScriptName) { " at $($ErrorRecord.InvocationInfo.ScriptName):$($ErrorRecord.InvocationInfo.ScriptLineNumber)" } else { '' }
    Write-GateCommand -Type error -Title $leaf -Message ("{0}: the gate script stopped before it could report. NOTHING WAS CHECKED, so this is a fault in the gate itself, not a finding in the code or docs it reads. Script: {1}{2}. Reason: {3}. Repeat it locally with: {4}" -f $Clause, $leaf, $where, $ErrorRecord.Exception.Message, $HowToRepeat)
    return [pscustomobject]@{ Result = 'Failed'; Summary = "${Clause}: $leaf could not run" }
}

Export-ModuleMember -Function Get-GateRepeatCommand, Write-GateAnnotation, Write-GateCrashAnnotation, Write-GateCommand
