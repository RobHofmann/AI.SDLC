---
name: wrap-up
kind: workflow
phase: create
persona: Developer
description: >
  Close the gap between working code and a finished change. Sweep the repository for anything that
  still refers to what the change renamed, removed or inverted. Then bring the tests, both
  documentation layers, the user story and the gates up to what the change actually did. Then commit
  and run the pre-flight on that commit, so one command stands before the pull request. Use when the
  user says "finalise this", "the feature works, finish it off", "are the docs and tests up to
  date", "what else still refers to the old name", "I renamed a parameter, what else points at
  it", "did anything get left behind", or when Check-ChangeCompleteness reports a gap before a
  push. Do NOT use it as a second code-review pass; it is about what the change left behind, not
  about the code itself.
---

# Wrap up a change

Owned by the **Developer** persona. Called as `/wrap-up`, by every build loop before it pushes
(`implement`, `refactor`, `fix-pr-feedback`), and by `adopt-docs`. `write-prd`, `write-pipeline`
(github pack) and the discovery skills of the discovery pack call it for the repository files they
write: `write-hypothesis`, `draw-customer-journey` and `write-research-summary`. The knowledge pack
calls it from `write-platform-note`, outside a build loop.
`write-adr`, `update-constitution`, `write-docs`, `add-gate`, `capture-learning` and `write-api-spec`
(dotnet pack) call it only after a standalone run. When this skill calls `write-docs`, `write-adr` or
`capture-learning` itself, they write the files and do not call it back.
The pre-push flow calls it when the completeness check reports a gap. It ends with the commit and the pre-flight, so a person types one
command before the pull request.

This skill is the single owner of the steps that finish a change. They are the docs (`write-docs` with
the `docs-reviewer` agent) and the ADR check (`write-adr`). They are also the story and pull request
contract, the lessons step, the commit and the pre-flight. A calling loop runs none of them itself, before or after this skill.

A feature is not done when it works. It is done when the tests describe what it now does and the
documentation describes what the system now is. Those two steps come at the end of a change,
which is exactly where they get dropped. The code works and the branch is green, but the change ships
with its tests and docs one version behind. This skill is that end, split out so it can be reached
from anywhere and triggered without a human remembering.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).

## Why this is a separate skill

**It is an orchestrator, not a second copy of the rules.** Tests, documentation, decisions, the
user story and the gates each already have a skill that owns them. This skill's own part is small
and specific. It reads what the change really did, and finds who else still refers to what it
changed. Then it calls the owners in the right order. When a rule is restated here instead of called,
the two copies drift. Which one a developer happens to read is then a coin toss.

Detection is free and fixing is not. `.claude/skills/ai-sdlc-gates/scripts/Check-ChangeCompleteness.ps1` answers "did source
change while tests and docs stood still" from the diff alone, so nothing is spent on noticing. This
skill is the expensive half. It runs only when the cheap half says there is something to do, or when
a human asks for it.

## Workflow

0. **Check the branch.** When the current branch is `main` or `master`, or its name holds no story
   key, stop before step 1 and say so. A story key looks like `42-<topic>`, or the bare `42` for a bug. Ask the person to create the story
   branch from the current state (`git switch -c <number>-<topic>`); the work moves with it. When there is
   no story yet, `/write-story` makes one first. A calling loop has made the branch already.
1. **Read what the change did, not what it was meant to do.** Diff the branch against its base and
   list the behaviour that changed. Nothing is committed yet, so run `git add --intent-to-add .`, then
   `git diff $(git merge-base origin/main HEAD)`; a diff of two commits leaves the work out. Work from the diff, because the plan and the result drift.
