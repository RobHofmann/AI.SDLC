---
story: "#1"
phase: governance
step: write-adr
intent:
  assumption: "a rule that an agent loads from its source cannot drift, where any copy of it can"
  decision-drivers:
    - "every agent needs every clause in every session, not only a pointer to them"
    - "a rule restated in a second place drifts, and then two texts disagree"
    - "Claude Code expands an @ import inside AGENTS.md at the start of a session"
relates:
  constitution: core/.apm/skills/ai-sdlc-handbook/references/constitution.md
  agents: core/.apm/skills/ai-sdlc-gates/assets/agents-core.md
  dotnet: packs/dotnet/.apm/skills/dotnet-gates/assets/agents-dotnet.md
because:
  constitution: "the one source of every core clause, and the home of clause C12"
  agents: "the core part of AGENTS.md that imports the constitution"
  dotnet: "the dotnet part of AGENTS.md that imports the dotnet clauses the same way"
---

# ADR 0014: Every rule has one source of truth

**Status:** Accepted
**Date:** 2026-10-25
**Supersedes:** none
**Superseded by:** none

## Context

The core clauses lived in two places. The handbook page `constitution.md` held the full clauses. The
core part of `AGENTS.md`, `agents-core.md`, held a one-line form of each clause. The dotnet pack did the
same for DOTNET-01 and DOTNET-02. Many skills, agents and docs also restated a clause in their own
words. Nothing checked that these texts still said the same thing.

Every agent needs the clauses in every session. Claude Code reads `AGENTS.md` through the import line
`@../AGENTS.md` in `.claude/CLAUDE.md`. Its docs say that an `@path` line is expanded at the start of a
session, also inside `AGENTS.md`. The path is relative to the file that holds it, up to four hops deep
([Claude Code memory](https://code.claude.com/docs/en/memory.md), "Import additional files"). GitHub
Copilot reads `AGENTS.md` too, but does not expand an `@` line.

## Decision

**Every rule and every fact has one source.** Clause C12 in `constitution.md` states it. Anywhere else,
a text loads the source or links to it, with the clause ID and a link. A rule is never copied. Only where
a tool can neither load nor link the source, a script generates the copy and a gate checks it. The
`## Standing rules` block of a skill is a pointer with a one-line summary, so it stays.

**`AGENTS.md` imports the clauses instead of listing them.** The core part holds one rule line and the
import line `@.claude/skills/ai-sdlc-handbook/references/constitution.md`. The dotnet part imports
`.claude/skills/api-contract-conventions/references/clauses.md` the same way. `Sync-AgentsFile.ps1`
copies both lines into `AGENTS.md` as they are. The root `AGENTS.md` sits next to `.claude/`, so the
path resolves in every consumer.

**Free text is checked in review.** No gate can find a restated rule reliably. So code review and the
`docs-reviewer` agent check a changed page for a rule restated in free text.

## Consequences

**Positive:**

- A clause changes in one place, and every session loads the new text at once.
- An agent has the full clause in context, with its reason and its enforcement, not a one-line form.
- No generator, no marker lines and no drift gate to keep.

**Negative:**

- Every Claude Code session loads about 4,500 more tokens of context: the constitution has about
  3,300 words.
- GitHub Copilot sees the import line as a plain path. It has the clauses only when it opens that file.

**Neutral:**

- The shared parts of `AGENTS.md` get shorter, so they stay further within the budget of
  [ADR 0007](0007-agents-md-has-a-size-limit.md). That budget counts lines in `AGENTS.md`, not the
  imported page.

## Alternatives considered

1. **A clause list that a script generates from the Short form lines, with a drift gate.** Rejected
   because it is still a copy of the rule. It also needs a generator, two marker lines and a gate, and the
   agent still sees only one line per clause.
2. **Only a sentence in `AGENTS.md` that tells the agent to read the constitution.** Rejected because an
   agent then has no clause in its context until it chooses to open the page.
3. **A copy kept by hand, checked in review only.** Rejected because a hand-kept copy drifts. Review does
   not compare two texts line by line every time.

## Verification

- `Sync-AgentsFile.Tests.ps1` covers how the parts are copied into `AGENTS.md`.
- A fresh Claude Code session in AI.SDLC quotes clause C12 without opening a file.
- The tests do not find a rule restated in free text; review does.

## References

- `core/.apm/skills/ai-sdlc-handbook/references/constitution.md` - clause C12 and every core clause.
- `core/.apm/skills/ai-sdlc-gates/assets/agents-core.md` - the import line of the core part.
- `core/.apm/skills/ai-sdlc-gates/scripts/Sync-AgentsFile.ps1` - copies the parts into `AGENTS.md`.
- [Claude Code memory](https://code.claude.com/docs/en/memory.md) - how an `@path` import is expanded.

## Related

- [ADR 0007](0007-agents-md-has-a-size-limit.md) - the size budget of `AGENTS.md`.
- [ADR index](README.md) - the list of decisions in this repository.
