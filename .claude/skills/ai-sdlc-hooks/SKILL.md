---
name: ai-sdlc-hooks
kind: knowledge
user-invocable: false
description: >
  What the AI-SDLC hooks do and why one refused or commented on a step. It covers the push check
  that needs a finished change and a green pre-flight, and the reading-level and build check after an
  edit. It also covers the compact suggestion, the autolearn prompt, and the git hooks with the
  one-time setup that wires them. Use when a hook denied a push, when a hook message needs explaining,
  or when a hook itself looks broken. Also use when a fresh clone needs its hooks wired. Do NOT use to run the pre-flight (run-preflight), to
  finish a change (wrap-up) or to explain a gate result (ai-sdlc-gates).
---

# AI-SDLC hooks

The agent hooks run in every agent tool that reads `.claude/settings.json`, and the scripts they call
sit in this skill's `scripts/` folder. Each hook command calls its script by a path relative to the
repository root. The git hooks sit in `githooks/`, and `Initialize-AiSdlc.ps1` points
`core.hooksPath` at that folder.

## The agent hooks

| Event | Script | What it does |
|---|---|---|
| Before a Bash or PowerShell command | `Deny-IncompletePush.ps1` | Refuses a push to `main` or `master`, a push of an unfinished change, and a push of a commit without a green pre-flight receipt. A push that sends nothing new, such as a tag on a commit the remote has or a branch delete, needs no receipt |
| Before a Bash or PowerShell command | `Deny-AgentMerge.ps1` | Refuses `gh pr merge` and a `gh api` call to a pull request merge endpoint, so the agent never merges (clause C09). The owner's merge is the approval at Checkpoint Bravo. Like the other hooks, it lets the command through when it cannot judge it |
| Before an edit or write | `Deny-SharedFileEdit.ps1` | Refuses an edit to a file listed in `apm.lock.yaml`, and names its source in AI.SDLC |
| Before an edit or write | `Invoke-CompactSuggestionHook.ps1` | Suggests a compact at a logical boundary when the context window is full |
| After an edit or write | `Invoke-PostEditCheck.ps1` | Runs the reading-level and em-dash gates on a markdown file, and hands any other file to the `postEdit` script of the pack that claims its extension, for example the dotnet build of a C# file |
| When a prompt arrives, and at stop | `Invoke-AutolearnHook.ps1` | Reminds the agent to capture a correction as a lesson |

The dotnet pack adds one more: `Deny-StaleGraphQuery.ps1` in `dotnet-code-graph` refuses a raw
`graphify` query in Bash or PowerShell on a stale code graph.

## The git hooks and the setup

- `githooks/pre-push` first refuses a push to `main` or `master`, the same rule as
  `Deny-IncompletePush.ps1`, so it also holds for GitHub Copilot and a push from a terminal. Then it
  runs the blocking gates, which include the doc-drift check when the dotnet pack is installed. It
  skips them when a passing pre-flight receipt covers the tree of the tip commit of each pushed ref
  (`Test-PushReceipt.ps1` in `ai-sdlc-gates`). The pre-flight ran the same gates on that content, and
  the pull request build still runs them. A push that only deletes refs, or whose commits
  the remote already has, runs no gate at all. Only the refs of the remote being pushed to count. Both
  push hooks judge this with one rule, `Test-PushSendsNothingNew` in `PreflightReceipt.psm1`. It also shows the change-completeness report, which is advisory and never fails the push. Last, it
  hands the same ref lines on to `git lfs pre-push`, so the LFS objects are uploaded. The other
  hooks refresh the code graph, and do nothing when the graph tooling is absent.
- `githooks/git-lfs-hook` is shared by `pre-push`, `post-checkout`, `post-commit` and `post-merge`.
  Git ignores the LFS hooks in `.git/hooks` once `core.hooksPath` is set, so these hooks hand on to
  Git LFS themselves. A repository whose `.gitattributes` never names `filter=lfs` sees no change.
  When the repository uses LFS but `git-lfs` is missing, the push fails with a clear message.
- A clone that still points `core.hooksPath` at an older folder, such as `.githooks/`, moves to
  `githooks/` the next time `Initialize-AiSdlc.ps1` runs.
