---
story: "#69"
phase: governance
step: write-adr
intent:
  assumption: "a label that moves only on the person's publish and on GitHub's state tells a team what waits for review, without a second board"
  decision-drivers:
    - "many people and teams use this framework, not only one owner who merges alone"
    - "a GitHub issue has no status field of its own; open and closed say nothing about review"
    - "a status must move on a fact, never on the agent's own sign-off (clause C09)"
    - "the merge already closes the issue through Fixes #n"
relates:
  constitution: core/.apm/skills/ai-sdlc-handbook/references/constitution.md
  orchestration: core/.apm/skills/ai-sdlc-handbook/references/orchestration.md
  skill: packs/github-issues/.apm/skills/move-story/SKILL.md
  plan: packs/github-issues/.apm/skills/move-story/scripts/Get-StoryMovePlan.ps1
  move: packs/github-issues/.apm/skills/move-story/scripts/Invoke-StoryMove.ps1
  config: core/.apm/skills/ai-sdlc-gates/scripts/AiSdlcConfig.psm1
  docs: docs/packages/github-issues.md
because:
  constitution: "clause C09 names the in-review label as the one status move the agent makes"
  orchestration: "Checkpoint Bravo says when the label moves"
  skill: "the skill that runs the move on the person's signal"
  plan: "plans the move from the person's signal and GitHub's state, and never moves a closed issue"
  move: "creates the label when it is missing, adds it, and reports a failure as a warning"
  config: "tracker.inReviewLabel, in-review by default"
  docs: "the technical page of the github-issues package"
---

# ADR 0022: A published pull request puts its stories in review with a label

**Status:** Accepted
**Date:** 2026-11-26
**Supersedes:** none
**Superseded by:** none

## Context

A GitHub issue has two states, open and closed. It has no field that says "waits for review". Only a
GitHub Projects board adds a status field. The merge of a pull request that says `Fixes #n` already
closes its issue, so the move to done exists.

ADR 0024 makes the agent open every pull request as a draft, and only the person publishes it. So "in
review" has a clear start: the person's publish. Clause C09 says a status never moves on the agent's
own sign-off.

The owner chose the option, with this reason: many people and teams use this framework. So it must
not only fit one owner who merges alone. A team that shares a backlog needs to see which stories wait for
review.

## Decision

1. **A story that waits for review carries a label.** The label is `tracker.inReviewLabel` in
   aisdlc.json, `in-review` by default, next to `refined`. A team can set its own name.
2. **The label moves on two facts together.** The person says in the session that they published the
   draft, and `gh pr view` shows the pull request open with `isDraft` false. The `move-story` skill
   plans the move with `Get-StoryMovePlan.ps1` and applies it with `Invoke-StoryMove.ps1`.
3. **The stories come from the pull request only.** The plan names them from the branch, the title and
   the `Fixes`, `Closes` and `Resolves` lines, never from the conversation.
4. **A closed issue is never moved.** The merge closes the issue through `Fixes #n`; the agent never
   closes or reopens one. The label stays on the closed issue, so the view of waiting work is
   `is:open label:in-review`.
5. **A failed move never stops the pull request.** It is a warning, and the run summary and the
   evidence record name it.

## Consequences

**Positive:**

- A team sees which stories wait for review with one search, without a board.
- The label moves on facts, so it cannot claim a review that nobody asked for.
- A team can use its own label name.

**Negative:**

- A closed issue keeps the label. A search without `is:open` shows done work too.
- The move needs the person to say the draft is published. When they forget, the label does not move.
- The label is created in the repository on the first move, which is a write the team may not expect.

## Alternatives considered

1. **No status move (option A).** The merge closes the issue, and the draft pull request shows on the
   issue page. Rejected, because a team that shares a backlog cannot search for the stories that wait
   for review. It fits one owner who merges alone, not the many teams that use the framework.
2. **A GitHub Projects status field (option C).** Rejected for now. It needs the `project` scope on
   the `gh` login, and the field and its options in aisdlc.json. Its built-in move to done on close
   would fight a second move. A label works in every repository with no setup.

## Verification

- `Get-StoryMovePlan.Tests.ps1` checks that the plan adds the label only with the person's signal and
  `isDraft` false on an open pull request, and never for a closed issue.
- `Invoke-StoryMove.Tests.ps1` checks that a failed move warns, that the summary names it, and that
  the next issue still moves.
- By hand: the first published pull request of a consumer shows the label on its open stories.

## References

- [gh pr view](https://cli.github.com/manual/gh_pr_view) - the `isDraft` and `state` fields.
- [gh label create](https://cli.github.com/manual/gh_label_create) - creates the label when it is missing.
- [Linking a pull request to an issue](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/linking-a-pull-request-to-an-issue) -
  how `Fixes #n` closes the issue on the merge.

## Related

- [ADR index](README.md) - the list of decisions in this repository.
- [ADR 0024](0024-the-agent-opens-a-draft-pull-request-and-the-person-publishes-it.md) - the draft and the publish this move follows.
- [github-issues](../packages/github-issues.md) - the package that holds the `move-story` skill.
