---
story: "#46"
phase: governance
step: write-adr
intent:
  assumption: "a pull request build that shows green means every blocking gate really checked its rule"
  decision-drivers:
    - "a gate that could not check has proved nothing, so a green build must not hide it"
    - "a gate with nothing to check is not a warning and should not look like one"
    - "the runner, the CI wrapper and the agent push hook must read an exit code the same way"
relates:
  runner: core/.apm/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1
  wrapper: core/.apm/skills/ai-sdlc-gates/scripts/Invoke-Gate.ps1
  annotation: core/.apm/skills/ai-sdlc-gates/scripts/GateAnnotation.psm1
  hook: core/.apm/skills/ai-sdlc-hooks/scripts/Deny-IncompletePush.ps1
  contract-test: core/tests/skills/ai-sdlc-gates/scripts/GateContract.Tests.ps1
  skill: core/.apm/skills/ai-sdlc-gates/SKILL.md
because:
  runner: "reads the exit code of every gate in a local run, the pre-push hook and the pull request action"
  wrapper: "reads the exit code of one gate in a workflow step"
  annotation: "turns the exit code into the workflow command and the result that both share"
  hook: "reads the exit code of the completeness gate before an agent push"
  contract-test: "runs every gate in an empty repository and checks its exit code"
  skill: "tells a person and an agent what each exit code means"
---

# ADR 0019: A gate reports pass, finding, could not check or not applicable

**Status:** Accepted
**Date:** 2026-11-26
**Supersedes:** point 1 of [ADR 0005](0005-the-gate-contract.md)
**Superseded by:** none

## Context

A gate is a script that checks one rule and reports through its exit code. Point 1 of
[ADR 0005](0005-the-gate-contract.md) gave the contract three values: 0 pass, 1 finding, 2 could not
check. Exit 2 was always a warning and never blocked, in a local run and in the pull request build.

That contract had three faults (#46):

- A blocking gate that could not reach its source left the pull request build green. A failed
  gitleaks download or a missing setting looked like a pass to anyone who did not read the warnings.
- There was no value for "nothing to check here". Gates printed OK and exited 0, or crashed, when
  there was nothing to check, for example a pull request rule on a push, or a skill gate in a
  repository with no skills.
- `Deny-IncompletePush.ps1` read any exit code other than 0 as "the change is unfinished".

## Decision

1. **A gate exits with one of four codes.**
   - `0` pass: the gate checked, and found nothing.
   - `1` finding: the gate checked, and found a break of its rule. Any other code counts as 1.
   - `2` could not check: a tool, a setting, the git history or an input it needs is missing or
     broken. It prints why, and a `FIX:` line that names what to set up.
   - `3` not applicable: there is nothing in this repository or context for the gate to check. It
     prints why in one plain line.
2. **Exit 2 of a Blocking gate fails the pull request build.** `Invoke-LocalGates.ps1` and
   `Invoke-Gate.ps1` both apply this when `GITHUB_ACTIONS` is `true`. In a local run and in the
   pre-push hook exit 2 stays a warning, because a person cannot always set up every service on
   their own machine. Exit 2 of an Advisory gate is a warning everywhere.
3. **Exit 3 never blocks and writes no annotation.** The run summary shows the gate as `N/A`.
4. **A crashed gate keeps its mode.** A crashed Blocking gate fails the run; a crashed Advisory gate
   gives a warning.
5. **The agent push hook denies only on exit 1.** On exit 2 or 3 it goes on to the pre-flight receipt
   check. When the push goes through after exit 2, it shows a note. After exit 3 it stays silent,
   like exit 0.
6. **A contract test holds every gate to this.** `GateContract.Tests.ps1` runs each gate of the core,
   the packs and `repoGates` in an empty repository. The exit code must be in a set listed per gate,
   a gate that exits 2 prints a `FIX:` line, and no gate prints a workflow command itself.

The rest of ADR 0005 stays: the `FIX:` line, the located findings, the change rules, the pointer
gate and the advisory-first path.

## Consequences

**Positive:**

- A green pull request build means every blocking gate really checked.
- A gate with nothing to check shows `N/A` instead of a pass or a warning that nobody can act on.
- The runner, the CI wrapper and the push hook share one reading of an exit code.

**Negative:**

- A consumer whose pull request workflow lacks what a blocking gate needs goes red after the update,
  for example a .NET repository without `paths.sourceRoot`. The CHANGELOG lists these as consumer
  steps.
- An outage of an outside service that a blocking gate reads, such as the gitleaks download, now
  blocks every pull request until it is back. A person can rerun the job when the service returns.

**Neutral:**

- A local run still passes with a gate that could not check, as before. The pull request build is the
  place that blocks.

## Alternatives considered

1. **Keep exit 2 as a warning in CI.** Rejected, because a build stayed green while a blocking rule was
   never checked, which is the fault this ADR fixes.
2. **Exit 0 with an OK line for "nothing to check".** Rejected, because the summary then claims a check
   that did not happen, and the contract test cannot tell the two apart.
3. **Block on exit 2 locally too.** Rejected, because a person without a token could then not push at
   all. The pre-push hook is a fast check, and the pull request build is the gate of record.

## Verification

- `core/tests/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.Tests.ps1`, `Invoke-Gate.Tests.ps1` and
  `GateAnnotation.Tests.ps1` check each exit code in each mode, in a local run and with
  `GITHUB_ACTIONS` set (tests tagged `#46`).
- `core/tests/skills/ai-sdlc-hooks/scripts/Deny-IncompletePush.Tests.ps1` checks that exit 2 and 3 do
  not deny a push, and that only exit 2 shows a note.
- `core/tests/skills/ai-sdlc-gates/scripts/GateContract.Tests.ps1` runs every gate in the empty
  repository.

## References

- Issue #46, the story, which ports this contract from the upstream copy of the framework.
- GitHub workflow commands, `error` and `warning`: https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands
- Exit codes and job results in GitHub Actions: https://docs.github.com/en/actions/how-tos/create-and-publish-actions/set-exit-codes

## Related

- [ADR 0005](0005-the-gate-contract.md) - the rest of the gate contract, which stays.
- [ADR 0012](0012-ci-is-a-composite-action-inside-the-installed-core.md) - the action that runs the gates in a pull request.
- [ADR index](README.md) - the list of decisions in this repository.
- [core](../packages/core.md) - the package that holds the runner and the gates of the core.