2. **Search the references from elsewhere.** The diff tells you what changed. It does not tell you who else
   talks about it, and that is where this step earns its place. List every parameter, command,
   file path, default, figure and rule the change renamed, removed or inverted. Grep the WHOLE
   repository for the old form of each. That covers `AGENTS.md`, `.claude/skills/`, the tools folder
   (`paths.toolsFolder` in aisdlc.json), both `docs` layers, the workflows, and the help blocks inside
   scripts. Three places bite hardest:
   - **`AGENTS.md`** is loaded on every agent run, so a stale rule there propagates into all
     following work rather than sitting quietly on a page.
   - **`.claude/skills/*/SKILL.md`** is what the next agent reads and acts on. A skill that still
     calls a now-blocking gate "advisory" turns a real failure into a note.
   - **Sibling tools.** A script that calls the one you changed breaks on a removed parameter, and
     `Invoke-Preflight.ps1` and `Invoke-LocalGates.ps1` both call the gates.

   Grep for the concrete strings, not the concept: the old parameter name, the old number, the old
   command line. A change that removes a parameter and leaves one caller behind is not finished,
   it is broken in a way the diff cannot show you.

   **Grep the rule, not only the identifier.** This is where the search gets missed, measured. On the
   coverage-gate change the identifier grep (`-Threshold`) came back clean. But six references to the
   RULE it enforced (`>= 80%`, `the C04 bar`) survived in three skills, because they never named the
   parameter. If the change changed a threshold, a default or a policy, grep the number. Also grep
   the phrasing a human would use for it, in every wording you can think of. Have something other
   than your own memory make that list. Your memory of how you phrased it is the weakest input there
   is.

   Two broken cross-references also survived that way: a `test-coverage` skill was named in two
   files and no such skill exists. `Check-SkillHygiene.ps1` now checks that every `/name` reference
   resolves to a skill folder, but a name written without the slash still passes it. Check those yourself.
3. **Tests: run the tests of what changed, and measure.** Run only the tests of the files the change
   touched. That is the test file next to a changed script, or the test project of a changed project. Do not
   run the full test command here. The pre-flight at step 11 is the one full run on the commit. It runs
   `commands.test` of aisdlc.json, or the tests and the C04 ratchet of the dotnet pack. A full run here
   as well doubles the slowest part of the wrap-up. Then hold the behaviour list from step 1 against the story's
   tagged tests. Every acceptance criterion has a covering test, or is marked as a check by hand.
   When the change is to a skill rather than to application code, the equivalent is
   `/test-skills`, which owns the skill eval harness. A pass of `Check-SkillHygiene.ps1` is
   structural. It does not show that a reworded skill still routes and behaves.
4. **Documentation: call `/write-docs`.** It owns both layers, the routing between them,
   the cross-linking, and the staleness check. Hand it the behaviour list and the reverse-reference
   findings from step 2, because a stale reference it cannot see is one it will not fix. It ends with
   the `docs-reviewer` agent, so the pages are checked by a reader that did not write them.
   When the caller already ran `write-docs` on these pages, their `docs-reviewer` pass is done too. That
   is a standalone `write-docs` run, or a standalone `capture-learning` run that sent its lesson
   through `write-docs`. Skip this step unless the diff holds a change outside those pages.
   Then check one thing yourself: for each area the change touched, does each layer have a page for
   it? Where a layer had none, the new page must describe the whole area, not only this change (the
   scope step of `/write-docs`). No gate sees this, because `Check-DocCoverage.ps1` knows
   only units.
5. **Decisions: call `/write-adr`** when the change rests on a key choice (C01). A routine
   change covered by an existing convention does not need one.
6. **The substrate.** Three jobs, all for `write-story` (github-issues pack), and none for this skill:
   - **`/write-story`** when the change changed what "done" means, because it owns the acceptance
     criteria. The mapping of criteria to tests is in the evidence record.
   - **`write-story` in update mode** for the issue body, the title and the links, since it is the
     single writer for those. Point it at any claim the work has since disproved. That can be a risk recorded as
     open that is now closed, a figure since re-measured, or a scope line the change moved. A description that
     goes against what shipped is worse than a thin one, because a reader trusts it. The diff joins the
     one list of issue updates for the run. When the person confirms that list as shown, `write-story`
     rewrites the false line as shown. Without that confirmation, update mode only adds.
   - **`write-story` in update mode again, on the work items this change limited.** This is the part no other
     skill will do for you, because it is about a work item other than the one in hand. The change may
     add a gate, an exclusion list or a test that a linked or follow-up work item will have to change.
     Then say so on that work item now, naming the file. Otherwise whoever picks it up meets a failing test
     with no idea why, and the limit is found only by breaking it.

   **The pull request description** is the evidence record in `temp/`. Correct it there when the
   change grew or a stated figure turned out wrong. The calling skill writes it to the pull request
   after the push. When a person called this skill and a pull request is open, tell them to update it
   after their push. They use the pull request skill of the installed pack (`Update-PullRequest.ps1` in
   `github-pull-requests`).
