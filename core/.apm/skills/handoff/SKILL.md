---
name: handoff
kind: workflow
phase: cross-cutting
persona: any
disable-model-invocation: true
argument-hint: "What will the next session be used for?"
description: >
  Compact the current conversation into a handoff document for another agent to pick up. Use when you
  type /handoff at a phase boundary, before a /compact, a new session, a new folder or a colleague.
---

# Handoff

Usable by any persona, at any phase. Invoked as `/handoff`, by a person only. The compact-suggestion
hook names it when the context window is filling up.

Write a handoff document that sums up the current conversation, so a fresh agent can continue the work.
Save it to the temporary folder of the user's OS (`$TMPDIR`, else `/tmp`; `%TEMP%` on Windows), not the
current workspace.

Include a "Suggested skills" section in the document. It names which skills the next agent should load.

Do not copy content that other artifacts already hold (specs, plans, ADRs, work items, commits, diffs).
Point at them by path or URL instead.

Redact any secret or private information, such as API keys, passwords or personal data.

If the person passed arguments, treat them as a description of what the next session will focus on.
Shape the document to that.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).

## Is this a boundary?

A compact or a fresh session is cheap between two phases, and expensive in the middle of a build. The
boundary table, and what a compact keeps and drops, are in the
[context management page](/.claude/skills/ai-sdlc-handbook/references/context-management.md). Before you write:

1. **Say where the session is.** Name the phase that just ended and the one about to start. The boundary
   table turns that pair into a yes, a no or a maybe. In the middle of a build the answer is "not yet":
   finish the edit in hand first, and say so in one line.
2. **Write the costly parts to their own home first.** Only a file survives a compact. The plan goes to
   the story file when `implement` wrote one; without one, write it to `temp/plan-<KEY>.md`. A decision
   goes to an ADR through `/write-adr`. A lesson goes through `capture-learning`. A finding goes on the
   work item through `write-story` in update mode (github-issues pack), or into the pull request description.
   That mode shows the diff and asks once. The handoff document then points at each of them. Called from here,
   those skills write the files only. The session that goes on with the work commits them with the
   rest of the change, through `/wrap-up`. A platform note is the one exception: `write-platform-note`
   hands it to a pull request itself.
3. **Write the handoff document**, as above. Then tell the person its path, and offer the next command,
   for example `/compact keep the plan for #42 and the branch state`. The agent never runs
   `/compact`; only a person can type it.

## Failure modes

- **The handoff is written before the costly parts have a home** -> the plan or the decision then lives
  only in a temporary file. Write it to its own home first, and point at it.
- **The document copies the plan, the diff or the ADR** -> two copies drift. Point at the artifact.
- **A secret, a token or personal data lands in the document** -> redact it before you write. The file
  sits in a shared temporary folder.
- **The task list is treated as a safe home** -> the tool that holds one is not in every agent or every
  version. A file survives everywhere.
- **It runs in the middle of a build** -> the file paths, the names and the half-finished edit are what
  a compact drops. Finish the edit, then look again.
- **The nudge of the hook is read as an order** -> the hook reports a number, not a decision. A session
  that is 80% full and two minutes from a pull request should finish the pull request.

## Observable signal

**Positive:** the next session reads the handoff document and goes on from the story file, the plan and
the branch. It does not ask the person to repeat what was decided.

**Audit trail:** the handoff document, and the files written just before it, are the receipt.

**Drift signal:** if a session keeps re-reading the same code after a compact, the costly context was
never written down and step 2 is being skipped.

## Next steps

- `/capture-learning` (Lead) - move a lesson from this session into its durable home first.
- `/write-adr` (Architect) - record a decision that was made in the chat and lives nowhere else.
- `/wrap-up` (Developer) - when the boundary is the end of a change, not just the end of a phase.

## Sources

- Adapted from `skills/productivity/handoff/SKILL.md` in
  [mattpocock/skills](https://github.com/mattpocock/skills), MIT licence, Copyright (c) 2026 Matt Pocock.
  We added the boundary check and the "write it to its own home first" step. The licence is in
  [LICENSE-upstream.md](LICENSE-upstream.md).
