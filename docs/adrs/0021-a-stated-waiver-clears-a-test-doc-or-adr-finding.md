---
story: "#60"
phase: governance
step: write-adr
intent:
  assumption: "an agent can state in a commit why a test, a doc or an ADR is not needed, and a reviewer can judge that reason"
  decision-drivers:
    - "a correct change, such as a rename, should not need a person to push it"
    - "every waiver must stay visible, so nothing passes in silence"
    - "a gate can check the shape of a reason, but not whether it is true"
relates:
  completeness: core/.apm/skills/ai-sdlc-gates/scripts/Check-ChangeCompleteness.ps1
  contract: packs/github-issues/.apm/skills/check-pr-contract/scripts/Check-PrStoryContract.ps1
  wrap-up: core/.apm/skills/wrap-up/SKILL.md
  conventions: core/.apm/skills/adr-conventions/SKILL.md
because:
  completeness: "reads the No-Test and No-Docs trailers and clears a finding for the files of that commit"
  contract: "reads the No-ADR trailer and passes a data-model change with no ADR"
  wrap-up: "is the only step that writes a trailer, after a reviewer agent agrees"
  conventions: "holds the three tests that a No-ADR reason refers to"
---

# ADR 0021: A stated waiver clears a test, doc or ADR finding

**Status:** Accepted
**Date:** 2026-11-26
**Supersedes:** none
**Superseded by:** none

## Context

The completeness check refused an agent push when code changed but no test or doc moved. It did so
also when none was needed, such as for a rename. The pull request contract check failed a data-model change with
no ADR, also when the decision did not pass the three tests of `adr-conventions` (#65). In both cases a
person had to step in, and the reason was lost in the chat (#60).

## Decision

1. **A commit trailer states a waiver.** `No-Test: <reason>: <why>` and `No-Docs: <reason>: <why>`
   take a reason from a closed list: `no-behaviour-change` (both), `existing-tests-cover-it` (No-Test
   only) and `no-doc-reader-affected` (No-Docs only). `No-ADR: <why>` takes a free reason. git's own
   trailer parser reads them.
2. **A waiver clears a finding only for the files of its own commit.** A file is waived only when every
   commit that changes it carries a valid trailer of that kind. A later commit without one makes it a
   finding again.
3. **Nothing passes in silence.** The check prints each waiver it used, each one it did not use and why,
   and each one that cleared nothing. An unknown reason, an empty why or a control character clears
   nothing.
4. **Only `wrap-up` writes a trailer**, after the reviewer agent agrees with the reason: `test-analyzer`
   for No-Test, `docs-reviewer` for No-Docs, and `architect` for No-ADR.
5. **The person who reviews the pull request reads every trailer.** The gate checks only the shape of a
   reason; the person judges whether it is true.

## Consequences

**Positive:**

- A rename or a refactor goes out without a person, and its reason stays in the history.

**Negative:**

- An agent can write a weak reason that the reviewer agent accepts. The person who reviews the pull
  request is the last guard.

**Neutral:**

- Constitution clause C01 names the No-ADR waiver in its enforcement line.

## Alternatives considered

1. **A label on the pull request.** Rejected, because a label says nothing about which files or which
   commit the waiver covers, and the local push hook cannot read it.
2. **A free-text reason for No-Test and No-Docs.** Rejected, because a closed list makes a typo or a
   vague reason clear nothing, and the reviewer reads a reason it knows.

## Verification

- `core/tests/skills/ai-sdlc-gates/scripts/Check-ChangeCompleteness.Tests.ps1`, tests tagged `#60`.
- The test of `Check-PrStoryContract.ps1` in the github-issues pack, tests tagged `#60`.
- Not covered by a test: that `wrap-up` asks the reviewer agent first. A person checks it on a real run.

## References

- Issue #60, the story, which ports this from the upstream copy of the framework.
- git interpret-trailers and the `%(trailers)` format: https://git-scm.com/docs/git-interpret-trailers

## Related

- [ADR 0019](0019-a-gate-reports-pass-finding-could-not-check-or-not-applicable.md) - the exit codes the checks report with.
- [ADR index](README.md) - the list of decisions in this repository.
- [core](../packages/core.md) - the package that holds the completeness check.
