---
story: "#82"
phase: governance
step: write-adr
intent:
  assumption: "a written layer order in the repository settings, checked on each new reference, keeps the layers that the team chose, also when an agent adds a reference"
  decision-drivers:
    - "no shared rule writes the layer order of a solution, so the reference graph is its only statement"
    - "an agent can add a project reference that nobody asked for, and nothing guards the order"
    - "each repository has its own layers, so the order is a setting and not a rule in a shared file"
    - "a check with a yes or no answer holds, and a rule that needs judgement does not"
relates:
  gate: packs/dotnet/.apm/skills/dotnet-gates/scripts/Check-ProjectLayerOrder.ps1
  graph: packs/dotnet/.apm/skills/dotnet-gates/scripts/DotnetTestScope.psm1
  clause: packs/dotnet/.apm/skills/api-contract-conventions/references/clauses.md
  layout: core/.apm/skills/ai-sdlc-handbook/references/layout.md
  test: packs/dotnet/tests/skills/dotnet-gates/scripts/Check-ProjectLayerOrder.Tests.ps1
  docs: docs/packages/dotnet.md
because:
  gate: "warns about an added reference that does not point to a lower layer"
  graph: "the one reader of project files that both reference gates use"
  clause: "DOTNET-03 covers use in code and the layer order"
  layout: "describes the dotnet.layers setting"
  test: "checks the order, the setting shape and the cases the gate cannot judge"
  docs: "the technical page of the dotnet package"
---

# ADR 0028: A repository sets its .NET layer order, and a new reference points down

**Status:** Accepted
**Date:** 2026-11-27
**Supersedes:** none
**Superseded by:** none

## Context

A .NET solution often keeps its projects in layers: a kernel at the bottom, then the domain, then the
hosts. A project may reference a project below it, never one above it. But nothing writes that order
down. The project references are the only place where it exists, and nothing guards it.

An agent can add a project reference that nobody asked for, and a person can too. Such a reference
against the order mixes parts that the team keeps apart. The order differs per repository, so it cannot
be a rule in a shared file.

The setting needs a way to say which project sits in which layer. `aisdlc.json` already has a setting
with path patterns, `pullRequest.sizeExclude`, which `Test-AiSdlcPathGlob` matches.

## Decision

1. **A repository writes its layer order in `dotnet.layers` of `aisdlc.json`.** It is a list from the
   bottom layer up. Each layer has a `name` and a list `projects` of path patterns to project files. No
   default ships, so a repository without the setting gets "not applicable" (exit 3).
2. **The patterns follow `pullRequest.sizeExclude`.** `Test-AiSdlcPathGlob` matches them, with `**` for
   any depth of folders. A pattern in the wrong case leaves a project in no layer on Linux, and the gate
   names it.
3. **A reference must point to a lower layer, never to its own.** A reference inside one layer is a
   finding, so a host that references another host is caught. A repository that wants two projects of
   one layer to reference each other splits that layer.
4. **There is no separate cycle check.** Every cycle holds a reference that does not point down, so rule
   3 reports it. `dotnet build` also stops on a cycle of project references.
5. **The gate `Check-ProjectLayerOrder.ps1` is Advisory, under clause DOTNET-03.** It judges only the
   references that a change adds; `-All` judges every reference. A project that no layer holds, or that
   two layers hold, is named and its reference is not judged.
6. **The architect checks a plan before the files exist.** `-From` and `-To` judge one planned reference
   by path, and the plan of the `architect` agent names the layers on a `Layers:` line.

## Consequences

- A reference against the layers shows up in the pull request that adds it, as a warning.
- A repository writes its architecture down once, where agents and gates can read it.
- A new project that no pattern matches is named until a person adds it to a layer.
- The gate reads the setting from the working tree, so a pull request can change the order and its
  references together. The change of the setting shows in the diff.
- A consumer that sets no `dotnet.layers` sees no change.

## Alternatives considered

1. **Layers by a regular expression on the project name.** Rejected: a name pattern is harder to read
   than a folder pattern, and the other path settings already use globs.
2. **A shared default order.** Rejected: each solution has its own layers, so a default would be wrong
   for most repositories.
3. **A Blocking gate.** Rejected for now: the gate reads text, and a new setting needs a release to
   settle. A finding is a warning, and the person decides.

## Related

- [ADR 0019](0019-a-gate-reports-pass-finding-could-not-check-or-not-applicable.md) - the exit codes the gate uses.
- [ADR 0026](0026-a-test-proves-the-teams-own-logic-not-the-frameworks.md) - the test rule for the gate tests.
