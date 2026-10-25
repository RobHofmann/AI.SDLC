---
name: docs-wiki-conventions
kind: knowledge
user-invocable: false
description: >
  How the two documentation layers stay one checked wiki. It covers which layer a change belongs in,
  the generated indexes, and relative links and a Related section on every page. It also covers no
  orphans, no line numbers, no em-dash and no team member names. The reading level is in it too, and
  the gates that check pages against the code. Use when writing or reviewing a page in docs/ or docs-functional/, or
  when an ADR or a skill links a page. Also use when the docs-reviewer agent checks a change. This is
  a rulebook, not a task: it fixes nothing. Do NOT use to fix or rewrite a page that fails the reading level,
  the orphan check or another gate (write-docs), to run the documentation step itself
  (write-docs), to bring a whole repository up to the rules (adopt-docs), for ADR
  content (adr-conventions), for the constitution (update-constitution) or to re-pitch an answer in chat
  (wait-what).
---

# Docs wiki conventions

`docs/` and `docs-functional/` are one wiki that tools check. Use this whenever a page is written or
judged. `write-docs` and `adopt-docs` load it, also to check a page when they cannot
run agents, and the `docs-reviewer` agent preloads it. The layer folders come from `paths.technicalDocs` and `paths.functionalDocs`
in aisdlc.json (`paths.docsRoots` lists both); this page uses the common names `docs/` and
`docs-functional/`.

## Which layer

- **`docs/`** is technical, for developers: architecture, API, handlers, libraries, deployment,
  conventions, how it works.
- **`docs-functional/`** is functional, for product people and new joiners: domain model, lifecycle,
  glossary, personas, what the product does and why.
- Decide each layer on its own for every change, even when the answer is "no functional change", and
  say which you decided.

## Pages and links (clause C05)

- **Read the index first**: `docs/index.md` and `docs-functional/index.md`. Extend a page that exists
  before you add one.
- **The index is generated.** After adding, removing or retitling a page, run
  `pwsh .claude/skills/ai-sdlc-gates/scripts/Build-DocsIndex.ps1`; the gate runs it with `-Check`.
- **Relative markdown links only**, never `[[wikilinks]]`.
- **A graph, not a star.** Every content page links related pages inline and ends with a `## Related`
  section, one reason per link. A link from the index or a README does not count. No page without links
  in, no page without links out, no broken link.
- **A pointer names a section that is there.** "See the X section of page.md" must match a heading;
  `Check-DocSectionRefs.ps1` blocks.
- **Update in one pass.** Change every affected page and the index together, not one page alone.
- **Link the source, do not paste it**: a code symbol, an ADR or a work item.

## House style

- **The page clauses:** C02, C06, C07, C08 and C11 of the [constitution](/.claude/skills/ai-sdlc-handbook/references/constitution.md) hold on every
  page. The exact name of a thing may go on the reading-level allow list (`paths.readingLevelAllowlist`
  in aisdlc.json).
- **Every documented row carries a fact**: no row that names a thing and says nothing about it, no
  absolute path from one machine.

## The page still describes the code

- `Check-DocDrift.ps1` (dotnet pack, blocking) reports a constant the page misses, a file that is gone, and a
  backticked name that exists nowhere. It also reports a documented route no controller carries, and a
  service a library or handler page never names. Scope it with `-Doc <fragment>`.
- `Check-DocGraphClaims.ps1` (dotnet pack, advisory, needs the code graph) reports a stated relationship the graph
  does not have. When the graph is behind, rebuild it with `Invoke-GraphifyIndex.ps1`, then run
  `Invoke-DocGraphLink.ps1`, then run the check. Without the links, the check skips a page whose
  name does not match a project.
- A clean run proves names, not behaviour. Read the source for anything you state about behaviour.

## Before you hand it on

Run `pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1`. The wiki, index, em-dash, reading-level, section-ref
and row-content gates block there and in CI, and the drift gate too when the dotnet pack is installed.

## Sources

- [AI-SDLC documentation wiki](/.claude/skills/ai-sdlc-handbook/references/docs-wiki.md) - the full contract and every lint.
- [Constitution](/.claude/skills/ai-sdlc-handbook/references/constitution.md) - C02, C05, C06, C07, C08, C11.
- [Language and reading level](/.claude/skills/ai-sdlc-handbook/references/language.md) - the levels and the words to replace.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).
