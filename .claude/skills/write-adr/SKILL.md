---
name: write-adr
kind: workflow
phase: cross-cutting
persona: Architect
description: >
  Suggest and author MADR-style Architecture Decision Records in docs/adrs/, and flag decisions
  that ought to be recorded. Use when a load-bearing decision is being made or has just been made
  ("we decided to...", "let's go with X over Y", "should this be an ADR?", "record this decision",
  "write an ADR", "supersede ADR NNNN"), or when a plan or change implies an unrecorded
  architectural choice. Do NOT use for the project-wide constitution (update-constitution), for
  ordinary feature docs or for tracker work items.
---

# Write an ADR

Owned by the **Architect** persona (also serves the architecture step in elaboration). Called as `/write-adr`.

Spot, suggest, and author **Architecture Decision Records**. An ADR captures *why* a
key choice was made, so a future reader (or agent) does not re-litigate it or
unknowingly break it. ADRs are decision history: append-only, superseded but not
deleted, read on demand (never preloaded into context).

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).

## Use the repo's own template and rules

Load the `adr-conventions` skill first: it holds the numbering, the frontmatter, the status lines and
the "state, not process" rule, and points at the full template. Then **read the repo's ADR template
and index** so output matches what is already there:
- The ADR folder is `paths.adrFolder` in aisdlc.json (`docs/adrs` by default).
- Template: `0000-template.md` in the ADR folder (or the repo's equivalent). Mirror its exact
  sections and frontmatter. Do not invent a different format.
- Index/README: `README.md` in the ADR folder. Follow its conventions for listing and status.
If the repo has no ADR folder, propose creating it with a template first (and say so).

Link to artefacts; do not paste them in.

## What counts as "key" (when to suggest an ADR)

Suggest an ADR when a change does any of these, and there is no existing ADR covering it:
- introduces, replaces, or splits an architectural pattern or boundary (e.g. a new
  handler/service split, a storage choice, an auth model);
- makes a cross-cutting tradeoff a future reader would ask "why" about;
- **deviates from an existing convention or a constitution clause** (this especially
  needs a record, or a constitution amendment);
- chooses one technology/approach over a viable alternative with lasting consequences.

Do not propose ADRs for routine, reversible, or local choices. Noise erodes the set of pages.
When not sure, ask: "would someone six months from now be confused or annoyed if this
choice were undocumented?"

## Modes

- **suggest** - state that a decision looks key, summarise it in one or two
  lines, and ask whether to author an ADR. Do not write anything yet.
- **author** - draft a new ADR, have it reviewed, and write it.
- **supersede** - author a new ADR that replaces an older one.

## author workflow

0. **Question the decision (right-sized).** Before recording, run `grilling` to test the choice. The Architect leads, with the Lead when it touches a constitution clause, auth, or data. Ask: what are the realistic alternatives, what forces really decide between them, and what is the riskiest assumption the decision rests on? Use a method that fits (approach comparison, arguing the other side, or a pre-mortem for a far-reaching choice). The answers become the `intent` frontmatter and sharpen the Alternatives and Context sections. A small, clearly-forced decision earns one or two questions; do not turn it into a meeting. Inside a build loop (the ADR check of `wrap-up`), do not put rounds to the person. Answer the questions from the plan, the code and the ADRs, with the `architect` agent where you can. List what stays open as open questions in the ADR Context and in the evidence record for Checkpoint Bravo. A departure from an ADR, a convention or a constitution clause is still a stop. Called by a person directly, grilling runs as usual.
1. **Allocate the number.** List the ADR folder, find the highest `NNNN`, increment, zero-pad to 4 digits. Filename: `NNNN-<kebab-short-title>.md`.
2. **Emit the graph frontmatter, then fill the template from reality.** Begin the file with the YAML frontmatter the template shows. `story:` is the work item this decision belongs to, a valid issue key in quotes, such as `"#42"` (`owner/repo#42` for an issue in another repository). Then `phase: governance` and `step: write-adr`. The `intent` block holds the riskiest `assumption` and the `decision-drivers`, written from the grilling answers and not left for the user to type by hand. The `relates:` / `because:` edges point at the spec, docs, or code the decision touches. This is what joins the ADR to the artifact graph; the artifact-graph gate in `Invoke-LocalGates.ps1` checks it resolves. Then complete every section of the repo template:
   - **Context** - the forces and limits *as they are now*; check key facts against the code before stating them (read the file/symbol). Record the forces as they stand, not the timeline of how the decision was reached. No story of the review process (who reviewed, how many rounds, who caught what) and no named people; those belong in PR history. If an earlier try failed, give it one line: what is not visible in the current code, plus the merged PR it came from. Never an unmerged commit hash. PR and story keys are sources and anchors: keep them in References, not woven through the body as narrative.
   - **Decision** - what was decided, plainly; include a short code/config shape only if it removes unclear meaning; name the files/types/patterns it touches.
   - **Consequences** - Positive, Negative (be honest; this is the section readers trust most), Neutral.
   - **Alternatives considered** - each with a one-sentence "rejected because".
   - **Verification** - how someone confirms a change in this area is correct; what tests do and do not cover.
   - **References** - files by path + symbol, merged PR numbers, external links.
3. **Set status and dates.** Write a new ADR as `Accepted`, dated today. The branch is the proposal and the merge is the sign-off, so a `Proposed` status tracks nothing while the pull request is open. Reserve `Proposed` for a decision on purpose recorded ahead of the work that implements it. This is a status convention, not a sign-off. It does not let you mark an acceptance criterion done or move a work item to a done state (constitution C09). It does not excuse a stale body either. If review changes the design, update Context, Decision, Consequences and Alternatives to match what is being merged.
4. **Review, then write.** Hand the draft to the `architect` agent
   on Opus 5.5 (model `opus` in Claude Code, `claude-opus-5.5` in Copilot) for review. If you cannot run agents,
   load `adr-conventions` and review the draft against it yourself. Fix each finding or record why you
   declined it. Inside a build loop (the ADR check of `wrap-up`), write the file without a separate
   confirmation. An ADR is a repository file, and the person sees it in the diff at Checkpoint Bravo. Run
   standalone, show the draft first, then write.
5. **Update the index** (`README.md` in the ADR folder): add the new ADR with its status.
6. **Backlink the story (required closing step, not an offer).** Authoring an ADR is not complete until its source story shows it. Hand off to `write-story` in update mode (github-issues pack) to record the ADR on the story named in the `story:` frontmatter. It goes in as a `🧭 Decisions & ADRs` bullet in the **description** (the living record, cheaper to read back than a comment): `YYYY-MM-DD: <decision> - see <ADR folder>/NNNN-...md`. The write itself belongs to that update mode and joins the Checkpoint Alpha or Checkpoint Bravo confirmation, so the single-writer rule holds. Do not edit the story from here, but do drive the handoff rather than leaving it as a suggestion. If `story:` is really absent (a graph-orphan ADR), say so and stop, rather than skipping silently. If the decision means a new or changed non-negotiable, also run `update-constitution`.
7. **Hand the work to a pull request (standalone run only).** A standalone run is one a person
   starts directly, not from `wrap-up`, a build loop or another skill. The work goes on a branch named
   with a story key. When you are not on a branch named with a story key, create it from the current
   state (`git switch -c <number>-<topic>`); the work moves with it. When you are on one, stay on it. Then
   `/wrap-up` commits it and runs the pre-flight. Push the branch and open or update the pull request through the pull request skill of the
   installed pack, as `implement` does. In `github-pull-requests`, `New-PullRequest.ps1` opens a new one and `Update-PullRequest.ps1` updates an open one. Called
   from `wrap-up`, a build loop or another skill, skip this step: write the files only, and `wrap-up`
   commits them. So `wrap-up` never runs itself a second time.

## supersede workflow

1. Author the new ADR as above; in its frontmatter set `Supersedes: ADR NNNN`.
2. In the old ADR, set `Status: Superseded` and `Superseded by: ADR <new>`. Keep the old ADR's body intact - it is history.
3. Update the index to reflect both statuses.
4. Have both diffs reviewed as in author step 4 before writing.
5. **Backlink both stories (required).** Run the step-6 handoff for the new ADR's story. Also record the supersession on the source story of the superseded ADR (if different), via `write-story` in update mode. Then a reader of either story sees the decision moved. A supersession that never reaches the affected stories leaves the graph saying the old decision still stands.
6. **Hand the work to a pull request (standalone run only)**, as in author step 7.

## Guardrails

- **Check before asserting.** Every key fact in Context/Decision must be checked against the codebase first. If you cannot confirm it, write it as an open question, not a fact.
- **An enforcement claim must be true now, not a wish.** When the Decision or Verification states that a gate, check, or test enforces the rule, that enforcement must already exist. Name the test or gate that proves it, or build it in the same change. Do not describe intended enforcement as current. (Two ADRs once described gate behaviour the gate did not yet have.)
- **Review before writing**, and never overwrite an existing ADR's history when superseding - only switch its status fields. A standalone run shows the draft first; inside the build loop the diff reaches the person at Checkpoint Bravo ([orchestration.md](/.claude/skills/ai-sdlc-handbook/references/orchestration.md)).
- **One decision per ADR.** If a change carries two independent decisions, write two.
- **Record state, not process.** An ADR is lasting architectural memory, not a postmortem. Review timeline, round counts, and named reviewers belong in PR history; reference the PR by number instead.
- **Match to the node shape.** The ADR already carries the graph frontmatter (`0000-template.md` in the
  ADR folder). Per [node-templates.md](/.claude/skills/ai-sdlc-handbook/references/node-templates.md),
  its why-bearing sections are Context (the forces), Alternatives (each with its rejected-because), and
  `intent.decision-drivers`. Fill them from the
  grilling, not as an afterthought.
- **No pasted artefacts.** Match the repo template exactly.

## Failure modes

- **The ADR claims a gate or test enforces the rule, and it does not yet** -> build the enforcement in the same change. Or write the claim as intent. This has already happened: a pull request shipped two ADRs describing gate behaviour the gate did not have.
- **The change carries two decisions** -> write two ADRs. One ADR with two decisions cannot be superseded cleanly later, because half of it stays true.
- **A key fact cannot be confirmed against the codebase** -> write it as an open question in Context. An unverified fact in an ADR lasts longer than the session that guessed it.
- **Superseding an existing ADR** -> switch the status fields on the old one and leave its body alone. Rewriting the superseded ADR destroys the record of what was believed at the time, which is the only reason it is still in the repository.
- **The decision was reached in a review and the draft names who said what** -> reference the PR by number. Named contributors in a permanent record are a data-protection problem (C08) and a blocking gate.
- **No alternative was really considered** -> that is a signal the decision is not key, or that the alternatives were not explored. An Alternatives section with one straw-man entry is worse than admitting the decision was obvious.
- **The frontmatter `story:` or `relates:` does not resolve** -> the artifact-graph gate in `Invoke-LocalGates.ps1` fails and the ADR is orphaned from the work that asked for it. Fix the front-matter, do not remove the edge.

## Observable signal

**Positive:** a later reader who asks "why is it done this way" finds the answer, with the rejected alternatives and the reason. They do not reopen a settled decision or undo it without knowing what it cost.

**Audit trail:** the ADR file plus its `story:` edge is the receipt linking a decision to the work that forced it. When behaviour later looks wrong, it separates "we chose this and it was a bad choice" from "nobody chose this".

**Drift signal:** if ADRs keep being written after the code shipped rather than before merge, C01 is not holding. The ADR then documents rather than decides. If stories keep showing no `🧭 Decisions & ADRs` line for their ADRs, the update-mode follow-up of `write-story` is being dropped.

## Next steps

- `/wrap-up` (Developer) - after a standalone run, commits the ADR and runs the pre-flight; then push
  and open or update the pull request (author step 7). Inside `wrap-up` or a build loop, skip it.
- `write-story` in update mode (any) - backlink the new ADR onto its source story and add a dated decision-log line.
- `/update-constitution` (Lead) - only if the decision means a new or changed non-negotiable.
- Run `pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1` once the ADR is linked, to confirm its `story:` and `relates:` front-matter resolves. The pre-push hook runs the same check.
