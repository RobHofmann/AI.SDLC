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

    The check reports through its exit code: 0 nothing found, 1 a gap, 2 could not check, 3 not
    applicable. Any other code counts as 1. A check that cannot start counts as exit 2: a missing check
    script, or a start that throws. The first line of the note then says what failed. Only a gap denies.
    On 2 or 3 the hook goes on to the
    pre-flight receipt check exactly as on 0. When that allows the push after exit 2, the hook writes
    one JSON object with only a systemMessage, which Claude Code shows to the user. It says the check
    could not check, and gives the first line of its output as the reason. After exit 3 it stays
    silent, like exit 0, because nothing was left to check, and a note on every push would hide the
    real ones. The note is never a permissionDecision of allow, because that would skip the permission
    prompt of the user. When the completeness gate is Off (its mode, or gateModes in aisdlc.json), the
    hook does not start it and goes on to the receipt check, as after exit 3. The receipt check stays.

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
    path here exits 0, also when it refuses. A command that is not a git push always allows, and so does
    a payload this script cannot read as a git push; the early filter runs before any module loads.
    Once the command is a git push, a fault the hook can name refuses the push: aisdlc.json that is not
    valid JSON, a missing paths.preflightReceipts, a module that cannot load, or a module that lacks a
    function this script calls. The reason names the fix (fix aisdlc.json, or run apm install). The
    reason is that a push the hook cannot check must not go out unchecked. An unexpected error, such as
    git failing in a way this script did not expect, allows the push with a systemMessage warning
    instead. That is a decision: a bug in this script must not block every push, and the pre-push git
    hook stays the backstop that no configuration can miss. Each call of git rev-parse is checked by
    its exit code, so a failed call never leaves a path or a commit that looks like a value.
    Before the completeness check it refuses any push to main or master: a named target, a quoted one,
    heads/main as git expands it, HEAD while on main, a bare push while on main, a matching refspec
    (: or +:), a wildcard refspec that is not under refs/tags/, and --all, --mirror or --branches. A push
    with no refspec is judged on what git is set to send: push.default (matching reaches main),
    remote.<name>.push and remote.<name>.mirror (true reaches main), for the remote the push names, else
    the push remote of the branch, else origin. A bare push whose settings send only a story branch passes.
    A bare push under push.default upstream, tracking or simple counts as a push to main when
    branch.<name>.merge of the current branch names main or master. After that check it refuses any
    git -c or --config-env option on a push, also quoted. A list of bad keys cannot be complete
    (include.*, branch.<name>.merge, remote.pushDefault), and no agent push needs one. A
    command that holds pushes to two different repositories is refused too. A repository that
    sets git.allowTrunkPush to true in aisdlc.json may update main or master directly, but only in a plain
    push that is the whole command: a +refspec, a delete refspec (:main), any push option outside a short
    allow list (-u, -q, -v, --set-upstream, --quiet, --verbose, --progress, --no-progress, --porcelain,
    --atomic, --follow-tags, each written in full), a git option before push other than -C, and a push
    chained with any other command stay refused. So --force, --delete, --mirror and --no-verify are refused,
    also when shortened. The setting counts only when it is in aisdlc.json on the remote-tracking ref of
    that main branch (refs/remotes/<remote>/main), so an edit in the working tree cannot switch it on.
    That ref lives in the clone, so it is a first check only. The pre-push git hook is the backstop: it
    reads the setting from the remote tip that git passes during the push, which no local ref can change. The rest of the checks still run on such a
    push. A permission rule
    cannot see which branch a bare push targets, so this hook is the guard for Claude Code and Copilot
    CLI alike. It is registered for the Bash tool and for the PowerShell tool, because a repository
    that allows git push in PowerShell would otherwise push past it. The PowerShell payload has the same
    shape (tool_name PowerShell, tool_input.command), and the filter also reads the PowerShell forms:
    git push, git -C <dir> push, & git push, & 'git' push and git.exe push. The if condition on the
    PowerShell entry keeps the hook from starting a process before every other PowerShell command. The
    branch policy on main refuses a direct push on the server anyway
    (.claude/skills/ai-sdlc-handbook/references/orchestration.md).
    After the completeness check it asks for the pre-flight receipt of each commit about to be pushed,
    not of HEAD: the hook reads the commit of every pushed ref, and git push origin other-branch looks up
    the tree of other-branch. Invoke-Preflight.ps1 writes temp/preflight/<tree hash>.json when no check
    failed on a clean tree (PreflightReceipt.psm1). A push whose commit the hook cannot tell is refused
    with no receipt lookup: a name that does not resolve, an option outside the short list, a quote or
    variable in a ref, a command before the push, or a git option the hook does not read. The reason
    tells an agent to stop and ask the person, and to give the push command in a code block the person
    can run. Only a person pushes with --no-verify, so no refusal names it as a way past. A gitleaks finding outside the baseline is a FAIL row, so it stops the
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
    case, and a wrong guess would let a push through, so the hook does not try. Each push in a command
    resolves its own repository (its own -C folder, else the folder change, else the cwd). Two different
    repositories in one command are refused. A -C folder the hook cannot read leaves the push judged on
    the repository of the cwd for the main and settings checks, but gives no commit, so a push that
    passes the completeness check is then refused as one whose commit the hook cannot tell.
    Known gaps stay open on purpose. This hook reads shell text, and each new form it learned brought
    another, so no more forms are added here. The git pre-push hook stays the backstop.
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
    Test seam: the tree hash to use for a pushed commit that is HEAD. Every other pushed commit, and
    HEAD when this is not supplied, gets its tree from git.
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

