---
story: "#1"
phase: governance
step: write-adr
intent:
  assumption: "noticing that a step was skipped needs no judgement, so a hook can do it for free, every time, the same way for every tool"
  decision-drivers:
    - "the steps after the code works are the ones that get dropped, because the change already looks finished"
    - "a finding at the push reports a sentence written twenty edits ago, when the agent has moved on"
    - "a step that depends on someone remembering runs on the quiet days only"
    - "a bug in a hook must never block every tool call"
relates:
  hooks: core/.apm/hooks/ai-sdlc-hooks.json
  push: core/.apm/skills/ai-sdlc-hooks/scripts/Deny-IncompletePush.ps1
  postedit: core/.apm/skills/ai-sdlc-hooks/scripts/Invoke-PostEditCheck.ps1
  autolearn: core/.apm/skills/ai-sdlc-hooks/scripts/Invoke-AutolearnHook.ps1
  compact: core/.apm/skills/ai-sdlc-hooks/scripts/Invoke-CompactSuggestionHook.ps1
  payload: core/.apm/skills/ai-sdlc-hooks/scripts/HookPayload.psm1
because:
  hooks: "the hook entries that the core package installs"
  push: "the push deny that runs the completeness check"
  postedit: "the hook that returns the gate result of an edit at once"
  autolearn: "the hook that fires the learning loop after a correction"
  compact: "the hook that reports a measurement and decides nothing"
  payload: "the shared reader of both payload shapes"
---

# ADR 0006: Hooks enforce what must happen every time

**Status:** Accepted
**Date:** 2026-10-24
**Supersedes:** none
**Superseded by:** none

## Context

Some steps must happen every time, and an instruction does not make them happen. The Claude Code best
practices say so directly: instructions are advisory, and hooks are deterministic. Four cases matter
here.

- **Finishing a change.** Tests, both doc layers and an ADR come last, and last is where they are
  dropped. A change without them looks the same as one with them.
- **A finding long after the edit.** The gates run at the push and in CI, minutes after the line that
  fails them. The agent then goes back through files it no longer has in view.
- **Standing rules.** The language rule and the learning loop hold in every skill run. A copy in each
  skill drifts, and a loop that runs when someone asks runs rarely.
- **A full context.** Claude Code compacts the context where the harness decides. In the middle of a
  build that drops the plan. Only a person can type `/compact`.

GitHub Copilot CLI reads the hooks in `.claude/settings.json`. It ignores the Claude-only `if`
condition, sends its arguments in a different shape, and denies a call when a hook exits non-zero
(GitHub Copilot hooks reference).

## Decision

**1. Noticing is deterministic and free; fixing costs a model and runs only when noticing says so.**
`Check-ChangeCompleteness.ps1` reads the diff and reports code that moved without its tests or docs.
`Deny-IncompletePush.ps1`, a PreToolUse hook on `Bash|PowerShell`, turns a gap into a deny whose reason
names the `wrap-up` skill. The pre-push git hook runs the same check for every tool, and CI is the
backstop. The hook also refuses a push to the default branch. It refuses a commit with no green
pre-flight receipt as well. `PreflightReceipt.psm1` keys the receipt on the tree hash, so any changed
file needs a new run.

**2. An edit gets its gate result at once.** `Invoke-PostEditCheck.ps1`, a PostToolUse hook on
`Edit|Write`, runs the checks for that file type, such as the reading-level and em-dash gates on a
markdown page. It returns the findings as `additionalContext` and never denies the edit, because
refusing it would leave the file half-written.

**3. A standing rule is defined once and fires by itself.** The language rule and the learning loop each
have one page in the handbook. Every `SKILL.md` carries a `## Standing rules` block that links both, and
`Check-SkillHygiene.ps1` blocks a skill without it. `Invoke-AutolearnHook.ps1` matches a correction on
`UserPromptSubmit`, and on `Stop` blocks the end of the turn once until `capture-learning` has run. The
skill proposes; it never writes on its own.

**4. A hook may report a measurement and decide nothing.** `Invoke-CompactSuggestionHook.ps1` reads the
context size from the session transcript and reports it through `additionalContext`. It never blocks,
because the agent cannot compact; only a person can. When to compact is a handbook page, not a
standing rule, because it depends on the session and not on the step.

**5. The same rules for every hook.**

