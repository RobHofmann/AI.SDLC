---
name: write-docs
kind: workflow
phase: create
persona: Tech Writer
description: >
  Maintain BOTH documentation layers as one linked wiki after a change: technical docs in docs/
  and functional docs in docs-functional/. It reads the layer index first, routes each change to
  the right layer, cross-links related pages and flags stale sections. Use after implementing or
  changing a feature, or as the documentation step of a development cycle. Use when a good answer to a
  real question deserves to become a page, or when the user says "update the docs", "sync the
  documentation", "the docs are out of date" or "document how this works". Use when a page from
  your own change fails the reading level or another doc gate and needs a rewrite. Do NOT use for
  the pages of a whole repository (adopt-docs), ADRs
  (write-adr), the constitution (update-constitution) or API spec / OpenAPI generation
  (write-api-spec).
---

# Create documentation (dual-layer wiki)

Owned by the **Tech Writer** persona (the write-docs step). Called as `/write-docs`.

Documentation rots silently and then misleads. Treat the two doc layers not as loose files but as one
lasting, interlinked, LLM-maintained wiki. Compile understanding into cross-linked pages once, rather
than re-deriving it from the code every time. The convention this carries is the handbook page
`docs-wiki.md` (the knowledge layer); read it for the full schema. This is a partner to the
traceability graph in the handbook page `artifact-graph.md`. A single page can be both a wiki page
(index entry plus cross-links) and a graph node carrying `story:` front-matter.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).

## The two layers (route each change correctly)

| Layer | Folder | Audience | Holds |
|---|---|---|---|
| **Technical** | `paths.technicalDocs` in aisdlc.json (`docs/` by default) | developers | architecture, API reference, handlers, libraries, deployment, conventions, troubleshooting - how it works |
| **Functional** | `paths.functionalDocs` (for example `docs-functional/`) | product / business / new joiners | personas, domain model, lifecycle, glossary, overview - what the product does and why |

A single change often touches both. A new endpoint updates the API page (technical). If it changes
observable behaviour, it may also shift the domain model or lifecycle page (functional).
Always ask "did developer-facing detail change?" and "did product-observable behaviour change?"
separately, and decide each even if the answer is "no functional change".

## Wiki rule

Load the `docs-wiki-conventions` skill. It holds the linking, index and house-style rules: relative
links, the `## Related` section, no orphans, C02, C05, C06, C08 and the reading level. It points at
the handbook page `docs-wiki.md` for the full rule. The points below are how this skill applies them.

- **Index, read first.** Before answering or editing, read the layer index (the `index.md` at the root
  of each layer). It shows the right page, so you do not spawn duplicates or orphans. The
  index is generated, one entry per page (a relative link plus a one-sentence summary). If a layer
  has no index yet, scan that layer directly and note the index is absent.
- **Single-pass synthesis.** When a change lands, read it once and update *all* affected pages plus
  the index together, not one page in isolation. The common failure is fixing one page and leaving
  its neighbours and the index stale.
- **Synthesis over storage.** A page holds understanding that has grown, not a raw dump. Link to the source
  (code symbol, ADR, work item) for the detail rather than pasting it.
- **Cross-link into a graph, not a star.** Link each touched page to its real neighbours inline and in
  its `## Related` section, in both directions where the relationship is mutual. The natural clusters
  here are a library page <-> its handler page <-> the API resource it serves <-> the convention or ADR
  that governs it. The functional concept pages interlink, and anchor the technical pages that realise
  them. The link rules themselves are in `docs-wiki-conventions`.
- **Query-filing.** A good answer to a real question becomes (or updates) a page, so knowledge
  compounds in the wiki instead of disappearing into chat history. If you just explained how
  something works, file it.
- **Concept and entity pages.** The functional layer holds concept pages (domain model,
  glossary, lifecycle, personas, overview). Grow that set as new concepts, terms, or entities emerge,
  each cross-linked into the existing pages rather than added in isolation.

## Workflow

1. **Read the index** for both layers first; locate the page(s) that already cover the affected
   area. Prefer extending an existing page over creating a new one.
