---
name: add-gate
kind: workflow
phase: cross-cutting
persona: Lead
description: >
  Turn a plain-English rule into a new deterministic gate: the validator, its Pester test and its
  entry in gates.json or repoGates, which the shared composite action also runs. Then show the diff and how to trip it. It
  hands the draft back for human review; a standalone run then goes to a pull request. Use when the intent is to
  ENFORCE a rule mechanically: "add a gate for this", "make this a CI check", "scaffold a
  validator that X", "enforce X on every PR", "turn this convention into a gate", "we keep getting
  X wrong, gate it", or as the home for a learning that capture-learning classified as a new
  gate. Do NOT use to RUN the existing gates (Invoke-LocalGates.ps1, or run-preflight for the
  whole PR check set). Do NOT use to author an architecture decision (write-adr) or to evaluate a
  skill's quality (test-skills).
---

# Add a gate

Owned by the **Lead** persona (gates and contract integrity). Called as `/add-gate`. It is a
producing skill: it drafts a gate in the shape the existing gates follow and returns it for human
review. It never commits or merges the gate itself (org policy + the constitution: draft, never publish).
See [pattern.md](/.claude/skills/ai-sdlc-handbook/references/pattern.md) for the producing shape and
the advisory-then-blocking path.

A rule that lives only in text drifts; a rule with a gate holds. This skill makes adding a gate cheap,
so a recurring mistake becomes a check rather than a hope. **A gate that can't check the contract is
not a gate.** A gate that cannot reach what it needs to check fails closed: it exits 2 and warns,
and never passes silently. A gate that only sometimes runs is documented as such.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).

## Step 1: classify the rule

Decide what the rule can really be checked against, because that decides where the gate can run:

- **Deterministic / repo-local** (a file or content pattern, a frontmatter rule, a naming or structure
  check): a PowerShell `Check-*.ps1` that reads the working tree. Runs both locally and in CI. This is the
  default and the cheapest.
