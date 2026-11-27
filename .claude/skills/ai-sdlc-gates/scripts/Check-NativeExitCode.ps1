#Requires -Version 7
<#
.SYNOPSIS
    Gate: each native call that a change adds to a PowerShell script is followed by a check of its exit code (clause C13).
.DESCRIPTION
    A native call is a program outside PowerShell. When it fails, the script goes on, also with
    $ErrorActionPreference = 'Stop'. So the rule of the powershell-conventions skill is to check
    $LASTEXITCODE right after each native call
    (.claude/skills/powershell-conventions/references/house-style.md, section "Check the exit code after
    each native call").

    The gate reads the .ps1 and .psm1 files of the change with the PowerShell parser, never as plain text.
    A native call is a command named az, git, dotnet or bicep, also with .exe or .cmd, a folder in front,
    or the & operator. A cmdlet such as Get-ChildItem is not a native call, and neither is a word that is
    only an argument, as in Get-Command git. A call whose name is built at run time, such as & $tool, is
    not seen.

    The call passes when the next statement in the same block tests $LASTEXITCODE: in the condition of
    an if, on the right side of an assignment, or in a throw or exit. The rest of the statement that
    holds the call counts the same way. A read inside the body of an if, a loop, a function or a script
    block is not a test. A call on the left of a || or && chain passes too. A call inside $( ) or @( )
    is judged by the statement around it. A $LASTEXITCODE inside a string or a comment is not a check.
    A call that is the last statement of its block has no next statement, so it is a finding. A call
    also passes when an earlier $PSNativeCommandUseErrorActionPreference = $true is a direct statement
    of the same script block or of one around it, because PowerShell then stops on the failure itself.
    A set inside an if, a loop, a try or a switch does not count. A later direct set to any other value
    ends it, so only the last such set before the call decides.

    Only a call on a line that the change adds or changes is judged, so the older code of a touched file
    does not fail anyone (Get-AiSdlcLineChange in ChangedFiles.psm1). The files that apm.lock.yaml at the
    base lists under deployed_files are skipped: the install wrote them, and the repository must not edit
    them. A file under .claude/ that apm.lock.yaml at HEAD lists with its right SHA-256 hash is skipped
    too, because a change that installs a new version adds its own files to the lock. The list comes from the base and
    from the .claude/ paths of HEAD (Get-AiSdlcInstalledPath -WithHeadInstall), so a change cannot skip
    any other file. A symbolic link or junction is named as not checked, so the parser never reads a
    file outside the repository through it.

    It fails closed. Exit codes follow ADR 0019: 0 checked and clean, 1 a native call with no exit-code
    check, 2 the change could not be read or a script does not parse, so it was not checked, 3 the change
    touches no .ps1 or .psm1 file. When the run has both a finding and a file it could not check, it
    names both and exits 1, because the finding is certain and exit 2 would hide it.
.PARAMETER RepoRoot
    Repository root. Defaults to the folder that holds aisdlc.json, found from this script.
.PARAMETER BaseRef
    The ref the change is measured against. Defaults to the main branch of the repository
    (Get-AiSdlcMainBranch in AiSdlcConfig.psm1). The pull request build passes HEAD^1.
.PARAMETER ChangedFiles
    Repo-relative paths to read instead of asking git for the change. Without a base, every line of a
    listed file counts as added. Used by the tests.
.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Check-NativeExitCode.ps1
.EXAMPLE
    pwsh .claude/skills/ai-sdlc-gates/scripts/Check-NativeExitCode.ps1 -BaseRef HEAD~3
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$BaseRef,
    [string[]]$ChangedFiles
)

Import-Module (Join-Path $PSScriptRoot 'AiSdlcConfig.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ChangedFiles.psm1') -Force
if (-not $RepoRoot) { $RepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if (-not $BaseRef) { $BaseRef = Get-AiSdlcMainBranch -RepoRoot $RepoRoot }

$ErrorActionPreference = 'Stop'

$nativeName = '^(az|git|dotnet|bicep)(\.exe|\.cmd)?$'
$checkedPattern = '\.(ps1|psm1)$'


function Get-VariableName {
    param([System.Management.Automation.Language.VariableExpressionAst]$Variable)
    return ($Variable.VariablePath.UserPath -replace '^(global|script|local|private):', '')
}

function Test-ReadsExitCode {
    param([System.Management.Automation.Language.Ast]$Ast, [int]$AfterOffset = -1)
    $found = $Ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.VariableExpressionAst] -and
            (Get-VariableName $node) -eq 'LASTEXITCODE' -and
            $node.Extent.StartOffset -gt $AfterOffset
        }, $false)
    foreach ($variable in $found) {
        $inString = $false
        for ($p = $variable.Parent; $p; $p = $p.Parent) {
            if ($p -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) { $inString = $true; break }
        }
        if (-not $inString) { return $true }
    }
    return $false
}