7. **Check what the docs now claim (dotnet pack).** When the dotnet pack is installed, run
   `pwsh .claude/skills/dotnet-gates/scripts/Check-DocDrift.ps1 -Doc <area>` over the area the change
   touched. Renaming or deleting a type is exactly how a page starts describing something that is not
   there. This is the step where that is caught rather than shipped. It needs only git and the files.
   It reports:
   - a constant the page never names;
   - a file it names that is gone;
   - an identifier the page names that no longer exists;
   - an endpoint an API page documents that no route-carrying file names;
   - on a project page only, a service in the project that appears nowhere on it.

   The identifier signal is the one to read first after a rename: it is the only one that asks page
   to code. Fix what this change caused; a
   finding that predates it is worth listing, not necessarily fixing here.
7b. **Check what the docs claim about relationships, if the change moved a dependency (dotnet pack).** A rename is
   caught by step 7; a moved or dropped dependency is not, because every name involved still exists.
   When the dotnet pack is installed, first bring the graph up to the code, in this order:
   1. If `graphify-out/` exists without `graph.json`, a git hook is rebuilding the graph right now.
      Wait until `graph.json` is back (a build takes about 30 seconds); two builds at once break each other.
   2. When Graphify is installed (`graphify` on the PATH), rebuild with
      `pwsh .claude/skills/dotnet-code-graph/scripts/Invoke-GraphifyIndex.ps1`.
   3. Then run `pwsh .claude/skills/dotnet-code-graph/scripts/Invoke-DocGraphLink.ps1`. A rebuild drops
      the links from the pages to the code, and the claims check needs them. The git hook
      `graphify-refresh` runs the same two steps in the same order.

   Then run `pwsh .claude/skills/dotnet-code-graph/scripts/Check-DocGraphClaims.ps1`. It warns when the
   graph is older than the working tree. Right after a rebuild that warning is expected while the change
   is not committed, because the graph records the commit, not the edits. It reports a page linking two projects the code
   graph records no edge between, and an implementation a page never names. A line saying `no direct
   code path` is exempt. A page may link a project exactly to explain that the code does not reach
   it. It needs the graph, and says so and exits clean when there is none. This is the only check here that can see a stated
   relationship being false. Fix what this change caused; a finding that predates it is worth listing,
   not necessarily fixing here.

8. **Fast check: run `pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1 -SkipTests`**, the gate set
   the pull request workflow runs, including `Check-ChangeCompleteness.ps1`. `-SkipTests` leaves out the gates that
   run Pester tests, because the pre-flight at step 11 runs them. Fix what fails, so the lessons step and
   the commit start from a green tree. This is the quick check before the commit; the pre-flight at
   step 11 is the one that counts. It runs the gates, the full test run and, when the github-issues pack is
   installed, `check-pr-contract` for the story-and-ADR wiring.
9. **Lessons: call `/capture-learning`.** Turn a correction from this change into a lasting rule, or
   say in one line that nothing general came out of it. When `fix-pr-feedback` called this skill, use
   the pull request entry on the review, which is still unresolved: no thread is resolved before the push. It runs before the commit, so a lesson that
   changes a file in this repository is part of the commit and of the pre-flight.
   When a standalone `capture-learning` run called this skill, its lesson step is done; skip this step.
10. **Commit.** Commit the change on the story branch, with a message that names the story key. This
    commits everything on the current branch. So a person who wants a separate pull request for a side
    change makes a separate branch for it first. Say
    plainly that a commit is not a sign-off: it is a save point. The person still reviews the change at
    Checkpoint Bravo, and nothing is pushed here.
11. **Pre-flight: call `run-preflight` on that commit.** It runs the pull request checks locally, and a green
    run on the committed tree writes the receipt the push hook asks for. When it fails, fix, commit again
    and run it again until it is green. Report the result. The calling loop then pushes and opens or
    updates the pull request; when a person called this skill, the push is theirs.

## Guardrails

- **Call, do not restate.** If another skill owns a step, call it and pass it the context from
  steps 1 and 2. Copying its rules in here creates a second source of truth that will go stale. This
  skill is where that costs the most, because it runs at the end when nobody is looking closely.
- **Never write a test whose only purpose is the gate.** A test that asserts nothing to make a
  number move is a lie told to the next reader. It removes the signal the gate exists to give.
- **Update, do not append.** A documentation page that grows a new paragraph for every change becomes
  a changelog. Correct the page so it describes the system as it now is.
