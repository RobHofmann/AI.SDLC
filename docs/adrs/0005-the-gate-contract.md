---
story: "#1"
phase: governance
step: write-adr
intent:
  assumption: "a gate that reports pass, violation or could-not-check through its exit code, with a FIX line and located findings, is enough for a person and an agent to act without opening a log"
  decision-drivers:
    - "a gate that blocks on a broken credential blocks every change until someone with admin rights acts"
    - "a gate that passes on what it could not check stops checking, and nobody notices"
    - "the check summary and the pull request show the annotation, not the log"
    - "the rules that get broken most are about the change, not about any one file"
relates:
  gate: core/.apm/skills/ai-sdlc-gates/scripts/Invoke-Gate.ps1
  annotation: core/.apm/skills/ai-sdlc-gates/scripts/GateAnnotation.psm1
  runner: core/.apm/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1
  pointers: core/.apm/skills/ai-sdlc-gates/scripts/Check-DocSectionRefs.ps1
  pattern: core/.apm/skills/ai-sdlc-handbook/references/pattern.md
because:
  gate: "the wrapper that turns an exit code into a result and an annotation"
  annotation: "the module that writes the GitHub workflow commands"
  runner: "the runner that gives the same result locally, in the push hook and in CI"
  pointers: "the gate that checks a pointer names a section that is there"
  pattern: "the advisory-then-blocking path every gate follows"
---

# ADR 0005: The gate contract

**Status:** Accepted
**Date:** 2026-10-24
**Supersedes:** none
**Superseded by:** none

## Context

A gate is a PowerShell script that checks one rule. Gates run in three places: the pre-push hook, the
pre-flight and CI. Four lessons shape how they report.

- **Two answers are not enough.** A gate that cannot reach what it checks, such as an API behind a
  broken credential, has no honest pass or fail. Fail closed blocks every change until someone with
  admin rights acts. Pass hides that nothing was checked.
- **The annotation is what people read.** The check summary and the pull request show the annotation,
  not the log. An annotation that says "see above" sends the reader into a long log.
- **Some rules are about the change.** A story key in the pull request, tests that moved with the code,
  a description that was not cut: no single file shows these.
- **A pointer can lie.** A link check stops at the file name. A sentence like "see the X section of
  `page.md`" survives the section being renamed or deleted.

## Decision

**1. A gate reports three results through its exit code.**

| Exit | Meaning | What the run does |
|---|---|---|
| 0 | Checked, nothing found | pass |
| 1 | Checked, and found a violation | an Advisory gate warns, a Blocking gate fails |
| 2 | Could not check at all | always a warning that starts "COULD NOT BE CHECKED", never a pass, never a block |

`Invoke-Gate.ps1` carries this for every gate. `Invoke-LocalGates.ps1` prints exit 2 as UNVERIFIED and
does not count it as a blocking failure. A gate splits its cases by who can fix them. What the author
can fix is exit 1, and what only an admin can fix is exit 2.

**2. Every gate prints one `FIX:` line.** The gate owns the rule, so it owns the advice. A local run
shows the same advice as CI. `SharedWiring.Tests.ps1` fails a `Check-*.ps1` that has no `FIX:` line.

**3. An annotation names the file, the line and the rule.** A finding is a line with two spaces in front,
read as `path:line  text` or `path : text`. On GitHub Actions, `GateAnnotation.psm1` writes
`::error file=<path>,line=<n>,title=<gate>::<message>`, or `::warning` for an Advisory gate. It raises at
most five findings per gate and says how many more are in the log. The summary carries the rule after
"Why:" and the `FIX:` text after "Fix:". The wrapper never invents a path it did not read.

**4. Some gates read the diff, not the tree.** They take `CHANGED_FILES` and the pull request fields from
the CI environment ([ADR 0012](0012-ci-is-a-composite-action-inside-the-installed-core.md)).
`Check-ChangeCompleteness.ps1` asks whether tests and docs moved with the code; it is Advisory.
`Check-PrHygiene.ps1` asks whether the pull request names a story and whether its description is real
free text, not the title again and not cut short. It is Blocking.

