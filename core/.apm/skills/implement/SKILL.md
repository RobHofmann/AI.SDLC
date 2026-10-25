---
name: implement
kind: workflow
phase: create
persona: Developer
description: >
  The one way a change to product code is built here, from a refined story to a tested pull request.
  It runs on its own between the two human checkpoints: walk, plan (architect agent), branch, API contract
  when an endpoint moves, test-first build (builder agent), review by agents, wrap-up, push and open
  the PR. Then it loops on the PR checks and the bot review threads until no bot finding is open, and
  waits at Checkpoint Bravo. Use whenever a request means writing or changing code, however it is phrased:
  "implement #42", "add a field to the order", "fix this bug", "make the portal show X", "build
  this", or when guide-me reports that the next step is the build. Do NOT use for a question, or for
  a change that touches no code such as documentation. Do NOT use for a pure refactor (refactor), for
  a standalone git request (a branch, a commit, a rebase), or to triage or start the fix of a bug
  already in GitHub Issues (fix-bug).
---

# Implement (the build loop)

Owned by the **Developer** persona. Called as `/implement`.

This skill is a lead, not a performer. It runs the build loop and hands each step to the skill or
agent that owns it. The main session walks, plans through the `architect` agent, builds through the
`builder` agent and reviews through the review agents. Then it runs `wrap-up`, which owns the docs,
the ADR check, the story, the lessons, the commit and the pre-flight. Then it pushes and opens or updates the pull
request itself. Each agent runs on its own model, so the session model matters
less: Sonnet is enough for the main session. It stops for a person only on the stop list, or at Checkpoint Bravo, the review of the pull
request it opened. The gates, the stop list and
the evidence record are defined once in
[orchestration.md](/.claude/skills/ai-sdlc-handbook/references/orchestration.md); this file follows them.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).

## The one entry for code

Every change to product code that adds or changes behaviour enters here. That is a plain request, a
`guide-me` report whose next step is the build, or a bug that `fix-bug` framed. A change that keeps the behaviour
enters through `refactor`. Do not edit product code inline from another skill or a plain request. The first usage report found this skill named by 16
others and run twice, while `wrap-up`, the repair for a change that skipped it, ran seven times.

## Start condition

Read the story first, with `gh issue view <n> --json title,body,state,labels,comments`. The loop runs
on its own only when the issue is open and carries the `refined` label and a `size:<n>` label.
Without both, stop and say what is missing: a story nobody refined has no agreed scope.
With no user story at all, run `write-story` first; it ends at Checkpoint Alpha. The same condition holds
for a bug that `fix-bug` hands over: a person refines the issue.

**Light path:** a change you can state in one sentence, inside one component, with no HTTP surface, no
data-model change and no new dependency. Skip the story file and the written plan; every other step
applies. **Full path:** everything else, and the default when you are not sure. When a light change
grows, switch to the full path.

## The loop

1. **Walk.** Hand the context walk to the `substrate-walker` agent on Sonnet 5.5 (model `sonnet` in Claude Code, `claude-sonnet-5.5` in Copilot).
   If you cannot run agents, run
   `walk-substrate` yourself. When the block says the agent could not read every comment, read them
   as `walk-substrate` says before the plan. Reuse a context block this thread already has. For a story of about 5
   points or more, or one that touches more than one component, write `docs/stories/<KEY>.md` (the issue number without `#`, such as `docs/stories/42.md`) from
   `references/story-context-template.md`. Link it from the area page it changes, and run `Build-DocsIndex.ps1`.
2. **Plan.** Hand the context block to the `architect` agent on Opus 5.5 (model `opus` in Claude Code, `claude-opus-5.5` in Copilot)
   to write the plan. The plan names the files to change, and every member of any closed set the change
   branches on. It also names the seams the tests go through, and the reuse the walk found. The agent returns the plan as text. Save it where the
   plan lives: the `## Tasks` section of `docs/stories/<KEY>.md` when the story has that file,
   otherwise this thread. If you cannot run agents, load `adr-conventions`, write the plan yourself
   and check it against the ADRs. A conflict with an ADR or clause is a stop.
