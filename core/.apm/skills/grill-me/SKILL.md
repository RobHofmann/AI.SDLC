---
name: grill-me
kind: workflow
phase: cross-cutting
persona: any
disable-model-invocation: true
description: >
  A relentless interview to sharpen a plan or a design. Use when you type /grill-me to stress-test
  your own thinking before anything is written.
---

# Grill me

Usable by any persona, in any phase. Invoked as `/grill-me`, by a person only.

Run the `grilling` skill on the plan, the decision or the idea the person names. If they name nothing,
take the one in the conversation.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).

## The docs impact

`grilling` ends with a docs impact: each docs page the answers change, and what it will say. Where it
goes depends on where you run it:

- **On a story branch**, hand it to `write-docs`. Run on its own, that skill shows the diffs before it
  writes.
- **With an issue but not on its branch**, `write-story` posts it as one `📚 Docs impact YYYY-MM-DD HH:mm`
  comment on the issue after you confirm. The build of that issue applies it.
- **With no issue and no branch**, write nothing. Show the docs impact, and tell the person how to keep
  it: run `/write-story` for a docs story, which posts the docs impact as its comment.

## Failure modes

- **There is no artifact in view** -> that is fine. `grilling` still records the answers and the why in
  chat, and the person decides what to write.
- **The interview turns into drafting** -> stop when the frontier is empty and the person confirms. To
  write the result, run the authoring skill that owns it.
- **The docs impact is written with no issue and no branch** -> nothing is written then. A docs change
  needs a story key for its branch, so the person starts a docs story with `/write-story`.

## Observable signal

**Positive:** the person ends with every branch of the plan settled, or with a short, named list of what
is still open.

## Next steps

- `/write-story` (Product Manager), `/write-prd` (Product Manager) or `/write-adr` (Architect) - write
  the settled plan into the artifact that keeps it.
- `/convene-personas` - to talk to one role in a free conversation instead.
- `/write-docs` (Tech Writer) - on a story branch, apply the docs impact.

## Sources

- Adapted from `skills/productivity/grill-me/SKILL.md` in
  [mattpocock/skills](https://github.com/mattpocock/skills), MIT licence, Copyright (c) 2026 Matt Pocock.
  We added the sections our skill gate asks for. The licence is in
  [LICENSE-upstream.md](LICENSE-upstream.md).
