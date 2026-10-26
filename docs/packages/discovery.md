---
units:
  - packs/discovery
---

# discovery

The `discovery` pack provides skills for research synthesis, customer journey mapping, and evidence-based hypothesis framing during discovery.

## What it contains

The pack contains four files:

- `packs/discovery/apm.yml`
- `packs/discovery/.apm/skills/draw-customer-journey/SKILL.md`
- `packs/discovery/.apm/skills/write-research-summary/SKILL.md`
- `packs/discovery/.apm/skills/write-hypothesis/SKILL.md`

Each skill writes its page as a Markdown file in the repository, under `paths.discoveryRoot` of
`aisdlc.json` (`docs-functional/discovery` by default). The pull request publishes it.

### `draw-customer-journey`

`draw-customer-journey` creates a diagram of the customer journey and opportunity landscape for a discovery topic.

It exposes journey stages, user pains, and opportunities before solution work begins.

Use it when a spike needs a navigable view of the current experience.

Do not use it to run or synthesize research. Use `write-research-summary` for research synthesis.

Do not use it to frame assumptions that could be wrong. Use `write-hypothesis` for hypothesis framing.

Do not use it to create user stories or epics with `write-story`.

Do not use it to add links to an existing issue; `write-story` does that in its update mode.

### `write-research-summary`

`write-research-summary` turns raw research into findings anchored on an issue with the `spike` label.

It is the entry point to the discovery phase when gathered research needs to become navigable and actionable.

Research collection remains in the upstream tool.

Do not use this skill to create a standard feature story with `write-story`.

Do not use it to author an ADR with `write-adr`.

Do not use it to add links to an already synthesized issue; `write-story` does that in its update mode.

### `write-hypothesis`

`write-hypothesis` captures a product hypothesis as a lean canvas for a discovery topic.

It separates facts from assumptions and records how the riskiest assumption could be tested.

Use it when a discovery direction needs evidence-based framing before work continues.

Do not use it to synthesize raw research. Use `write-research-summary` instead.

Do not use it to write a full PRD with `write-prd`.

Do not use it to map stories with `write-story`.

Do not use it to author an ADR with `write-adr`.

## Dependencies

`write-research-summary` receives research gathered in an upstream tool and anchors the synthesis to a spike issue.

Its output can feed later elaboration work.

`draw-customer-journey` can make a spike journey navigable after research is available.

`write-hypothesis` can capture a belief surfaced by research so the team can state and test it.

A repository file that one of these skills writes goes on a branch named with the issue number of the spike. `wrap-up` commits it and runs the pre-flight, and the skill then pushes and opens or updates the pull request through `github-pull-requests`.

Keep these boundaries when changing the pack. Research synthesis, journey mapping, and hypothesis framing remain separate responsibilities.

## Related

- [How AI.SDLC is built](../overview.md) - where this pack sits among the packages.
- [core](core.md) - the package every repository installs next to this one.
- [github-issues](github-issues.md) - the pack whose `write-story` turns findings into issues.
- [Index](../index.md) - every page of this layer.
