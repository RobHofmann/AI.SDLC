---
name: tc-setup-notes
kind: knowledge
user-invocable: false
description: >
  How this test consumer is set up: which packs it installs and where its own skills live. Use when a
  change touches apm.yml or the root .apm folder of this repository. It is the own skill of a test
  consumer, so the install test proves that an own skill and the shared skills install together.
---

# Setup notes

This repository keeps its own skills in the root `.apm/skills/` folder, next to `apm.yml`. APM
installs them into `.claude/skills/` together with the shared skills. The prefix `tc-` marks a skill
of this repository, so its name never meets a shared name.

## Failure modes

- **An own skill gets a shared or a retired name** -> rename it with the `tc-` prefix. The sync gate
  fails on the clash.
- **An own skill sits in a local package that git does not track** -> move it to the root `.apm/`
  folder. The local-package gate fails on the missing folder.

## Observable signal

**Positive:** `apm install` puts this skill in `.claude/skills/tc-setup-notes/`, and the blocking
gates pass.

**Drift signal:** the gates name this skill after an install. Then the own-content rules changed.

## Sources

- [Setup](/docs/setup.md) - how this repository installs its packs.
- [Own skills, agents and hooks](/.claude/skills/ai-sdlc-handbook/references/consumer-own.md) - the shared rule.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words. See
  [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson that would change a future run goes to its durable home. See
  [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).
