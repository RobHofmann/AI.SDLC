#Requires -Version 7
<#
.SYNOPSIS
    PreToolUse hook: say when the context window is filling up, so a compact happens at a logical
    boundary instead of wherever auto-compaction lands.

.DESCRIPTION
    A long AI-SDLC session walks the substrate, plans, builds test-first, runs the pre-flight and
    opens a pull request. Auto-compaction fires where the harness decides, which can be in the
    middle of a build. This hook adds the missing signal: it reads how full the window really is
    and says so once, in time to compact at the next boundary. The boundaries, and what to write
    down before compacting, are in .claude/skills/ai-sdlc-handbook/references/context-management.md. The message names
    /handoff, the skill that writes the costly parts down first. The agent decides nothing here; it
    passes the suggestion on and the human types /handoff or /compact, or does not.

    Ported from the strategic-compact skill in the open-source ECC repository
    (https://github.com/affaan-m/ECC), which pairs the same two signals with a PreToolUse hook.
    MIT licence, Copyright (c) 2026 Affaan Mustafa.

    Two signals, in the order of how much they are worth:

      - Context size (primary). The last usage record in the session transcript partitions the
        prompt into input_tokens, cache_read_input_tokens and cache_creation_input_tokens, so
        their sum is the real context size of that turn. The suggestion fires once the sum passes
        a window-scaled threshold, and repeats only after the context has grown by another
        interval, measured from the size at which it last spoke. ECC computes that step from the
        threshold instead, so a suggestion at 300k can repeat at 310k although its own text promises
        a full interval of growth. Only the tail of the transcript is read, so a long session stays
        cheap.
      - Tool-call count (secondary). A count of calls in this session, first at ToolCallThreshold
        and then every 25. It is a weak proxy on its own: a few large file reads can fill the
        window in very few calls, and many small calls can pass fifty while the window is nearly
        empty. It stays because it still catches a session whose transcript cannot be read.

    The context window is worked out from evidence only, in this order: an explicit override, a
    [1m] marker in the model id, the largest context ever seen for this model, and last a guess.
    Measured on Claude Code 2.x, the transcript records the model id WITHOUT the [1m] marker, so in
    practice that branch does not fire and the last two carry the work.

    The size ever seen is the part that makes this automatic. A turn holding more than 200000 tokens
    cannot be running on a 200k window, so it PROVES the window is the larger one. The script keeps
    that peak per model in the state folder, so the proof from one session is still there in the
    next. Without it a large-window session reads as a 200k one until it passes 200k itself, and
    speaks at 160000 tokens with the window one sixth full. That false alarm was seen in a real
    session, which spoke at 169191 tokens and went on to hold 236524.

    Where nothing proves the size, the script assumes 200k and leaves the share out of the message,
    because a share measured against a guess reads as a fact and is five times too high on a
    large-window model. This is where the script differs from ECC, which maps known model families
    to a 1M window. That map cannot tell a large-window tier from the standard tier of the same
    family, since the two share a model id, so it makes a guess look like evidence. A size actually
    observed is evidence; a family name is not.

    Wired from .claude/settings.json on the PreToolUse event for Edit and Write, next to
    Deny-SharedFileEdit.ps1. It follows the safety contract of Invoke-AutolearnHook.ps1: any payload it cannot read, any
    transcript it cannot use, and any error inside it exits 0 with no output. A bug here can slow
    an edit down; it can never block one. No prompt text and no transcript content is ever written
    to disk, only a token count and a call count.

    Copilot CLI 1.0.100 was probed on 2026-10-20. It raises PreToolUse for its edit, create and
    apply_patch tools, and it hands this script's nested additionalContext to the model. Its PreToolUse
    payload carries no transcript path, so the context-size signal stays silent there and only the
    tool-call count works; there the rule also runs from the skill text.

.PARAMETER Payload
    The hook payload as JSON. Read from stdin when not supplied.

.PARAMETER StateRoot
    The folder that holds the per-session call-count and last-suggested files, and the per-model
    largest-context-seen file. Defaults to a ai-sdlc-compact
    folder in the temporary folder, so nothing lands in the repository.

.PARAMETER ToolCallThreshold
    Tool calls in this session before the secondary suggestion fires, then every 25 after that.

.PARAMETER WindowTokens
    The context window size in tokens, overriding detection. Set this for a large-window model
    whose id carries no [1m] marker, so the threshold scales to the real window. Falls back to the
    AISDLC_CONTEXT_WINDOW_TOKENS and CLAUDE_CODE_AUTO_COMPACT_WINDOW environment variables.

.PARAMETER ThresholdTokens
    The context size at which to suggest a compact, overriding the window-scaled default of
    160000 tokens on a 200k window and 250000 on a 1M window.

.PARAMETER IntervalTokens
    How much the context must grow before the suggestion repeats.

.PARAMETER StateRetentionDays
    Days before a state file from a finished session is swept from the state folder.

.EXAMPLE
    '{"hook_event_name":"PreToolUse","session_id":"abc","transcript_path":"/tmp/s.jsonl"}' | pwsh .claude/skills/ai-sdlc-hooks/scripts/Invoke-CompactSuggestionHook.ps1
#>
[CmdletBinding()]
param(
    [string]$Payload,
    [string]$StateRoot = (Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath 'ai-sdlc-compact'),
    [int]$ToolCallThreshold = 50,
    [int]$WindowTokens = 0,
    [int]$ThresholdTokens = 0,
    [int]$IntervalTokens = 60000,
    [int]$StateRetentionDays = 14
)

$ErrorActionPreference = 'Stop'

trap { exit 0 }

$standardWindowTokens = 200000
$largeWindowTokens = 1000000
$standardThresholdTokens = 160000
$largeThresholdTokens = 250000
$transcriptTailBytes = 256 * 1024
$toolCallRepeatStep = 25
$guidancePage = '.claude/skills/ai-sdlc-handbook/references/context-management.md'
$usageFields = @('input_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens')

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

function Get-SafeStateName {
    param([string]$Text, [string]$Fallback)

    $safe = if ([string]::IsNullOrWhiteSpace($Text)) { '' } else { [regex]::Replace($Text, '[^A-Za-z0-9._-]', '_').TrimStart('.') }
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = $Fallback }
    return $safe
}

