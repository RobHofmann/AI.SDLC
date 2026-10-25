#Requires -Version 7
<#
.SYNOPSIS
    Runs a constitution / AI-SDLC gate script in a GitHub Actions workflow with a readable result.

.DESCRIPTION
    A gate script reports through its exit code, and three values are distinguished:

      0  checked, nothing found.
      1  checked, and found a violation. Advisory mode warns; Blocking mode fails the build.
      2  COULD NOT check. Always a warning and never a pass, whatever the mode, because a gate that
         could not reach its source has proved nothing. It is not a violation either: nobody on the
         pull request can fix a missing credential or an unreachable service by editing the code.

    The gate scripts (Check-*.ps1) signal "issues found" with a non-zero exit code. Run directly in a
    workflow step, that surfaces as the opaque "Process completed with exit code 1", which reads like
    the script crashed rather than the validation simply finding issues.

    This wrapper runs the gate, lets its own output (the human-readable violation list) flow to the
    log, and then translates a non-zero exit into GitHub annotations (GateAnnotation.psm1):

      - Advisory mode: a warning, and the wrapper exits 0 (the gate does not block the build yet).
      - Blocking mode: an error, and the wrapper exits 1 (the gate fails the step, with a clean
        message next to the exit code).

    The result of the gate is the exit code of the wrapper. The gate script is unchanged and still
    exits non-zero on a developer machine.

    Every annotation says WHAT is wrong, WHERE it is, WHY it is wrong, and HOW TO FIX IT, without
    anyone opening the log. The fix comes from the gate itself: a gate prints one line that starts
    with "FIX: " and this wrapper lifts it into the annotation. The gate owns that sentence because
    the gate owns the rule, and printing it means a local run shows the same advice as the build.
    The line is left out of the rule, the count and the findings, so a gate can put it anywhere.
    A gate that prints none still reports what and where; only the advice is missing.

    The gates all print their findings indented by two spaces, most of them as "path:line  what",
    so this wrapper reads those lines back and raises up to five of them as their own annotations,
    each carrying file and line. GitHub then shows them in the run summary and on the pull request,
    next to the file. A gate that names no single place (a pull request rule,
    a count) keeps its own first finding lines instead, and the annotation says so rather than looking
    empty.

    The summary annotation quotes two lines of the gate's own output. For the rule that was broken it
    takes the last unindented line BEFORE the first finding, which is the header every gate here prints
    to introduce its findings. Taking the first line instead read the wrong thing on a gate that opens
    with an advisory note. For the count it takes the last line. It also prints the command to repeat
    the same check locally.

    A crash in the gate (a thrown, terminating error rather than a clean non-zero exit) also fails the
    step, but it is reported as its own case: nothing was checked, so it is a bug in the gate rather
    than a finding in what the gate reads. The reason, the script and the line are named, because a
    raw PowerShell stack trace in a build log tells a reader nothing about which of the two happened.

.PARAMETER Script
    Path to the gate script to run (e.g. Check-DocEmDashes.ps1).

.PARAMETER Clause
    Constitution clause id or short tag used in the message (e.g. C06, AI-SDLC).

.PARAMETER What
    Short human label used in the message (e.g. "no em-dash characters").

.PARAMETER Mode
    Advisory (default) emits a warning and exits 0. Blocking emits an error and exits 1.

.PARAMETER GateArgs
    Remaining arguments are passed through verbatim to the gate script (e.g. -RepoRoot <path>, or
    -CoverageFile <x> -RepoRoot <path>). Captured via ValueFromRemainingArguments so callers pass them
    as plain trailing arguments.

.EXAMPLE
    pwsh Invoke-Gate.ps1 -Script ./Check-DocEmDashes.ps1 -Clause C06 -What "no em-dash characters" -Mode Blocking -RepoRoot .

.EXAMPLE
    pwsh Invoke-Gate.ps1 -Script ./Check-ChangeCompleteness.ps1 -Clause AI-SDLC -What "tests and docs moved with the code" -Mode Advisory -RepoRoot .
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Script,
    [Parameter(Mandatory)][string]$Clause,
    [Parameter(Mandatory)][string]$What,
    [ValidateSet('Advisory', 'Blocking')][string]$Mode = 'Advisory',
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$GateArgs
)

# Parse the pass-through args ("-Name value" pairs and bare "-Switch") into a hashtable and splat
# THAT. Array-splatting $GateArgs binds positionally and mis-handles "-Name value", so a gate's
# -RepoRoot would not bind. Gate values here are paths, a number, and switches, none starting with '-'.
$splat = @{}
for ($i = 0; $i -lt $GateArgs.Count; $i++) {
    $token = $GateArgs[$i]
    if ($token -notlike '-*') { continue }
    $name = $token.TrimStart('-')
    if (($i + 1) -lt $GateArgs.Count -and ($GateArgs[$i + 1] -notlike '-*')) {
        $splat[$name] = $GateArgs[$i + 1]
        $i++
    }
    else {
        $splat[$name] = $true
    }
}

Import-Module (Join-Path $PSScriptRoot 'GateAnnotation.psm1') -Force
$repeatRoot = if ($splat.ContainsKey('RepoRoot') -and $splat['RepoRoot'] -is [string]) { $splat['RepoRoot'] } else { $null }
$howToRepeat = Get-GateRepeatCommand -Script $Script -RepoRoot $repeatRoot

$lines = @()
$code = 0
try {
    $global:LASTEXITCODE = 0
    $lines = & $Script @splat *>&1
    $code = $LASTEXITCODE
}
catch {
    $lines | ForEach-Object { Write-Host $_ }
    $outcome = Write-GateCrashAnnotation -Clause $Clause -Script $Script -ErrorRecord $_ -HowToRepeat $howToRepeat
    Write-Host $outcome.Summary
    exit 1
}

$lines | ForEach-Object { Write-Host $_ }

$outcome = Write-GateAnnotation -Lines $lines -ExitCode $code -Clause $Clause -What $What -Mode $Mode -HowToRepeat $howToRepeat
if ($outcome.Result -ne 'Succeeded') { Write-Host $outcome.Summary }
if ($outcome.Result -eq 'Failed') { exit 1 }
exit 0
