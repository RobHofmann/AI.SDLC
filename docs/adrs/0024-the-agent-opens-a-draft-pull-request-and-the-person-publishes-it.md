---
story: "#67"
phase: governance
step: write-adr
intent:
  assumption: "a draft that only the person publishes keeps unchecked agent work out of review and merge"
  decision-drivers:
    - "the agent opened every pull request as ready for review, so others could review work the person had not checked"
    - "the line between the agent's work and the person's sign-off must be plain (clause C09)"
    - "GitHub Actions starts a pull_request workflow on a draft, so the checks still run"
relates:
  constitution: core/.apm/skills/ai-sdlc-handbook/references/constitution.md
  orchestration: core/.apm/skills/ai-sdlc-handbook/references/orchestration.md
  create: packs/github/.apm/skills/github-pull-requests/scripts/New-PullRequest.ps1
  description: packs/github/.apm/skills/github-pull-requests/scripts/PullRequestDescription.psm1
  hook: core/.apm/skills/ai-sdlc-hooks/scripts/Deny-AgentMerge.ps1
  copilot: packs/github/.apm/skills/github-pull-requests/scripts/Request-CopilotReview.ps1
  docs: docs/packages/github.md
because:
  constitution: "clause C09 now says the agent opens a draft and only the person publishes it"
  orchestration: "Checkpoint Bravo is now check, publish, then merge"
  create: "opens the pull request with gh pr create --draft"
  description: "puts the Before you publish block at the top of a draft description, once"
  hook: "refuses gh pr ready and the markPullRequestReadyForReview mutation"
  copilot: "asks Copilot for a review on the draft, at set moments"
  docs: "the technical page of the github package"
---

# ADR 0024: The agent opens a draft pull request, and the person publishes it

**Status:** Accepted
**Date:** 2026-11-26
**Supersedes:** none
**Superseded by:** none

## Context

The agent opened every pull request as ready for review. So a reviewer could read, and the owner could
merge, work that the person who ran the loop had not checked. Clause C09 says an agent never signs off
for a human, but "ready for review" already reads like a sign-off.

GitHub has a draft state. `gh pr create --draft` opens a draft, and `gh pr ready` marks it ready for
review ([gh pr create](https://cli.github.com/manual/gh_pr_create),
[gh pr ready](https://cli.github.com/manual/gh_pr_ready), read on 2026-11-26). A draft cannot be merged
until it is ready. The pull request workflow of this repository runs on the `opened`, `synchronize` and
`reopened` activity types. GitHub sends them for a draft too, so the checks still run
([Events that trigger workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows)).

## Decision

1. **The agent opens every pull request as a draft.** `New-PullRequest.ps1` passes `--draft` and puts a
   `## Before you publish` block at the top of the description, once. The block asks the person to read
   and test the change, and to read the evidence record and the open threads, before they publish.
2. **Only the person publishes the draft.** `Update-PullRequest.ps1` keeps the block while the pull
   request is a draft, and never passes a draft flag. `Deny-AgentMerge.ps1` refuses an agent command that
   publishes: `gh pr ready` (but not `gh pr ready --undo`) and the `markPullRequestReadyForReview`
   mutation through `gh api graphql`.
3. **Checkpoint Bravo is check, publish, merge.** The person checks the draft, clicks Ready for review,
   then merges. Clause C09 says so, and the constitution moves to version 1.1 with the C11 change of
   ADR 0023.
4. **The AI-SDLC update pull request stays published.** `New-AiSdlcUpdatePullRequest.ps1` opens a
   published pull request, because it carries no agent-written code.

## Consequences

**Positive:**

- A reviewer sees only work the person has checked.
- The line between the agent's work and the person's sign-off is plain on the pull request itself.

**Negative:**

- The owner clicks Ready for review before every merge.
- The GitHub docs do not say whether a Copilot review that is asked by hand runs on a draft. If it
  does not, the `fix-pr-feedback` loop gets no Copilot review. The loop then ends on green checks
  and no open bot thread, and says so in the evidence record.
- The hook reads only agent shell commands. A publish in the browser is the person's path and is not
  checked.

## Alternatives considered

1. **Keep opening a published pull request.** Rejected, because "ready for review" then reads like a
   sign-off that no person gave.
2. **A label such as `agent-draft` instead of the draft state.** Rejected, because a label does not stop
   a merge, and GitHub already has the draft state.
3. **Queue the builds by hand on a draft.** Not needed on GitHub, because a `pull_request` workflow
   already runs on a draft.

## Verification

- `New-PullRequest.Tests.ps1` checks the `--draft` argument and the block at the top of the description.
- `Update-PullRequest.Tests.ps1` checks that a draft keeps the block once, and that a published pull
  request gets the description as given.
- `PullRequestDescription.Tests.ps1` checks that the block is added once and moves to the top.
- `Deny-AgentMerge.Tests.ps1` checks that `gh pr ready` and the mutation are refused, and that
  `gh pr ready --undo` and `gh pr create --draft` are allowed.
- By hand: the first draft pull request of this change shows whether Copilot reviews a draft.

## References

- [gh pr create](https://cli.github.com/manual/gh_pr_create) - the `--draft` flag.
- [gh pr ready](https://cli.github.com/manual/gh_pr_ready) - marks a pull request ready for review.
- [Events that trigger workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows) -
  the default activity types of the `pull_request` event.
- [Using GitHub Copilot code review](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/request-a-code-review/use-code-review) -
  how to ask Copilot for a review with `@copilot`.

## Related

- [ADR index](README.md) - the list of decisions in this repository.
- [ADR 0004](0004-two-human-checkpoints-and-one-skill-model.md) - the two human checkpoints this ADR sharpens.
- [github](../packages/github.md) - the package that holds the pull request scripts.
- [core](../packages/core.md) - the package that holds the hook and clause C09.
