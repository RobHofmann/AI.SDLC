# ADR NNNN: short decision title

Copy this file to `NNNN-short-title.md`, fill in every section, and remove this line.

```yaml
---
story: "#1234"
phase: governance
step: write-adr
intent:
  assumption: "the riskiest belief this decision rests on, stated so it could be proven wrong"
  decision-drivers:
    - "the force that drove this choice over the other option"
relates:
  docs: docs/<area>.md
because:
  docs: "why this page belongs to the decision"
---
```

Put the block above, without the fence, at the very top of the file. The fields are described in the
[artifact graph page](../../core/.apm/skills/ai-sdlc-handbook/references/artifact-graph.md).

**Status:** Accepted | Proposed | Superseded
**Date:** YYYY-MM-DD
**Supersedes:** none | ADR NNNN
**Superseded by:** none | ADR NNNN

## Context

The forces behind the decision, as they are now. Name files, symbols and pipeline names, never line
numbers. Do not tell the story of the review and do not name people.

## Decision

What was decided, in plain words. Name the files, packages and pipelines it touches.

## Consequences

**Positive:**

- What gets better or simpler.

**Negative:**

- What gets harder or easier to break.

**Neutral:**

- Side effects that are neither a gain nor a loss.

## Alternatives considered

1. **Option name.** What it was, and why it was rejected.

## Verification

How someone checks that a change in this area is right: the gate, the test or the steps by hand. Say
what the tests do not cover.

## References

- `path/to/file` - what it anchors.
- Merged pull requests by number, and external pages with their links.

## Related

- [ADR index](README.md) - the list of decisions in this repository.