- `scripts/Install-AiSdlc.ps1` is the one command for a fresh clone. It checks Windows long paths
  and switches them on when they are off, with one administrator prompt. It never does that in a
  CI run, and `-SkipLongPaths` leaves them alone. Then it checks the GitHub login (`gh auth status`),
  as advice only: a failed login check never skips `apm install`. It installs
  the pinned APM with `Install-Apm.ps1` when APM is missing, and warns when an installed APM is not
  the pinned version. It runs `apm install --frozen`, or plain `apm install` when there is no lock
  yet, and then `Initialize-AiSdlc.ps1`. When the knowledge folder (`paths.knowledgeRoot`) is missing, it
  says so, with the `gh repo clone` command when `knowledge.repository` is set. When a blocking setup check fails, it skips `apm install` and says so.
  It still runs `Initialize-AiSdlc.ps1`, and then exits 1. It works before APM is on the machine,
  because the repository commits the installed files.
- `scripts/AiSdlcSetup.ps1` holds three setup steps that the setup and update scripts share. They are
  the GitHub login check (`Test-GitHubLogin`), the advice after a failed `apm install`, and the executable bit of the
  git hooks.
- `scripts/Initialize-AiSdlc.ps1` wires `core.hooksPath`, checks the core tools and runs the `setup`
  script of each installed pack. When no ignore rule covers `temp/`, it adds `temp/` to
  `.git/info/exclude`, so a pre-flight receipt is never committed. It does the same for the folder
  that `paths.preflightReceipts` names when that folder is outside `temp/`, with a rule from the root
  such as `/out/`. It takes `-Minimal`, `-SkipRestore`, `-SkipGraphify`,
  `-SkipGlobalGitConfig` and `-WhatIf`.

## Rules every hook script follows

- **Filter inside the script, before anything slow.** GitHub Copilot CLI ignores the `if` field and runs
  every hook entry in turn before each tool call. So a script checks the command or file first, before
  it loads a slow module, and exits 0 in silence when it does not apply. Only `HookPayload.psm1` may
  load first, because a script needs it to read the payload. Keep one entry per tool.
- **Fail open.** A payload the script cannot read, a missing file or a bug exits 0 with no output. A
  hook error is a deny in Copilot CLI, so a crash must never block every step.
- **Read every payload shape** through `HookPayload.psm1`. Claude Code sends `tool_input`. Copilot CLI
  sends `tool_input` or `toolArgs`, sometimes as a JSON string. A GPT model in Copilot edits with
  `apply_patch`, which sends the text of the edit, and one such edit can name several files.
- **Return context in both shapes.** After a prompt or an edit, Copilot CLI reads `additionalContext`
  at the top level, and Claude Code reads it in `hookSpecificOutput`. `New-HookContextOutput` writes both.
- **Start the session in the root folder.** Copilot CLI runs no agent hook in a session that starts in
  a subfolder. The git `pre-push` hook still holds there.
- **Read repository paths from `aisdlc.json`** through `AiSdlcConfig.psm1` in the `ai-sdlc-gates` skill.

## When a hook refused a step

- A push to `main` or `master` was refused: push the story branch and open or update its pull
  request. A change reaches `main` only through a pull request.
- Any other push was refused: run `wrap-up`. It commits the change and ends with the pre-flight on
  that commit. Never push with `--no-verify`.
- The push check judges the repository the push targets. A push that names no folder is judged on
  the repository of the `cwd` field of the hook payload. In a session that works in a git worktree,
  that is the worktree, even though the hook itself runs from the main checkout.
- A push names a folder only in the plain forms: `git -C <dir> push`, and one `cd`, `pushd` or
  `Set-Location` right before the push, joined with `&&` or `;`. The folder may stand in quotes, and a
  relative folder starts at the `cwd`. Any other form is judged on the repository of the `cwd`. That
  covers a chain of steps, a `-C` folder with `$` or a wildcard, and a relative `-C` after a `cd`.
- An edit was refused: the file is shared. Change it in AI.SDLC; the handbook page on the layout says
  how to try the change against a local clone first.

## Sources

- [The layout of the shared AI-SDLC](/.claude/skills/ai-sdlc-handbook/references/layout.md) - core, packs, repo files and the local clone.
- [Orchestration](/.claude/skills/ai-sdlc-handbook/references/orchestration.md) - the two human checkpoints the push check protects.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).
