---
name: run-preflight
kind: workflow
phase: cross-cutting
persona: Developer
user-invocable: false
description: >
  Run the whole pull-request workflow locally before pushing: the deterministic gates, the
  SonarCloud analyzer rules, the tests and the coverage ratchet, and gitleaks. So failures are
  caught in seconds against your working diff instead of after a slow CI round-trip. It loops the
  checks to green and surfaces what needs a human decision; it never suppresses a finding and
  never pushes. Use when the user says "run the pre-flight", "check everything before I push",
  "run the PR checks locally", "what will the PR build flag". It is the last step of wrap-up, on the
  commit wrap-up makes; a build loop does not run it again before the push.
  For the deterministic gates alone, run Invoke-LocalGates.ps1 directly. Do NOT use to work
  findings on an already-open PR's threads (fix-pr-feedback). Do NOT use to mine a finished
  review for process learnings (capture-learning) or to author the change (implement).
---

# Run pre-flight

Owned by the **Developer**. It is an internal step: `wrap-up` calls it on the commit it makes. A build loop
runs the tests and `Invoke-LocalGates.ps1` while it checks, never this skill. A person types
`/wrap-up`, not this skill.

The pull-request workflow (`paths.codeAnalysisPipeline` in aisdlc.json) runs deterministic gates,
the SonarCloud analyzer rules, the tests and coverage, and gitleaks. Without a pre-flight, we push and
wait minutes for the verdict. Almost all of it can run locally first. This skill runs everything that can run locally and loops
it to green, so the CI run confirms rather than discovers.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).

## Workflow

1. **Run the deterministic and tool checks, loop to green.** Run `pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-Preflight.ps1`
   (`-SkipTests` for speed; `-IncludeSonar` to also run the SonarCloud upload-and-wait gate with a token). It
   runs:
   - `Invoke-LocalGates.ps1`: the gate set. It leaves out the self-tests of the shared gate scripts.
     No pull request job of a consumer runs them, and AI.SDLC tests them before each release.
     The tests of a repository gate run through a repository gate with `Invoke-PesterGate.ps1`, or
     through `commands.test`, as `add-gate` says;
   - the test command `commands.test` of aisdlc.json, when it is set, from the repository root. It starts
     beside the gates, and its output follows theirs. It is the one full test run of a wrap-up, and `-SkipTests` leaves it out. When a pack pre-flight runs the
     tests itself, as the dotnet pack does, `commands.test` does not run, so the tests do not run twice;
   - the `preflight` step of each installed pack. For the dotnet pack that is `dotnet build`, then the tests
     and coverage. SonarAnalyzer mirrors the SonarCloud rules, so the S-rule findings appear as build
     warnings on changed files. For the bicep pack it is `bicep build` of every template;
   - gitleaks over the branch's commits, and the security scanners when available. A gitleaks finding
     that `gitleaks-baseline.json` does not hold is a `FAIL` row, so it stops the receipt.

   Any `FAIL` is yours to fix; fix it and re-run until the deterministic rows are green. Read the `REVIEW` rows and the
   `NEEDS-*` / `OPT-IN` rows the script prints (the parts that need a token or are not offline; see Coverage).

2. **Run the issue contract check, when the github-issues pack is installed.** The script fails a branch whose name has no story key. When
   `gh` is not signed in, it reports `NEEDS-GH`. Then run `check-pr-contract` here, which reads the issue to
   confirm the branch's story is dev-active and that a data-model change carries an ADR. This is the agent-side
   half of the pre-flight that `Invoke-Preflight.ps1` cannot do without `gh`.

3. **Triage the `REVIEW` rows, and never silence one.** A `REVIEW` row is a finding that needs a decision
   rather than a rerun. Examples are an analyzer warning on a changed file or a scanner finding.
   A gitleaks hit is a `FAIL` row, not a `REVIEW` row: see the failure mode on a real secret. Triage
   each as `fix-pr-feedback` does: **fix**, **decline** (record why), or **false positive** (record
   why). Every decline and false positive goes into the evidence record, so the person sees it in
   the pull request at Checkpoint Bravo. Suppressing a finding just to reach green removes the human decision the framework needs (C09).

4. **Hand back; do not push.** First the checks are green, the `REVIEW` rows are triaged, and the fixes
   are made and re-checked. Then report the result to the calling skill or the person. A green full run on a
   clean, committed tree writes the receipt `temp/preflight/<tree>.json`. The push hook
   `Deny-IncompletePush.ps1` first runs the change-completeness check. Then it refuses a push whose commit
   has no receipt, so run this on the commit you are about to push, not before it. A `-SkipTests` run writes no receipt. The calling loop then pushes
   and opens or updates the pull request on its own
   ([orchestration.md](/.claude/skills/ai-sdlc-handbook/references/orchestration.md)); this skill never pushes.