**5. A pointer must resolve.** `Check-DocSectionRefs.ps1` blocks a pointer at a section that is not there.
It reads three shapes: a named section, a quoted section, and a link anchor. It also reads PowerShell
help blocks and workflow YAML, and fails when a script names a decision record that does not exist.

**6. A gate starts Advisory and turns Blocking once it is clean.** A gate that lands with zero findings
may start Blocking. One that would fail on old findings starts Advisory, because a gate that turned
blocking failed consumers on findings they did not cause.

## Consequences

**Positive:**

- A run that proved nothing never reads as a run that proved something.
- A broken credential no longer blocks every change. It says "could not be checked" on every run until
  someone fixes it.
- A reader sees the file and the line on the pull request, next to the code.
- A reporting rule lives in one wrapper, so a new gate gets it for free.

**Negative:**

- While a credential is broken, the half of a gate that needs it is not enforced. The warning on every
  run is the guard against people learning to ignore it.
- The `FIX:` sentence is text a person wrote, so it can go stale when the rule moves.
- The pointer gate checks that words match, not that the target says what the pointer claims.
- The completeness gate will report a one-file fix that has a test and no doc change. That is why it
  stays Advisory.

**Neutral:**

- The cap of five findings truncates a long list in the summary. The full list stays in the log.

## Alternatives considered

1. **Fail closed on anything a gate cannot verify.** Rejected because one secret that runs out then blocks
   every change, and nobody on those changes can fix it.
2. **Keep a gate Advisory as a whole when part of it needs a credential.** Rejected because it also
   stops enforcing the half that needs nothing but the repository.
3. **Let every gate write its own annotations.** Rejected because it is the same code in every gate, and
   a new gate would have to remember it.
4. **Raise every finding with no cap.** Rejected because a summary with hundreds of findings is as
   unreadable as one with none.
5. **Keep the change rules as text in `AGENTS.md`.** Rejected because rules in that file were broken
   anyway ([ADR 0007](0007-agents-md-has-a-size-limit.md)).
6. **Ask that every section reference is a link with an anchor.** Rejected because it forces a rewrite
   of every page, and a gate should follow the way people write.

## Verification

- `Invoke-Gate.Tests.ps1` covers exit 2 in both modes, the located findings, the cap, the rule and the
  `FIX:` line in the annotation.
- `GateAnnotation.Tests.ps1` covers the GitHub workflow command format.
- `SharedWiring.Tests.ps1` fails a gate without a `FIX:` line.
- `Check-PrHygiene.Tests.ps1`, `Check-ChangeCompleteness.Tests.ps1` and `Check-DocSectionRefs.Tests.ps1`
  cover each rule.
- Not covered by a test: how GitHub renders an annotation on the pull request. Check it on a real run.

## References

- `core/.apm/skills/ai-sdlc-gates/scripts/Invoke-Gate.ps1` and `GateAnnotation.psm1` - the contract and the writer.
- `core/.apm/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1` - the runner.
- `core/.apm/skills/ai-sdlc-gates/gates.json` - the core gates and their mode.
- [Skill patterns](../../core/.apm/skills/ai-sdlc-handbook/references/pattern.md) - the advisory-first path.
- GitHub workflow commands, `error` and `warning`: https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands
- Exit codes and job results in GitHub Actions: https://docs.github.com/en/actions/how-tos/create-and-publish-actions/set-exit-codes

## Related

- [ADR 0006](0006-hooks-enforce-what-must-happen-every-time.md) - the hooks that run the same gates earlier.
- [ADR 0012](0012-ci-is-a-composite-action-inside-the-installed-core.md) - the CI that sets the change environment.
- [ADR index](README.md) - the list of decisions in this repository.