- **Substrate-dependent** (needs GitHub Issues, e.g. "the PR's story is dev-active", "a data-model
  change links an ADR"). The **local/interactive** form runs in-session with `gh`, read-only, and fails
  closed. The **CI** form reads the issue with `gh` and the `GH_TOKEN` the composite action sets from
  `github.token`. When the issue lives in another repository that this token cannot read, scaffold the
  local form. Record the CI form as a documented TODO rather than a silently-absent gate.

State which kind it is before scaffolding; it changes what you write.

Then decide where the gate lives:

- **Shared:** the rule holds in every repository that installs a package. The gate goes into the
  `scripts/` folder of the skill that owns the rule in AI.SDLC. It reaches the repository through a
  pull request on AI.SDLC and a new release. Never edit an installed file under `.claude/`.
- **Repository only:** the rule is about this repository. The gate goes in the tools folder
  (`paths.toolsFolder` in aisdlc.json) and is listed in `repoGates` of aisdlc.json.

The [layout page](/.claude/skills/ai-sdlc-handbook/references/layout.md) says how to try a shared change against a local clone.

## Step 2: scaffold the validator

Write `Check-<Name>.ps1` in the place Step 1 chose: the `scripts/` folder of the owning skill in
AI.SDLC, or the tools folder. Use the shape every existing gate follows. Read `Check-DocEmDashes.ps1`
or `Check-ArtifactGraph.ps1` as the model, and do not invent a new shape:

- `#Requires -Version 7`, and a comment-based `.SYNOPSIS` / `.DESCRIPTION` stating the rule and that
  it fails closed.
- `param([string]$RepoRoot)` that defaults through `Find-AiSdlcRepoRoot` in `AiSdlcConfig.psm1`. Add a
  `[switch]$Strict` if the rule has an advisory and a stricter mode.
- Use the three-value exit contract. Exit 0 when the gate checked and found nothing, and 1 when it
  checked and found a violation. Exit 2 when it COULD NOT check (a missing credential, an unreachable
  service). Exit 2 is never a pass and never blocks, because nobody on the pull request can fix it by
  editing code.
- Collect violations, and print each with the file and the rule. **Exit non-zero on any violation,
  zero on none** (loud on failure, silent on success). For a substrate gate, an unreachable substrate
  exits 2: a warning, never a pass.
- **Print each finding with two spaces in front, as `path:line  what is wrong`.** `Invoke-Gate.ps1`
  reads that shape back and raises up to five findings as their own GitHub Actions annotations
  (`::error file=<path>,line=<n>::`). Each one has its file and line, so it shows in the run summary
  and against the file on the pull request.
  A finding printed in another shape still reaches the log, but the reader has to go and find it.
- **Print one line that starts with `FIX: `, saying what the reader should do.** The wrapper lifts it
  into the annotation as "Fix: ...", and a local run shows the same sentence. Write it as an
  instruction, not a restatement of the rule: "Replace each em-dash with a spaced hyphen", not
  "em-dashes are not allowed". A shared gate with no `FIX:` line fails the wiring test
  `SharedWiring.Tests.ps1` in the ai-sdlc-gates skill. A repository gate has no such test, so add a
  case to its own `Check-<Name>.Tests.ps1` that checks the `FIX:` line (Step 3). Use it on the exit-2 path too, where the fix
  belongs to whoever owns the credential or the service.
- **Read the narrowest scope the rule is about.** A rule about one section reads that section only,
  from its heading to the next heading of the same level. A search over the whole file can pass an
  empty section. That happens when the text it wants sits elsewhere on the page, for example under
  References.
  The gate then reports green while the rule is broken, which is worse than no gate. The same holds
  for frontmatter against body, and for one block against a whole file.
- No em-dashes. A line number in a finding is fine; clause C02 is about documentation.

## Step 3: scaffold the Pester test

Write `Check-<Name>.Tests.ps1` beside the gate (Pester v5). No registration is needed. For a shared
gate, the AI.SDLC pull request workflow runs it with every other test. For a repository gate, add a repository gate
that runs `Invoke-PesterGate.ps1` over the folder of the gate, or put the folder under `commands.test`.
Then every gate run, the pre-flight and the shared composite action run the test. The composite action and the
pre-flight do not run `Invoke-LocalGates.ps1 -IncludeToolTests`.
Cover at least these cases:

- a clean fixture passes (exit 0);
- a breaking fixture fails (exit non-zero and names the file at fault);
- for a substrate gate, an unreachable-substrate case exits 2;
- the output has a `FIX:` line.

When the rule is about one part of a file, add the right-text-wrong-place fixture. It holds the text
the rule wants, placed outside the part it is about. That case must fail, and it is the one a
file-wide search lets through.

## Step 4: register the gate

- **Local aggregator:** for a shared gate, add one entry to the `gates.json` of the skill that owns
  it. For a repository gate, add the same entry to `repoGates` in aisdlc.json, with the script path
  from the repository root. The runner `.claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1`
  reads both:
  `{ "name": "<clause/area> <what>", "script": "scripts/Check-<Name>.ps1", "clause": "<clause>", "mode": "Advisory" }`.
  When no clause covers the gate, name its rule family, as the core gates do with `AI-SDLC` and
  `house-style`. Or leave `clause` out, and the runner then shows the package name.
  New gates enter **Advisory** so they do not block while the codebase clears any old debt. Promote
  them to `Blocking` once they are green (the standard path). A pure contract-verifying gate with no
  backlog of violations may start `Blocking`.
- **Workflow:** nothing to add. The shared composite action (`ai-sdlc-gates/assets/actions/ai-sdlc-pr`) runs every gate in
  `gates.json` and `repoGates`, so the entry above is the whole registration.
- **Never a workflow step.** Do not add the gate as a step of a workflow, in `pre-gate-command`, or as a
  call to `Invoke-Gate.ps1`. A step runs in CI only, so a local run, the pre-flight and the pre-push hook
  miss it. When the gate needs other arguments, such as a wider `Path`, give its entry `args`; a second
  entry with other `args` is fine.

## Step 5: show the diff and how to trip it

Return the diff of all changed files: the new `Check-*.ps1`, the new `*.Tests.ps1`, and the
`gates.json` or `repoGates` entry. Tell the user exactly how to **trip it on purpose then satisfy it**, so
they can confirm it works before relying on it. Run standalone, wait for the person to agree to the
diff, then go to step 6. Inside a build loop, `wrap-up` commits a repository gate with the rest of the
change, and the loop pushes it. A person then reviews the gate in the pull request at Checkpoint Bravo. A shared
gate goes to AI.SDLC, as step 6 says.

## Step 6: hand the work to a pull request (standalone run only)

A standalone run is one a person starts directly, not from `wrap-up`, a build loop or another skill.
For a repository gate, the work goes on a branch named with a story key. When you are not on a branch
named with a story key, create it from the current state (`git switch -c <number>-<topic>`); the work
moves with it. When you are on one, stay on it. Then `/wrap-up` commits it and runs the pre-flight.
Push the branch and open or update the pull request through the pull request skill of the installed
pack, as `implement` does. In `github-pull-requests`, `New-PullRequest.ps1` opens a new one and `Update-PullRequest.ps1` updates an open one. Called from
`wrap-up`, a build loop or another skill, skip this step: write the files only, and `wrap-up` commits
them. So `wrap-up` never runs itself a second time.

A shared gate is not committed in this repository, and `wrap-up` does not handle it, standalone or
not. It lives in the AI.SDLC clone. Follow "How a change moves" in the AGENTS.md of that clone, and
the section [Developing against a local clone](/.claude/skills/ai-sdlc-handbook/references/layout.md#developing-against-a-local-clone)
of the layout page. Then open the pull request on AI.SDLC.

## Failure modes

- **Rule cannot be checked deterministically and no substrate access exists in CI** -> say so.
  Scaffold the local form and document the CI form as a TODO. Do not ship a gate that silently never runs.
- **Rule is vague** ("code should be clean") -> push back; a gate needs a checkable predicate. Help sharpen
  the rule into one, or decline rather than scaffold a gate that cannot fail honestly.
- **The gate searches the whole file for a rule about one part of it** -> an empty section passes on text that sits elsewhere. The gate then reports the set as healthy. Scope the read to that part, and pin it with the right-text-wrong-place fixture.
- **A gate already covers this** -> point at it rather than adding a near-duplicate; extend the existing one
  if the rule is a refinement.
- **Asked to enable it blocking immediately** -> return the diff for review. Enabling it and
  promoting it to blocking is the human's call, after it is seen green.

## Guardrails

- **Draft, never publish.** Return the scaffolded files and the diff for review first. `wrap-up`
  commits a repository gate; the calling loop, or step 6 after a standalone run, pushes and opens or updates the
  pull request. A shared gate goes through the steps of the AI.SDLC clone instead (step 6).
  Nothing merges it; a person does that after the review.
- **Fail closed.** A contract-verifying gate that cannot reach what it checks exits 2; it never passes blind.
- **Advisory first, then blocking.** New gates enter advisory and are promoted once green, unless they are
  pure contract checks with no existing violations.
- **An advisory gate's failure paths stay advisory.** While a gate is advisory, every way it can fail
  must route through `Invoke-Gate` or carry `continue-on-error: true`. That includes a preflight step
  that fetches or computes the gate's inputs. Then a short-lived infrastructure failure cannot hard-fail a
  job that is meant to be advisory. A raw `exit 1` in an inline preflight before the `Invoke-Gate`
  wrapper goes around the path. Keep the hard fail for when the gate is promoted to blocking.
- **A PR-authored gate job's credentials stay within the risk its ADR accepts.** A gate job that runs
  PR-authored scripts must not get a credential broader than the remaining risk its ADR records as
  accepted. For example, set `persist-credentials: false` on `actions/checkout` (otherwise the token stays in git
  config) when the ADR only accepted a read-only token. Prefer a method that needs no token. For a PR
  diff the merge-ref checkout already holds the target base. So `git diff HEAD^1 HEAD` computes the
  changed files with no fetch and no token.
- **Match the existing shape.** Read a current `Check-*.ps1` and mirror it; do not introduce a second gate
  idiom.
- **No em-dashes** in the gate or its messages. A file path with a line number in a finding is fine.

## Observable signal

**Positive:** a recurring mistake stops recurring, because it is now caught in seconds locally and on
the PR. The rule has one enforcement point instead of living in text that drifts.

**Audit trail:** the gate script and its Pester test are the receipt; the test fixture shows exactly what the
gate does and does not catch.

**Drift signal:** a new gate may sit advisory forever. Then either it has a real backlog to clear
(track it) or it was never promoted. If gate scripts start differing in shape, people are going around
this skill.

## Next steps

- Run the new gate locally with `pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1` and confirm it
  passes on a clean tree and fails on the breaking fixture.
- `/wrap-up` (Developer) - after a standalone run, commits a repository gate and runs the pre-flight;
  then push and open or update the pull request (step 6). Inside `wrap-up` or a build loop, skip it. A shared gate
  goes to AI.SDLC through its own steps.
- `/capture-learning` (Lead) - the usual upstream caller, when a PR lesson is classified as
  needing a new gate.
- If the rule is about artifact-graph or docs-wiki integrity, it may belong in `Check-ArtifactGraph.ps1`
  or `Check-DocsWiki.ps1` rather than in a new gate.
