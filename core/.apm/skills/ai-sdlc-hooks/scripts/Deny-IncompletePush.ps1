#Requires -Version 7
<#
.SYNOPSIS
    PreToolUse hook: refuse a push that leaves tests or documentation behind, and tell the agent to
    finish the change instead of just reporting the problem.
.DESCRIPTION
    Runs the deterministic completeness check. When it reports nothing the hook stays silent and the
    push proceeds. When it reports a gap the hook returns a deny decision whose reason instructs the
    agent to run the wrap-up skill, which then runs on whatever model the developer is already
    using. No model is spent deciding whether the work is needed, only doing it.

    Wired from .claude/settings.json, which Claude Code and GitHub Copilot CLI both read, so one entry
    covers both tools. The payload arrives as JSON on stdin in the Claude shape (tool_name,
    tool_input.command); the camelCase toolArgs shape of the Copilot-native config is accepted too.

    The git push filter lives in this script rather than in the configuration. Claude's `if` condition
    is a Claude-only field, and Copilot CLI loads the same entry and ignores it, so a hook that trusted
    the configuration would run the check on every shell command and deny unrelated work. Copilot runs
    the entries one after another, so the script tests the command before it loads any module, and the
    configuration holds one entry per tool: Bash(*git* *push*) and PowerShell(*git* *push*).

    Allowing is exit 0 with no output. Denying is exit 0 with a deny decision on stdout, written in
    both shapes in one object: the top-level permissionDecision Copilot CLI reads, and the nested
    hookSpecificOutput Claude Code reads. A non-zero exit denies the call under Copilot CLI, so every
    failure path here exits 0 and allows rather than blocking every shell command on a bug in this
    script. A payload this script cannot read as a git push allows for the same reason; the pre-push
    git hook stays the backstop that no configuration can miss.
    Before the completeness check it refuses any push to main or master: a named target, a quoted one,
    HEAD while on main, a bare push while on main, and --all, --mirror or --branches. A permission rule
    cannot see which branch a bare push targets, so this hook is the guard for Claude Code and Copilot
    CLI alike. It is registered for the Bash tool and for the PowerShell tool, because a repository
    that allows git push in PowerShell would otherwise push past it. The PowerShell payload has the same
    shape (tool_name PowerShell, tool_input.command), and the filter also reads the PowerShell forms:
    git push, git -C <dir> push, & git push, & 'git' push and git.exe push. The if condition on the
    PowerShell entry keeps the hook from starting a process before every other PowerShell command. The
    branch policy on main refuses a direct push on the server anyway
    (.claude/skills/ai-sdlc-handbook/references/orchestration.md).
    After the completeness check it asks for the pre-flight receipt of the commit about to be pushed:
    Invoke-Preflight.ps1 writes temp/preflight/<tree hash of HEAD>.json when no check failed on a clean
    tree (PreflightReceipt.psm1). A gitleaks finding outside the baseline is a FAIL row, so it stops the
    receipt; a REVIEW row, such as a build warning on a changed file, still needs a person. No receipt for this tree, no push; the reason says to
    run the wrap-up skill, which ends with the pre-flight. So every commit an agent pushes had a pre-flight with no FAIL row, as it
    is. The receipt lists the checks that passed. A SKIP or NOT-AVAIL row is shown, but it proves
    nothing, because that check did not run. A push from a terminal skips this hook.
    A push that sends nothing new needs neither the completeness check nor a receipt, such as a tag on
    a commit that passed its pull request build, or a branch delete. The rule is the one the git
    pre-push hook uses, Test-PushSendsNothingNew in PreflightReceipt.psm1: every pushed ref is a delete,
    or its commit is reachable from the remote-tracking refs of the remote being pushed to, never of
    another remote. The hook reads the pushed refs only from the plain form git push [options] <remote>
    <refspec>..., with the options -f, --force, --force-with-lease, --force-if-includes, -u,
    --set-upstream, -q, -v, --atomic, --porcelain, --progress, -d and --delete. The push must be the
    whole command, at most followed by 2>&1 or 2>&1 | Out-String, with no git option before push. A chain such as git commit && git
    push, a second command, a redirect, a subshell, a bare push, any other option, a quote, a variable
    or a wildcard keeps every check, because the hook judges the refs before the command runs. The refusal of a push to main or master
    comes first and still applies.
    The push is judged on the repository it targets, not on the one the hook is installed in. A push
    that names no folder is judged on the repository of the cwd field of the payload: the folder the
    shell runs in, which is the worktree in a session that works in a git worktree. Claude Code starts
    the hook in the folder the session started in, so the location of this script names the main
    checkout there. Only a payload without a usable cwd falls back to the repository this hook is
    installed in. The hook reads only the plain forms that name a folder: git -C <dir> push, and one
    folder change right before the push, joined with && or ;, such as cd ../Other && git push. A
    relative folder starts at the cwd. A -C folder with $, a backtick, ~ or a wildcard, or a relative
    -C folder after a folder change, names no folder. So does an unquoted -C folder with a backslash
    or a quote in bash. A folder change counts only where it starts a command, also after a new
    line, a brace or builtin, and only with a name the shell runs: in bash cd, pushd or popd. A folder
    change inside a quoted argument still counts, because the hook does not read quotes there. In bash the folder change is cd or pushd. In PowerShell it is
    cd, pushd, sl, Set-Location or Push-Location, in any case. The folder is written without ~,
    $, a backtick, brackets or a wildcard, and in bash without a backslash. It may stand in single or
    double quotes, so a folder with a space works; in bash, double quotes also refuse !.
    Every other form leaves the push judged on the repository of the cwd. That covers escapes, ~, a
    call operator, a chain of folder changes, a subshell, more than one -C, --git-dir, --work-tree
    and an environment variable before git. A shell command parser cannot match the shell in every
    case, and a wrong guess would let a push through, so the hook does not try.
    The git pre-push hook stays the backstop.
