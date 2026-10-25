---
name: refactor
kind: workflow
phase: create
persona: Developer
description: >
  Improve the internal structure of existing code without changing its observable behaviour: the
  tests pass before and after, and the public contract is unchanged. Use when the user says
  "refactor this", "clean this up", "simplify this", "extract a method/class", "rename for
  clarity", "reduce this duplication" or "tidy this without changing behaviour". Do NOT use to add
  or change behaviour, fix a bug or build a feature (implement). Do NOT use to delete dead code as
  the primary goal.
---

# Refactor

Owned by the **Developer** persona (the refactor step). Called as `/refactor`.

Improve the internal structure of code that already works, **without changing what it does**.
The whole skill turns on one limit: observable behaviour and the wire contract stay
the same. The proof is the tests, run green before you start and green again after every step.
You may want to change a return value, a status code, a JSON shape, or any externally visible
behaviour. That is a feature or a fix, not a refactor: stop and use `implement` instead.

A code rot finding is a trigger for a refactor story. The `code-reviewer` agent (dotnet pack) marks it
`ROT`. It is a fix on top of an earlier fix in the same area. Or it is a second implementation next to
one that does the same job. Do not fold it into the change under review. Raise it as its own story, and refactor
it here.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).

## Reuse the agent's refactor ability

Do not re-implement refactoring mechanics here. Drive the change through your agent's own refactor
flow. Let this skill enforce the rule around it: the safety net, the review and the constitution
check. This skill's job is the guardrails, not the edits.

From the start to the open pull request the work runs on its own, as
[orchestration.md](/.claude/skills/ai-sdlc-handbook/references/orchestration.md) describes, and stops only on its stop list.

## Workflow

1. **Scope it.** State precisely what structure changes and why (readability, copying,
   coupling), and what stays the same. The behaviour and the public surface are out of scope to
   change. Keep it small; one structural intent per pass. Every refactor has a work item. When there
   is none yet, `/write-story` makes one first. The loop runs on its own only when the work item
   carries the `refined` label and a `size:<n>` label. That is the start condition of `implement` (see
   orchestration.md), read with `gh issue view <n> --json labels,state`. Without both, stop and say what a person must add to the issue. Make sure the
   substrate walk has run for it (call `walk-substrate` if no block exists in this thread). Then you
   move code with the governing ADRs and recent activity in the area in view.
   Before the first change, put the work on a branch named with the story key, such as
   `42-refactor`. When you are not on a branch named with a story key, create it from the current
   state (`git switch -c <number>-<topic>`); the work moves with it. When you are on one, stay on it.
   Start from an up-to-date base, and never refactor on `main`.
   `wrap-up` commits on that branch, and its step 0 stops on a branch with no story key.
2. **Establish the safety net (green BEFORE).** Run the tests for the affected projects and confirm
   they pass before touching anything (the test command, `commands.test` in aisdlc.json, or the
   narrower project).
   Check this; do not assume it. Coverage over the code you are about to move may be thin. Then
   **write pinning tests first** that pin the current behaviour, and get those green before refactoring.
3. **Change in small steps.** Make one structural move at a time (pull out, rename, inline, split,
   dedupe). Re-run the tests that cover it after each, so a break is localised to the last step. Prefer
   many small checked steps over one large rewrite. A doc comment moves with its member. A comment
   that only said what the old code did is dropped, and so is commented-out code (C10).
4. **Check (green AFTER).** Run the full affected test suite again. It must pass with no test
   assertions changed to accommodate new behaviour. If a behavioural test needed editing, behaviour
   moved and this is no longer a refactor. Total coverage must not drop below the recorded baseline,
   and new lines target >= 80% in SonarCloud (C04). A refactor preserves behaviour, so it should not move either figure much; a drop means a test stopped exercising something.
5. **Confirm contracts held.** The public API is the same, and no clause in `AGENTS.md` is newly
   broken. That covers the core clauses and the repository's own clauses. It also covers the clauses of
   the installed packs, for example the PascalCase wire format, DOTNET-01, and thin controllers, DOTNET-02.
6. **Review.** Nothing is committed yet, so build the diff from the working tree. Run
   `git add --intent-to-add .`, so new files show, then write
   `git diff $(git merge-base origin/main HEAD)` to `temp/review.diff`, since the reviewers have no
   shell. Hand it to the review agents of the installed packs side by side, for example
   `code-reviewer` and `test-analyzer` from the dotnet pack. Both run on Sonnet 5.5 (model `sonnet` in
   Claude Code, `claude-sonnet-5.5` in Copilot).
   If you cannot run agents, load the stack
   skills of the installed packs, such as `csharp-generation-smells` and `test-first-dotnet`, and
   review the diff yourself. Add `security-reviewer` (dotnet pack) on Opus 5.5 (model `opus` in Claude Code, `claude-opus-5.5` in Copilot)
   when the diff touches auth, RBAC,
   outbound calls, JS interop or request logging. If you cannot run agents, load
   `blazor-authorization` (blazor pack) and review that part yourself. Fix each finding or decline it with a reason, and run the checks again. A finding tagged
   `[HIGH][DESIGN]` needs a design change: stop and ask, do not loop on it.