2. **Scope the change.** Find what changed (the current diff, the feature just built, or a named
   area). List the affected code surfaces by path plus symbol, never line numbers.

   **An area with no page gets a whole page, in both layers.** When the change touches an area that
   has no page in a layer, document the WHOLE area there, not only the change. For example, a change
   to the deployments of a repository with no deployment page means writing that page. The functional
   page says what deployments do for a user; the technical page says how they work. A page that
   describes only the latest change to an area nobody documented reads like a changelog. This is a
   rule for this skill, not a gate: `Check-DocCoverage.ps1` knows only units, not areas.
3. **Map to docs.** For each affected surface, find the doc(s) that describe it in both layers.
   `paths.sourceDocMap` in aisdlc.json maps each source folder to its doc folders. For example:
   - API endpoint -> the API page for that resource (technical); behaviour change -> the lifecycle or
     domain model page (functional).
   - new or changed project, handler or library -> its project page, as the source map names it.
   - new domain concept or term -> the domain model and glossary pages.
   - new persona-visible ability -> the personas or overview page.
4. **Draft updates** for every matched page in both layers, plus the cross-links between them and any
   index entries the change means. A change that adds a unit (a project, a building block) adds its
   page. Draft it with `New-DocCandidate.ps1 -Unit <unit>` from the `adopt-docs` skill, and
   check it like any other draft (step 6). Keep each layer in its own voice: technical = precise and
   developer-facing; functional = behaviour and intent, few technical terms.
5. **Flag staleness, with a tool rather than by eye.** When the dotnet pack is installed, load
   `dotnet-code-graph`. It runs the doc checks: `Check-DocDrift.ps1` for what a page names that the code
   no longer has, and `Check-DocGraphClaims.ps1` for a relationship the code does not have. For a page
   they flag, it runs the candidate generator `Update-DocFromGraph.ps1`. Without a pack tool, hold each page
   against the code yourself: every file, constant, member and relationship it names. Fix what falls in
   your change's scope and list the rest as "stale, needs update" rather than leaving it silently wrong.
   A clean check is not a correct page: read what the check says it did not look at.
6. **Verify each added claim before you merge it. This step is yours, not a script's.** A candidate from
   a generator is a proposal from a model that did not read the code. Diff it against the page, take the
   added and changed lines, and check each one against the source before it goes anywhere:
   - **Every symbol must exist.** Grep the repository for each type, member, constant and file name the
     addition introduces. A name can be real and still be described wrongly.
   - **Every behavioural sentence must be checked against the code, not against what sounds right.**
     "Caches the token for an hour", "retries three times": open the file and confirm it.
   - **A clash between the candidate and the page is a finding, not a merge conflict.** One of the two is
     wrong. Read the code and decide which, then fix that one. Do not keep both.
7. **Merge what survived, line by line, and say what did not.** Merging is add-only: copy the checked
   additions into the page, keeping the existing text as it stands. Do not copy a candidate over the
   page wholesale, because then no reader can tell the unchecked lines from the checked ones.

   Drop every claim you could not confirm, and note it in your report so a human can chase it. Then
   delete the candidate file, so nobody later mistakes a draft for a page.

   You are the one merging, and you do not sign off your own documentation (constitution C09). Report
   what you checked and how, so the human reviewing the diff can spot-check you.
8. **Write, then report.** Inside the build loop, write the pages without a separate confirmation.
   They are repository files, and the person sees them in the diff at Checkpoint Bravo. Run standalone, show the
   diffs first. Report which layer each edit landed in, and which added claims you checked against
   which files. Say which claims you dropped and why. List any stale references you flagged but did
   not fix.
9. **Regenerate the index and lint.** After writing, regenerate the layer indexes with
   `Build-DocsIndex.ps1`, so the index cannot drift from the pages. Then run the wiki lint with
   `pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1`, which runs `Check-DocsWiki.ps1`.
   It catches orphans, broken relative links, index drift, and connectivity (isolated pages with no
   page-to-page cross-link). Fix what it
   reports before considering the docs done; do not leave a page you touched isolated. The pre-push
   hook runs the same scripts.
10. **Review.** Run `git add --intent-to-add .` first, so the new pages show in the diff. Then hand
   the changed pages to the `docs-reviewer` agent
   on Sonnet 5.5 (model `sonnet` in Claude Code, `claude-sonnet-5.5` in Copilot). It checks both layers against the change. If you cannot run agents, load `docs-wiki-conventions` and check the pages yourself.
   Fix each finding or record why you declined it, for the evidence record.