3. **Branch.** Create the branch named for the story key (`42-short-name`) from an up-to-date base, unless you are
   already on it. Use `git switch --no-track -c <branch> <base>` so the new branch does not track the base.
   On its first push, use `git push --set-upstream origin <branch>`.
   Check that its upstream is `origin/<branch>`, never the base branch.
   Never build on `main`. Load the pull request skill of the installed pack
   (`github-pull-requests` in the github pack) and run its preflight now, so Checkpoint Bravo cannot
   dead-end.
4. **Contract.** When the change touches an HTTP surface, run `write-api-spec` (dotnet pack)
   before the code. Otherwise, or when that skill is not installed, say that no contract was written.
5. **Build test-first.** Hand the plan and the context block to the `builder` agent
   on Sonnet 5.5 (model `sonnet` in Claude Code, `claude-sonnet-5.5` in Copilot). It writes the failing test, sees it fail and makes it
   pass, then reports what it changed and the test result. Read its report and the diff before the
   next step. If you cannot run agents, or the agent cannot write files (as in Copilot CLI with
   `copilot -p`), do the build in this session. In that case, load the stack skills of the installed packs, for
   example `test-first-dotnet` and `csharp-generation-smells` from the dotnet pack. Either way, tag
   each new test with the story key. Document the code as [C10](/.claude/skills/ai-sdlc-handbook/references/constitution.md) asks. Keep the build green with no new analyzer warnings on changed
   projects.
6. **Check.** Run the tests that map to the changed files, and
   `pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1 -SkipTests`, until green. A changed test
   file runs itself. A changed script runs the test file next to it, and a changed project runs its test
   project. Run the full test command instead (`commands.test` in aisdlc.json) when a changed
   code file maps to no test. Do the same when a shared module or the test runner changed. The full pre-flight runs
   once inside `wrap-up` at step 11, with the full test run, the analyzer rules, the coverage ratchet and
   gitleaks. So nothing that the build loop leaves out reaches the push untested.
7. **Review.** Nothing is committed yet, so build the diff from the working tree. Run
   `git add --intent-to-add .`, so new files show, then write
   `git diff $(git merge-base origin/main HEAD)` to `temp/review.diff`, since the reviewers have no
   shell. Hand it to the review agents of the installed packs side by side, for example `code-reviewer`
   and `test-analyzer` from the dotnet pack. Both run on Sonnet 5.5 (model `sonnet` in Claude Code, `claude-sonnet-5.5` in Copilot). Add
   `security-reviewer` on Opus 5.5 (model `opus` in Claude Code, `claude-opus-5.5` in Copilot) when the diff touches auth, RBAC,
   outbound calls, JS interop or request logging. If you cannot run agents, or no pack ships a
   reviewer, load the stack skills and review the diff yourself. For a diff that touches auth, RBAC,
   outbound calls, JS interop or request logging, also load `blazor-authorization` (blazor pack) when it
   is installed. Then say in the evidence record that the review ran inline. Fix each
   finding or decline it with a reason, then check again. Run `update-constitution` in check mode.
8. **Wrap up and record.** Write the pull request description in `temp/` in the evidence record shape
   from orchestration.md. Then run `wrap-up`, the single owner of the rest of the change. It searches
   the repository for what the change renamed or removed. It runs `write-docs` for both doc layers,
   with the `docs-reviewer` agent, and the ADR check through `write-adr`. It brings the story and the
   pull request contract in line, and runs the lessons step. It ends by committing and running
   `run-preflight` on that commit, so a green run writes the receipt `temp/preflight/<tree>.json`. Do
   not run any of those steps here, before or after it: a second commit has no receipt, and the push
   hook refuses it.
