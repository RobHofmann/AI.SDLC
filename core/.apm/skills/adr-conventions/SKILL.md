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

- It adds, replaces or splits a pattern or a boundary: a new service split, a storage choice, an auth
  model.
- It departs from a convention or a constitution clause. That always needs a record, or an amendment
  of the clause.
- It picks one approach over a real alternative, and the choice has lasting effects.
- A new gate, a governance method or a repo-wide contract counts as key, even when it was built
  outside `implement`. Write its ADR in the same change.
- Not for a routine, local choice that is easy to undo. Ask: would someone in six months be confused
  if this were not written down?

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
