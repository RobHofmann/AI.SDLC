---
name: github-pull-requests
kind: knowledge
user-invocable: false
description: >
  How a pull request is opened and checked on GitHub, in the repository named in aisdlc.json or read
  from the git remote. It covers gh auth login rather than a token in a file, the gh CLI with gh api for
  REST and GraphQL, and the helpers New-PullRequest.ps1 and Update-PullRequest.ps1. It also covers the
  description traps and the read-back, the gh errors, and linking the PR to its issue. Use whenever a
  pull request is opened or updated, also on a plain request such as "open the PR for my branch" or
  "create the pull request". Also use when a gh call fails on auth, or when checking that a PR path
  works before the build starts. Do NOT use for the build that leads to the PR (implement, which opens
  it at the end of its loop). Do NOT use to work the review threads (fix-pr-feedback) or to edit the
  story's title, description or links (write-story).
---

# GitHub pull requests

Use this at the PR preflight and at the end of the loop. `implement`, `refactor`, `fix-pr-feedback`, `adopt-docs`,
`write-platform-note`, `write-pipeline`, `write-prd`, `write-hypothesis`, `draw-customer-journey` and
`write-research-summary` load it before they push, and `fix-bug` through `implement`. After a standalone run, `write-adr`,
`update-constitution`, `write-docs`, `add-gate`, `capture-learning` and `write-api-spec` load it too. The push and the pull request run with no prompt. Checkpoint Bravo is the person's review of the pull request on GitHub ([orchestration.md](/.claude/skills/ai-sdlc-handbook/references/orchestration.md)).
A push to `main` or `master` is always refused. The link from the PR to its story is a tracker update, so it joins the
one list of tracker updates for the run. The agent opens the pull request as a request for review; it never
approves, reviews with approval, or merges one (C09). A hook refuses `gh pr merge` and a merge call through `gh api`.

## The constants

- Read the repository from `github.repository` in aisdlc.json (`owner/name`); when it is empty, `gh` reads the git remote.
- Read the main branch from `github.trunk` in aisdlc.json, `main` by default.
- Pass `--repo <owner/name>` on a `gh` command when the repository is set; the scripts do this for you.

## Sign-in and tooling

- Sign in with `gh auth login`. Check it with `gh auth status`. Do not keep a token in a file.
- Use the `gh` CLI: `gh pr`, `gh run`, `gh issue`, and `gh api` for an endpoint with no command of its own,
  such as review threads (GraphQL) or rulesets (REST).
- `scripts/Initialize-GitHub.ps1` is the setup step of this pack. It checks that `gh` is installed and
  signed in, and gives a WARN row with the command to run when it is not. It never fails the setup.
- An auth error (`HTTP 401`, `gh auth login` in the message) means a new `gh auth login`, not a token.

## The preflight, before the first code change

Check that a working PR path exists before you build, so the last step cannot dead-end. Try in order,
and record which one works:

1. **The helper `.claude/skills/github-pull-requests/scripts/New-PullRequest.ps1`** (entry function `New-PullRequest`),
   backed by `gh`, the normal path. First run `gh auth status` and `gh repo view`.
2. **The GitHub MCP**, only if it can really write to this repository. It runs with its own token;
   a `403` means that token lacks write access, and `gh auth login` does not fix it. Skip the MCP for repo writes then.
3. **The browser URL**, as the last fallback:
   `https://github.com/<owner>/<repo>/compare/main...<branch>?expand=1`.

## Opening the pull request

- Call the helper from PowerShell, not from bash with a `@'...'@` here-string; bash lets the `@` markers slip into the description.
- The helper passes the description as a file (`gh pr create --body-file <file>`). It reads the PR back
  with `gh pr view --json`, and throws on a lost line, a cut-off or an empty description.
- The description is the evidence record from `temp/`. It holds each acceptance criterion with its
  test and every check result. It also holds every review finding, fixed or declined with the reason,
  the ADRs, and what was not checked. It ends with a `## Merge danger` part: the door (one-way or
  two-way) and the blast radius in one word, as the evidence record in orchestration.md shows.
- The description says `Fixes #42` for the story of the branch, so GitHub links the PR to the issue and
  closes it on the merge. The helper reminds you when the line is missing.
- Nothing in the title, description, branch or commits names an AI tool.

## If you call gh directly

- `--body` with one multi-line string can lose lines or quotes on the way through the shell. Use
  `--body-file <file>`, and stay under the 65536 characters that GitHub takes.

## The read-back

Read the PR back with `gh pr view <number> --json number,url,title,body` and measure the body in
PowerShell. `gh pr list` shows no body, so it cannot prove anything. An empty, title-length or
first-heading-only description is a hard failure: fix it with `Update-PullRequest.ps1` before you go on.

**The title and the description are the agent's to keep true, at any time, with no prompt.**
`scripts/Update-PullRequest.ps1 -Id <number>` takes `-Title`, `-Description` or both, applies the rules
above, and reads the result back. It passes nothing else to `gh pr edit`, so it can never add a reviewer,
change the base or mark the pull request ready. Keep `gh pr edit` itself behind a prompt. Use it when the
branch has an open pull request already: `New-PullRequest.ps1` only calls `gh pr create`, which fails on a second one.

## After the pull request is open

The PR feedback loop uses two scripts, both signed in through `gh auth login`:

- `Get-PullRequestFeedback.ps1 -Wait` waits for the checks of the head commit (`-ReturnOnReview`: also for a
  bot review thread on that commit). Then it lists the unresolved review threads tagged `sonarcloud`, `gitleaks`,
  `bot` or `human`, the failed checks with their run id, and the new bot comments. It reads every page.
  With no check on the head commit yet, it waits 3 minutes (`-NoCheckGraceMinutes`), then says `ready` with a `Note`.
- `Reply-PullRequestThread.ps1` answers a thread through GraphQL. `-Resolve` resolves only a `sonarcloud` or
  `gitleaks` thread; a person's thread or another bot's thread is never resolved (C09).

An author is a bot when its login ends in `[bot]`, such as `github-actions[bot]` or `sonarqubecloud[bot]`.
They and `Wait-WorkflowRun.ps1` share `PullRequestFeedback.psm1`: it makes the `gh` calls and tells which source a
thread came from. For any other workflow run, wait with `Wait-WorkflowRun.ps1 -RunId <ids> -Wait`, never a sleep loop.
It says `approval` when a run waits for a reviewer of an environment; that is a person's step.

Check that the story shows its PR: GitHub links them through `Fixes #42`. Otherwise put the PR URL on the story
through `write-story` in update mode (github-issues pack). The change is not done while the story does not show its PR.

A new repository sets its branch ruleset once, after the first workflow run, with `Set-BranchRuleset.ps1
-RequiredCheck <names>`. The ruleset on the default branch asks for a pull request with zero required approvals and
the named status checks. It also blocks a force push and a deletion. The owner's merge is the approval. `-WhatIf` shows the change first.

## Sources

- [Delivery metrics](references/delivery-metrics.md) - what `Get-PrMetrics.ps1` counts about the pull requests, and how to read it.
- [Orchestration](/.claude/skills/ai-sdlc-handbook/references/orchestration.md) - Checkpoint Bravo, the evidence record and the PR feedback loop.
- [Run pre-flight](/.claude/skills/run-preflight/SKILL.md) - what runs before the push.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).
