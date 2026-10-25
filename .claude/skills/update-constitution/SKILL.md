---
name: update-constitution
kind: workflow
phase: cross-cutting
persona: Lead
description: >
  Create, amend or check the project's governing "constitution": the small set of non-negotiable
  engineering principles that every agent run (Claude Code and GitHub Copilot) should honour.
  Use when the user says "create/set up a constitution", "add a rule/principle to the
  constitution", "amend/update the constitution", "make this a non-negotiable", "what are our
  project principles", or asks to bootstrap the AGENTS.md contract; and in check mode when the
  user says "check my changes against the constitution", "does this violate a clause",
  "constitution check" or "review this for constitution compliance". Do NOT use to author a single
  architectural decision (write-adr) or to validate doc or graph link integrity
  (Invoke-LocalGates.ps1). Do NOT use for ordinary docs or for editing tracker work items.
---

# Constitution

Owned by the **Lead** persona (custodian of the contract and graph integrity). Called as `/update-constitution`.

Create and maintain a project's **constitution**: a short list of non-negotiable principles. They
govern how the team and its AI tools (Claude Code + Copilot) build software. The constitution is the
spine of the AI-SDLC contract. It works only if it is **small, always-loaded, and every clause is
enforceable**. A long text document that no tool loads and no check enforces is worse than nothing,
because it creates false confidence.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).

## Where it lives and how it loads (do not get this wrong)

The contract is split into an always-loaded core and on-demand detail. This split is
key for token cost, so respect it:

