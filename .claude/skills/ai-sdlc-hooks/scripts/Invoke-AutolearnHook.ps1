#Requires -Version 7
<#
.SYNOPSIS
    UserPromptSubmit and Stop hook: notice that the user corrected the agent, make sure the lesson is
    captured before the turn ends, and remind the agent of lesson proposals that are still open.

.DESCRIPTION
    The autolearn loop (.claude/skills/ai-sdlc-handbook/references/autolearn.md) only pays off when it runs on the day the
    correction happens. Waiting for someone to remember a skill at the end of the week is what it
    replaces, so three of its moments are made deterministic here.

      - UserPromptSubmit: when the prompt matches a short list of correction phrases, in English and
        Dutch, the hook writes a flag for this session and returns additionalContext that tells the
        agent to run the capture-learning skill once it has handled the request.
      - Stop: when that flag is there, the hook deletes it and then blocks the stop once, with the
        same instruction. Deleting before blocking is what stops a loop: one correction can be
        redeemed one time, so the agent can always finish its turn.

      - UserPromptSubmit, second kind: when the prompt asks the agent to update or revise its advice or
        recommendation, in English or Dutch, and is not a correction, the hook returns a softer
        additionalContext that asks two questions about a lesson. It writes no flag, so Stop does nothing.
        Correction phrases are tested first and win.

      - UserPromptSubmit, first prompt of a session: the capture-learning skill keeps a lesson proposal
        that still waits for an answer as one line in temp/autolearn/pending.md of the checkout. On the
        first prompt of a session the hook writes a .seen marker next to the flag, finds the checkout
        from the cwd of the payload and counts the non-empty lines of that file. When the count is above
        zero it adds a sentence to the context that names the file and the count, and asks the agent to
        bring the proposals up through the capture-learning skill when the work allows. It only reads and
        counts: it never writes the file and never prints a line of it. A payload without a cwd, a
        missing, empty or unreadable file, or a folder that is no git checkout, adds nothing. The hook
        does not use SessionStart: the sonarcloud pack already has an entry there, and APM 0.31.0 reports
        drift in apm audit when two packages add an entry to one event.

    The script never judges whether a lesson is real. It says a correction just happened and names the
    page that holds the rules; the judgement stays with the skill and the human.

    Wired from .claude/settings.json, which GitHub Copilot CLI reads too. Copilot CLI 1.0.100 raises
    both events (probed 2026-10-20). It reads the prompt context only at the top level of the output,
    so Write-PromptContext writes it in both shapes (HookPayload.psm1). It honours the Stop block, which
    forces one more turn. Every failure path exits 0 with no output, the way Deny-IncompletePush.ps1
    and Invoke-PostEditCheck.ps1 do, so a bug here can never break a prompt or trap a session.

    The Stop payload is written in both shapes in one object: the top-level decision/reason pair and
    the nested hookSpecificOutput, so the hook keeps working whichever shape the running agent reads.
    The flag holds a timestamp and nothing else. No prompt text is ever written to disk; the hook only
    reads and counts the file that the agent writes. The flag name
    never starts with a dot, because such a file is hidden on Linux and the agents run on both.

.PARAMETER Payload
    The hook payload as JSON. Read from stdin when not supplied.

.PARAMETER FlagRoot
    The folder that holds the per-session flags. Defaults to a ai-sdlc-autolearn folder in the
    temporary folder, so nothing lands in the repository.

.PARAMETER StateRetentionDays
    Days before a session marker (.seen) is swept from the flag folder, so the folder does not grow
    without end.

.EXAMPLE
    '{"hook_event_name":"UserPromptSubmit","session_id":"abc","user_input":"no, that is wrong"}' | pwsh .claude/skills/ai-sdlc-hooks/scripts/Invoke-AutolearnHook.ps1
#>
[CmdletBinding()]
param(
    [string]$Payload,
    [string]$FlagRoot = (Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath 'ai-sdlc-autolearn'),
    [int]$StateRetentionDays = 14
)

$ErrorActionPreference = 'Stop'

trap { exit 0 }

