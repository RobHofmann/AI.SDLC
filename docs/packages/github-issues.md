---
units:
  - packs/github-issues
---

# github-issues

The `github-issues` package supports GitHub issue creating, updates, triage, review, conventions, and PR contract checks.

## What it contains

### Draft review agent

The `draft-reviewer` agent lives at `packs/github-issues/.apm/agents/draft-reviewer.agent.md`. It runs on `opus`.

It reviews draft Checkpoint Alpha documents before a person sees them. It checks issues against the definition of ready.

It checks other documents against their node templates. These checks cover evidence, issue anchors, lifecycle headers, and graph links.

It fails a section over its budget and an issue with more than 5 criteria (8 in the old form). It also fails a criterion that names a file, a class, a setting or a rule ID. It also fails an evidence comment that holds a requirement or a decision ([ADR 0023](../adrs/0023-a-story-has-six-sections-with-budgets-at-most-5-criteria-and-ste100.md)).

The agent also asks the Product Manager, QA, and Analyst questions in the `grilling` and `convene-personas` panels. It only reads and reports.

### Skills

- `check-pr-contract` lives at `packs/github-issues/.apm/skills/check-pr-contract/SKILL.md`. It verifies PR links to active issues and required ADRs. It is an internal step that `wrap-up` and `run-preflight` call.
- `fix-bug` lives at `packs/github-issues/.apm/skills/fix-bug/SKILL.md`. It reads the state of an existing bug first. It triages an issue nobody triaged, with a red test on the bug branch, and stops at Checkpoint Alpha. It says what a person must add to a triaged bug that is not refined. It frames the fix of a refined bug and hands off to `implement`.
- `github-issue-conventions` lives at `packs/github-issues/.apm/skills/github-issue-conventions/SKILL.md`. It defines the conventions for drafting, sizing, reviewing, and updating issues. It covers the labels `refined`, `to-refine` and `spike`, a size as a `size:<n>` label, and an epic as a parent issue with sub-issues.
- `write-story` lives at `packs/github-issues/.apm/skills/write-story/SKILL.md`. It creates or drafts issues and derives testable acceptance criteria. It is also the single writer for an existing issue. Its update mode brings an issue in line with what shipped. Other skills call it to record PR links, ADR backlinks, issue links, comments and labels. It also splits an epic into vertical slices, as sub-issues.

- `move-story` lives at `packs/github-issues/.apm/skills/move-story/SKILL.md`. It adds the in-review label to the open stories of a pull request. It does that only when the person says the draft is published and GitHub shows it is no longer a draft ([ADR 0022](../adrs/0022-a-published-pull-request-puts-its-stories-in-review-with-a-label.md)). It never moves a closed issue, and a failed move is a warning. `Get-StoryMovePlan.ps1` plans the move and writes nothing; `Invoke-StoryMove.ps1` creates the label when it is missing, adds it and reads it back.

The story template lives at `packs/github-issues/.apm/skills/write-story/references/story-template.md`.

### The issue form

A new issue has six sections, goal first: goal, background, approach, value, acceptance criteria, and risks. Each section has a budget: at most 3 bullets for the background, the value and the risks, and at most 5 for the approach. A story, bug or task has at most 5 criteria under `✅ Acceptance Criteria`; an epic and a spike have no limit. An issue with the heading `✅ Success Criteria` has the old form, with an ELI5 and at most 8 criteria. Every reader accepts both forms, and an old issue keeps its form unless a person asks.

The body holds conclusions only. Test results, probes and measurements go in one evidence comment per run, which starts with `Evidence YYYY-MM-DD HH:mm`. The one other dated comment is the docs impact of `grilling`, which starts with `📚 Docs impact YYYY-MM-DD HH:mm` and says per docs page what it will say. `write-story` posts both with `gh issue comment` after the Checkpoint Alpha go. The walk carries them into the context block: evidence as context, the docs impact as docs scope. Update mode rewrites a section the agent wrote, and only adds to text a person wrote.

The package configuration lives at `packs/github-issues/apm.yml`.

### Gates

The gate configuration lives at `packs/github-issues/.apm/skills/check-pr-contract/gates.json`.

- `PR-story contract` is blocking in CI and PR runs. It is a no-op locally.
- `Graph: stories backlink their anchoring ADRs` is advisory in CI. It is a no-op locally.

### Scripts and tests

`packs/github-issues/.apm/skills/check-pr-contract/scripts/Check-PrStoryContract.ps1` checks that a PR is anchored to a development-active issue: labelled `refined`, open or closed. A key of another repository, `owner/repo#42`, counts only when `tracker.acceptedRepositories` lists that repository; the gate then reads the issue there. An update pull request uses this for the release issue of AI.SDLC.

A data-model change with no ADR also passes when a commit of the pull request ends with a `No-ADR: <why>` trailer. The gate prints the waiver, and only `wrap-up` writes it, after the `architect` agent agrees.

Its test is `packs/github-issues/tests/skills/check-pr-contract/scripts/Check-PrStoryContract.Tests.ps1`.

`packs/github-issues/.apm/skills/check-pr-contract/scripts/Check-StoryBackEdges.ps1` checks whether an anchoring repository artifact has a backlink from its issue. It reads an ADR only when the change adds or changes the `story:` line of that ADR.

Its test is `packs/github-issues/tests/skills/check-pr-contract/scripts/Check-StoryBackEdges.Tests.ps1`.

`packs/github-issues/.apm/skills/check-pr-contract/scripts/Invoke-IssuePreflight.ps1` provides the issue part of the local pre-flight through the PR-story contract, read with `gh`.
It fails a branch whose name has no issue number (`42-short-name`) before it reads the issue, so that branch never gets a receipt.

Its test is `packs/github-issues/tests/skills/check-pr-contract/scripts/Invoke-IssuePreflight.Tests.ps1`.

## Dependencies

The issue skills use the repository named in `tracker.repository` of `aisdlc.json`, or the git remote when it is empty. The in-review label is `tracker.inReviewLabel`, `in-review` by default.

`github-issue-conventions` covers the issue key (`#42`, or `owner/repo#42` across repositories), the labels, sizes, sub-issues, duplicate scans, and readiness checks.

The `draft-reviewer` agent uses `github-issue-conventions` when it checks a draft.

`core/tests/skills/ai-sdlc-gates/scripts/StoryTemplate.Tests.ps1` checks the six headings of the template, the budgets and the limit of 5 criteria. It also checks that the readers name both criteria headings.

`check-pr-contract` reads the PR and substrate. `wrap-up` runs it inside `run-preflight`, before the pull request opens.

## Changing it safely

Keep `draft-reviewer` read-only. It must never create, edit, or comment on an issue or a page.

Keep `check-pr-contract` read-only. It must never edit the PR, the issue, or code.

Preserve its rule that it never passes blind. When the issue cannot be read, the session form reports BLOCKED and the CI form exits 2, a warning.

Keep the blocking and advisory gate scopes defined in `gates.json`. Both gates must remain no-ops in their stated local contexts.

Update the matching `*.Tests.ps1` file when changing a gate script.

Keep issue responsibilities separate. `write-story` creates issues and is the only skill that changes an existing one, through its update mode.

Keep `fix-bug` a thin entry point. It triages and frames the fix; `implement` builds it.

## Related

- [How AI.SDLC is built](../overview.md) - where this pack sits among the packages.
- [core](core.md) - the package every repository installs next to this one.
- [github](github.md) - the forge pack every repository installs next to this one.
- [Index](../index.md) - every page of this layer.