## Coverage: what this reproduces, and what it cannot

`Invoke-Preflight.ps1` tries every shell-runnable step and reports each. Some parts are not shell- or
offline-reproducible by nature: the skill handles them, or the script reports what they need.

- **Gates** - fully local (`Invoke-LocalGates.ps1`, the same scripts CI runs).
- **Tests of the repository** - `commands.test`, when aisdlc.json sets it and no pack pre-flight runs the
  tests itself. A FAIL row stops the receipt.
- **SonarCloud rule findings** (dotnet pack) - local via `dotnet build` (`SonarAnalyzer.CSharp` is pinned and mirrors the
  SonarCloud rules).
- **SonarCloud server quality gate** (dotnet pack only; a repository without it has no SonarCloud row) - computed on SonarCloud after upload; there is no offline gate. Opt in
  with `-IncludeSonar` and `SONAR_TOKEN`: the script runs the scanner, uploads, and waits for the server
  verdict. Keep it opt-in; every run posts a real analysis to the SaaS.
- **Tests + coverage (C04)** (dotnet pack) - run by default (`-SkipTests` to skip). The coverage rules
  are in the `test-first-dotnet` skill: the ratchet against the baseline (`paths.coverageBaseline` in
  aisdlc.json), the run settings and the 80% on new code in SonarCloud. Load it to read a coverage result.
  No coverage file, or no `dotnet-coverage` tool, is a `FAIL` row that names the fix.
- **Gitleaks** - local with the repo baseline, scoped to the branch's commits. A finding outside the
  baseline is a `FAIL` row, as it fails the secret scan of the shared composite action.
- **Trivy / Checkov / Semgrep** - tried when the tool (or Docker for the container forms) is available,
  else reported with how to enable. No workflow that the AI-SDLC ships runs them, so the pre-flight is the
  only place they run. The local configs are best-effort.
- **IssueContract** - the script runs `Check-PrStoryContract.ps1` when `gh` is installed and signed in
  (`gh auth status`). When it is not, the agent runs `check-pr-contract` as part of the pre-flight. A
  branch with no story key is a FAIL row, with or without `gh`, because the pre-flight has no pull request title or
  description. `wrap-up` step 0 refuses such a branch before the pre-flight, so rename the branch
  (`git branch -m <number>-<topic>`, such as `42-short-name`).
- **Human review** - not reproducible and not tried. The PR is where a reviewer reads the change. An
  automatic AI review does not sit here, because a person at Checkpoint Bravo reads the change.

## Guardrails

- **Loop the checks; triage what needs a decision.** The gates, the build and the tests converge and should be
  green before push. A `REVIEW` row does not converge on its own: its stop condition is human triage.
- **Never suppress a finding, never push.** A decline or a false positive is judged by a person in the
  pull request at Checkpoint Bravo; this skill surfaces and sequences. Record every decline and false positive in the evidence
  record so it is not re-litigated.

## Failure modes

- **A `REVIEW` row is treated like a failing check and "fixed" to make it go away** -> it does not settle on its own. Its stop condition is human triage. Silencing it is a decision made by accident.
- **Green here, but the server-side quality gate still fails** -> the SonarCloud gate runs on the server, and the pre-flight checks it only with `-IncludeSonar`. Report what this covers, not what it means.
- **The loop runs on a dirty tree that includes unrelated work** -> the findings then belong to someone else's change. Check what is staged before believing the output.
- **A finding is suppressed to reach green** -> never. A decline or a false positive goes into the evidence record for the person at Checkpoint Bravo; this skill surfaces and sequences.
- **A decline is made and not recorded** -> it comes back next run, and the next reader cannot tell it was already considered.
- **The loop converges and the push happens from here** -> this skill does not push. Green is the precondition for the push, not the act.
- **A real secret is found by gitleaks** -> stop and rotate, following the incident process. Never baseline it to reach green.

## Observable signal

**Positive:** the PR build reports nothing the author had not already seen. The first CI result confirms rather than surprises, and the push-and-wait round trip disappears from the change.

**Audit trail:** the converged run plus the triage decisions on the `REVIEW` rows is the receipt for what was known before the push. It is what separates a finding that CI caught from one the author chose to accept.

**Drift signal:** if PR builds keep surfacing findings this loop should have caught, the local run is being skipped or scoped to the wrong diff. If the same `REVIEW` rows recur across changes, the declines are not being recorded anywhere lasting.

## Next steps

- `check-pr-contract` (Lead) - the one PR check that reads the issue; run it for the story-and-ADR contract.
- `/fix-pr-feedback` (Developer) - after the PR is open, work the real CI threads with the same triage.
- `/capture-learning` (Lead) - turn the recurring corrections this surfaces into conventions, gates, or guardrails.
- `/implement` (Developer) - if the findings need non-trivial code changes, author them there.
