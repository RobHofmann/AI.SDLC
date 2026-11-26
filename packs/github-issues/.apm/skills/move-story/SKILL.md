---
name: move-story
kind: workflow
phase: create
persona: Developer
user-invocable: false
description: >
  Mark the stories of a pull request as waiting for review with the in-review label (tracker.inReviewLabel
  in aisdlc.json, default in-review), after the person published the draft. It plans the move from facts:
  the person says the draft is published, and GitHub shows the pull request open and no longer a draft.
  It names the stories only from the branch, the title and the Fixes lines, never labels a closed issue,
  and a failed move never stops the pull request. Use when the person says "I published the PR", "the
  draft is ready for review", "mark the story in review", or at Checkpoint Bravo after the publish. Do NOT
  use to publish a draft (only the person does), to close or reopen an issue (the merge closes it through
  Fixes #n), or to write the body of an issue (write-story).
---

# Move a story to in review

Owned by the **Developer** persona. It is an internal step: `implement` and `fix-pr-feedback` run it
when the person says the draft pull request is published. It is the one status move the agent makes
on an issue (clause C09, [ADR 0022](/.claude/skills/ai-sdlc-handbook/references/orchestration.md#the-issue-status)).

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).

## When it moves a story

A story moves to the in-review label only on two facts together:

1. **The person's signal.** The person says in this session that they published the draft. The
   agent never publishes a draft, and a hook refuses `gh pr ready` (ADR 0024).
2. **GitHub's state.** `gh pr view` shows the pull request open and `isDraft` false.

A closed issue is never moved. An issue that already carries the label is left as it is. The label is
`tracker.inReviewLabel` in aisdlc.json, `in-review` by default, so a team can use its own name. The
issue closes on the merge through `Fixes #n`, which GitHub does; this skill never closes or reopens an
issue. The label stays on the closed issue, so the view of waiting work is `is:open label:in-review`.

## Process

1. **Plan.** Run `pwsh .claude/skills/move-story/scripts/Get-StoryMovePlan.ps1 -PullRequest <n> -PersonSaysPublished`.
   It names the stories from the branch (`42-short-name`), the title and each `Fixes #n`, `Closes #n`
   or `Resolves #n` line. It returns one row per issue: `add-label` or `skip`, with the reason. It writes nothing.
2. **Move.** Run `pwsh .claude/skills/move-story/scripts/Invoke-StoryMove.ps1 -PullRequest <n> -PersonSaysPublished`.
   It creates the label when the repository does not have it, adds it, and reads the issue back. Use
   `-WhatIf` to see the writes first.
3. **Report.** Put the summary line in the run summary and the evidence record: each issue moved,
   skipped with its reason, or failed with the error. A failed move is a warning, never a stop.

## Failure modes

- **The agent moves a story before the person published the draft** -> the label then claims a review
  that nobody asked for. The plan skips without the person's signal, and skips while GitHub shows a draft.
- **A closed issue gets the label** -> it shows as waiting work after the merge. The plan never moves a closed issue.
- **A story is named from the conversation** -> the wrong issue moves. Name stories only from the
  branch, the title and the `Fixes` lines, as the plan does.
- **A failed move stops the hand-back** -> the pull request waits on a label. Report the failure and go on.

## Observable signal

**Positive:** every open issue with the in-review label has a published pull request that waits for
review. The agent moved no closed issue.

**Audit trail:** the run summary and the evidence record list each issue with moved, skipped or
failed, and the reason.

**Drift signal:** open issues may keep the label after their pull request went back to a draft. Or
published pull requests may have stories without it. Then the step is skipped or run too early.

## Next steps

- `/fix-pr-feedback` (Developer) - the review threads on the published pull request.
- The person merges the pull request; `Fixes #n` closes the issue.