| Part | Lives in | Load policy |
|---|---|---|
| **Constitution core** (clause statements only, one line each; keep the repository clauses to about 12) | `AGENTS.md`: the core between its `ai-sdlc` markers, written by `Sync-AgentsFile.ps1`; the repository clauses outside them | **Always-on, by design.** Read natively by Copilot; by Claude via the `.claude/CLAUDE.md` import. Keep the repository part tiny. |
| **Full constitution** (each clause's rationale, enforcement, history) | the constitution page (`paths.constitution`) | **On demand.** Read only when someone needs the detail. |

Why not import the full file into context? In Claude Code, `@import` is **eager** (it
loads at launch and does not save tokens), and Copilot cannot import at all. So the
core must physically sit in `AGENTS.md`, and the detail must stay a separate on-demand
file. Never `@import docs/constitution.md` or the ADRs into `CLAUDE.md`/`AGENTS.md`.

In this skill, the constitution page is the repository's page in `paths.constitution` of aisdlc.json,
`docs/constitution.md` by default.

## Clause IDs: core, pack and repository

A clause has one home, and its ID says which:

| ID | Home | Where the full text lives | How it changes |
|---|---|---|---|
| `C<NN>` | core, every repository | the [handbook constitution](/.claude/skills/ai-sdlc-handbook/references/constitution.md) | A pull request on AI.SDLC, never a local edit |
| `<PACK>-<NN>`, for example `DOTNET-01` | a pack | a `references/` page of that pack | A pull request on AI.SDLC |
| `<REPO>-<NN>`, a prefix the repository picks | this repository | the constitution page (`paths.constitution`) | The amend workflow below |

- A retired number is never reused. A clause that moves out of core gets a new ID in its pack or its
  repository, and the old C number stays retired.
- `Sync-AgentsFile.ps1` writes the core and pack parts into `AGENTS.md` between
  `ai-sdlc:<package>:start` and `ai-sdlc:<package>:end` markers. Never edit between them by hand;
  the repository's own clauses go outside the markers.
- A core clause has one source (C12): its section in the handbook constitution, with a
  `- **Short form:**` bullet. In AI.SDLC, add or change a core clause there only. The core part of
  `AGENTS.md` imports that page with an `@` line, so never copy a clause into `AGENTS.md`.
- Before you amend, decide which home the clause belongs to. A rule that holds in every repository
  is core or pack; a rule about this repository's code, names or cloud setup is a repository clause.

**Claude reads `CLAUDE.md`; recent Claude Code also reads `AGENTS.md`.** So `.claude/CLAUDE.md` holds
`@../AGENTS.md` (an import line), and Claude picks up the core in every version. Keep that import out of
a root `CLAUDE.md`: GitHub Copilot reads a root `CLAUDE.md` and its import too, and then loads
`AGENTS.md` twice. On Windows use the import line, not a symlink (symlinks need admin). Copilot reads
`AGENTS.md` directly.

## Modes

Spot which the user wants; ask if unclear.

- **create** - bootstrap a constitution for a repo that has none.
- **amend** - add, change, or supersede a clause in an existing constitution.
- **check** (read-only) - review proposed or recent changes against the constitution and report violations. No writes.

## Clause format

Every clause is a testable, non-negotiable rule. In the constitution page (`paths.constitution`) each clause carries:

```
### <REPO>-<NN>: <short imperative statement>
- **Statement:** <the rule, one sentence, verifiable not vague>
- **Rationale:** <why this is non-negotiable here>
- **Enforcement:** <mechanism> - <status>
    mechanism = CI gate | linter | hook | skill | code review (manual)
    status    = active | deferred (planned: <what + where, e.g. "CI coverage gate">)
- **Added:** <YYYY-MM-DD>  **Version:** <bump on change>  **Supersedes:** none | <ID>
```

The repository clauses in `AGENTS.md`, outside the markers, carry only the one-line rule per clause (so the always-on cost stays minimal). Detail lives in the constitution page (`paths.constitution`).

**The enforcement field is mandatory.** A clause with no enforcement is the "constitution
as text" anti-pattern. If the gate does not exist yet, record it as `deferred (planned: ...)`
so it is a tracked debt, not a wish. This is what lets the gate phase attach later.

Good clauses are concrete: "Total line coverage must not drop below the recorded baseline",
"Every Bicep module reference pins an explicit version tag (no @latest)", "Key
architectural decisions need an ADR in the ADR folder before merge". Avoid "write clean
code" style non-clauses.

## create workflow

1. **Seed from what exists, do not invent.** Read the repo's current standards and lift the real, already-followed rules: `CLAUDE.md`, `AGENTS.md`, `.github/copilot-instructions.md`, the conventions pages, any ADRs in the ADR folder (`paths.adrFolder`). The constitution should ratify the team's real non-negotiables, not force new ones.
2. **Interview for the gaps.** Briefly confirm the candidate clauses with the user and ask what else is truly non-negotiable (security, coverage, naming, decision-recording, deployment safety). Keep pushing items that are "nice to have" out of the constitution and into conventions or docs.
3. **Draft both artefacts.** Write the constitution page (`paths.constitution`) (full, every clause with rationale + enforcement) and the repository clauses in `AGENTS.md`, under a `## Repository clauses` heading outside the `ai-sdlc` markers (statements only). Keep it short; if there are more, the extra ones probably belong in path-scoped conventions, not the constitution.
4. **Wire the loaders.**
   - If `AGENTS.md` does not exist, create it with a short project-facts section and the repository clauses, outside the markers. Add a `## Where the detail lives` pointer block (to the constitution page (`paths.constitution`), the ADR folder, conventions).
   - Make sure Claude reads `AGENTS.md` through `.claude/CLAUDE.md` (see "Handling an existing CLAUDE.md").
   - Remove `.github/copilot-instructions.md` only if its content has been folded into `AGENTS.md` (Copilot reads `AGENTS.md`); otherwise leave it and note that they cover the same ground.
5. **Confirm the diff before writing**, then write. Report what loads always (the core) vs on demand.
6. **Hand the work to a pull request (standalone run only).** A standalone run is one a person
   starts directly, not from `wrap-up`, a build loop or another skill. The work goes on a branch named
   with a story key. When you are not on a branch named with a story key, create it from the current
   state (`git switch -c <number>-<topic>`); the work moves with it. When you are on one, stay on it. Then
   `/wrap-up` commits it and runs the pre-flight. Push the branch and open or update the pull request through the pull request skill of the
   installed pack, as `implement` does. In `github-pull-requests`, `New-PullRequest.ps1` opens a new one and `Update-PullRequest.ps1` updates an open one. Called
   from `wrap-up`, a build loop or another skill, skip this step: write the files only, and `wrap-up`
   commits them. So `wrap-up` never runs itself a second time.

## amend workflow

1. Read the constitution page (`paths.constitution`) and the repository clauses in `AGENTS.md` first (never blind-write).
2. Apply the change: add a new clause with the repository prefix, change an existing one, or supersede one. A core or pack clause is not amended here: draft the change as a pull request on AI.SDLC instead. To supersede, mark the old clause `Superseded by <ID>`, keep it in the constitution page (`paths.constitution`) for history, and remove it from the repository clauses in `AGENTS.md`.
3. Bump the document version and append a one-line entry to a `## History` section in the constitution page (`paths.constitution`) (date, what changed, why). Git history is the backstop, but the explicit log helps reviewers.
4. Keep the repository clauses in `AGENTS.md` and the constitution page (`paths.constitution`) in sync (statements the same). If the repository clauses grow past about 12, flag it and propose moving the weakest clause out.
5. Confirm the diff, then write.
6. **Backlink the source (required when there is one).** If a story or ADR caused the clause change, record it on that story. Hand off to `write-story` in update mode (github-issues pack) for that. Use a `🧭 Decisions & ADRs` bullet naming the clause id and what changed. Also add the clause to the References of the related ADR. The write is that update mode's and joins the Checkpoint Alpha or Checkpoint Bravo confirmation; drive the handoff rather than leaving it a suggestion. A really cross-cutting clause with no single source story or ADR has nothing to backlink: say so explicitly rather than skipping silently.
7. **Hand the work to a pull request (standalone run only)**, as in create step 6.

## check workflow

1. Write the change under review to `temp/review.diff`. It is often not committed yet, so run
   `git add --intent-to-add .` first, so new files show, then write
   `git diff $(git merge-base origin/main HEAD)`. A diff of two commits leaves the working tree out.
2. When the dotnet pack is installed, hand the check to its `code-reviewer` agent
   on Sonnet 5.5 (model `sonnet` in Claude Code, `claude-sonnet-5.5` in Copilot). It has no shell and reads the file. It reads the diff against every clause in `AGENTS.md`: the core, the pack and the repository clauses. It reports each
   clause the change breaks, with the file and the symbol. Without that agent, or if you cannot run
   agents, read the diff against the clauses and do the check yourself. A finding tagged `[HIGH][DESIGN]` is a stop-and-ask.
3. Report the findings; do not fix them here and do not write anything. Leave out what a gate already
   checks, and name the gate instead. Each gate names its clause, for example C02, C05, C06, C08, C11 or
   DOTNET-01. That holds for the gates of the installed packages and for `repoGates` in aisdlc.json. A gate that no clause covers names its rule family, such as `AI-SDLC` or `house-style`. Or it leaves `clause` out, and the runner then shows its package name. A rule family is not a clause to check against.
4. Inside the build loop, a broken clause is a stop. The loop either fixes the change, or it stops and
   asks whether the clause should change ([orchestration.md](/.claude/skills/ai-sdlc-handbook/references/orchestration.md)).

An amendment is never part of the loop. Changing a clause is a stop-and-ask: the person confirms the
diff to `AGENTS.md` and the constitution page (`paths.constitution`) before it is written.

## Handling an existing CLAUDE.md (important)

Many repos already have a large `CLAUDE.md` (this is common). **Never overwrite it with a one-line stub.** Instead:
- Offer to migrate: move its lasting, tool-neutral content into `AGENTS.md`. Keep any really Claude-only notes in `.claude/CLAUDE.md` after the line `@../AGENTS.md`, and remove the root file.
- If the user does not want to migrate now, leave `CLAUDE.md` as-is and add `@AGENTS.md` at its top so Claude still loads the core. Note the copying risk for later cleanup, and that Copilot then reads `AGENTS.md` twice.
Either way, surface the existing file and the proposed change before touching it.

## Guardrails

- **Police the size of `AGENTS.md`.** It is the only always-on cost for both tools, and `Check-AgentsFileSize.ps1` blocks it past 150 lines. The core between the markers comes from AI.SDLC. To make room, move the detail of a repository clause to the constitution page (`paths.constitution`) or to path-scoped conventions.
- **Confirm before writing** any of `AGENTS.md`, `CLAUDE.md`, or the constitution page (`paths.constitution`). Show the diff. These files are key, so a constitution change is always a stop-and-ask, also inside the build loop.
- **Match the repo's existing heading style.**
- **Check clauses against reality.** Do not write a clause the codebase already breaks without flagging it - either the clause is wrong or there is debt to record. State which.
- **Every clause names its enforcement.** Deferred is allowed; absent is not.

## Failure modes

- **A clause is written that the codebase already breaks** -> say so and say which. Either the clause is wrong, or there is debt to record with an owner. A clause that is false on the day it lands teaches the team that clauses are a wish.
- **A clause names no enforcement** -> deferred is allowed, absent is not. "Upheld in review" is an enforcement; silence is how a rule becomes hidden.
- **The repository clauses in `AGENTS.md` grow past about 12** -> it is the only always-on cost for every agent run in both tools. Move the detail to the constitution page (`paths.constitution`) and leave one line behind.
- **A clause is really a convention** -> the constitution is the small set of non-negotiables. A rule that is fine to break with a good reason belongs in a conventions page, not here.
- **An amendment rewrites a clause's history** -> the changelog at the bottom is the record of what the team believed and when. Append to it; do not edit past entries to match the present.
- **Two clauses now cover the same ground** -> say which one governs. Two rules covering the same ground is how a review argument becomes unresolvable.
- **The clause change is agreed in chat and only `AGENTS.md` is updated** -> `AGENTS.md`, the constitution page (`paths.constitution`), and any gate that enforces it move together. Otherwise the three drift, and the gate becomes the real rule.

## Observable signal

**Positive:** an agent run and a human reviewer reach the same verdict on whether a change is allowed. The rule is written in one place that both of them read.

**Audit trail:** the dated changelog in the constitution page (`paths.constitution`) is the receipt for when a rule arrived, what forced it, and what it replaced. It is what lets a clause be retired on evidence rather than on feel.

**Drift signal:** if the same argument recurs in reviews, a clause is missing or two clauses cover the same ground. If clauses keep listing enforcement as deferred for months, the path is not closing and the rule is being announced rather than enforced.

## Next steps

- `/wrap-up` (Developer) - after a standalone create or amend, commits the change and runs the
  pre-flight; then push and open or update the pull request (create step 6). Inside `wrap-up` or a build loop, skip it.
- If a new or amended clause needs a code or doc change to follow it, run `/implement` (Developer) or `/write-docs` (Tech Writer).
- If the clause came out of a specific architectural decision, record it with `/write-adr` (Architect) and backlink it via `write-story` in update mode.
- A clause that needs a gate gets one through `/add-gate` (Lead). Until then it is upheld in review,
  and by the `code-reviewer` agent where the dotnet pack is installed.
