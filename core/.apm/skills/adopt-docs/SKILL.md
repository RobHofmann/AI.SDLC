---
name: adopt-docs
kind: workflow
phase: cross-cutting
persona: Tech Writer
description: >
  Give a repository complete documentation that meets the AI-SDLC wiki rules: a technical and a
  functional layer, and a page for every unit (a .NET project, a Bicep building block, a package).
  It lists what is missing, runs the machine fixes, proposes moves between the layers, drafts each
  missing page from facts read out of
  the code, and has every claim checked before it is merged. Use once per repository after the first
  install, when the coverage gate or the doc gates fail on pages that existed before the AI-SDLC, or
  when a repository has no functional layer. Also use when the user says "make our docs AI-SDLC
  compatible", "adopt the docs", "document every project" or "we have no functional docs". Do NOT use
  to document a change that was just built (write-docs), to write an ADR (write-adr) or to change the
  wiki rules themselves (docs-wiki-conventions).
---

# Adopt the documentation

Owned by the Tech Writer persona and usable by any. Called as `/adopt-docs`. The setup script
of AI.SDLC names it when the docs of a new repository still fail a gate after the machine fixes.

A repository that installs the AI-SDLC usually has docs already, and they rarely cover every part. The
doc gates then fail on pages that were fine before, and `Check-DocCoverage.ps1` fails on the parts
that have no page at all. This skill makes the docs one complete, checked wiki, once, so that
`write-docs` can keep them true after every change. It changes form and fills gaps; it does
not change meaning. A fact on a page stays a fact on the page, and a page is never deleted.

The rules the pages must meet are in [docs-wiki-conventions](/.claude/skills/docs-wiki-conventions/SKILL.md)
and on the handbook [docs wiki page](/.claude/skills/ai-sdlc-handbook/references/docs-wiki.md). This skill
runs them on a whole repository; it does not restate them.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).

## When it fires

- Right after the first install, when `tools/Add-AiSdlcConsumer.ps1` reports doc gates that still fail.
- When `Check-DocCoverage.ps1` reports a missing layer or a unit with no page.
- When the doc gates fail on pages that nobody changed in this pull request.
- When the user asks to make the existing docs complete or meet the AI-SDLC rules.

## Workflow

1. **Read the work list.** `pwsh .claude/skills/ai-sdlc-gates/scripts/Check-DocCoverage.ps1` names each
   missing layer and each unit with no technical page, with the page to write. A repository with no
   functional layer gets one first. Set `paths.functionalDocs` and add it to `paths.docsRoots` in
   `aisdlc.json`. Start the layer with `overview.md` (what the repository gives its users) and
   `glossary.md`, and link the two.
2. **Run the machine fixes.** `pwsh .claude/skills/adopt-docs/scripts/Repair-DocsWiki.ps1`
   replaces em-dashes, gives each page a title and a Related section, writes the index, and runs the
   blocking gates. Read its output: the gates that still fail join the work list.
3. **Propose the structure.** Read every page and say which layer it belongs in. How the repository
   is built goes in the technical layer. What it gives its users goes in the functional layer. Move a
   page with `git mv` and fix the links to it. A page that covers a unit under another name gets the
   unit path in its front matter (`unit: <path>`), so the coverage gate matches it. List every move and
   every front matter line in a table for the pull request.
4. **Build the facts.** For a .NET repository, build the code graph with
   `pwsh .claude/skills/dotnet-code-graph/scripts/Initialize-CodeGraph.ps1`, so the drafts carry who
   uses what. A Bicep repository needs the Bicep CLI or `az bicep`; without it the facts come from the
   source. Other units need nothing.
5. **Draft each missing page.** For each unit on the work list, run
   `pwsh .claude/skills/adopt-docs/scripts/New-DocCandidate.ps1 -Unit <unit>`. It calls no model. It
   reads the facts through the pack that names the unit (`docFacts`, or `Get-FolderFacts.ps1` for a
   unit no pack names). It writes one facts file per unit to `doc-candidates/<unit>.facts.md`, with
   the target path of the page and the check list, never to the page. For the functional layer, plan
   one page per thing a user gets, often spanning several units:
   `-Layer Functional -Unit <unit>,<unit> -Page <page> -Title <title>`.
   Then hand each facts file to a subagent, a few at a time, that drafts the page through `write-docs`
   from that file alone. If you cannot run agents, draft each page yourself in this session, one facts
   file at a time. For a page that exists and is thin, use `Update-DocFromGraph.ps1` in a .NET
   repository, or write the missing part by hand. That script writes a facts file the same way.