- **The diff is the source of truth.** Not the story, not the plan, not the commit messages.
- **One commit point, one pre-flight.** This skill commits and runs the pre-flight once, at its end. A
  caller does not repeat either step. Never push from here, and never push to `main` or `master`.

## Failure modes

- **Running on every push.** This is the expensive half. It belongs at the end of a working change,
  not after each commit. That is why the trigger is a deterministic check and not a schedule.
- **Treating the completeness check as the standard.** It answers whether tests and docs moved, not
  whether they are any good. A clean check with a bad page is still a bad page.
- **Documenting a plan instead of a result.** If the change was withdrawn, reduced, or turned into
  something else, the documentation must say what shipped.
- **Working only from the diff.** The diff is the source of truth for WHAT changed, and blind to who
  else refers to it. Skipping step 2 is how a removed parameter survives in a caller, a superseded
  rule survives in `AGENTS.md`, and a now-blocking gate stays "advisory" in three skills. This was
  the observed failure that added that step. The first pass on the coverage-gate change corrected the
  pages the diff touched. It left five references elsewhere, one of them a broken script call.
- **Restating instead of delegating.** An earlier version of this skill spelled out the test and
  documentation rules itself. That is how the repository ends up with two versions of the same rule.
  It is why the workflow above is a list of calls.
- **A commit read as a sign-off.** The commit is a save point for the pre-flight receipt. The change
  is accepted only when a person approves the pull request at Checkpoint Bravo.
- **A second commit and pre-flight by the caller.** A loop that commits again after this skill gets a
  new tree, so the receipt no longer matches and the push hook refuses it. The caller pushes what this
  skill committed.
- **Finishing inside the repository.** A change is not finished when the repo is in line with
  itself. The story, the work items it limits, and the pull request description are part of the
  change, and they are the parts a human reads.

## Observable signal

`Check-ChangeCompleteness.ps1` reports nothing, and the gates and the full test run pass. The
receipt `temp/preflight/<tree>.json` exists for the commit this skill made. The diff
of the change contains test and documentation edits that a reader can match to the behaviour that
changed. Grepping the repository for the old form of anything the change renamed or removed returns
nothing outside intended history (a changelog entry, a superseded ADR). The story carries no claim
the work disproved. Every work item this change limits says so. The pull request description draft in
`temp/` matches what is on the branch.

## Next steps

The workflow above is a sequence of calls; these are those skills, in the order they run.

- `run-preflight` (Developer) - step 11, runs the gates, the tests, the coverage ratchet, the analyzer
  rules, gitleaks and `check-pr-contract`, and writes the receipt for the commit.
- `/test-skills` (Lead) - step 3 when the change edits a skill, owns the skill eval harness.
- `/write-docs` (Tech Writer) - step 4, owns both documentation layers and their cross-links.
- `/write-adr` (Architect) - step 5, records a key decision the change rests on.
- `/write-story` (Product Manager) - step 6, owns the acceptance criteria when the change moved
  what "done" means.
- `write-story` in update mode (any) - step 6, the single writer for the description, title and links, on this
  story and on the work items this change limited.
- `pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1` - step 8, the fast check before the commit.
- `check-pr-contract` (Lead) - step 11, inside `run-preflight`; owns the story-and-ADR wiring before the
  pull request opens.
- `/capture-learning` (Lead) - step 9, before the commit. Turn a correction from this change into a
  lasting rule, or say in one line that nothing general came out of it.
- `/implement`, `/refactor`, `/fix-pr-feedback` (Developer) and `/adopt-docs` (Tech Writer) - the flows that
  call this skill. Each pushes the commit and opens or updates the pull request.
- `write-platform-note` (Operations engineer, knowledge pack), outside a build loop, and `/write-prd`
  (Product Manager) - they call this skill for the files they write. Then they push and open or update
  the pull request.
- `/write-pipeline` (Developer, github pack), and `/write-hypothesis`, `/draw-customer-journey`
  and `/write-research-summary` (Analyst, discovery pack) - the same, for the files they write.
- `/write-adr` (Architect), `/update-constitution`, `/add-gate` and `/capture-learning` (Lead),
  `/write-docs` (Tech Writer) and `/write-api-spec` (Architect, dotnet pack) - the same, but only after a
  standalone run. Called from this skill or a build loop, they write only.