function Read-TranscriptTail {
    param([string]$Path, [int]$TailBytes)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $length = $stream.Length
        if ($length -le 0) { return $null }

        $start = [Math]::Max(0, $length - $TailBytes)
        $count = [int]($length - $start)
        $null = $stream.Seek($start, [System.IO.SeekOrigin]::Begin)
        $buffer = [byte[]]::new($count)
        $read = $stream.Read($buffer, 0, $count)

        return [pscustomobject]@{
            Text      = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
            Truncated = $start -gt 0
        }
    }
    catch { return $null }
    finally { if ($stream) { $stream.Dispose() } }
}

function Get-RecordTokens {
    param([object]$Record)

    $message = $Record.PSObject.Properties['message']
    if (-not $message -or -not $message.Value) { return 0 }

    $usage = $message.Value.PSObject.Properties['usage']
    if (-not $usage -or -not $usage.Value) { return 0 }

    $total = 0
    foreach ($field in $usageFields) {
        $property = $usage.Value.PSObject.Properties[$field]
        if (-not $property -or $null -eq $property.Value) { continue }

        $parsed = 0
        if ([int]::TryParse("$($property.Value)", [ref]$parsed) -and $parsed -gt 0) { $total += $parsed }
    }

    return $total
}

function Get-RecordModel {
    param([object]$Record)

    $message = $Record.PSObject.Properties['message']
    if (-not $message -or -not $message.Value) { return '' }

    $model = $message.Value.PSObject.Properties['model']
    if (-not $model -or $null -eq $model.Value) { return '' }

    return [string]$model.Value
}