function Test-DirectCheck {
    param([System.Management.Automation.Language.StatementAst]$Statement, [int]$AfterOffset = -1)
    $tested = switch ($Statement) {
        { $_ -is [System.Management.Automation.Language.IfStatementAst] } { @($_.Clauses | ForEach-Object { $_.Item1 }) }
        { $_ -is [System.Management.Automation.Language.AssignmentStatementAst] } { @($_.Right) }
        { $_ -is [System.Management.Automation.Language.ExitStatementAst] -or $_ -is [System.Management.Automation.Language.ThrowStatementAst] } { @($_.Pipeline) }
        default { @() }
    }
    foreach ($part in @($tested | Where-Object { $_ })) {
        if (Test-ReadsExitCode -Ast $part -AfterOffset $AfterOffset) { return $true }
    }
    return $false
}

function Get-NativePreferenceOffset {
    param([System.Management.Automation.Language.Ast]$Root)
    $assignments = $Root.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Operator -eq [System.Management.Automation.Language.TokenKind]::Equals -and
            $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            (Get-VariableName $node.Left) -eq 'PSNativeCommandUseErrorActionPreference' -and
            $node.Parent -is [System.Management.Automation.Language.NamedBlockAst]
        }, $true)
    foreach ($assignment in $assignments) {
        $right = $assignment.Right
        $isTrue = $right -is [System.Management.Automation.Language.CommandExpressionAst] -and
            $right.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and
            (Get-VariableName $right.Expression) -eq 'true'
        [pscustomobject]@{ Block = $assignment.Parent.Parent; Offset = $assignment.Extent.EndOffset; IsTrue = $isTrue }
    }
}

function Test-StopsOnFailure {
    param([System.Management.Automation.Language.CommandAst]$Call, [object[]]$Preferences)
    $latest = $null
    foreach ($preference in $Preferences) {
        if ($preference.Offset -ge $Call.Extent.StartOffset) { continue }
        if ($latest -and $latest.Offset -ge $preference.Offset) { continue }
        for ($p = $Call.Parent; $p; $p = $p.Parent) {
            if ([object]::ReferenceEquals($p, $preference.Block)) { $latest = $preference; break }
        }
    }
    return [bool]($latest -and $latest.IsTrue)
}

function Test-InChainLeft {
    param([System.Management.Automation.Language.CommandAst]$Call)
    for ($p = $Call.Parent; $p; $p = $p.Parent) {
        if ($p -is [System.Management.Automation.Language.PipelineChainAst] -and
            $Call.Extent.EndOffset -le $p.LhsPipelineChain.Extent.EndOffset) { return $true }
        if ($p -is [System.Management.Automation.Language.StatementBlockAst] -or $p -is [System.Management.Automation.Language.NamedBlockAst]) { return $false }
    }
    return $false
}

function Test-CheckedCall {
    param([System.Management.Automation.Language.CommandAst]$Call)
    if (Test-InChainLeft -Call $Call) { return $true }
    $node = $Call
    while ($true) {
        $statement = $node
        while ($statement.Parent -and
            $statement.Parent -isnot [System.Management.Automation.Language.StatementBlockAst] -and
            $statement.Parent -isnot [System.Management.Automation.Language.NamedBlockAst]) {
            $statement = $statement.Parent
        }
        if (Test-DirectCheck -Statement $statement -AfterOffset $Call.Extent.EndOffset) { return $true }
        $block = $statement.Parent
        $siblings = @($block.Statements)
        $index = [array]::IndexOf($siblings, $statement)
        if ($index -ge 0 -and $index + 1 -lt $siblings.Count) { return (Test-DirectCheck -Statement $siblings[$index + 1]) }
        $holder = $block.Parent
        if ($holder -isnot [System.Management.Automation.Language.SubExpressionAst] -and $holder -isnot [System.Management.Automation.Language.ArrayExpressionAst]) { return $false }
        $node = $holder
    }
}

function Find-UncheckedCall {
    param([System.Management.Automation.Language.ScriptBlockAst]$Root, [System.Collections.Generic.HashSet[int]]$Added)
    $preferences = @(Get-NativePreferenceOffset -Root $Root)
    $calls = $Root.FindAll({
            param($node)
            if ($node -isnot [System.Management.Automation.Language.CommandAst]) { return $false }
            $name = $node.GetCommandName()
            if (-not $name) { return $false }
            return (($name -split '[\\/]')[-1] -match $nativeName)
        }, $true)
    foreach ($call in $calls) {
        if (-not $Added.Contains($call.Extent.StartLineNumber)) { continue }
        if (Test-StopsOnFailure -Call $call -Preferences $preferences) { continue }
        if (Test-CheckedCall -Call $call) { continue }
        [pscustomobject]@{ Line = $call.Extent.StartLineNumber; Text = ($call.Extent.Text -split '\r?\n')[0].Trim() }
    }
}