6. **Verify each claim before you merge it. This step is yours, not a script's.** Run
   `pwsh .claude/skills/adopt-docs/scripts/Test-DocCandidate.ps1 -Draft <page> -FactsFile <facts file>`
   over each drafted page. Every backticked name that is not in the facts is listed under
   `UNVERIFIED:`. The script also checks the title, the em-dash rule and the reading level. Start
   with that list. Check every sentence about behaviour against the source.
   Keep only what you confirmed, drop the rest, and delete the facts file. Then hand the page to the
   `docs-reviewer` agent. A draft
   with no confirmed claim beyond names and paths is still a page: say the name and where it lives.
7. **Fix the reading level and the links, page by page.** Split the long sentences and swap the hard
   words, as the language page describes. A word that is the exact name of a thing goes on the allow
   list the gate names. Point a broken link at the page as it is now. Replace a line-number reference
   with the file path and the symbol (clause C02), and a team member's name with the pull request
   number (clause C08). Replace each Related line the script wrote with what the linked page is for.
8. **Rebuild the index, then run the gates again.** Run
   `pwsh .claude/skills/ai-sdlc-gates/scripts/Build-DocsIndex.ps1`, then
   `pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1`, which must pass with
   `Check-DocCoverage.ps1` among them. Loop steps 5 to 8 until it does.
9. **Hand it over as one change.** The pages go into one pull request per repository, through
   `wrap-up`. Before you call it, put the work on a branch named with the story key of this docs
   work, such as `42-adopt-docs`. When you are not on a branch named with a story key, create it from
   the current state (`git switch -c <number>-<topic>`); the work moves with it. When you are on one, stay
   on it. When there is no story yet, `/write-story` makes one first. `wrap-up` commits on that branch, and its step 0
   stops on a branch with no story key. Its `write-docs` step ends with the `docs-reviewer` agent, and then it commits and runs
   the pre-flight; do not run those steps here. Then push and open or update the pull request through the pull
   request skill of the installed pack, as
   `implement` does. In `github-pull-requests`, `New-PullRequest.ps1` opens a new one and
   `Update-PullRequest.ps1` updates an open one. The description holds the table from step 3, the pages
   drafted and how each was checked, and the gate results before and after. A person reviews it
   (Checkpoint Bravo).

## Failure modes

- **A draft is pasted in whole** -> a subagent wrote it from a facts file, a partial view of the code.
  Copy only the lines you checked against the source (C09).
- **A page loses a fact while it is rewritten for the reading level** -> the page reads better and is
  now wrong. That is worse than hard to read. Compare each rewritten page with the old one before the
  next page.
- **A functional page describes the code** -> a user learns nothing they can act on. Write what they
  get and when they need it; name code only when they must act on it.
- **A unit is left out to make the gate pass** -> `docs.unitExclude` hides a part a reader will look
  for. Leave out only what nobody uses, and say why in the pull request.
- **A word is changed that was the exact name of a thing** -> the page stops matching the code or the
  product. Put the name on the allow list instead.
- **A decision record is rewritten** -> an ADR records what was decided at the time. Fix its em-dashes
  and links, never its reasoning.
- **Everything goes into the first pull request of the install** -> the install and the docs then
  review as one huge diff. Keep the docs in their own pull request.

## Observable signal

**Positive:** after the run, `Invoke-LocalGates.ps1` passes on the whole repository, with
`Check-DocCoverage.ps1` green. The next change only needs `write-docs` for the pages it touches.

**Audit trail:** the pull request lists the moves, the pages drafted and how each was checked, and the
gates before and after. It also lists the words added to the allow list and the units left out, each
with the reason.

**Drift signal:** if the allow list grows by dozens of ordinary words, pages are being made to pass
instead of being rewritten. If `docs.unitExclude` grows, parts are being hidden instead of documented.
If the doc gates fail again soon after, new pages are skipping `write-docs`.

## Next steps

- `/write-docs` (Tech Writer) - keep the pages true after each change from now on.
- `/wrap-up` (Developer) - step 9: the review of the pages, the commit and the pre-flight before the
  docs pull request.
