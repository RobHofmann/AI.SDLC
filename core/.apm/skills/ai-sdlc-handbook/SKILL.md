---
name: ai-sdlc-handbook
kind: knowledge
user-invocable: false
description: >
  The handbook of the AI-SDLC. It says how work runs from idea to merged change. It covers the two
  human checkpoints, the artifact graph, the skill and agent patterns, and the personas. It also holds the docs wiki rules,
  the language rules, autolearn and context management, and the layout of the shared files. Use when
  a skill or agent needs the full rule behind a step, or when a person asks how the way of working
  fits together. Also use when deciding whether a file is shared or belongs to the repository. Do NOT use to find the next step for
  a work item (guide-me) or to run a gate (ai-sdlc-gates).
---

# AI-SDLC handbook

The pages in `references/` are the full rules of the way of working. Every repository that installs
the core gets them, and they are read-only there: a change goes to AI.SDLC. A repository's own pages
link to them with a normal relative link, and the doc gates follow that link.

## Start here

- [README.md](references/README.md) - the phases, the skills, the agents and the personas.
- [layout.md](references/layout.md) - core, packs and repo-only files, `aisdlc.json`, the version pin
  and developing against a local clone.
- [orchestration.md](references/orchestration.md) - the two human checkpoints and the stop list.

## The rules by topic

| Topic | Page |
|---|---|
| Your first story through the flow | [first-story.md](references/first-story.md) |
| How a skill, a knowledge skill and an agent are built, and the model of each step | [pattern.md](references/pattern.md) |
| The design decisions behind the way of working | [plan.md](references/plan.md) |
| The core clauses and their enforcement | [constitution.md](references/constitution.md) |
| The artifact graph that links stories, ADRs, specs and docs | [artifact-graph.md](references/artifact-graph.md) |
| The shape of each artifact | [node-templates.md](references/node-templates.md) |
| The personas and the agents that speak for them | [personas.md](references/personas.md) |
| The docs wiki: links, indexes and the doc gates | [docs-wiki.md](references/docs-wiki.md) |
| Language and reading level | [language.md](references/language.md) |
| Comments in code and other files | [comments.md](references/comments.md) |
| Where a lesson goes | [autolearn.md](references/autolearn.md) |
| A repository's own skills, agents, hooks and gates | [consumer-own.md](references/consumer-own.md) |
| When to compact the context | [context-management.md](references/context-management.md) |
| How skill use is counted | [skill-usage.md](references/skill-usage.md) |

## Sources

- [The handbook start page](references/README.md) - the full guide.
- [The layout page](references/layout.md) - where every shared file comes from.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](references/autolearn.md).