function Get-LatestUsage {
    param([string]$TranscriptPath, [int]$TailBytes)

    $tail = Read-TranscriptTail -Path $TranscriptPath -TailBytes $TailBytes
    if (-not $tail) { return $null }

    $lines = $tail.Text -split "`n"
    $firstIndex = if ($tail.Truncated) { 1 } else { 0 }

    for ($i = $lines.Count - 1; $i -ge $firstIndex; $i--) {
        $line = $lines[$i].Trim()
        if (-not $line) { continue }

        $record = $null
        try { $record = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if (-not $record) { continue }

        $tokens = Get-RecordTokens -Record $record
        if ($tokens -gt 0) {
            return [pscustomobject]@{
                Tokens = $tokens
                Model  = Get-RecordModel -Record $record
            }
        }
    }

    return $null
}

function Resolve-ContextWindow {
    param([int]$Tokens, [string]$Model, [int]$Override, [int]$ObservedPeak)

    $explicit = $Override
    if ($explicit -le 0) {
        foreach ($name in 'AISDLC_CONTEXT_WINDOW_TOKENS', 'CLAUDE_CODE_AUTO_COMPACT_WINDOW') {
            $parsed = 0
            if ([int]::TryParse("$([Environment]::GetEnvironmentVariable($name))", [ref]$parsed) -and $parsed -gt 0) {
                $explicit = $parsed
                break
            }
        }
    }

    if ($explicit -gt 0) { return [pscustomobject]@{ Tokens = $explicit; Inferred = $false } }
    if ($Model -and $Model.Contains('[1m]')) { return [pscustomobject]@{ Tokens = $largeWindowTokens; Inferred = $false } }

    $proof = [Math]::Max($Tokens, $ObservedPeak)
    if ($proof -gt $standardWindowTokens) { return [pscustomobject]@{ Tokens = $largeWindowTokens; Inferred = $false } }

    return [pscustomobject]@{ Tokens = $standardWindowTokens; Inferred = $true }
}

function Get-ObservedPeak {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 0 }

    $parsed = 0
    $raw = (Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue)
    if ([int]::TryParse("$raw".Trim(), [ref]$parsed) -and $parsed -gt 0) { return $parsed }

    return 0
}

function Save-ObservedPeak {
    param([string]$Path, [int]$Tokens, [int]$Previous)

    if ($Tokens -le $Previous) { return }
    Set-Content -LiteralPath $Path -Value $Tokens -Encoding utf8
}

function Get-LastSuggestedTokens {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 0 }

    $parsed = 0
    $raw = (Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue)
    if ([int]::TryParse("$raw".Trim(), [ref]$parsed) -and $parsed -gt 0) { return $parsed }

    return 0
}

function Step-ToolCallCount {
    param([string]$Path)

    $count = 1
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $parsed = 0
        $raw = (Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue)
        if ([int]::TryParse("$raw".Trim(), [ref]$parsed) -and $parsed -gt 0 -and $parsed -lt 1000000) { $count = $parsed + 1 }
    }

    Set-Content -LiteralPath $Path -Value $count -Encoding utf8
    return $count
}

