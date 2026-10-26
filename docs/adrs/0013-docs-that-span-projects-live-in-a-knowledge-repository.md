---
story: "#1"
phase: governance
step: write-adr
intent:
  assumption: "a knowledge repository cloned next to each consumer, at ../Knowledge, is found by the agent without any setup per repository"
  decision-drivers:
    - "the agent must grep the docs next to the code, so the docs must be files in a working tree"
    - "an agent edit to the docs must go through a pull request and its checks"
    - "facts that span projects need one home, and the public repository cannot be it"
relates:
  config: core/.apm/skills/ai-sdlc-gates/scripts/AiSdlcConfig.psm1
  allow: core/.apm/skills/ai-sdlc-gates/scripts/Sync-AllowRules.ps1
  install: core/.apm/skills/ai-sdlc-hooks/scripts/Install-AiSdlc.ps1
  note: packs/knowledge/.apm/skills/write-platform-note/SKILL.md
  wiki: core/.apm/skills/ai-sdlc-handbook/references/docs-wiki.md
because:
  config: "the default paths.knowledgeRoot of ../Knowledge"
  allow: "the script that gives the agent read access to the knowledge folder"
  install: "the setup that reports a missing knowledge folder and how to clone it"
  note: "the skill that writes a knowledge note through a pull request there"
  wiki: "the docs model the knowledge repository follows, two layers of checked markdown"
---

# ADR 0013: Docs that span projects live in a knowledge repository

**Status:** Accepted
**Date:** 2026-10-24
**Supersedes:** none
**Superseded by:** none

## Context

Each repository documents itself in two layers of markdown ([ADR 0008](0008-every-repository-documents-every-unit-in-two-layers.md)).
Some knowledge spans projects: how a server, a network or a home setup behaves, decisions that hold
across repositories, and the private term list ([ADR 0011](0011-the-public-repository-holds-no-private-information.md)).
It needs one home, and AI.SDLC cannot be it, because AI.SDLC is public.

Two forms were open: markdown in a repository, or a GitHub Wiki. A GitHub Wiki is a separate git
repository. It has no pull requests and no checks, so an agent edit lands unreviewed. It is not in the
working tree, so a grep next to the code misses it (GitHub docs on wikis).

Claude Code reads only the working folder without asking. A setting can add more folders
(`permissions.additionalDirectories`).

## Decision

**1. Markdown in a repository, never a GitHub Wiki.** The docs model of AI.SDLC is a checked wiki of
markdown pages, with an index per layer and two layers. It does what a wiki does, with review.

**2. A separate private repository holds the docs that span projects.** It installs AI.SDLC like any
consumer, with the `knowledge` pack, so its notes follow the same rules and gates.

**3. Its clone sits next to each consumer.** `paths.knowledgeRoot` defaults to `../Knowledge`. A
consumer sets nothing; a different layout overrides it in `aisdlc.json`.

**4. Five parts make the folder work without thought.**

- `knowledge.repository` in a consumer's `aisdlc.json` names the repository. `Install-AiSdlc.ps1`
  prints an advisory row when the folder is missing, with `gh repo clone <repository> <knowledgeRoot>`.
- `Sync-AllowRules.ps1` writes the absolute path of the folder into `permissions.additionalDirectories`
  of `.claude/settings.local.json`. That file is per machine and not tracked. It never writes into
  `.claude/settings.json`.
- `walk-substrate` and `guide-me` grep the folder next to the repository docs when it exists, and say so
  plainly when it does not.
- `capture-learning` and `write-platform-note` write a fact about how a system behaves to the knowledge
  repository, through a branch and a pull request there. A write is never part of the consumer's own
  pull request.
- CI never reads the folder, because CI has no clone of a private repository.

## Consequences

**Positive:**

- The agent finds shared facts with the same grep it uses for the repository docs.
- Every change to shared docs goes through a pull request and the doc gates.
- Private facts stay private, and AI.SDLC stays process only.

**Negative:**

- One more repository to clone on each machine. The setup row says how.
- A gate in a consumer cannot check anything that lives only in the knowledge repository.
- The absolute path in `.claude/settings.local.json` must be written once per machine, by the setup.

**Neutral:**

- Copilot CLI gets the same folder through its `--add-dir` option, which the handbook names.

## Alternatives considered

1. **A GitHub Wiki.** Rejected because it has no pull requests and no checks, and it is not in the
   working tree, so the agent's grep misses it.
2. **The shared docs inside AI.SDLC.** Rejected because AI.SDLC is public and the facts are private.
3. **A copy of the shared docs in each consumer.** Rejected because the copies drift.
4. **A relative path in `.claude/settings.json`.** Rejected because how Claude Code resolves a relative
   path there is not documented, and that file is shared by every machine.

## Verification

- `AiSdlcConfig.Tests.ps1` covers the default `paths.knowledgeRoot`.
- `Sync-AllowRules.Tests.ps1` covers the write into `.claude/settings.local.json`, and that
  `.claude/settings.json` is not touched.
- `Install-AiSdlc.Tests.ps1` covers the advisory row with the clone command.
- Not covered by a test: the agent's grep of the folder in a real session.

## References

- `core/.apm/skills/ai-sdlc-gates/scripts/AiSdlcConfig.psm1` - `paths.knowledgeRoot` and `knowledge.repository`.
- `core/.apm/skills/ai-sdlc-gates/scripts/Sync-AllowRules.ps1` - the read access.
- `packs/knowledge/` - the pack the knowledge repository installs.
- [Documentation wiki](../../core/.apm/skills/ai-sdlc-handbook/references/docs-wiki.md) - the docs model.
- About GitHub wikis: https://docs.github.com/en/communities/documenting-your-project-with-wikis/about-wikis
- Claude Code settings, `additionalDirectories`: https://code.claude.com/docs/en/settings
- Claude Code permissions, working directories: https://code.claude.com/docs/en/permissions

## Related

- [ADR 0008](0008-every-repository-documents-every-unit-in-two-layers.md) - the docs of each repository.
- [ADR 0011](0011-the-public-repository-holds-no-private-information.md) - why the facts cannot be in AI.SDLC.
- [ADR index](README.md) - the list of decisions in this repository.