$isPush = $false
# An unexpected error allows the push with a warning, so a bug in this script cannot block every push. A
# failure the hook can name (a setting or a module it cannot read) refuses instead, where it is caught.
trap {
    if ($isPush) {
        $why = @("$($_.Exception.Message)" -split '\r?\n' | Where-Object { $_.Trim() })[0]
        @{ systemMessage = ('The agent push hook stopped on an unexpected error, so it did not check this push for a ' +
                "green pre-flight or a push to main: $why. Report it, so the hook gets fixed.") } | ConvertTo-Json -Compress | Write-Output
    }
    exit 0
}

$gitName = '[''"]?git(?:\.exe)?[''"]?'
$gitPrefix = '(?:^|[\s;&|(])' + $gitName + '(?:\s+-C\s+(?:"[^"]*"|''[^'']*''|\S+)|\s+-c\s+(?:"[^"]*"|''[^'']*''|\S)\S*|\s+\S*(?:"[^"]*"|''[^'']*'')\S*|\s+-\S+|\s+\S+=\S*)*'
$protectedBranches = @('main', 'master')
$plainPushOption = '^(?:-f|--force|--force-with-lease(?:=\S+)?|--force-if-includes|-u|--set-upstream|-q|--quiet|-v|--verbose|--atomic|--porcelain|--progress|--no-progress)$'
# The options that leave the pushed commits as they are, so the receipt lookup may read past them. The
# allowTrunkPush rules take the same short options (-uq) and --follow-tags. --no-verify is not here.
$sentCommitOption = '^(?:-[uqv]+|--follow-tags|' + $plainPushOption.Substring(4)

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
    return (Resolve-Path -LiteralPath $dir).ProviderPath
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

function Test-RefspecReachesProtected {
    # True for a refspec that can update main or master: a name (git also expands heads/ to refs/heads/),
    # HEAD while on main, a matching refspec (: or +:), and a wildcard that is not under refs/tags/.
    param([string]$Refspec, [string]$Branch)

    if ($Refspec.TrimStart('+') -eq ':') { return $true }
    if ($Refspec.Contains('*') -and ($Refspec -split ':')[-1] -notmatch '^refs/tags/') { return $true }
    $target = ($Refspec.TrimStart('+') -split ':')[-1] -replace '^(?:refs/)?heads/', ''
    if ($target -in $protectedBranches) { return $true }
    # git reads @ as HEAD, and on a file system that ignores case it finds HEAD as head too.
    return ($target -in 'HEAD', '@' -and $Branch -in $protectedBranches)
}

function Get-ConfigValue {
    # Every value of a git setting. A setting that is not set makes git exit 1, which is not an error here.
    param([string]$Root, [string]$Key)

    $value = @(git -C $Root config --get-all $Key 2>$null)
    if ($LASTEXITCODE -ne 0) { return @() }
    return @($value | Where-Object { "$_".Trim() })
}

