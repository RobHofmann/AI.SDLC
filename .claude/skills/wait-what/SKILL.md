---
name: wait-what
kind: workflow
phase: cross-cutting
persona: any
disable-model-invocation: true
description: >
  Stop. That last message did not land: re-pitch it. Use when you type /wait-what after an answer
  you could not follow.
---

# Wait, what?

Usable by any persona, in any phase, inside any other skill. Invoked as `/wait-what`, by a person only.

Wait, I do not understand where you have got to here. Re-pitch that: give me a little bit of context.
Write it by clause C11 of the [constitution](/.claude/skills/ai-sdlc-handbook/references/constitution.md) and the
[language rule](/.claude/skills/ai-sdlc-handbook/references/language.md). Use the words of the functional glossary,
`docs-functional/glossary.md` (the folder `paths.functionalDocs` in aisdlc.json names), for each thing
it defines.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).

## Failure modes

- **The re-pitch repeats the same words** -> start from what the person already knows, then add the one
  step they missed. Shorter and with the same words does not land either.
- **A glossary term is swapped for another word** -> keep the glossary word, and explain it once in
  plain words. A new name for a known thing makes the person learn two words.
- **A name, a path or an error is put in plain words** -> keep it exactly as it is. Explain it next to it.
- **The re-pitch writes a file** -> it never does. It is one answer in chat.

## Observable signal

**Positive:** the next message from the person is about the work, not another "what do you mean".

**Drift signal:** if people keep typing `/wait-what` after the same kind of answer, that skill writes
above the reading level. Raise it as a lesson through `capture-learning`.

## Next steps

- Go on with the step that was running. This skill changes how it was said, not what is next.

## Sources

- Adapted from `skills/productivity/wait-what/SKILL.md` in
  [mattpocock/skills](https://github.com/mattpocock/skills), MIT licence, Copyright (c) 2026 Matt Pocock.
  We swapped its reading standard for our language rule and its glossary for the functional glossary.
  The licence is in [LICENSE-upstream.md](LICENSE-upstream.md).
