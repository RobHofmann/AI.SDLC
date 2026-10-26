# Story context template

A committed, context-engineered story file that gives the implementer everything needed to build the slice
without finding it again. It holds the goal, the acceptance criteria, the limits and the code to touch. Its
References section names every technical claim to its source. Adapted from the story-context mechanic in
bmad-code-org/BMAD-METHOD (`src/bmm-skills/4-implementation/bmad-create-story`). That mechanic exists to
prevent the recurring LLM-developer failures (reinventing what exists, wrong files, wrong libraries, ignoring
regressions, vague implementation). No BMAD code is vendored.

Written by `implement` at the start of build to `docs/stories/<KEY>.md`, then consumed by the
implementation step. It is the bridge artifact between elaboration and build, and the second pillar (with the
`intent` fields) of carrying the why into the code phase.

## When to write one

For any story of real size (roughly 5 points and up, or anything touching more than one component). A very small
2-point change does not need it; the story issue is enough. Do not make one for very small work.

## The template

```markdown
---
story: "#42"
phase: create
step: story-context
intent:
  hypothesis: docs/discovery/<theme>/hypothesis.md
  assumption: "the riskiest belief this slice rests on"
  decision-drivers:
    - "why this approach over the alternative"
relates:
  spec: specs/<feature>.openapi.yaml
  adr: docs/adrs/NNNN-<decision>.md
  design: <journey or design link>
  docs: docs/<area>.md
because:
  spec: "the wire contract the build and tests consume"
  adr: "the decision this slice implements"
---

# Story #42: <title>

Phase: create. Step: story-context. Owner: Developer.
Upstream: <the PRD, journey or hypothesis this story derives from, or "none">.
Downstream: <the pull request, or "(not yet created)">.

## Story

As a <persona>,
I want <capability>,
so that <reason>.

## Acceptance criteria

1. AC-1: <specific, observable, one-assertion condition>
2. AC-2: <...>
3. AC-3: <the edge: empty / identical / unaffected neighbour / error path>

(Test tags: each covering test carries the story key, the way the test skill of the installed pack says.
In the dotnet pack that is `[Trait("Story", "#42")]`. There is no tag per criterion.)

## Context and constraints

- Reused as-is: <existing service / component / model and what it already does>.
- New or changed: <component with its path and responsibility>.
- Source tree to touch: <the files and the methods that do the work>.
- Conventions in play: <the relevant convention pages and any constitution clause this touches>.
- Regression risk: <existing behaviour that must stay intact, and the test that guards it>.

## Tasks

- [ ] Task 1 (AC-1): <step>
  - [ ] <subtask>
- [ ] Task 2 (AC-2, AC-3): <step>

## References

Cite every technical claim above to its source, so the implementer does not rediscover or guess:

- [Source: <the convention page>#<its section>]
- [Source: docs/adrs/0007-order-compare.md#decision]
- [Source: specs/order-compare.openapi.yaml]
- [Source: Services/OrderCompareService.cs > CompareOrders]

## Related

- [<area page>](../<area>.md) - the page that describes the area this story changes.
- [ADR NNNN](../adrs/NNNN-<decision>.md) - the decision this story implements, if there is one.

## Graph links

Upstream: <links>
Downstream: <links, or "(not yet created)">
```

Keep comments out of the front matter, because the artifact-graph gate reads the rest of a line as its
value. Leave out `intent.hypothesis` when no hypothesis exists, and `relates.spec` when the slice has no
API surface. Leave out `relates.adr` when no decision was recorded, and `relates.design` when there is no
journey or design.

## Rules

- **Every technical claim carries a source.** A claim can be about how a method behaves, where a type lives,
  or what a convention needs. It must name the file (and symbol or section) it came from. Reference code by path and
  symbol ([C02](/.claude/skills/ai-sdlc-handbook/references/constitution.md)).
- **Aggregate, do not invent.** Pull context from the story issue, the PRD, the journey, the spec, and the
  code. If a key fact cannot be sourced, write it as an open question, not as a stated fact.
- **Carry the why.** The `intent` fields and the `So that` line come from the `grilling` pass; do not
  drop them.
- **No AI attribution** in the written file; [C02 and C06](/.claude/skills/ai-sdlc-handbook/references/constitution.md) hold for it too.
