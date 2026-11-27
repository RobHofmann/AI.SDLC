---
name: adr-conventions
kind: knowledge
user-invocable: false
description: >
  How an Architecture Decision Record is written in this repository. It covers when a decision needs
  one (clause C01), the next free number, and the MADR sections and status lines. It also covers the graph
  frontmatter (story, phase, step, intent, relates, because), recording the decided state rather than
  the process, and the README index row. Use when an ADR is drafted, superseded or reviewed, or when a
  plan or a change may carry a decision the architecture rests on. Do NOT use to run the ADR step
  itself (write-adr) or to change a constitution clause (update-constitution).
---

# ADR conventions

How we write an ADR here. The `write-adr` workflow skill loads this before it drafts, and the
`architect` agent loads it when it reviews a plan or a draft. The template and the index hold the full
rule; this is the short list of what goes wrong.

## When a decision needs an ADR (C01)

A decision needs an ADR only when it passes all three tests. When one test fails, there is no ADR.

1. **Hard to undo.** Undoing it later costs real work: a storage choice, a boundary, a contract that
   other repositories read.
2. **Surprising without context.** A reader in six months would ask "why this way?", and the code does
   not answer it.
3. **A real trade-off.** There was a real alternative, and the choice gave something up for it.

- A new gate, a setting or a routine, local choice does not count as key by itself. It gets an ADR
  only when it passes the three tests. When it fails one, its reason lives in the skill or the page
  that lists it.
- A change to a decision that an existing ADR records updates or supersedes that ADR, whatever the
  three tests say.
- A departure from a convention or a constitution clause goes to that convention, or to
  `update-constitution` for a clause. It gets an ADR as well only when the three tests also hold.
- A data-model change (`tracker.dataModelPatterns`) whose decision misses a test carries a
  `No-ADR: <why>` commit trailer instead. Only `wrap-up` writes it, after the `architect` agent agrees.

## The file

- **Number.** List the ADR folder (`paths.adrFolder` in aisdlc.json, `docs/adrs` by default). Take
  the highest `NNNN` and add one, zero-padded to four digits. The file name is `NNNN-<kebab-short-title>.md`.
- **Frontmatter first.** `story:` is the work item key, `phase: governance`, `step: write-adr`. The
  `intent:` block holds the riskiest `assumption` and the `decision-drivers`, written from the
  grilling answers. `relates:` and `because:` point at the spec, doc or code the decision touches,
  and every path must resolve (`Check-ArtifactGraph.ps1`).
- **Status lines.** A new ADR is `Accepted` and dated today: the branch is the proposal and the merge
  is the sign-off. Keep `Proposed` for a decision recorded on purpose ahead of the work.
- **Sections.** Context, Decision, Consequences (Positive, Negative, Neutral), Alternatives considered
  (each with its "rejected because"), Verification, References. Fill every one.

## What the body says

- **The decided state, not the process.** No review history and no round counts; [C08](/.claude/skills/ai-sdlc-handbook/references/constitution.md)
  covers names. Never cite an unmerged commit hash.
- **Facts checked against the code.** Name a file path and a symbol ([C02](/.claude/skills/ai-sdlc-handbook/references/constitution.md)). A fact
  you cannot check is written as an open question.
- **An enforcement claim is true now.** If the ADR says a gate or test enforces the rule, that gate or
  test exists in the same change.
- **One decision per ADR.** Two independent decisions get two files.
- **Link, do not paste.** Point at the artifact rather than copying it in.

## Superseding

- Write the new ADR with `Supersedes: ADR NNNN`.
- In the old ADR, change only `Status: Superseded` and `Superseded by:`. Its body stays as it was,
  because it records what was believed at the time.

## After the file

- Add a row to the table in the `README.md` of the ADR folder with the number, title and status.
- The story in `story:` gets a backlink through `write-story` in update mode (github-issues pack). That is a GitHub issue write,
  so it joins the one list of issue updates for the run. The ADR itself reaches the person in the pull request
  at Checkpoint Bravo.

## Sources

- The `README.md` (index and rules) and `0000-template.md` of the ADR folder in the repository.
- [Node templates](/.claude/skills/ai-sdlc-handbook/references/node-templates.md) - the frontmatter every graph node carries.
- [Artifact graph](/.claude/skills/ai-sdlc-handbook/references/artifact-graph.md) - the frontmatter edges and the gate that checks them.
- [Constitution](/.claude/skills/ai-sdlc-handbook/references/constitution.md) - C01, C02 and C08.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).