$correctionPatterns = @(
    '^\s*(?:no|nope|nee)\b\s*[,.!:]'
    "\bthat(?:'s| is|s)\s+(?:wrong|incorrect|not right|not correct)\b"
    '\bthis\s+is\s+(?:wrong|incorrect|not right)\b'
    '\bnot\s+what\s+i\s+(?:asked|meant|wanted|said)\b'
    '\byou\s+(?:should|shouldn|must)\S*\s+have\b'
    '\bi\s+(?:already\s+)?told\s+you\b'
    "\bdon'?t\s+do\s+that\b"
    '\bstop\s+doing\b'
    '\bnever\s+do\s+(?:that|this)\b'
    '\byou\s+keep\s+(?:doing|making|adding|forgetting)\b'
    '\bwhy\s+did\s+you\b'
    '\byou\s+forgot\b'
    '\b(?:revert|undo)\s+(?:that|this|it)\b'
    '\bdat\s+klopt\s+niet\b'
    '\bdat\s+is\s+(?:fout|verkeerd|niet\s+goed)\b'
    '\bniet\s+wat\s+ik\s+(?:vroeg|bedoelde|wilde)\b'
    '\bdat\s+zei\s+ik\s+niet\b'
    '\bje\s+(?:vergeet|bent\s+vergeten)\b'
    '\bwaarom\s+(?:deed|doe)\s+je\b'
    '\bdoe\s+dat\s+niet\b'
    '\bnooit\s+doen\b'
    '\bdraai\s+(?:dat|het|dit)\s+terug\b'
)

$adviceUpdatePatterns = @(
    '\b(?:update|revise|reconsider)\s+your\s+(?:advice|recommendations?)\b'
    '\b(?:update|updaten|herzie)\s+(?:je|jouw)\s+(?:advies|aanbeveling(?:en)?)\b'
    '\b(?:pas|werk)\s+(?:je|jouw)\s+(?:advies|aanbeveling(?:en)?)\s+(?:\w+\s+)?(?:aan|bij)\b'
    '\b(?:je|jouw)\s+(?:advies|aanbeveling(?:en)?)\s+(?:\w+\s+){0,2}(?:updaten|herzien|bijwerken|aanpassen)\b'
)

$adviceUpdateNegations = @(
    "\b(?:(?:not|don'?t|never)\s+(?:need\s+to\s+)?|no\s+need\s+to\s+|(?:don'?t|do\s+not)\s+think\s+you\s+should\s+)(?:update|revise|reconsider)\s+your\s+(?:advice|recommendations?)\b"
    '\b(?:advies|aanbeveling(?:en)?)\s+(?:\w+\s+){0,2}?niet\s+(?:\w+\s+)?(?:aan|bij|updaten|herzien|bijwerken|aanpassen)\b'
    '\b(?:update|updaten|herzie)\s+(?:je|jouw)\s+(?:advies|aanbeveling(?:en)?)\s+(?:\w+\s+)?niet\b'
)

$adviceUpdateInstruction = @(
    'The user asked you to update your advice, often with new input. First update the advice.'
    'Then ask yourself two questions: could you have found or asked for this input before you advised,'
    'and does it hold beyond this work item? When both answers are no, say nothing about a lesson.'
    'When one answer is yes, propose a capture through the capture-learning skill, and never write it'
    'without asking. While the proposal waits for an answer, keep it in temp/autolearn/pending.md as'
    'that skill says. The filter and the route table are in .claude/skills/ai-sdlc-handbook/references/autolearn.md.'
) -join ' '

$instruction = @(
    'A correction just happened in this session. Run the capture-learning skill on it before this'
    'turn ends: decide whether the lesson is general, and when it is, name its home and propose the'
    'write. The filter and the route table are in .claude/skills/ai-sdlc-handbook/references/autolearn.md. When nothing general'
    'came out of it, say so in one line and carry on. Never write to a page, a gate or a work item'
    'without asking first.'
) -join ' '

function Read-HookPayload {
    param([string]$Json)

    if ([string]::IsNullOrWhiteSpace($Json)) { return $null }
    try { return $Json | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
}

function Get-PayloadField {
    param([object]$Hook, [string[]]$Names)

    foreach ($name in $Names) {
        $property = $Hook.PSObject.Properties[$name]
        if ($property -and $null -ne $property.Value -and "$($property.Value)".Trim()) { return [string]$property.Value }
    }
    return $null
}

function Test-MatchesAny {
    param([string]$Text, [string[]]$Patterns)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    foreach ($pattern in $Patterns) {
        if ($Text -match "(?im)$pattern") { return $true }
    }
    return $false
}

function Test-IsCorrection {
    param([string]$Text)

    return (Test-MatchesAny -Text $Text -Patterns $correctionPatterns)
}

function Test-IsAdviceUpdate {
    param([string]$Text)

    if (Test-MatchesAny -Text $Text -Patterns $adviceUpdateNegations) { return $false }
    return (Test-MatchesAny -Text $Text -Patterns $adviceUpdatePatterns)
}

function Get-FlagPath {
    param([string]$SessionId, [string]$Root)

    $safe = if ([string]::IsNullOrWhiteSpace($SessionId)) { '' } else { [regex]::Replace($SessionId, '[^A-Za-z0-9._-]', '_').TrimStart('.') }
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'session' }
    return (Join-Path -Path $Root -ChildPath "$safe.flag")
}