11. **Hand the work to a pull request (standalone run only).** A standalone run is one a person
   starts directly, not from `wrap-up`, a build loop or another skill. The work goes on a branch named
   with a story key. When you are not on a branch named with a story key, create it from the current
   state (`git switch -c <number>-<topic>`); the work moves with it. When you are on one, stay on it. Then
   `/wrap-up` commits it and runs the pre-flight. Push the branch and open or update the pull request through the pull request skill of the
   installed pack, as `implement` does. In `github-pull-requests`, `New-PullRequest.ps1` opens a new one and `Update-PullRequest.ps1` updates an open one. Called
   from `wrap-up`, a build loop or another skill, skip this step: write the files only, and `wrap-up`
   commits them. So `wrap-up` never runs itself a second time.

## Guardrails

- **A generated candidate is not evidence.** Nothing a model proposes reaches a page until you have
  opened the source and confirmed it. Merge the claims you checked, drop the ones you could not, and
  report both. A soft word ("appears to", "likely") is no substitute for reading the file.
- **Check before asserting.** Do not document behaviour you have not confirmed in the code.
  Reference code by file path plus symbol name, never line numbers (constitution C02). If a doc claim
  is now uncertain, mark it for review rather than restating it confidently.
- **No writing unasked outside the loop.** Run standalone, show the diffs and get a go-ahead. Inside
  the build loop the diff reaches the person at Checkpoint Bravo ([orchestration.md](/.claude/skills/ai-sdlc-handbook/references/orchestration.md)).
- **Surgical edits.** Update the sections the change affects; do not rewrite untouched pages or
  "improve" adjacent text outside the change.
- **Both layers, every time**, and the index with them. Single-pass synthesis means a page is never
  updated while its cross-links or its index entry are left behind.
- **Match to the node shape when a page is a graph node.** A doc that opts into the artifact graph
  (declares `story:`) carries the envelope in [node-templates.md](/.claude/skills/ai-sdlc-handbook/references/node-templates.md):
  the lifecycle header and a graph-links footer with "(not yet created)" markers. An ordinary wiki page keeps
  the why behind a behaviour, not just the what.
- **Match each page's existing heading and tone.** Relative markdown links only; no `[[wikilinks]]` or Dataview-only front-matter.
- **Tool-neutral.** This skill is read by Claude Code and GitHub Copilot; the scripts run from any
  shell. Claude-only conveniences are noted in parentheses. Do not invent docs structure: if only one
  layer exists, update that one and note the other is absent.

## Failure modes

Each of these happened in a repository that uses this skill and was measured; none is made up.

- **Copying the candidate over the page.** The candidate is a model's proposal. Copy it whole and the
  unchecked lines land next to the checked ones, and nobody afterwards can tell which is which. Merge
  claim by claim.
- **Reading the guards as a verdict.** A word-count or heading guard catches a rewrite, not a wrong
  fact. One generator run cut a page from 1902 words to 333 with every heading intact, and the drift
  check passed it.
- **Treating a clean check as a correct page.** A drift check reads names and files. It measures no
  behaviour, no route, no configuration key, and no text. Read what it says it did not check.
- **Believing a name exists because it is written in backticks.** A name can be real and still be
  described wrongly, and a sentence about what something does is the model's working out.
- **Documenting a type because its name looks like a service.** A class named like a provider can be a
  plain model. Open the file.
- **Fixing one page.** Single-pass synthesis exists because the neighbours and the index go stale in the
  same change that made the page stale.

## Observable signal

The doc checks of the installed packs report nothing new on the pages the change touched. Any
finding left behind is listed in your report rather than left silent. No candidate file is left,
because every candidate was either merged claim by claim or thrown away. The wiki lint passes: no orphan, no broken relative link, no
isolated page, and the index matches the pages. The reviewer
can trace every claim added in this pass to a file you named. The claims you could not check appear in
your report instead of on the page.

## Next steps

- Run `pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1` to lint the wiki (orphans, broken links, index drift) and, if a page
  opted into the artifact graph, confirm its `story:` and `relates:` links resolve.
- `write-story` in update mode (any, github-issues pack) - if the docs are a story deliverable, link them onto the story.
- `/wrap-up` (Developer) - after a standalone run, commits the pages and runs the pre-flight; then
  push and open or update the pull request (step 11). Called from `wrap-up` or a build loop, return there
  instead. The calling loop then opens or updates the pull request for Checkpoint Bravo.
