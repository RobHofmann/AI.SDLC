---
name: dotnet-code-graph
kind: knowledge
user-invocable: false
description: >
  The local Graphify code graph of a .NET repository and how to use it. It answers what a text search
  answers badly: what calls this, who consumes this project, is this relationship real. It also covers
  the query and index scripts, the freshness check, the doc tools that read it, and the pinned
  version. Use when a question is about callers, consumers or the path between two types, or before a
  change to a shared library. Also use when a graph query was refused as stale, or when a page claims a
  relationship. Do NOT use for a plain text search (use grep) or for the doc gates that need no graph
  (dotnet-gates). Do NOT use to write the documentation itself (write-docs).
---

# .NET code graph

The code graph is a local, code-only map of the C# code, built by Graphify into `graphify-out/`, which
git ignores. It answers questions about relationships. The scripts sit in this skill's `scripts/`
folder. Every one of them reads the graph through `CodeGraph.psm1`. That module checks first whether
the graph still describes the code that is checked out.

## Ask the graph

```bash
pwsh .claude/skills/dotnet-code-graph/scripts/Invoke-GraphifyQuery.ps1 affected IOrderRepository
pwsh .claude/skills/dotnet-code-graph/scripts/Invoke-GraphifyQuery.ps1 explain OrderService
pwsh .claude/skills/dotnet-code-graph/scripts/Invoke-GraphifyQuery.ps1 path TypeA TypeB
```

- **Always ask through `Invoke-GraphifyQuery.ps1`.** A raw `graphify affected` reads the graph without
  checking it. The `Deny-StaleGraphQuery.ps1` hook refuses a raw query on a stale graph.
- **Know what it cannot see.** Configuration, Bicep, Service Bus messages and HTTP calls between
  services are not in the graph. Read the source for those.

## Build and keep it current

- `Invoke-GraphifyIndex.ps1` builds the graph, code-only, and refuses any argument that would reach a
  model backend. `-Report` shows the coverage and how far behind it is.
- The git hooks in `ai-sdlc-hooks` rebuild it after a commit, merge, checkout or rebase, in the
  background, and do nothing when Graphify is not installed.
- `Invoke-DocGraphLink.ps1` adds the edges from the doc pages to the code they cite.
- `graphify-version.json` pins the Graphify version. `Initialize-CodeGraph.ps1` installs that version
  at setup. `Invoke-GraphifyBenchmark.ps1` scores the graph against the question set of the repository,
  named in `dotnet.graphifyBenchmarkCases` of `aisdlc.json`.

## The doc tools that read it

- `Check-DocGraphClaims.ps1` (advisory gate) reports a page that states a relationship the graph does
  not have.
- `Update-DocFromGraph.ps1` writes the facts for a candidate page from the graph, and checks the
  drafted candidate with `-Check`. It never edits the page itself and calls no model.

## Refresh a doc page from the code

`write-docs` loads this skill for these steps when the dotnet pack is installed.

1. **Find the drift with the tool.** Run `pwsh .claude/skills/dotnet-gates/scripts/Check-DocDrift.ps1`
   (`-Doc <fragment>` scopes it). Act first on a documented endpoint that reaches no controller. A
   `[thin]` page names fewer than a quarter of the public methods of its project: open the source.
2. **Check the relationships.** Run `Check-DocGraphClaims.ps1` after `Invoke-GraphifyIndex.ps1` and `Invoke-DocGraphLink.ps1`. Act on
   `[unused]`: two projects with no edge between them should not read as one using the other. `[impl]`
   names an implementation the page leaves out; `[unlisted]` is for information only. No edge at all is
   the strong signal; a consumer list is a lead to check, not a fact to paste. `Get-ProjectConsumer`,
   `Get-ProjectDependency`, `Get-ProjectImplementation` and `Get-TypeCaller` in `CodeGraph.psm1` help
   write the `## Related` section. On a small library with one consumer, grep answers as well.
3. **Generate a candidate only when the gap is a missing name** (`[missing]`, `[service]`, `[thin]`).
   `Update-DocFromGraph.ps1 -DocPath <page>` writes the facts file `doc-candidates/<page>.facts.md`;
   `-DryRun` writes nothing. Hand the facts file to a subagent that drafts the candidate through
   `write-docs` at the path the file names; without subagents, draft it inline. Then run the script
   again with `-Check`. It refuses a candidate that loses a heading or 2 percent of the words, and
   lists names it cannot trace under `UNVERIFIED:`. For a wrong relationship, read the source and write
   the fix by hand.
4. **Check every added claim against the code.** Grep for every new symbol, starting with the
   `UNVERIFIED:` list. Confirm every sentence about behaviour in the source. A clash with the page is
   a finding: read the code and fix the wrong side.
5. **Merge line by line, add-only.** Drop what you could not confirm and say so in your report. Delete
   the candidate file. You do not sign off your own page (clause C09 in the
   [constitution](/.claude/skills/ai-sdlc-handbook/references/constitution.md)).

## Sources

- [The Graphify code graph](references/code-graph.md) - how it is built, what it answers and what it does not.
- [Docs wiki](/.claude/skills/ai-sdlc-handbook/references/docs-wiki.md) - the doc checks, the graph-backed ones among them.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).