function Clear-StaleState {
    param([string]$Root, [int]$RetentionDays, [string[]]$Keep)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return }

    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    $keepNames = @($Keep | ForEach-Object { Split-Path -Path $_ -Leaf })

    foreach ($file in Get-ChildItem -LiteralPath $Root -File -Force -ErrorAction SilentlyContinue) {
        if ($file.Extension -notin '.count', '.mark', '.peak') { continue }
        if ($keepNames -contains $file.Name) { continue }
        if ($file.LastWriteTime -ge $cutoff) { continue }

        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Format-TokenCount {
    param([int]$Tokens)

    return "{0}k" -f [Math]::Round($Tokens / 1000)
}

function Format-WindowLabel {
    param([int]$Tokens)

    # A window of a million tokens or more reads in millions, so 2000000 is 2M and 1500000 is 1.5M.
    if ($Tokens -ge 1000000) { return ([Math]::Round($Tokens / 1000000, 1)).ToString('0.#', [Globalization.CultureInfo]::InvariantCulture) + 'M' }
    return "{0}k" -f [Math]::Round($Tokens / 1000)
}

function Get-ContextMessage {
    param([object]$Usage, [string]$MarkPath, [string]$PeakPath)

    $peak = Get-ObservedPeak -Path $PeakPath
    Save-ObservedPeak -Path $PeakPath -Tokens $Usage.Tokens -Previous $peak

    $window = Resolve-ContextWindow -Tokens $Usage.Tokens -Model $Usage.Model -Override $WindowTokens -ObservedPeak $peak

    $threshold = $ThresholdTokens
    if ($threshold -le 0) {
        $threshold = if ($window.Tokens -ge $largeWindowTokens) { $largeThresholdTokens } else { $standardThresholdTokens }
    }

    if ($Usage.Tokens -lt $threshold) { return $null }

    $step = if ($IntervalTokens -gt 0) { $IntervalTokens } else { 60000 }
    $lastSuggested = Get-LastSuggestedTokens -Path $MarkPath
    if ($lastSuggested -gt 0 -and $Usage.Tokens -lt ($lastSuggested + $step)) { return $null }

    Set-Content -LiteralPath $MarkPath -Value $Usage.Tokens -Encoding utf8

    $share = if ($window.Inferred) { '' } else { " ({0}% of {1} window)" -f [Math]::Round(($Usage.Tokens / $window.Tokens) * 100), (Format-WindowLabel -Tokens $window.Tokens) }
    return "[CompactSuggestion] Context is about {0} tokens{1}. Consider /handoff, then /compact, at the next logical boundary; which boundaries are safe, and what to write down first, are in {2}." -f (Format-TokenCount -Tokens $Usage.Tokens), $share, $guidancePage
}

function Get-ToolCallMessage {
    param([int]$Count)

    if ($Count -eq $ToolCallThreshold -or ($Count -gt $ToolCallThreshold -and (($Count - $ToolCallThreshold) % $toolCallRepeatStep) -eq 0)) {
        return "[CompactSuggestion] {0} tool calls in this session. A good checkpoint for /handoff and /compact if the context has gone stale; see {1}." -f $Count, $guidancePage
    }

    return $null
}

function Write-Suggestion {
    param([string[]]$Messages)

    @{
        hookSpecificOutput = @{
            hookEventName     = 'PreToolUse'
            additionalContext = ($Messages -join "`n")
        }
    } | ConvertTo-Json -Depth 5 -Compress | Write-Output
}

if (-not $PSBoundParameters.ContainsKey('Payload')) {
    $Payload = if ([Console]::IsInputRedirected) { [Console]::In.ReadToEnd() } else { '' }
}

$hook = Read-HookPayload -Json $Payload
if (-not $hook) { exit 0 }

$hookEvent = Get-PayloadField -Hook $hook -Names @('hook_event_name', 'hookEventName', 'event')
if ($hookEvent -ne 'PreToolUse') { exit 0 }

$safeSession = Get-SafeStateName -Text (Get-PayloadField -Hook $hook -Names @('session_id', 'sessionId')) -Fallback 'session'
$countPath = Join-Path -Path $StateRoot -ChildPath "$safeSession.count"
$markPath = Join-Path -Path $StateRoot -ChildPath "$safeSession.mark"

if (-not (Test-Path -LiteralPath $StateRoot -PathType Container)) { New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null }

$usage = Get-LatestUsage -TranscriptPath (Get-PayloadField -Hook $hook -Names @('transcript_path', 'transcriptPath')) -TailBytes $transcriptTailBytes
$peakPath = Join-Path -Path $StateRoot -ChildPath ("{0}.peak" -f (Get-SafeStateName -Text $(if ($usage) { $usage.Model } else { '' }) -Fallback 'model'))

Clear-StaleState -Root $StateRoot -RetentionDays $StateRetentionDays -Keep @($countPath, $markPath, $peakPath)

$messages = [System.Collections.Generic.List[string]]::new()

$contextMessage = if ($usage) { Get-ContextMessage -Usage $usage -MarkPath $markPath -PeakPath $peakPath } else { $null }
if ($contextMessage) { $messages.Add($contextMessage) }

$toolCallMessage = Get-ToolCallMessage -Count (Step-ToolCallCount -Path $countPath)
if ($toolCallMessage) { $messages.Add($toolCallMessage) }

if ($messages.Count -gt 0) { Write-Suggestion -Messages $messages }

exit 0
