# Architecture Decision Records

This folder records the key technical decisions for AI.SDLC itself. An ADR (Architecture Decision
Record) says why a decision was made, which options were rejected, and how to check a change in that
area. It stops the team, and any agent, from reopening a settled decision without knowing what it cost.
A decision about the shared way of working is written in the shared files themselves. This folder
holds the decisions about how this repository is built and run.

## When to write one

Write an ADR when a decision is key (constitution clause C01). A decision is key when getting it wrong
breaks the packages, tools or pipelines that depend on it. It is also key when the code alone does not
show the reason. Typical cases:

- A new pattern or boundary, such as a new package split or a new way to release.
- One approach chosen over a real option that the next person could well pick instead.
- A change that departs from a convention or a constitution clause.

Do not write one for a local choice that is easy to undo, or for something a good name already makes
clear. The `adr-conventions` skill holds the full rules, and the `write-adr` skill writes one.

## How to write one

1. Copy [0000-template.md](0000-template.md) to `NNNN-short-title.md`, where `NNNN` is the next number.
2. Start the file with the graph frontmatter: `story:`, `phase: governance`, `step: write-adr`,
   `intent:`, `relates:` and `because:`. Quote the story key, as in `story: "#42"`, because a bare `#`
   starts a YAML comment. Every `relates:` path must exist.
3. Fill in every section. Write it as `Accepted` and dated today: the branch is the proposal and the
   merge is the sign-off.
4. Add a row to the index below.

## Conventions

- **Append-only.** Do not rewrite an accepted ADR. When a decision changes, write a new ADR with
  `Supersedes:`, and change only the status lines of the old one.
- **Stable anchors.** Name a file path, a script or a pipeline ([C02](../../core/.apm/skills/ai-sdlc-handbook/references/constitution.md)).
- **State, not process.** Say what is true and why, and do not tell the story of the review
  ([C08](../../core/.apm/skills/ai-sdlc-handbook/references/constitution.md) covers names).
- **Sources in the References section**, as [C07](../../core/.apm/skills/ai-sdlc-handbook/references/constitution.md) asks.
- **One decision per ADR.**

## Index

| ADR | Title | Status |
|---|---|---|
| [0001](0001-ai-sdlc-is-shared-as-apm-packages.md) | AI.SDLC is shared as APM packages | Accepted |
| [0002](0002-distribution-auth-and-updates-on-github.md) | Distribution, auth and updates on GitHub | Accepted |
| [0003](0003-ai-sdlc-installs-its-own-packages-from-its-own-source.md) | AI.SDLC installs its own packages from its own source | Accepted |
| [0004](0004-two-human-checkpoints-and-one-skill-model.md) | The way of working runs between two human checkpoints | Accepted |
| [0005](0005-the-gate-contract.md) | The gate contract | Accepted |
| [0006](0006-hooks-enforce-what-must-happen-every-time.md) | Hooks enforce what must happen every time | Accepted |
| [0007](0007-agents-md-has-a-size-limit.md) | AGENTS.md has a size limit | Accepted |
| [0008](0008-every-repository-documents-every-unit-in-two-layers.md) | Every repository documents every unit in two layers | Accepted |
| [0009](0009-coverage-is-a-ratchet-against-a-baseline.md) | Coverage is a ratchet against a baseline | Accepted |
| [0010](0010-the-story-key-is-a-github-issue-number.md) | The story key is a GitHub issue number | Accepted |
| [0011](0011-the-public-repository-holds-no-private-information.md) | The public repository holds no private information | Accepted |
| [0012](0012-ci-is-a-composite-action-inside-the-installed-core.md) | CI is a composite action inside the installed core | Accepted |
| [0013](0013-docs-that-span-projects-live-in-a-knowledge-repository.md) | Docs that span projects live in a knowledge repository | Accepted |
| [0014](0014-every-rule-has-one-source-of-truth.md) | Every rule has one source of truth | Accepted |

## Related

- [ADR 0001](0001-ai-sdlc-is-shared-as-apm-packages.md) - how the way of working is shared.
- [ADR 0003](0003-ai-sdlc-installs-its-own-packages-from-its-own-source.md) - why AI.SDLC runs its own packages, from the branch.
- [How AI.SDLC is built](../overview.md) - the packages, the self install and the pipelines.
- [ADR template](0000-template.md) - the file to copy for a new decision.
