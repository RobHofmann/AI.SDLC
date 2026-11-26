---
story: "#48"
phase: governance
step: write-adr
intent:
  assumption: "a gate whose input files a change does not touch cannot find anything new in that change"
  decision-drivers:
    - "a small change should get its answer in seconds, not minutes"
    - "the pull request build must still check everything before a merge"
    - "a wrong scope must check more, never less"
relates:
  runner: core/.apm/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1
  change: core/.apm/skills/ai-sdlc-gates/scripts/ChangedFiles.psm1
  preflight: core/.apm/skills/ai-sdlc-gates/scripts/Invoke-Preflight.ps1
  receipt: core/.apm/skills/ai-sdlc-gates/scripts/PreflightReceipt.psm1
  hook: core/.apm/skills/ai-sdlc-hooks/githooks/pre-push
because:
  runner: "leaves out a gate whose inputs the change does not touch"
  change: "gives the one list of files a change touches, and the path globs"
  preflight: "runs commands.testChanged and measures from the last green pre-flight"
  receipt: "finds the commit of the last green pre-flight on the branch"
  hook: "runs every blocking gate when a pushed ref is not the checked-out commit"
---

# ADR 0020: A local run checks what the change touches

**Status:** Accepted
**Date:** 2026-11-26
**Supersedes:** none
**Superseded by:** none

## Context

A local gate run and the pre-flight ran every gate, also for a change to one page. A small change
waited for slow gates that could not find anything in it (#48). The pull request build is the gate of
record ([ADR 0019](0019-a-gate-reports-pass-finding-could-not-check-or-not-applicable.md)). So a local
run may do less, as long as it never hides a finding the build would make.

## Decision

1. **A gate may name its inputs.** `inputs` in a `gates.json` entry or a `repoGates` entry is a list of
   path globs. A local run starts the gate only when the change touches a file that matches, or a file
   in the skill folder of its script. A gate without `inputs` always runs. A gate that did not run shows
   `NOT TOUCHED`.
2. **Every gate runs when the scope is in doubt.** That is when the change deletes or moves a file, or
   when git cannot read the change. It is also when the change touches `aisdlc.json`, a `gates.json` or
   the skill folder of the runner. GitHub Actions and `-All` always run every gate, so the pull request build checks
   everything.
3. **The change is the branch plus the working tree.** It is what the branch committed since the merge
   base with `origin/<github.trunk>`, with the staged, edited and new files. `ChangedFiles.psm1` gives
   this one list to the runner, the pre-flight and the gates.
4. **A fix commit checks what changed since the last green pre-flight.** `Invoke-Preflight.ps1` finds the
   commit of the newest passing receipt on the branch and sets `AISDLC_CHANGE_BASE` to it. A value that
   is not a full commit hash in the history of HEAD is ignored, so a stale value checks more.
5. **The pre-flight runs the changed tests.** When `aisdlc.json` sets `commands.testChanged`, a scoped
   pre-flight runs it in place of `commands.test`, and `-Full` runs `commands.test`. A test command that
   exits 3 ran no test; its row is `N/A` and the receipt is still written.
6. **The pre-push hook runs every blocking gate when a pushed ref is not the checked-out commit.** The
   working tree then says nothing about what is pushed.

## Consequences

**Positive:**

- A change to one page runs the page gates, not the skill and agent gates.
- A fix commit after a green pre-flight checks only what the fix changed.

**Negative:**

- A wrong glob in `inputs` hides a finding locally. The pull request build still finds it, but later.

**Neutral:**

- The receipt of a scoped pre-flight covers the tree it ran on, as before.

## Alternatives considered

1. **Scope the pull request build too.** Rejected, because the build is the gate of record and must
   check everything before a merge.
2. **Let each gate decide by itself whether the change concerns it.** Rejected, because each gate would
   start, read the change and stop. That costs the time this decision saves, and each gate would read
   the change in its own way.

## Verification

- `core/tests/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.Tests.ps1`, tests tagged `#48`. A gate
  whose inputs are not touched shows `NOT TOUCHED`. Every gate runs on a delete, a change to
  `aisdlc.json`, an unreadable change, `-All` and GitHub Actions.
- `Invoke-Preflight.Tests.ps1` and `PreflightReceipt.Tests.ps1`: `commands.testChanged`, the `N/A` row,
  and `Find-PreflightBase` with a stale receipt.
- `ChangedFiles.Tests.ps1`: the path globs and `AISDLC_CHANGE_BASE`.

## References

- Issue #48, the story, which ports this from the upstream copy of the framework.
- git merge-base and git diff, which `ChangedFiles.psm1` uses to list the change: https://git-scm.com/docs/git-merge-base

## Related

- [ADR 0019](0019-a-gate-reports-pass-finding-could-not-check-or-not-applicable.md) - the exit codes, and why the pull request build is the gate of record.
- [ADR index](README.md) - the list of decisions in this repository.
- [core](../packages/core.md) - the package that holds the runner and the pre-flight.