9. **Push, pull request.** Push the story branch that `wrap-up` committed. Open the pull
    request through the pull request skill of the installed pack (`New-PullRequest.ps1` in
    `github-pull-requests`), or update the one that is open (`Update-PullRequest.ps1`). The script
    opens it with your own `gh` login, and its body says `Fixes #42`. No
    confirmation: Checkpoint Bravo is the review, not the push. Never push to `main` or `master`; the push hook
    refuses it. Check the read-back. Then add the PR URL for the story to the run's list of issue
    updates (`write-story` in update mode, github-issues pack), which the person confirms once.
10. **Work the PR feedback.** Hand the PR to `fix-pr-feedback` (github pack) in loop mode.
    It waits for the PR checks and the review bots. It fixes and pushes until no bot finding
    is open. Then Checkpoint Bravo: a
    person reviews the PR on GitHub and merges it. The merge is the approval; the agent never merges.


## Stop and ask

Stop, say why, and wait on any condition on the stop list in orchestration.md:

- an unclear story, or a clause or ADR conflict;
- no convergence: 3 fix attempts on one check, 2 review rounds without progress, or a fourth round;
- scope growth;
- a secret, permission, production, deploy or destructive git need;
- a finding tagged `[HIGH][DESIGN]`.

A new ADR that follows an existing pattern is not a stop.

## Guardrails

- **Delegate, do not reimplement.** Each step calls its owning skill or agent. If one is missing, do
  the step yourself and keep the order.
- **Never sign off** ([C09](/.claude/skills/ai-sdlc-handbook/references/constitution.md)). Never approve, vote on, complete or merge the pull request.
- **Never deploy.** A deploy is a human act.
- **Do not skip `wrap-up`.** It holds the docs and the decisions, the two most skipped steps. The push
  deny catches a change without it: run `wrap-up` when it fires, and never skip the push hooks.

## Failure modes

- **The build starts from a story without the `refined` label or a `size:<n>` label** -> the loop guesses at
  scope and asks on every step. Stop at the start condition. Route a story to `write-story`,
  and ask a person to refine a bug issue.
- **An endpoint changed and no spec was written** -> code and contract drift apart. Run
  `write-api-spec` (dotnet pack) at step 4 or say plainly that no HTTP surface moved.
- **A reviewer finding is dropped without a word** -> the person at Checkpoint Bravo cannot see the triage.
  That failure ended an automatic AI review in CI. Every declined finding goes in the evidence
  record with its reason.
- **The loop keeps fixing the same check** -> after 3 attempts on one check it stops and asks. A
  fourth review round is a stop, not a retry.
- **The tests are written after the code to match it** -> they encode the bug; the failing test comes first.
- **Coverage drops below the baseline** -> add tests; never move the baseline in the same change.
- **The PR description comes back cut off** -> issue the corrective update (`github-pull-requests`).

## Observable signal

**Positive:** a person acts twice: at Checkpoint Alpha on the story, and at Checkpoint Bravo on an open pull request. That
pull request already carries its tests, both doc layers, its ADRs and an evidence record with every
finding.

**Audit trail:** the branch names the story, and the story names the PR. The evidence record names
each review and whether it ran in an agent or inline.

**Drift signal:** if runs keep stopping on "no convergence", the stop limits or the reviewer agents need
tuning. If the push deny keeps firing, `wrap-up` is being skipped. If rework per pull
request rises in the delivery metrics (`Get-PrMetrics.ps1` in the github pack), the reviewers
are not precise enough.

## Next steps

- At Checkpoint Bravo a person reviews the pull request; `/fix-pr-feedback` (Developer) works the findings
  and pushes the update, which returns to Checkpoint Bravo.
- After merge, `/fix-bug` (PM, Developer) for follow-up defects.
- If a reviewer reworked a lot of the output, `/capture-learning` (Lead), from the pull request.
- Each step skill also runs standalone: `/write-story`, `/write-api-spec`,
  `/write-docs`, `/write-adr`, `/wrap-up`. `/write-story` brings a story in line with what shipped,
  through its update mode.