7. **Wrap up, push, PR.** Write the evidence record in `temp/`. It holds the tests green before and
   after, every check result and every finding fixed or declined. It also says whether each review ran
   in an agent or inline. Then run `wrap-up`, the single owner of the rest of the change. It runs
   `write-docs` (with the `docs-reviewer` agent) when the move changed a name a docs page cites, and the
   ADR check through `write-adr`. It runs the lessons step, commits, and runs `run-preflight` on that
   commit until it is green, which writes the receipt the push hook asks for. Do not run any of those
   steps here. Then push the story branch, and open or update the pull request with the evidence record as its
   description. This runs on its own and with no prompt, through the pull request skill of the
   installed pack (`github-pull-requests`). Use `New-PullRequest.ps1` for a new pull request, or
   `Update-PullRequest.ps1` for one that is open. Never
   push to `main` or `master`. Then hand the PR to `fix-pr-feedback` (github pack) in loop mode. It works the PR
   checks and the bot review threads until no bot finding is open. Checkpoint Bravo is the person's review of that
   pull request; a person merges.

## Guardrails

- **Behaviour preservation is the contract.** Green before, green after, no behavioural test rewritten.
  If you cannot keep the tests green without changing what they assert, this is not a refactor.
- **No behaviour-adding "improvements".** Stay scoped to structure. New validation, new fields, changed
  responses, or "while I am here" fixes belong in `implement`, not here.
- **Honour the constitution.** C04 (coverage), the clauses of the installed packs (such as DOTNET-01
  and DOTNET-02) and the repository's own clauses in `AGENTS.md` must survive the refactor intact.
- **Usually no new graph artifact.** A refactor opts nothing new into the artifact graph; it changes
  structure, not work products. The refactor may carry a key structural decision (a new
  boundary, a pattern swap). Name it in the evidence record, so the ADR check in `wrap-up` records it
  through `write-adr` rather than burying it in the diff.
- **Check before asserting.** "The tests pass" and "behaviour is the same" are claims you confirm by
  running the suite, not by inspection.
- **Never sign off** ([C09](/.claude/skills/ai-sdlc-handbook/references/constitution.md)). A person reviews the pull request at Checkpoint Bravo and merges.

## Failure modes

- **A test has to change its assertion to stay green** -> this is not a refactor. Either the behaviour moved, in which case it belongs in `/implement`, or the test was asserting an implementation detail, which is itself the finding.
- **The area has no tests to preserve behaviour with** -> write the pinning tests first, against the current behaviour, and only then restructure. Refactoring untested code is rewriting it and hoping.
- **A "while I am here" fix slips in** -> new validation, a changed response, a corrected off-by-one. Each is behaviour, and each makes the diff unreviewable as a refactor. Note it and raise it separately.
- **Coverage falls because dead branches were removed** -> say so explicitly rather than adding tests to restore the number. The ratchet (C04) is a floor on the whole line count; a real drop from deleting code needs a human decision, not a workaround.
- **The restructure changes a boundary or swaps a pattern** -> that is a key decision. Record it as an ADR rather than leaving it to be worked out from the diff.
- **A constitution clause is broken in passing.** A moved log call drops the required logging helper,
  or a renamed property changes the wire name. The pack and repository clauses and C04 must survive
  the move intact.
- **Dead code is found** -> note it, do not delete it as part of the refactor. Deleting is a separate decision with its own reviewer.
- **A reviewer finding is declined without a reason** -> the person at Checkpoint Bravo cannot see the triage. Every declined finding goes into the evidence record with its reason.

## Observable signal

**Positive:** the same test suite passes before and after with no assertion touched. The next change in that area is smaller than it would have been. If neither is true, the refactor did not earn its diff.

**Audit trail:** the commit is the receipt, and its value is that it contains only structure. A refactor commit that also changes behaviour destroys the ability to bisect a later bug to the behaviour change. The evidence record says whether each review ran in an agent or inline.

**Drift signal:** if refactors keep needing test edits, the tests are coupled to implementation and that is the real problem to fix. If the same area keeps being refactored, the boundary is wrong and wants an ADR rather than another cleanup.

## Next steps

- `/fix-pr-feedback` (Developer) - works the PR checks and the bot review threads after the push, in loop mode, then returns to Checkpoint Bravo.
- `/wrap-up` (Developer) - step 7: the docs, the ADR check, the lessons, the commit and the pre-flight,
  which confirms coverage held after the move.