function Get-ConfiguredPush {
    # What git pushes for a push with no refspec: push.default, remote.<name>.push and remote.<name>.mirror,
    # for the remote the push names, else the push remote of the branch, else the default remote.
    param([string]$Root, [string]$Remote, [string]$Branch)

    $ErrorActionPreference = 'Continue'
    if (-not $Remote) {
        $Remote = @(
            foreach ($key in "branch.$Branch.pushRemote", 'remote.pushDefault', "branch.$Branch.remote") {
                @(Get-ConfigValue -Root $Root -Key $key) | Select-Object -Last 1
            }
            'origin'
        )[0]
    }
    $default = "$(@(Get-ConfigValue -Root $Root -Key 'push.default') | Select-Object -Last 1)"
    $refspecs = Get-ConfigValue -Root $Root -Key "remote.$Remote.push"
    $mirror = @(Get-ConfigValue -Root $Root -Key "remote.$Remote.mirror") | Select-Object -Last 1
    $merge = "$(@(Get-ConfigValue -Root $Root -Key "branch.$Branch.merge") | Select-Object -Last 1)"
    return [pscustomobject]@{
        Default  = $default.Trim()
        Refspecs = @($refspecs | Where-Object { $_ })
        Mirror   = @($mirror | Where-Object { "$_".Trim() -match '^(?i:true|yes|on|1)$' }).Count -gt 0
        Merge    = ($merge.Trim() -replace '^refs/heads/', '')
    }
}

function Test-TargetsProtectedBranch {
    param([string]$CommandLine, [string]$Branch, [string]$Root)

    # Every push in the command counts, so a second push in a chain cannot reach main unseen.
    foreach ($push in [regex]::Matches($CommandLine, "$gitPrefix\s+push(?<rest>[^;&|]*)")) {
        $all = @($push.Groups['rest'].Value.Trim() -split '\s+' | Where-Object { $_ } | ForEach-Object { $_ -replace '[''"]', '' })
        if (@($all | Where-Object { $_ -in @('--all', '--mirror', '--branches') }).Count -gt 0) { return $true }
        $repoOption = $null
        $words = [System.Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $all.Count; $i++) {
            if ($all[$i] -eq '--repo' -and $i + 1 -lt $all.Count) { $repoOption = $all[++$i]; continue }
            if ($all[$i] -match '^--repo=(?<r>.*)$') { $repoOption = $Matches['r']; continue }
            if (-not $all[$i].StartsWith('-')) { $words.Add($all[$i]) }
        }
        $refspecs = @($words | Select-Object -Skip 1)
        if ($refspecs.Count -eq 0) {
            if ($Branch -in $protectedBranches) { return $true }
            if (-not $Root) { continue }
            # git takes the settings of the remote a bare push goes to; the positional remote wins over --repo.
            $remote = if ($words.Count -gt 0) { $words[0] } else { $repoOption }
            $configured = Get-ConfiguredPush -Root $Root -Remote $remote -Branch $Branch
            if ($configured.Default -eq 'matching' -or $configured.Mirror) { return $true }
            # upstream (tracking) pushes to the branch that branch.<name>.merge names, and simple does
            # so when the names match; a feature branch that tracks main would reach it.
            if ($configured.Default -in '', 'simple', 'upstream', 'tracking' -and $configured.Merge -in $protectedBranches) { return $true }
            $refspecs = $configured.Refspecs
        }
        elseif ($Root -and @($refspecs | Where-Object { -not $_.Contains(':') }).Count -gt 0) {
            # git maps a refspec without :<dst> through remote.<name>.push, so git push origin feature
            # reaches main when that setting sends feature there. Any configured refspec that can reach
            # main or master counts, because the mapping by source is not worth parsing here.
            $remote = if ($words.Count -gt 0) { $words[0] } else { $repoOption }
            $configured = Get-ConfiguredPush -Root $Root -Remote $remote -Branch $Branch
            $refspecs = @($refspecs) + @($configured.Refspecs)
        }
        foreach ($refspec in $refspecs) {
            if (Test-RefspecReachesProtected -Refspec $refspec -Branch $Branch) { return $true }
        }
    }
    return $false
}

function Test-PushConfigOverride {
    # True for any git -c or --config-env option on a push. A list of bad keys cannot be complete:
    # include.*, includeIf.*, branch.<name>.merge and remote.pushDefault change a push as well. No agent
    # push needs a setting on the command line, so every one is refused.
    param([string]$CommandLine)

    $option = '(?:^|\s)(?:-c|--config-env)(?:\s|=)'
    foreach ($push in [regex]::Matches($CommandLine, "$gitPrefix\s+push(?:\s|$)")) {
        if (($push.Value -replace '[''"\\`]', '') -cmatch $option) { return $true }
    }
    return $false
}