- The filter lives in the script, not only in the `if` condition, because Copilot CLI ignores `if`.
- `HookPayload.psm1` reads both payload shapes: `tool_input` and `toolArgs`, as an object or as a JSON
  string.
- A deny is written in both shapes at once: a top-level `permissionDecision` and a nested
  `hookSpecificOutput`.
- A hook fails open. A payload it cannot read, and any error inside it, exits 0 with no output. The git
  hook and CI still run the same checks.
- A hook command calls its script by a path relative to the repository
  ([ADR 0001](0001-ai-sdlc-is-shared-as-apm-packages.md)).

## Consequences

**Positive:**

- A skipped step can no longer be skipped in silence, and the reminder comes when it can still be acted on.
- No model is spent on detection.
- A finding arrives in the turn that wrote the line. The push gate becomes the backstop.
- One wording change to a standing rule is one edit on one page.
- Each rule has Pester tests, which a model-based check could not have.

**Negative:**

- `git push --no-verify` goes around the git hook, and a person can decline the agent's deny. The gate is
  a reminder with teeth, not a lock; CI is the backstop.
- Copilot CLI does not raise `UserPromptSubmit` and `Stop`, so there the learning loop runs from the
  skill text only.
- A per-edit check costs time on every edit, and it grows with the project.
- The compaction hook reads a transcript format that is not a published contract. When the shape
  changes it goes silent, so a change costs the signal and nothing else.
- Copilot CLI reads hooks once, at session start. After a pull that moves a hook script, restart the
  Copilot session.

**Neutral:**

- A change that only touches docs or workflows is silent in the completeness check.

## Alternatives considered

1. **A model on the pull request that decides whether the end ran.** Rejected because the question is a
   diff question. A model costs money every time, answers differently on the same input, and cannot be
   unit tested.
2. **A reminder printed at the end of a skill.** Rejected because it depends on a person reading and
   acting, which is the failure this removes.
3. **A deny on a post-edit finding.** Rejected because it refuses the edit and leaves the file in its old
   state.
4. **Copy the standing rules into each skill.** Rejected because the copies drift.
5. **A `Stop` hook alone for the learning loop.** Rejected as the only trigger, because `Stop` runs after
   every turn and cannot tell a correction from ordinary work.
6. **Block the turn when the context is large.** Rejected because the agent cannot compact.
7. **A second hook configuration only for Copilot.** Rejected because Copilot CLI already loads the entry
   in `.claude/settings.json`, so a copy would run the check twice.

## Verification

- `Deny-IncompletePush.Tests.ps1`, `Invoke-PostEditCheck.Tests.ps1`, `Invoke-AutolearnHook.Tests.ps1`,
  `Invoke-CompactSuggestionHook.Tests.ps1` and `HookPayload.Tests.ps1` cover the filters, both payload
  shapes, both deny shapes and the fail-open paths.
- `Check-ChangeCompleteness.Tests.ps1` and `Check-SkillHygiene.Tests.ps1` cover the rules the hooks run.
- `PrePushHook.Tests.ps1` covers the git hook.
- Not covered: whether the docs a person writes after a deny are any good. That is judgement, and it
  belongs to `wrap-up` and to review.

## References

- `core/.apm/hooks/ai-sdlc-hooks.json` - the hook entries.
- `core/.apm/skills/ai-sdlc-hooks/scripts/` - the hook scripts and their tests.
- [Autolearn](../../core/.apm/skills/ai-sdlc-handbook/references/autolearn.md) and [language](../../core/.apm/skills/ai-sdlc-handbook/references/language.md) - the two standing rules.
- [Context management](../../core/.apm/skills/ai-sdlc-handbook/references/context-management.md) - when to compact.
- Claude Code best practices, hooks for what must happen every time: https://code.claude.com/docs/en/best-practices
- Claude Code hooks reference, `additionalContext`, `Stop` and the transcript path: https://code.claude.com/docs/en/hooks
- GitHub Copilot hooks reference: https://docs.github.com/en/copilot/reference/hooks-reference
- GitHub Copilot CLI hooks: https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-hooks

## Related

- [ADR 0005](0005-the-gate-contract.md) - the gates the hooks run.
- [ADR 0007](0007-agents-md-has-a-size-limit.md) - the other half: short instructions, enforcement in hooks.
- [ADR index](README.md) - the list of decisions in this repository.
