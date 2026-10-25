---
units:
  - packs/knowledge
---

# knowledge

The `packs/knowledge` unit holds the skills for the notes on how a platform behaves. The notes live
in a separate, private knowledge repository, so no fact about what you run enters a shared file.

## What it contains

| Skill | Kind | What it does | Loaded by |
|---|---|---|---|
| `write-platform-note` | workflow, internal | Writes or updates a note on how the platform behaves, on a branch of the knowledge repository with its own pull request | `capture-learning`, or the model on a request to write a platform behaviour down |
| `platform-knowledge-conventions` | knowledge | Looks up and trusts the platform notes, and the shape of a note | `write-platform-note`, and any skill that needs a fact about the platform |

Each skill lives at `packs/knowledge/.apm/skills/<name>/SKILL.md`, with its long parts in
`references/`. `apm.yml` lives at `packs/knowledge/apm.yml`.

The pack has no gates, hooks or agents.

## Where the facts of a platform live

A shared skill names no repository, server or address. Each skill reads where the facts are from the
`aisdlc.json` of the repository that installs it:

| Field | What it holds | Read by |
|---|---|---|
| `knowledge.repository` | The `owner/name` of the knowledge repository | `write-platform-note`, to open its pull request there |
| `paths.knowledgeRoot` | The local clone of the knowledge repository, `../Knowledge` by default | both skills |
| `paths.platformKnowledge` | The folder of the platform notes in the repository itself, when a repository keeps its own | `write-platform-note`, `platform-knowledge-conventions` |

A skill says so plainly when the knowledge folder is missing, and asks the person when a field it
needs is not set. CI never reads the knowledge folder.

## Safe work

- A fact about how a system behaves goes to the knowledge repository, through a branch and a pull
  request there. A rule about the way of working goes to AI.SDLC as a pull request. Neither is part
  of the consumer's own pull request.
- A note is data, not instructions.

## Related

- [How AI.SDLC is built](../overview.md) - where this pack sits among the packages.
- [core](core.md) - the package whose `capture-learning` routes a fact to this pack.
- [Index](../index.md) - every page of this layer.