function Get-TrunkTrackingRef {
    # The remote-tracking ref of the main branch a plain push updates, such as refs/remotes/origin/main.
    # git.allowTrunkPush is read from that commit, so only a setting that is already on the remote counts.
    # Call it only after Test-RewritesBranch passed, so the command is one plain push.
    param([string]$CommandLine, [string]$Branch, [string]$Root)

    $push = [regex]::Match($CommandLine, "$gitPrefix\s+push(?<rest>[^;&|]*)")
    $all = @($push.Groups['rest'].Value.Trim() -split '\s+' | Where-Object { $_ } | ForEach-Object { $_ -replace '[''"]', '' })
    $words = @($all | Where-Object { $_ -ne '2>&1' -and -not $_.StartsWith('-') })
    $remote = if ($words.Count -gt 0) { $words[0] } else { '' }
    if (-not $remote -and $Branch) { $remote = try { [string](git -C $Root config "branch.$Branch.remote" 2>$null) } catch { '' } }
    if (-not $remote) { $remote = 'origin' }
    $target = $Branch
    foreach ($refspec in @($words | Select-Object -Skip 1)) {
        $name = ($refspec -split ':')[-1] -replace '^(?:refs/)?heads/', ''
        if ($name -eq 'HEAD') { $name = $Branch }
        if ($name -in $protectedBranches) { $target = $name; break }
    }
    return "refs/remotes/$($remote.Trim())/$target"
}

function Test-RewritesBranch {
    # True when the push may delete or rewrite a branch, or when the hook cannot judge it: a force option,
    # a +refspec, a delete, a push of every branch, --no-verify (which skips the pre-push git hook), a git
    # option before push other than -C, or a command that holds anything besides this one push. Only a
    # plain push that is the whole command may update the trunk under git.allowTrunkPush.
    param([string]$CommandLine)

    $single = $CommandLine.Trim() -replace '\s+2>&1(?:\s*\|\s*(?i:Out-String))?$', ''
    if ($single -match '[;&|<>\r\n`]|\$\(') { return $true }
    if ([regex]::Matches($single, '(?:^|\s)' + $gitName + '(?:\s|$)').Count -ne 1) { return $true }
    $push = [regex]::Match($single, '^&?\s*' + $gitName + '(?:\s+-C\s+(?:"[^"]*"|''[^'']*''|\S+))?\s+push(?<rest>(?:\s.*)?)$')
    if (-not $push.Success) { return $true }
    $all = @($push.Groups['rest'].Value.Trim() -split '\s+' | Where-Object { $_ } | ForEach-Object { $_ -replace '[''"]', '' })
    # Options pass only from a short allow list, written in full. git accepts a shortened long option,
    # such as --dele for --delete, so a deny list of names would miss one.
    $safeLong = @('--set-upstream', '--quiet', '--verbose', '--progress', '--no-progress', '--porcelain', '--atomic', '--follow-tags')
    foreach ($word in $all) {
        # A remote or refspec holds only plain name characters. A backslash, $ or brace could hide an
        # option from this check (\--force reaches git as --force), so such a word is refused.
        if (-not $word.StartsWith('-')) {
            if ($word -notmatch '^[A-Za-z0-9._/:@^~+-]+$') { return $true }
            continue
        }
        if ($word.StartsWith('--')) {
            if ($word -notin $safeLong) { return $true }
        }
        elseif ($word -notmatch '^-[uqv]+$') { return $true }
    }
    $refspecs = @($all | Where-Object { -not $_.StartsWith('-') } | Select-Object -Skip 1)
    foreach ($refspec in $refspecs) {
        if ($refspec.StartsWith('+') -or $refspec.StartsWith(':')) { return $true }
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
        if ($refspec.TrimStart('+') -eq ':') { return $null }
        $source = ($refspec.TrimStart('+') -split ':')[0]
        if ($delete -or -not $source) { $commits.Add('0' * 40); continue }
        $sha = Get-RevisionCommit -Root $Root -Revision $source
        if (-not $sha) { return $null }
        $commits.Add($sha)
    }
    return [pscustomobject]@{ Remote = $words[0]; Commits = $commits.ToArray() }
}

function Split-ShellWord {
    # Split text into words with quotes taken out. Null when the text holds anything a shell would expand:
    # a backslash, $, a backtick or an unclosed quote.
    param([string]$Text)

    $word = '(?:"[^"$`\\]*"|''[^'']*''|[^\s"''\\$`]+)+'
    if (($Text -replace $word, '').Trim()) { return $null }
    return , @([regex]::Matches($Text, $word) | ForEach-Object { $_.Value -replace '["'']', '' })
}

