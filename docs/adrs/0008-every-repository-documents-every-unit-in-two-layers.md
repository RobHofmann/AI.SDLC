---
story: "#1"
phase: governance
step: write-adr
intent:
  assumption: "a page drafted in the session from facts read out of the repository, then checked claim by claim, is true enough to merge, and cheaper than a page written from nothing"
  decision-drivers:
    - "the doc gates check the pages that exist, so a repository with a page for half its units passes them all"
    - "a reader needs both how a part is built and what it gives, and these are different pages"
    - "a model backend outside the session is one more service, one more secret and one more cost, for work the session agent already does"
relates:
  gate: core/.apm/skills/ai-sdlc-gates/scripts/Check-DocCoverage.ps1
  coverage: core/.apm/skills/ai-sdlc-gates/scripts/DocCoverage.psm1
  candidate: core/.apm/skills/adopt-docs/scripts/New-DocCandidate.ps1
  facts: core/.apm/skills/adopt-docs/scripts/Get-FolderFacts.ps1
  wiki: core/.apm/skills/ai-sdlc-handbook/references/docs-wiki.md
because:
  gate: "the blocking gate that fails a missing layer or a unit with no page"
  coverage: "the module that names the units and finds the page of each"
  candidate: "the script that writes the facts of a missing page, with no model call"
  facts: "the reader of any folder, with no code run"
  wiki: "the handbook page that holds the coverage rule next to the other wiki rules"
---

# ADR 0008: Every repository documents every unit in two layers

**Status:** Accepted
**Date:** 2026-10-24
**Supersedes:** none
**Superseded by:** none

## Context

The doc gates read the pages that exist: links, the index, the reading level, and what a page claims
about the code. None of them sees a page that was never written. So a repository with a page for half
its units passes every doc gate. A reader looking for the other half finds nothing and guesses.

A reader also asks two different questions. A developer asks how a part is built. Someone who uses it
asks what it gives. One page that tries to answer both answers neither well.

A missing page is slow to start from nothing, which is how the gaps grow. A draft from facts helps. The
agent in the Claude Code session can already write a page: `write-docs` does it for every change, with
the `docs-reviewer` agent at the end.

## Decision

**1. Every repository has a technical and a functional layer.** `paths.technicalDocs` and
`paths.functionalDocs` in `aisdlc.json` each name a folder with an index and at least one page.
`tools/Add-AiSdlcConsumer.ps1` creates both for a new repository.

**2. Every unit has a technical page.** A unit is a part a reader looks for by name. A pack names its
units, such as a .NET project, and `docs.units` in `aisdlc.json` can replace the list. A page covers a
unit through its front matter (`unit:` or `units:`), its H1 or its file name. `docs.unitExclude` leaves
a unit out, with the reason in the pull request.

**3. A blocking core gate keeps it so.** `Check-DocCoverage.ps1` fails on a missing layer and on a unit
with no page, and names the page to write (clause C05).

**4. A missing page starts from facts, drafted in the session.** `New-DocCandidate.ps1` in `adopt-docs`
keeps the deterministic half. It finds the missing units, reads the facts of each one, and writes them
to `doc-candidates/<unit>.facts.md` with the page path and the check list. The facts come from the pack
that names the unit (`docFacts` in its `gates.json`), or from `Get-FolderFacts.ps1` for any other folder.
It never calls a model.

**5. The `adopt-docs` skill drafts each page through a subagent.** It hands a few facts files at a time
to a subagent that drafts the page through `write-docs`. So a large repository does not fill the main
context. It works inline when subagents are not available. The `docs-reviewer` agent checks each page.
Every name in backticks must appear in the facts; a name that does not is listed as unverified. A
person checks the claims at Checkpoint Bravo (clause C09).

## Consequences

**Positive:**

- A new unit needs its page in the same change, and the gate says which page.
- No model service, no model secret and no extra cost: the session that does the work writes the draft.
- The same facts give the same draft input on every machine, and the facts scripts have Pester tests.

**Negative:**

- A draft names more code and uses harder words than a page should. The unverified-names list and the
  reading-level gate make the check quick, but a person still has to read it.
- Drafting many pages costs session time and tokens. The subagents keep it out of the main context, not
  free.

**Neutral:**

- A unit that nobody uses can be left out, with the reason on record.

## Alternatives considered

1. **Keep the rule advisory.** Rejected because an advisory gate that finds a missing page is read once
   and then ignored, and the gaps grow that way.
2. **Write every missing page by hand.** Rejected as the only route, because it is the slow path that
   left the gaps. A person still checks the page; the draft only removes the empty start.
3. **A model service called from a script.** Rejected because it needs a separate service, a secret and
   a sign-in, for work the agent in the session already does. It also cannot run where that service is
   not set up.
4. **One layer for both readers.** Rejected because a page that explains the build and the use at once
   serves neither reader.

## Verification

- `Check-DocCoverage.Tests.ps1` and `DocCoverage.Tests.ps1` cover a missing layer, a unit with no page,
  each way a page covers a unit, and the list of left-out units.
- `New-DocCandidate.Tests.ps1` proves the script writes a facts file per unit and calls no model.
- `Get-FolderFacts.Tests.ps1` covers the facts of a plain folder.
- `tools/Test-Consumers.ps1` walks the route on a test consumer: the gate reports a unit with no page,
  the facts are written, and a page clears the gate.
- Not covered by a test: the quality of a drafted page. That is the review at Checkpoint Bravo.

## References

- `core/.apm/skills/ai-sdlc-gates/scripts/Check-DocCoverage.ps1` and `DocCoverage.psm1` - the gate.
- `core/.apm/skills/adopt-docs/scripts/New-DocCandidate.ps1` and `Get-FolderFacts.ps1` - the facts.
- `tools/Add-AiSdlcConsumer.ps1` - creates both layers in a new repository.
- [Documentation wiki](../../core/.apm/skills/ai-sdlc-handbook/references/docs-wiki.md) - the coverage rule among the wiki rules.
- [Constitution](../../core/.apm/skills/ai-sdlc-handbook/references/constitution.md) - clauses C05 and C09.
- Claude Code subagents, a separate context per task: https://code.claude.com/docs/en/sub-agents

## Related

- [ADR 0005](0005-the-gate-contract.md) - the contract the coverage gate follows.
- [ADR 0013](0013-docs-that-span-projects-live-in-a-knowledge-repository.md) - where docs that span projects live.
- [ADR index](README.md) - the list of decisions in this repository.
