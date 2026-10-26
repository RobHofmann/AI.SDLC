# AI-SDLC documentation wiki

The documentation layers of a repository are kept as a lasting, interlinked, **LLM-maintained knowledge
base**. It is a wiki in the sense of Andrej Karpathy's LLM Wiki pattern
(https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f). The agent compiles understanding
into cross-linked pages once. It does not work it out from the code every time.

The layers are the doc roots in aisdlc.json (`paths.docsRoots`). Most repositories have a technical
layer (`paths.technicalDocs`, default `docs`) and many also have a functional layer
(`paths.functionalDocs`). This page calls them the technical and the functional layer.

This is the **knowledge** layer. It is a partner to the **traceability** layer in
[artifact-graph.md](artifact-graph.md), not a stand-in. The graph answers "for #42, what spec,
ADR and docs exist". The wiki answers "how does the system really work". A single page can be
both: a wiki page (index entry and cross-links) that also carries `story:` front-matter (a graph node).

## The three layers (Karpathy's model, mapped)

| llmwiki layer | here |
|---|---|
| Raw sources (read, never the wiki's own content) | the codebase, the ADRs, GitHub issues, PRs |
| The wiki (LLM-owned, synthesised, cross-linked) | the doc roots: the technical and the functional layer |
| The schema (defines structure and conventions) | this page, `AGENTS.md`, and the `write-docs` skill |

## Conventions

### Index, read first

Each layer has a list the agent reads before answering or editing, so it finds the right page
instead of spawning duplicates or orphans:

- An `index.md` at the root of each layer.
- One entry per page: a relative link plus a one-sentence summary, grouped by area.
- **Generated, not hand-curated.** `.claude/skills/ai-sdlc-gates/scripts/Build-DocsIndex.ps1` emits them
  from the pages, so the index cannot drift from reality. Run it again after adding, removing, or
  retitling a page.

### Cross-links, usable everywhere (not Obsidian)

Pages link related pages with **relative markdown links** (for example `[lifecycle](../lifecycle.md)`), not
`[[wikilinks]]`. The docs render in the Git host and the IDE, where `[[...]]` and Dataview front-matter
queries do not resolve. Relative links render everywhere, and the lint checks them. This is the
one intended change from Karpathy's Obsidian-based original.

A repository page may link a page of this handbook with a normal relative link into
`.claude/skills/ai-sdlc-handbook/references/`, and the doc gates follow that link. The
[layout page](layout.md) says where the shared files land.

### Connectivity, a graph and not a star

The index is a list, not the web. A page that is only reachable from `index.md` is not yet part of
the graph. The value of the wiki is page-to-page links between *related* concepts. A reader (human or
agent) can then walk from one page to its neighbours without returning to the index each time. Therefore:

- **Every content page links its neighbours.** Link inline where a concept is mentioned. End the page
  with a `## Related` section that lists the topically adjacent pages as relative links. Give each a
  short reason (for example `[Billing handler](../handlers/billing.md) - the function that uses this library`).
- **The index does not count toward connectivity.** The lint's connectivity check (below) ignores links
  from `index.md` and `README.md`; a page needs real page-to-page links, not just an index entry.
- **Aim for a connected web, no isolated nodes.** Cross-link in both directions where the relationship is
  mutual (a library page and its handler page link each other). Link because the pages are really
  related, not to satisfy a counter; a `## Related` section of noise is worse than a focused one.

### Front-matter

A page that joins the artifact graph carries the graph front-matter (`story:` and friends, per
[artifact-graph.md](artifact-graph.md)). A wiki page may also carry a short `summary:` line for the index.
Keep front-matter small and usable everywhere; do not add Dataview-only fields.

## Maintenance principles (the write-docs skill carries these)

- **Single-pass synthesis.** When a change lands, read it once and update *all* affected pages plus
  the index together, not one page on its own.
- **Synthesis over storage.** A page holds understanding that has grown, not a raw dump. For the
  detail, link to the source (code symbol, ADR, work item) rather than pasting it.
- **Query-filing.** A good answer to a real question becomes (or updates) a page, so knowledge
  compounds in the wiki instead of disappearing into chat history.
- **Concept and entity pages.** The functional layer holds concept pages (domain model, glossary,
  lifecycle, personas); grow that set as concepts emerge, each cross-linked into the web.
- **A new area gets a whole page.** A change can touch an area that has no page in a layer. Then the
  new page describes the whole area, not only the change. Take a change to the deployments of a
  repository with no deployment page. It means a deployment page in both layers: what it does for a
  user, and how it works. The scope step of the `write-docs` skill carries this rule, and
  `wrap-up` checks it. No gate does, because `Check-DocCoverage.ps1` knows only units.

## Lint (the integrity check)

`.claude/skills/ai-sdlc-gates/scripts/Check-DocsWiki.ps1` checks wiki health (Karpathy's "periodic linting"):

- **Orphans:** a page that is not in its layer's index and that no other page links to.
- **Broken links:** a relative markdown link that does not resolve to a file.
- **Connectivity (the graph check):** a content page with no page-to-page cross-link to or from another
  content page is reported as isolated. Index and README links do not count, so this is what enforces a
  graph rather than a star. Without `-Strict` an isolated page is only reported. The core gate runs the
  script with `-Strict`, so an isolated page fails the build.
- **Index drift:** the committed index does not match what the generator would emit (`Build-DocsIndex.ps1 -Check`).

A sibling script, `.claude/skills/ai-sdlc-gates/scripts/Check-DocEmDashes.ps1`, enforces the **no-em-dash
house style**: it flags any em-dash (U+2014) character in `AGENTS.md` and in the doc roots. The house style
uses a spaced hyphen ' - ', commas, colons, or parentheses instead.

A third script, `.claude/skills/ai-sdlc-gates/scripts/Check-DocReadingLevel.ps1`, checks the reading
level: every page in the layers is English, with sentences at CEFR B2 and words at CEFR B1. It reports a
sentence over 25 words and a word the CEFR lists place above B1, and it runs as a blocking gate. See
[language conventions](language.md) for the levels, the words to replace, and which language each place uses.

A fourth script, `.claude/skills/ai-sdlc-gates/scripts/Check-DocSectionRefs.ps1`, reads what comes AFTER
the file name. The wiki check says a link resolves to a file. It says nothing about "see the X section of
page.md", so that pointer survives the section being renamed or removed. This one reads three shapes:

- a named section in backticks or after the word "the";
- a quoted section name after a file name;
- a link anchor.

Each must match a heading in the target, or, for the quoted shape, text that is there. It reads
PowerShell help blocks too, because the first real case was found there. One script sent a reader
to "The documentation updater credentials" where the heading read "The documentation updater's
credentials". It blocks.

In a script (.ps1, .psm1 or .yml) it also reads a path to a decision record, such as
`docs/adrs/0001-name.md`, and that file must exist. A help block is outside the wiki check, so a renamed
ADR would leave the script pointing at nothing. The folder comes from `adrFolder` in `aisdlc.json`.

These exit non-zero on any violation. `Invoke-LocalGates.ps1` and the pre-push hook run them locally, and
the repository's pull request workflow runs the same scripts.

### Truth (does the page still describe the code)

Link integrity says a page is reachable, not that it is right. One core check and two checks of the
dotnet pack read the pages against the code. The dotnet checks exist only where that pack is installed.

- `.claude/skills/ai-sdlc-gates/scripts/Check-DocRowContent.ps1` (core) is the house-style half. It
  reports a page saying something is "not described in the named sources", and a table row that names a
  thing and then says nothing about it. It also reports a template fragment, a table header with no rows,
  and an absolute path from one machine.
  These rules began as assertions inside a Pester suite, which made a text edit a hard CI failure reported
  as a gate script regression. They are repository-wide documentation rules, so they run as a gate with a
  mode like every other one.
- `.claude/skills/dotnet-gates/scripts/Check-DocDrift.ps1` (only when the dotnet pack is installed; blocking) needs only git and the
  files, so it runs for everyone and the pre-push hook runs it. It reports:
  - a constant the code declares and the page omits;
  - a file the page names that is gone;
  - a backticked identifier that exists nowhere in the repository;
  - a documented route no controller carries;
  - on the pages mapped to a project, a service in the project the page never names.

  It prints its own coverage so a clean run is not mistaken for a correct
  page: it reads names, never behaviour.
- `.claude/skills/dotnet-code-graph/scripts/Check-DocGraphClaims.ps1` (only when the dotnet pack is installed; advisory) needs the
  local code graph, which not every machine has. It is the only check that can see a stated relationship
  being false. Examples are a page linking two projects the graph records no edge between, and an
  interface whose second implementation the page never names. A line saying `no direct code path` is exempt, for the page that
  links a project to explain the code never reaches it. It exits clean when the graph is absent.

A fourth check reads the other side: what should have a page. `Check-DocCoverage.ps1` fails when the
technical or the functional layer is missing, or when a unit has no technical page. A unit is a part a
reader looks for by name: a .NET project, a Bicep building block, a package. Each pack names its units,
and `docs.units` in `aisdlc.json` can replace that list. A page covers a unit when its front matter
names the unit (`unit: <path>`), or when its H1 or its file name is the unit name. The
`adopt-docs` skill drafts the missing pages from facts read out of the code
(`New-DocCandidate.ps1`), and a person checks each claim before it is merged.

Where the dotnet pack is installed, the `write-docs` skill runs both dotnet checks before it
drafts. The drafting step itself (`Update-DocFromGraph.ps1`) is fed names and relationships from the same
sources, then checked claim by claim before anything is merged.

## Automation

| Concern | Method | Status |
|---|---|---|
| Maintain the wiki (synthesis, cross-links, query-filing) | `write-docs` skill | active |
| Generate the indexes | `Build-DocsIndex.ps1` | active |
| Check wiki integrity locally | `Invoke-LocalGates.ps1` and the pre-push hook (run `Check-DocsWiki.ps1`) | active |
| Enforce the no-em-dash house style | `Check-DocEmDashes.ps1` (via `Invoke-LocalGates.ps1`) | active, blocking in CI |
| Enforce the reading level (B2 sentences, B1 words) | `Check-DocReadingLevel.ps1` (via `Invoke-LocalGates.ps1`) | active, blocking |
| Check wiki integrity before merge | CI gate in the pull request workflow | active, blocking (orphans, broken links, index sync, page-to-page connectivity) |
| Check every pointer names a section that is there | `Check-DocSectionRefs.ps1` (via `Invoke-LocalGates.ps1`) | active, blocking |
| Check every documented row carries a fact | `Check-DocRowContent.ps1` (blocking gate; no graph needed) | active |
| Check pages against the code they name | `Check-DocDrift.ps1` (dotnet pack; pre-push hook, blocking gate; no graph needed) | active where installed |
| Check stated relationships against the code graph | `Check-DocGraphClaims.ps1` (dotnet pack; advisory gate; needs the local graph) | active where installed |
| Draft additions from names and relationships, check before merge | `Update-DocFromGraph.ps1` (dotnet pack) via `write-docs` | active where installed |
| Check both layers exist and every unit has a page | `Check-DocCoverage.ps1` (via `Invoke-LocalGates.ps1`) | active, blocking |
| Draft a missing page from the facts of its unit, check before merge | `New-DocCandidate.ps1` via `adopt-docs` | active |
| Make "docs maintained as a linted wiki" non-negotiable | constitution clause C05 | active, blocking in CI |

## Related

- [Artifact graph](artifact-graph.md) - the partner traceability layer (this is the knowledge layer).
- [AI-SDLC design](plan.md) - the phase, step, and persona design this wiki supports.
- [Constitution](constitution.md) - clause C05 makes maintaining this wiki non-negotiable.
- [Language and reading level](language.md) - the reading level and the language every page is written in.
- [The layout of the shared AI-SDLC](layout.md) - where the handbook pages land, so a repository page can link them.