function Get-RevisionCommit {
    # The commit a revision names, or null. A non-zero exit of git (no such revision) gives null, not a value.
    param([string]$Root, [string]$Revision)

    $sha = [string](git -C $Root rev-parse --verify --quiet "$Revision^{commit}" 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $sha.Trim()) { return $null }
    return $sha.Trim()
}

function Resolve-PushUnit {
    # The commits one `git [options] push ...` sends, or null when the hook cannot tell. A push with no
    # refspec sends what git is set up to send: the configured refspecs, else HEAD under a push.default
    # that pushes the current branch.
    param([string]$Body, [string]$Root, [string]$Branch)

    $m = [regex]::Match($Body, '^' + $gitName + '(?<opts>.*?)\s+push(?<rest>(?=\s|$).*)$', 'Singleline')
    if (-not $m.Success) { return $null }
    $globals = Split-ShellWord $m.Groups['opts'].Value
    if ($null -eq $globals) { return $null }
    for ($i = 0; $i -lt $globals.Count; $i++) {
        if ($globals[$i] -cnotin '-C', '-c' -or $i + 1 -ge $globals.Count) { return $null }
        $i++
    }
    $tokens = Split-ShellWord $m.Groups['rest'].Value
    if ($null -eq $tokens) { return $null }
    $delete = $false
    $repoOption = $null
    $words = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $token = $tokens[$i]
        if ($token -cin '-d', '--delete') { $delete = $true }
        elseif ($token -ceq '--repo' -and $i + 1 -lt $tokens.Count) { $repoOption = $tokens[++$i] }
        elseif ($token -cmatch '^--repo=(?<r>.+)$') { $repoOption = $Matches['r'] }
        elseif ($token -cmatch $sentCommitOption) { continue }
        elseif ($token.StartsWith('-') -or $token -match '[*?\[\]~(){}<>]') { return $null }
        else { $words.Add($token) }
    }
    $refspecs = @($words | Select-Object -Skip 1)
    if ($refspecs.Count -eq 0) {
        $remote = if ($words.Count -gt 0) { $words[0] } else { $repoOption }
        $configured = Get-ConfiguredPush -Root $Root -Remote $remote -Branch $Branch
        if ($configured.Refspecs.Count -gt 0) { $refspecs = $configured.Refspecs }
        elseif ($configured.Default -in '', 'simple', 'current', 'upstream', 'tracking') { $refspecs = @('HEAD') }
        else { return $null }
    }
    $commits = [System.Collections.Generic.List[string]]::new()
    foreach ($refspec in $refspecs) {
        if ($refspec.Contains('*')) { return $null }
        $source = ($refspec.TrimStart('+') -split ':')[0]
        if ($delete -or -not $source) { continue }
        $sha = Get-RevisionCommit -Root $Root -Revision $source
        if (-not $sha) { return $null }
        $commits.Add($sha)
    }
    return , $commits.ToArray()
}

function Resolve-PushedCommit {
    # The commit of every push in the command, or null when the hook cannot tell which commit goes out. Only a
    # folder change right before the first push, and && or ; between pushes, are read (a pipe to a viewer
    # at the end is cut). A folder change the hook could not read ($FolderResolved false) gives null.
    param([string]$CommandLine, [string]$Root, [string]$Branch, [bool]$FolderResolved)

    try {
        if ($CommandLine -match '[\r\n`]|\$\(') { return $null }
        $text = $CommandLine.Trim() -replace '(?:\s+\d?>&\d)?(?:\s*\|\s*(?i:Out-String|Select-Object|Select-String|Out-Null|tail|head)\b[^;&|]*)*$', ''
        $units = @([regex]::Matches($text, "$gitPrefix\s+push(?<rest>[^;&|]*)"))
        if ($units.Count -eq 0) { return $null }
        $folderStep = '^\s*(?:(?i:cd|pushd|sl|Set-Location|Push-Location)\s+(?:"[^"]*"|''[^'']*''|[^\s;&|]+)\s*(?:&&|;))?\s*$'
        $commits = [System.Collections.Generic.List[string]]::new()
        $end = 0
        foreach ($unit in $units) {
            $lead = if ($unit.Value -match '^[;&|(]') { $unit.Value.Substring(0, 1) } else { '' }
            $gap = $text.Substring($end, $unit.Index - $end) + $lead
            $allowed = if ($end -eq 0) { $folderStep } else { '^\s*(?:&&|;)\s*$' }
            if ($gap -notmatch $allowed) { return $null }
            if ($end -eq 0 -and $gap.Trim() -and -not $FolderResolved) { return $null }
            $unitCommits = Resolve-PushUnit -Body $unit.Value.Substring($lead.Length).Trim() -Root $Root -Branch $Branch
            if ($null -eq $unitCommits) { return $null }
            foreach ($sha in $unitCommits) { $commits.Add($sha) }
            $end = $unit.Index + $unit.Length
        }
        if ($text.Substring($end).Trim()) { return $null }
        return , $commits.ToArray()
    }
    catch {
        return $null
    }
}