function Test-ReparsePoint {
    param([string]$Path)
    for ($current = $Path; $current -and $current.Length -ge $RepoRoot.Length; $current = [System.IO.Path]::GetDirectoryName($current)) {
        if ($current.TrimEnd('\', '/') -eq $RepoRoot.TrimEnd('\', '/')) { break }
        $item = Get-Item -LiteralPath $current -Force
        if ($item.LinkType -in 'SymbolicLink', 'Junction') { return $true }
    }
    return $false
}

$change = Get-AiSdlcChange -RepoRoot $RepoRoot -BaseRef $BaseRef -Explicit $ChangedFiles
if (-not $change.Readable) {
    Write-Host "Native exit code: the change could not be read ($($change.Reason)), so NOTHING WAS CHECKED." -ForegroundColor Yellow
    $fix = if ($change.Fix) { $change.Fix } else { 'Fetch the base branch (git fetch origin <branch>), or pass -BaseRef with a ref that exists, then run this check again.' }
    Write-Host "FIX: $fix" -ForegroundColor Yellow
    exit 2
}

$installed = Get-AiSdlcInstalledPath -RepoRoot $RepoRoot -Base $change.Base -WithHeadInstall
if (-not $installed.Readable) {
    Write-Host "Native exit code: the list of installed files could not be read ($($installed.Reason)), so NOTHING WAS CHECKED." -ForegroundColor Yellow
    Write-Host 'FIX: Fetch the base branch (git fetch origin <branch>), or pass -BaseRef with a commit that exists, then run this check again.' -ForegroundColor Yellow
    exit 2
}
$scripts = @($change.Files | Where-Object { $_ -match $checkedPattern -and -not $installed.Paths.Contains($_) -and @($change.Deleted) -notcontains $_ })

$rootPrefix = $RepoRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
$pathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$findings = [System.Collections.Generic.List[object]]::new()
$unchecked = [System.Collections.Generic.List[string]]::new()
$readFiles = 0
foreach ($path in $scripts) {
    $full = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $path))
    if (-not $full.StartsWith($rootPrefix, $pathComparison)) {
        $unchecked.Add("$path : the path is outside the repository")
        continue
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        $unchecked.Add("$path : the file is not on disk")
        continue
    }
    if (Test-ReparsePoint -Path $full) {
        $unchecked.Add("$path : the path goes through a symbolic link or junction")
        continue
    }
    $lineChange = Get-AiSdlcLineChange -RepoRoot $RepoRoot -Base $change.Base -Path $path -AssumeNew:([bool]$ChangedFiles)
    if ($null -eq $lineChange) {
        $unchecked.Add("$path : git could not list the lines this change adds")
        continue
    }
    $added = [System.Collections.Generic.HashSet[int]]::new([int[]]@($lineChange.Added))
    if ($added.Count -eq 0) { continue }
    $tokens = $null
    $parseErrors = $null
    $root = [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        $unchecked.Add("$path : the file does not parse")
        continue
    }
    $readFiles++
    foreach ($finding in @(Find-UncheckedCall -Root $root -Added $added)) {
        $findings.Add([pscustomobject]@{ File = $path; Line = $finding.Line; Text = $finding.Text })
    }
}

if ($findings.Count -gt 0) {
    Write-Host 'Native exit code (clause C13): the change adds a call to az, git, dotnet or bicep with no check of $LASTEXITCODE in the next statement. PowerShell goes on after a failed native call, also with $ErrorActionPreference = ''Stop''.' -ForegroundColor Yellow
    Write-Host 'FIX: Check $LASTEXITCODE right after each call named below and throw when it is not 0, as .claude/skills/powershell-conventions/references/house-style.md shows. Or set $PSNativeCommandUseErrorActionPreference = $true as a direct statement at the top of the script.' -ForegroundColor Yellow
    foreach ($f in $findings) { Write-Host ("  {0}:{1}  {2}" -f $f.File, $f.Line, $f.Text) }
    Write-Host ("Found {0} native call(s) with no exit-code check in {1} file(s). A call whose name is built at run time, such as & `$tool, is not seen." -f $findings.Count, @($findings | Select-Object -ExpandProperty File -Unique).Count) -ForegroundColor Yellow
}

if ($unchecked.Count -gt 0) {
    Write-Host 'Native exit code: NOTHING WAS CHECKED in these file(s):' -ForegroundColor Yellow
    foreach ($u in $unchecked) { Write-Host "  $u" }
    Write-Host 'FIX: Fix the syntax error that pwsh reports for each file named above, or run the check inside the git clone of the change, then run it again.' -ForegroundColor Yellow
}
if ($findings.Count -gt 0) { exit 1 }
if ($unchecked.Count -gt 0) { exit 2 }

if ($readFiles -eq 0) {
    Write-Host 'Not applicable: the change adds no line to a .ps1 or .psm1 file, so there is no native call to look at.'
    exit 3
}
Write-Host ("Native exit code OK: {0} PowerShell file(s) read, every native call to az, git, dotnet or bicep on an added line checks its exit code." -f $readFiles)
exit 0
