---
story: "#1"
phase: governance
step: write-adr
intent:
  assumption: "a rule the agent keeps breaking is followed more often when the always-loaded file is short, not when the rule is stated more strongly"
  decision-drivers:
    - "an instruction file that grows past what can be read whole makes the model drop rules it did read"
    - "a size that is a number can be a gate; a size that is a feeling is a discussion"
    - "the shared parts of every package land in the same file, so each must stay small"
relates:
  gate: core/.apm/skills/ai-sdlc-gates/scripts/Check-AgentsFileSize.ps1
  shared: tools/Check-SharedAgentsPartSize.ps1
  agents: core/.apm/skills/ai-sdlc-gates/scripts/Sync-AgentsFile.ps1
because:
  gate: "the gate that counts the lines and words of AGENTS.md"
  shared: "the check that keeps the shared parts of all packages within one budget"
  agents: "the script that writes the shared parts into AGENTS.md"
---

# ADR 0007: AGENTS.md has a size limit

**Status:** Accepted
**Date:** 2026-10-24
**Supersedes:** none
**Superseded by:** none

## Context

`AGENTS.md` is loaded into every Claude Code and GitHub Copilot session. It is the place for the rules
that never bend and the pointers to everything else. Each package also writes its shared part into it
([ADR 0001](0001-ai-sdlc-is-shared-as-apm-packages.md)). Such a file tends to grow: a guide here, a
worked incident there.

A long file fails in a known way. The Claude Code best practices say a bloated instruction file makes the
model ignore rules. If it keeps doing something despite a rule, the file is probably too long. The
answer they give is to prune, and to turn a rule into a hook. Stating a broken rule more strongly does
the opposite, because it makes the file longer.

## Decision

**`AGENTS.md` stays within 150 lines and 1800 words, and a gate checks it.** `Check-AgentsFileSize.ps1`
counts both and fails when either limit is passed. It runs in `Invoke-LocalGates.ps1`, in the pre-push
hook and in CI, and it is Blocking. A line limit alone is met by writing longer lines, so the word limit
closes that: 1800 is 150 lines at twelve words per line.

The numbers are a choice, not a published standard. Public guidance agrees on short and specific
without a fixed number. A number is what makes the limit checkable.

**What the file keeps:** the communication rule in short, the project in one paragraph, the build and test
commands, and the core constitution clauses. It also keeps one short section for each step with a pointer to the
detail. Everything else is one link away.

**The shared parts have a budget of their own.** A line added to a shared part is a line taken from
every consumer, so a consumer could break on a change it never made. `tools/Check-SharedAgentsPartSize.ps1`
counts the parts of all packages together, as a consumer with every pack gets them. It fails past 50
lines or 600 words, a third of the consumer limit. So every consumer keeps room for its own part.

## Consequences

**Positive:**

- A new rule for the always-loaded file competes for space. The gate asks whether it belongs there or on
  a page the file points to.
- Every session starts with less context spent on instructions.

**Negative:**

- Detail is no longer in the model's context by default. A skill that needs it reads the page.
- A short file does not by itself make the model follow it. The rules that matter most are also carried
  by hooks and gates ([ADR 0006](0006-hooks-enforce-what-must-happen-every-time.md)). A short file is
  needed, and not enough on its own.

**Neutral:**

- The pointers that move detail out must resolve, which `Check-DocSectionRefs.ps1` checks
  ([ADR 0005](0005-the-gate-contract.md)).

## Alternatives considered

1. **State the broken rules more strongly, in capitals, twice.** Rejected because it grows the file that
   is already too long to be read whole.
2. **A line limit only.** Rejected because it is met by joining lines. The word limit closes that.
3. **Split `AGENTS.md` into several files and load them all.** Rejected because the total in context is
   what matters, not the file count.
4. **Move the constitution out too and keep only a pointer.** Rejected because the clauses are the one
   part that must be in every session, and they fit.

## Verification

- `Check-AgentsFileSize.Tests.ps1`: within the limits passes; over the line limit fails and names the
  count; over the word limit with few lines fails; a missing file exits 2.
- `tools/Check-SharedAgentsPartSize.Tests.ps1` covers the budget of the shared parts.
- `pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1` runs the gate on the real `AGENTS.md`.

## References

- `core/.apm/skills/ai-sdlc-gates/scripts/Check-AgentsFileSize.ps1` - the gate and its defaults.
- `tools/Check-SharedAgentsPartSize.ps1` - the budget of the shared parts.
- Claude Code best practices, keep the instruction file short and turn rules into hooks: https://code.claude.com/docs/en/best-practices
- GitHub blog, lessons from over 2,500 AGENTS.md files, start minimal and stay specific: https://github.blog/ai-and-ml/github-copilot/how-to-write-a-great-agents-md-lessons-from-over-2500-repositories/

## Related

- [ADR 0006](0006-hooks-enforce-what-must-happen-every-time.md) - the enforcement half of the same guidance.
- [ADR index](README.md) - the list of decisions in this repository.
