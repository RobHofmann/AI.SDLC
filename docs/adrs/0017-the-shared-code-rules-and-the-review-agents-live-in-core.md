---
story: "#55"
phase: governance
step: write-adr
intent:
  assumption: "one table of file types lets a general reviewer apply the rules of any language without a change in core"
  decision-drivers:
    - "a repository without the dotnet pack got no shared code rules and no review agents"
    - "a rule copied into each language skill drifts"
    - "a new language should need one table row, not a change to every agent"
relates:
  skill: core/.apm/skills/code-conventions/SKILL.md
  table: core/.apm/skills/code-conventions/references/skills-by-file-type.md
  reviewer: core/.apm/agents/code-reviewer.agent.md
because:
  skill: "the one home of the code rules for every language and the severity scale"
  table: "the convention skill of each file type, which the agents read"
  reviewer: "one of the three review agents that moved from the dotnet pack to core"
---

# ADR 0017: The shared code rules and the review agents live in core

**Status:** Accepted
**Date:** 2026-11-26
**Supersedes:** none
**Superseded by:** none

## Context

The code rules that hold in every language lived inside `csharp-generation-smells` of the dotnet pack.
Examples are reuse before you build, and build only what the story needs. The `code-reviewer`,
`test-analyzer` and `security-reviewer` agents lived in the dotnet pack too, and checked C# and Razor
only. A repository without that pack got no shared code rules and no review agents, so the build loop
reviewed its own work. The reviewers also used three severity levels, while the architect used its own.

## Decision

**The shared code rules live once in the core skill `code-conventions`.** It holds the rules for every
language, the two scope cases and one severity scale with two levels, HIGH and MEDIUM. The comment rule
points to clause C10, so doc comments stay required and a comment that says why is allowed. A language
skill holds only the rules of its language, and links to `code-conventions` for the rest.

**A table names the convention skill of each file type.** The page `skills-by-file-type.md` of
`code-conventions` maps a file ending to its skills and its pack. An agent loads the skills of the files
a change touches, and skips a skill whose pack is not installed. A new language needs one row.

**The three review agents live in core.** `code-reviewer`, `test-analyzer` and `security-reviewer`
preload `code-conventions` and read the rules of each changed file type from the table. The C# checks
of the old agents moved into `csharp-generation-smells`, and the Razor checks into the Razor convention skill of the blazor pack (`razor-conventions` since v2.0.0).
Each language skill with security rules has a section named Security. The dotnet pack ships no agent.

## Consequences

**Positive:**

- A repository with only core gets the shared code rules and the review agents.
- A shared rule changes in one place.
- Every reviewer and the architect use the same scale.

**Negative:**

- A reviewer reads more pages per review: the table and each skill in its rows.
- A consumer that linked to a moved section of `csharp-generation-smells` gets a broken link.

**Neutral:**

- The agent names do not change, so a consumer that installs the dotnet pack gets each agent once, now
  from core. No retired name is listed.

## Alternatives considered

1. **Keep the agents in the dotnet pack and copy them into each language pack.** Rejected because the
   copies drift, and a repository with no stack pack still gets no reviewer.
2. **Keep three severity levels.** Rejected because a LOW finding is noise the build loop cannot act
   on, and two scales let the same finding get two ratings.

## Verification

- `tools/BuildLoopPackaging.Tests.ps1` checks that each skill in the table exists and that core ships
  the review agents. It also checks that the dotnet pack ships none, and that no page names them as
  dotnet agents.
- The test consumers check that `minimal` and `bicep-only` install the agents and `code-conventions`.

## References

- `core/.apm/skills/code-conventions/SKILL.md` - the shared rules and the severity scale.
- `core/.apm/skills/code-conventions/references/skills-by-file-type.md` - the table.

## Related

- [ADR 0014](0014-every-rule-has-one-source-of-truth.md) - one source for every rule, which this applies to the code rules.
- [ADR 0016](0016-a-spec-review-runs-next-to-the-code-review.md) - the spec review that runs next to these reviewers.
- [ADR index](README.md) - the list of decisions in this repository.