.PARAMETER Payload
    The hook payload as JSON. Read from stdin when not supplied.
.PARAMETER CheckScript
    The completeness check to run. Defaults to Check-ChangeCompleteness.ps1 in the ai-sdlc-gates skill.
.PARAMETER CurrentBranch
    Test seam: the branch to treat as checked out. Read from git when not supplied.
.PARAMETER ReceiptRoot
    Where the pre-flight receipts live. Defaults to paths.preflightReceipts in aisdlc.json, which is
    temp/preflight unless the repository sets another folder.
.PARAMETER RepoRoot
    Test seam: the repository to judge when the push names no other folder in a plain form. It wins
    over the cwd of the payload. Defaults to the repository of that cwd, then to the repository this
    hook is installed in.
.PARAMETER HeadTree
    Test seam: the tree hash to look a receipt up for. Read from git (HEAD^{tree}) when not supplied.
.EXAMPLE
    '{"tool_input":{"command":"git push origin main"}}' | pwsh -NoProfile -File .claude/skills/ai-sdlc-hooks/scripts/Deny-IncompletePush.ps1
#>
[CmdletBinding()]
param(
    [string]$Payload,
    [string]$CheckScript = (Join-Path -Path $PSScriptRoot -ChildPath '..' '..' 'ai-sdlc-gates' 'scripts' 'Check-ChangeCompleteness.ps1'),
    [string]$CurrentBranch,
    [string]$ReceiptRoot,
    [string]$HeadTree,
    [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'

trap { exit 0 }

$gitName = '[''"]?git(?:\.exe)?[''"]?'
$gitPrefix = '(?:^|[\s;&|(])' + $gitName + '(?:\s+-C\s+(?:"[^"]*"|''[^'']*''|\S+)|\s+-\S+|\s+\S+=\S+)*'
$protectedBranches = @('main', 'master')
$plainPushOption = '^(?:-f|--force|--force-with-lease(?:=\S+)?|--force-if-includes|-u|--set-upstream|-q|--quiet|-v|--verbose|--atomic|--porcelain|--progress|--no-progress)$'

function Get-ShellCommand {
    param([string]$Json)

    if ([string]::IsNullOrWhiteSpace($Json)) { return $null }
    try { $hook = $Json | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    if (-not $hook) { return $null }

    foreach ($name in 'tool_input', 'toolArgs', 'tool_args') {
        $property = $hook.PSObject.Properties[$name]
        if (-not $property -or -not $property.Value) { continue }
        $value = $property.Value
        if ($value -is [string]) {
            try { $value = $value | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        }
        if ($value -and $value.PSObject.Properties['command']) { return [string]$value.command }
    }
    return $null
}

function ConvertFrom-BashDrivePath {
    param([string]$Path)

    if ($IsWindows -and $Path -match '^/([a-zA-Z])/(.*)$') { return '{0}:/{1}' -f $Matches[1], $Matches[2] }
    return $Path
}

function Get-PushDirectory {
    param([string]$CommandLine, [string]$Before, [string]$StartPath, [string]$Shell = 'bash')

    $m = [regex]::Match($CommandLine, '(?:^|[\s;&|(])' + $gitName + '\s+-C\s+(?:(?<quoted>"(?<d>[^"]*)")|(?<quoted>''(?<d>[^'']*)'')|(?<d>\S+))')
    if (-not $m.Success -or [regex]::Matches($CommandLine, '\s-C\s').Count -gt 1) { return $null }
    if ($m.Groups['d'].Value -match '[`$~*?\[\]]') { return $null }
    if ($Shell -eq 'bash' -and -not $m.Groups['quoted'].Success -and $m.Groups['d'].Value -match '[\\''"]') { return $null }
    $dir = ConvertFrom-BashDrivePath $m.Groups['d'].Value
    if ([IO.Path]::IsPathRooted($dir) -or -not $StartPath) { return $dir }
    $folderChange = if ($Shell -eq 'powershell') { '(?i:cd|pushd|popd|sl|Set-Location|Push-Location|Pop-Location)' } else { '(?:cd|pushd|popd)' }
    $commandStart = '(?:^|[;&|(){}!\r\n]|\b(?:then|do|else)\s)\s*(?:(?:builtin|command|exec|time)\s+)*'
    if ($Before -match ($commandStart + $folderChange + '(?:\s|;|$)')) { return $null }
    return Join-Path $StartPath $dir
}

function Get-SessionDirectory {
    param([string]$Json)

    try { $hook = $Json | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    $property = $hook.PSObject.Properties['cwd']
    if (-not $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) { return $null }
    $dir = ConvertFrom-BashDrivePath ([string]$property.Value)
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $null }
    return (Resolve-Path -LiteralPath $dir).Path
}

function Get-ShellName {
    param([string]$Json)

    try { $hook = $Json | ConvertFrom-Json -ErrorAction Stop } catch { return 'bash' }
    foreach ($name in 'tool_name', 'toolName') {
        $property = $hook.PSObject.Properties[$name]
        if ($property -and [string]$property.Value -match '^powershell$') { return 'powershell' }
    }
    return 'bash'
}

function Get-CdDirectory {
    param([string]$CommandLine, [string]$StartPath, [string]$Shell = 'bash')

    $push = [regex]::Match($CommandLine, "$gitPrefix\s+push(?:\s|$)")
    if (-not $push.Success -or $push.Value -match '\s-C\s|--git-dir|--work-tree') { return $null }
    $cdStep = if ($Shell -eq 'powershell') {
        '^\s*(?i:cd|pushd|sl|Set-Location|Push-Location)\s+(?:"(?<d>(?!-)[^"`$~*?\[\]]+)"|''(?<d>(?!-)[^''`$~*?\[\]]+)''|(?<d>(?!-)[^\s;&|<>''"`$~(){}#*?\[\]]+))\s*(?:&&|;)\s*$'
    }
    else {
        '^\s*(?:cd|pushd)\s+(?:"(?<d>(?!-)[^"`$~*?\[\]\\!]+)"|''(?<d>(?!-)[^''`$~*?\[\]]+)''|(?<d>(?!-)[^\s;&|<>''"`$~(){}#*?\[\]\\]+))\s*(?:&&|;)\s*$'
    }
    $step = [regex]::Match($CommandLine.Substring(0, $push.Index + 1), $cdStep)
    if (-not $step.Success) { return $null }
    $dir = ConvertFrom-BashDrivePath $step.Groups['d'].Value
    if ([IO.Path]::IsPathRooted($dir)) { return $dir }
    return Join-Path $StartPath $dir
}

function Test-IsGitPush {
    param([string]$CommandLine)

    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
    return [bool]($CommandLine -match "$gitPrefix\s+push(?:\s|$)")
}

function Test-TargetsProtectedBranch {
    param([string]$CommandLine, [string]$Branch)

    $push = [regex]::Match($CommandLine, "$gitPrefix\s+push(?<rest>[^;&|]*)")
    if (-not $push.Success) { return $false }
    $all = @($push.Groups['rest'].Value.Trim() -split '\s+' | Where-Object { $_ } | ForEach-Object { $_ -replace '[''"]', '' })
    if (@($all | Where-Object { $_ -in @('--all', '--mirror', '--branches') }).Count -gt 0) { return $true }
    $words = @($all | Where-Object { -not $_.StartsWith('-') })
    $refspecs = @($words | Select-Object -Skip 1)
    if ($refspecs.Count -eq 0) { return $Branch -in $protectedBranches }
    foreach ($refspec in $refspecs) {
        $target = ($refspec.TrimStart('+') -split ':')[-1] -replace '^refs/heads/', ''
        if ($target -in $protectedBranches) { return $true }
        if ($target -eq 'HEAD' -and $Branch -in $protectedBranches) { return $true }
    }
    return $false
}

function Get-PushedCommits {
    param([string]$CommandLine, [string]$Root)

    $single = $CommandLine.Trim() -replace '\s+2>&1(?:\s*\|\s*(?i:Out-String))?$', ''
    if ($single -match '[;&|<>\r\n`]|\$\(' -or [regex]::Matches($single, '(?:^|[\s;&|(])' + $gitName + '(?:\s|$)').Count -ne 1) { return $null }
    $push = [regex]::Match($single, "^$gitName\s+push(?<rest>.*)$")
    if (-not $push.Success) { return $null }
    $delete = $false
    $words = [System.Collections.Generic.List[string]]::new()
    foreach ($token in @($push.Groups['rest'].Value.Trim() -split '\s+' | Where-Object { $_ })) {
        if ($token -in @('-d', '--delete')) { $delete = $true; continue }
        if ($token.StartsWith('-')) {
            if ($token -notmatch $plainPushOption) { return $null }
            continue
        }
        if ($token -match '[''"`$*?\[\]~(){}]') { return $null }
        $words.Add($token)
    }
    if ($words.Count -lt 2) { return $null }
    $commits = [System.Collections.Generic.List[string]]::new()
    foreach ($refspec in ($words | Select-Object -Skip 1)) {
        $source = ($refspec.TrimStart('+') -split ':')[0]
        if ($delete -or -not $source) { $commits.Add('0' * 40); continue }
        $sha = try { [string](git -C $Root rev-parse --verify --quiet "$source^{commit}" 2>$null) } catch { '' }
        if ($LASTEXITCODE -ne 0 -or -not $sha.Trim()) { return $null }
        $commits.Add($sha.Trim())
    }
    return [pscustomobject]@{ Remote = $words[0]; Commits = $commits.ToArray() }
}

function Write-Deny {
    param([string]$Reason)

    @{
        permissionDecision = 'deny'
        permissionDecisionReason = $Reason
        hookSpecificOutput = @{
            hookEventName = 'PreToolUse'
            permissionDecision = 'deny'
            permissionDecisionReason = $Reason
        }
    } | ConvertTo-Json -Depth 5 -Compress | Write-Output
}

if (-not $PSBoundParameters.ContainsKey('Payload')) {
    $Payload = if ([Console]::IsInputRedirected) { [Console]::In.ReadToEnd() } else { '' }
}

if ([string]::IsNullOrEmpty($Payload) -or $Payload.IndexOf('push', [StringComparison]::OrdinalIgnoreCase) -lt 0) { exit 0 }

$command = Get-ShellCommand -Json $Payload
if (-not (Test-IsGitPush $command)) { exit 0 }

# Only a push gets this far. Copilot CLI starts this hook before every shell command, so the modules
# load after the cheap filter above.
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' '..' 'ai-sdlc-gates' 'scripts' 'PreflightReceipt.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' '..' 'ai-sdlc-gates' 'scripts' 'AiSdlcConfig.psm1') -Force
$hookRepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot

$sessionDir = Get-SessionDirectory -Json $Payload
$sessionRoot = if ($sessionDir) { try { [string](git -C $sessionDir rev-parse --show-toplevel 2>$null) } catch { '' } }
$targetRoot = if ($RepoRoot) { (Resolve-Path -LiteralPath $RepoRoot).Path }
elseif ($sessionRoot) { (Resolve-Path -LiteralPath $sessionRoot.Trim()).Path }
else { $hookRepoRoot }
$startPath = if ($sessionDir -and -not $RepoRoot) { $sessionDir } else { $targetRoot }
$pushMatch = [regex]::Match($command, "$gitPrefix\s+push(?:\s|$)")
$shellName = Get-ShellName -Json $Payload
$pushDir = Get-PushDirectory -CommandLine $pushMatch.Value -Before $command.Substring(0, $pushMatch.Index) -StartPath $startPath -Shell $shellName
if (-not $pushDir) { $pushDir = Get-CdDirectory -CommandLine $command -StartPath $startPath -Shell $shellName }
if ($pushDir) {
    $top = try { [string](git -C $pushDir rev-parse --show-toplevel 2>$null) } catch { '' }
    if ($top) { $targetRoot = (Resolve-Path -LiteralPath $top.Trim()).Path }
}
$targetInstalls = Test-Path -LiteralPath (Join-Path $targetRoot 'aisdlc.json') -PathType Leaf
if (-not $ReceiptRoot -and $targetInstalls) { $ReceiptRoot = Join-Path $targetRoot (Get-AiSdlcConfig -RepoRoot $targetRoot).paths.preflightReceipts }

if (-not $PSBoundParameters.ContainsKey('CurrentBranch')) {
    $CurrentBranch = try { [string](git -C $targetRoot rev-parse --abbrev-ref HEAD 2>$null) } catch { '' }
}
if (Test-TargetsProtectedBranch -CommandLine $command -Branch ([string]$CurrentBranch).Trim()) {
    Write-Deny ('A push to main or master is refused. A change reaches main only through a pull request that a ' +
        'person reviews and merges (.claude/skills/ai-sdlc-handbook/references/orchestration.md). Push the story ' +
        'branch and open or update its pull request instead.')
    exit 0
}

if (-not $targetInstalls) { exit 0 }

$pushed = Get-PushedCommits -CommandLine $command -Root $targetRoot
if ($pushed -and (Test-PushSendsNothingNew -RepoRoot $targetRoot -Remote $pushed.Remote -Commit $pushed.Commits)) { exit 0 }

if (-not (Test-Path -Path $CheckScript)) { exit 0 }

try {
    $ErrorActionPreference = 'Continue'
    $report = & pwsh -NoProfile -File $CheckScript -Strict -RepoRoot $targetRoot 2>&1 | Out-String
    $failed = $LASTEXITCODE -ne 0
}
catch {
    exit 0
}

if (-not $failed) {
    if (-not $PSBoundParameters.ContainsKey('HeadTree')) {
        $HeadTree = Get-HeadTree -RepoRoot $targetRoot
    }
    if (Test-PreflightReceipt -ReceiptRoot $ReceiptRoot -Tree $HeadTree) { exit 0 }
    Write-Deny ('This commit has no green pre-flight. Run the wrap-up skill, which ends with the pre-flight ' +
        '(pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-Preflight.ps1) on the committed tree: when no check fails it writes ' +
        'a receipt for the tree in the receipt folder (paths.preflightReceipts in aisdlc.json, temp/preflight by default), and this hook accepts the push. A run with -SkipTests or on ' +
        'uncommitted changes writes no receipt. Fix what fails, commit, run it again, then push ' +
        '(.claude/skills/ai-sdlc-handbook/references/orchestration.md).')
    exit 0
}

$reason = @(
    'This push would leave the change unfinished:'
    ''
    $report.Trim()
    ''
    'Run the wrap-up skill to bring the tests and both documentation layers up to what the'
    'code now does, then push again. If a gap is deliberate, stop and say why: a person decides whether'
    'the change goes out as it is.'
) -join "`n"

Write-Deny $reason

exit 0