function Write-PromptContext {
    param([string]$Text)

    Import-Module (Join-Path $PSScriptRoot 'HookPayload.psm1') -Force
    New-HookContextOutput -EventName 'UserPromptSubmit' -Text $Text | Write-Output
}

function Get-OpenProposalCount {
    param([object]$Hook)

    $cwd = Get-PayloadField -Hook $Hook -Names @('cwd')
    if (-not $cwd) { return 0 }
    $root = [string](git -C $cwd rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $root.Trim()) { return 0 }

    $file = Join-Path -Path $root.Trim() -ChildPath 'temp' 'autolearn' 'pending.md'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return 0 }
    return @(Get-Content -LiteralPath $file | Where-Object { $_.Trim() }).Count
}

function Get-OpenProposalReminder {
    param([object]$Hook, [string]$SeenPath)

    if (-not (Get-PayloadField -Hook $Hook -Names @('cwd'))) { return $null }
    $folder = Split-Path -Path $SeenPath -Parent
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $cutoff = (Get-Date).AddDays(-$StateRetentionDays)
    foreach ($file in Get-ChildItem -LiteralPath $folder -Filter '*.seen' -File -Force -ErrorAction SilentlyContinue) {
        if ($file.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) { continue }
        if ($file.LastWriteTime -lt $cutoff) { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue }
    }
    try { [IO.File]::Open($SeenPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write).Dispose() }
    catch { return $null }

    $open = Get-OpenProposalCount -Hook $Hook
    if ($open -le 0) { return $null }
    return ("temp/autolearn/pending.md holds $open open lesson proposal(s) that still wait for an answer. " +
        'When the current work allows, bring them up to the user through the capture-learning skill. ' +
        'Never edit the file without the skill.')
}

function Write-StopBlock {
    @{
        decision           = 'block'
        reason             = $instruction
        hookSpecificOutput = @{
            hookEventName            = 'Stop'
            permissionDecision       = 'block'
            permissionDecisionReason = $instruction
        }
    } | ConvertTo-Json -Depth 5 -Compress | Write-Output
}

if (-not $PSBoundParameters.ContainsKey('Payload')) {
    $Payload = if ([Console]::IsInputRedirected) { [Console]::In.ReadToEnd() } else { '' }
}

$hook = Read-HookPayload -Json $Payload
if (-not $hook) { exit 0 }

$hookEvent = Get-PayloadField -Hook $hook -Names @('hook_event_name', 'hookEventName', 'event')
if (-not $hookEvent) { exit 0 }

$flagPath = Get-FlagPath -SessionId (Get-PayloadField -Hook $hook -Names @('session_id', 'sessionId')) -Root $FlagRoot

switch ($hookEvent) {
    'UserPromptSubmit' {
        $prompt = Get-PayloadField -Hook $hook -Names @('user_input', 'prompt', 'userInput')
        $parts = [Collections.Generic.List[string]]::new()
        if (Test-IsCorrection -Text $prompt) {
            if (-not (Test-Path -LiteralPath $FlagRoot)) { New-Item -ItemType Directory -Path $FlagRoot -Force | Out-Null }
            Set-Content -LiteralPath $flagPath -Value (Get-Date -Format 'o') -Encoding utf8
            $parts.Add($instruction)
        }
        elseif (Test-IsAdviceUpdate -Text $prompt) {
            $parts.Add($adviceUpdateInstruction)
        }
        # A failure here must not take the correction or advice note with it.
        $reminder = try { Get-OpenProposalReminder -Hook $hook -SeenPath ([IO.Path]::ChangeExtension($flagPath, '.seen')) } catch { $null }
        if ($reminder) { $parts.Add($reminder) }
        if ($parts.Count -gt 0) { Write-PromptContext -Text ($parts -join ' ') }
        exit 0
    }
    'Stop' {
        $active = Get-PayloadField -Hook $hook -Names @('stop_hook_active', 'stopHookActive')
        if ($active -and $active -match '^(?i)true$') { exit 0 }
        if (-not (Test-Path -LiteralPath $flagPath)) { exit 0 }

        Remove-Item -LiteralPath $flagPath -Force -ErrorAction SilentlyContinue
        Write-StopBlock
        exit 0
    }
}

exit 0