function Get-PushRoot {
    # The repository root of each push in the command: the root of its own -C folder, else the base root.
    # An empty entry marks a -C folder the hook cannot read as a folder of a repository.
    param([string]$CommandLine, [string]$BaseRoot, [string]$StartPath, [string]$Shell)

    $roots = foreach ($unit in [regex]::Matches($CommandLine, "$gitPrefix\s+push(?:\s|$)")) {
        if ($unit.Value -cnotmatch '\s-C\s') { $BaseRoot; continue }
        $dir = Get-PushDirectory -CommandLine $unit.Value -Before $CommandLine.Substring(0, $unit.Index) -StartPath $StartPath -Shell $Shell
        if (-not $dir) { ''; continue }
        # A folder that does not exist makes git itself fail, so the push judged on the base repository is harmless.
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { $BaseRoot; continue }
        $top = [string](git -C $dir rev-parse --show-toplevel 2>$null)
        if ($LASTEXITCODE -ne 0 -or -not $top.Trim()) { ''; continue }
        (Resolve-Path -LiteralPath $top.Trim()).ProviderPath
    }
    return , @($roots)
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

function Write-Note {
    param([string]$Message)

    @{ systemMessage = $Message } | ConvertTo-Json -Depth 3 -Compress | Write-Output
}


if (-not $PSBoundParameters.ContainsKey('Payload')) {
    $Payload = if ([Console]::IsInputRedirected) { [Console]::In.ReadToEnd() } else { '' }
}

if ([string]::IsNullOrEmpty($Payload) -or $Payload.IndexOf('push', [StringComparison]::OrdinalIgnoreCase) -lt 0) { exit 0 }

$command = Get-ShellCommand -Json $Payload
if (-not (Test-IsGitPush $command)) { exit 0 }
$isPush = $true

# Only a push gets this far. Copilot CLI starts this hook before every shell command, so the modules
# load after the cheap filter above. A module that cannot load, or that lacks a function this script
# calls, refuses the push: with no module the hook cannot check anything, and an allow would hide that.
$moduleFunctions = [ordered]@{
    'PreflightReceipt.psm1' = @('Test-PushSendsNothingNew', 'Test-PreflightReceipt')
    'AiSdlcConfig.psm1'     = @('Find-AiSdlcRepoRoot', 'Get-AiSdlcConfig', 'Test-AiSdlcGateOff', 'Test-AiSdlcTrunkPushAllowed')
}
foreach ($module in $moduleFunctions.Keys) {
    try {
        Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' '..' 'ai-sdlc-gates' 'scripts' $module) -Force
    }
    catch {
        Write-Deny ("This push is refused because the push hook cannot load its module $module, so it cannot check the " +
            'pre-flight receipt. Run apm install to restore the AI-SDLC files, then push again.')
        exit 0
    }
    foreach ($name in $moduleFunctions[$module]) {
        if (-not (Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue)) {
            Write-Deny ("This push is refused because the module $module of the push hook has no function $name, so it cannot check the " +
                'push. Run apm install to restore the AI-SDLC files, then push again.')
            exit 0
        }
    }
}
$hookRepoRoot = Find-AiSdlcRepoRoot -StartPath $PSScriptRoot

$sessionDir = Get-SessionDirectory -Json $Payload
$sessionRoot = if ($sessionDir) {
    try {
        $found = [string](git -C $sessionDir rev-parse --show-toplevel 2>$null)
        if ($LASTEXITCODE -eq 0) { $found } else { '' }
    }
    catch { '' }
}
# ProviderPath: .Path keeps the FileSystem:: prefix on a UNC path, and git cannot read that (#29).
$targetRoot = if ($RepoRoot) { (Resolve-Path -LiteralPath $RepoRoot).ProviderPath }
elseif ($sessionRoot) { (Resolve-Path -LiteralPath $sessionRoot.Trim()).ProviderPath }
else { $hookRepoRoot }
$startPath = if ($sessionDir -and -not $RepoRoot) { $sessionDir } else { $targetRoot }
$shellName = Get-ShellName -Json $Payload
$cdDir = Get-CdDirectory -CommandLine $command -StartPath $startPath -Shell $shellName
$cdResolved = $false
if ($cdDir) {
    $top = try {
        $found = [string](git -C $cdDir rev-parse --show-toplevel 2>$null)
        if ($LASTEXITCODE -eq 0) { $found } else { '' }
    }
    catch { '' }
    if ($top.Trim()) {
        $targetRoot = (Resolve-Path -LiteralPath $top.Trim()).ProviderPath
        $cdResolved = $true
    }
}
# Each push resolves its own repository. Two different repositories in one command are refused below.
$pushRoots = Get-PushRoot -CommandLine $command -BaseRoot $targetRoot -StartPath $startPath -Shell $shellName
$comparer = if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
$knownRoots = [System.Collections.Generic.List[string]]::new()
foreach ($root in @($pushRoots | Where-Object { $_ })) {
    if (-not ($knownRoots | Where-Object { $comparer.Equals($_, $root) })) { $knownRoots.Add($root) }
}
$oneRepository = $knownRoots.Count -le 1
# A -C folder the hook cannot read leaves the push judged on the base repository for the main and settings
# checks, but its commits cannot be told apart, so a green completeness check still gets no receipt lookup.
$unknownRoot = @($pushRoots | Where-Object { -not $_ }).Count -gt 0
if ($knownRoots.Count -gt 0) { $targetRoot = $knownRoots[0] }
$targetInstalls = Test-Path -LiteralPath (Join-Path $targetRoot 'aisdlc.json') -PathType Leaf
if (-not $ReceiptRoot -and $targetInstalls) {
    try {
        $receiptFolder = (Get-AiSdlcConfig -RepoRoot $targetRoot).paths.preflightReceipts
        if ([string]::IsNullOrWhiteSpace($receiptFolder)) { throw 'paths.preflightReceipts is missing' }
        $ReceiptRoot = Join-Path $targetRoot $receiptFolder
    }
    catch {
        $why = @("$($_.Exception.Message)" -split '\r?\n' | Where-Object { $_.Trim() })[0]
        Write-Deny ('This push is refused because aisdlc.json cannot be read as AI-SDLC settings. ' +
            'It may not be valid JSON, it may miss paths.preflightReceipts, or it may name a source folder outside the repository. ' +
            "The reason: $why. Fix aisdlc.json, commit, and push again.")
        exit 0
    }
}

if (-not $PSBoundParameters.ContainsKey('CurrentBranch')) {
    $CurrentBranch = try {
        $found = [string](git -C $targetRoot rev-parse --abbrev-ref HEAD 2>$null)
        if ($LASTEXITCODE -eq 0) { $found } else { '' }
    }
    catch { '' }
}
if (Test-TargetsProtectedBranch -CommandLine $command -Branch ([string]$CurrentBranch).Trim() -Root $targetRoot) {
    $trunkPushAllowed = $targetInstalls -and (Test-AiSdlcTrunkPushAllowed -RepoRoot $targetRoot)
    if (-not $trunkPushAllowed) {
        Write-Deny ('A push to main or master is refused. A change reaches main only through a pull request that a ' +
            'person reviews and merges (.claude/skills/ai-sdlc-handbook/references/orchestration.md). Push the story ' +
            'branch and open or update its pull request instead.')
        exit 0
    }
    if (Test-RewritesBranch -CommandLine $command) {
        Write-Deny ('git.allowTrunkPush in aisdlc.json allows a plain push to main or master, not a force push, a ' +
            'delete, a push of every branch, --no-verify, a git option before push, or a push chained with other ' +
            'commands. Run the push of main on its own, as git push [remote] [branch].')
        exit 0
    }
    $trunkRef = Get-TrunkTrackingRef -CommandLine $command -Branch ([string]$CurrentBranch).Trim() -Root $targetRoot
    if (-not (Test-AiSdlcTrunkPushAllowed -RepoRoot $targetRoot -Ref $trunkRef)) {
        Write-Deny ("git.allowTrunkPush counts only when it is on the remote main branch ($trunkRef), not in the " +
            'working tree alone. Get the setting onto main through a pull request first, or fetch when it is ' +
            'already there.')
        exit 0
    }
}

if (Test-PushConfigOverride -CommandLine $command) {
    Write-Deny ('A push with a git -c or --config-env option is refused, because a setting such as push.*, remote.<name>.push, ' +
        'remote.<name>.mirror, include.* or core.hooksPath can change what the push sends or turn off the git pre-push hook. ' +
        'Push without that option. When a git hook does not ' +
        'work, an agent stops and asks the person, and gives the push command in a code block the person can run. ' +
        'Only a person pushes with git push --no-verify.')
    exit 0
}

if (-not $oneRepository) {
    Write-Deny ('This push is refused because the command pushes to two repositories, so the hook cannot judge them as one. ' +
        'Push one repository per command, and name its folder plainly with git -C <folder> or a cd <folder> before the push.')
    exit 0
}

if (-not $targetInstalls) { exit 0 }

$pushed = Get-PushedCommits -CommandLine $command -Root $targetRoot
if ($pushed -and (Test-PushSendsNothingNew -RepoRoot $targetRoot -Remote $pushed.Remote -Commit $pushed.Commits)) { exit 0 }

# The commits of every push in the command, or null when the hook cannot tell which commit goes out.
$commits = if (-not $unknownRoot) {
    Resolve-PushedCommit -CommandLine $command -Root $targetRoot -Branch ([string]$CurrentBranch).Trim() -FolderResolved $cdResolved
}

# An Off completeness gate does not run, and the push goes on to the receipt check as after exit 3. It
# counts as Off only when every pushed commit holds the gate settings of the working tree (#49).
$gateIsOff = ($null -ne $commits) -and $(try { Test-AiSdlcGateOff -RepoRoot $targetRoot -Script (Split-Path -Leaf $CheckScript) -Commit $commits } catch { $false })

if ($gateIsOff) {
    $report = ''
    $checkCode = 3
}
elseif (-not (Test-Path -LiteralPath $CheckScript)) {
    # A check that cannot start is exit 2: the receipt check still runs, and a green receipt allows with a note.
    $checkCode = 2
    $report = "the completeness check script is missing: $(Split-Path -Leaf $CheckScript)"
}
else {
    try {
        $ErrorActionPreference = 'Continue'
        $report = & pwsh -NoProfile -File $CheckScript -Strict -RepoRoot $targetRoot 2>&1 | Out-String
        $checkCode = $LASTEXITCODE
    }
    catch {
        $checkCode = 2
        $report = "the completeness check could not start: $($_.Exception.Message)"
    }
    finally {
        $ErrorActionPreference = 'Stop'
    }
}

$failed = $checkCode -notin 0, 2, 3

if (-not $failed) {
    if ($null -eq $commits) {
        Write-Deny ('This push is refused because the hook cannot tell which commit it sends, so it cannot check the ' +
            'pre-flight receipt of that commit. Push in the plain form, git push [options] <remote> <branch or src:dst>, ' +
            'as its own command; only a cd may come before it. When the push cannot take that form, an agent stops and ' +
            'asks the person, and gives the push command in a code block the person can run.')
        exit 0
    }
    # The receipt is looked up for the tree of every pushed commit, not for HEAD. -HeadTree stands in for the
    # tree of a pushed commit that is HEAD.
    $headSha = if ($PSBoundParameters.ContainsKey('HeadTree')) { Get-RevisionCommit -Root $targetRoot -Revision 'HEAD' }
    $trees = @(foreach ($sha in $commits) {
            if ($headSha -and $sha -eq $headSha) { $HeadTree; continue }
            $tree = [string](git -C $targetRoot rev-parse --verify --quiet "$sha^{tree}" 2>$null)
            if ($LASTEXITCODE -ne 0) { ''; continue }
            $tree.Trim()
        })
    if (@($trees | Where-Object { -not $_ -or -not (Test-PreflightReceipt -ReceiptRoot $ReceiptRoot -Tree $_) }).Count -eq 0) {
        if ($checkCode -eq 2) {
            $firstLine = @($report -split '\r?\n' | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })[0]
            if (-not $firstLine) { $firstLine = 'the check printed no reason' }
            Write-Note ("The completeness check could not check (exit 2), so this push was not judged on tests and documentation moving with the code: {0}" -f $firstLine)
        }
        exit 0
    }
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
