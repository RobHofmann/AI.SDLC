---
name: platform-knowledge-conventions
kind: knowledge
user-invocable: false
description: >
  How we keep and use the platform notes: short pages about how a platform or system really behaves
  in production, such as self-service paths, defaults and limits. It covers where the notes live, how to
  look one up, when a note is too old to trust, what never goes in a note, and the shape of a note.
  Use when an issue, an incident or a question may already be a known platform behavior, for example a
  request for access or rights, or when someone asks "do we know how the platform does X". Do NOT use to
  write or change a note (write-platform-note), or for the technical and functional docs of the
  repository (docs-wiki-conventions).
---

# Platform knowledge conventions

How the platform notes are found and trusted. The notes live in the knowledge repository: the
repository that installs this pack. Inside it they are in the folder of `paths.platformKnowledge` in
aisdlc.json, `docs/platform-knowledge` by default. From another repository, the knowledge repository is
the folder of `paths.knowledgeRoot` (`../Knowledge` by default). When that folder does not exist, say so
plainly. The notes exist so nobody has to work the same thing out twice. A request that looks like work
by hand may already be self-service. A symptom may already be a known default. Load this before you look
into an issue, an incident or a question about platform behavior. `write-platform-note` loads it before
it writes.

## Look up a note

1. Read the `README.md` of the folder for the index. Or search the folder for terms from the request:
   role names, resource types, the request type, the error text.
2. When a note matches, judge the fit with its "When this answers an issue" section. Run its "Checks
   for this issue" section against this request, read only.
3. A match does not remove the checks on this request: which environment, which application, which
   role. It removes the need to work out the general behavior again.
4. When a check fails, the note does not apply as written. Say so, and look into it as normal.
5. When nothing matches, say so plainly. Do not force a weak match.

## Trust a note only as far as it goes

- **A "Last verified" date older than 6 months** makes the note a lead, not evidence. Check the
  behavior again before you rely on it.
- **Every claim meets [C07](/.claude/skills/ai-sdlc-handbook/references/constitution.md).** Its source is a merged pull request, a template,
  workflow or source file, or an official doc. A claim with no source belongs under Caveats.

## What goes in a note, and what never does

- **In:** a fact that is not clear to a requester and is likely to come up again. Examples are a
  self-service path, a platform default, or a limit in a template, a workflow, a policy or the
  application code.
- **Never:** anything specific to one customer or one resource, anything no source confirms yet, a
  name of a person, or a story of one issue. A note reads as true whatever issue or change prompted it.
- **One note per topic.** Update the existing note when a change moves its behavior, with a new
  "Last verified" date, rather than write a second one.

The shape of a note and of the index is in [the note template](references/note-template.md).

## Sources

- [The note template](references/note-template.md) - the sections of a note and the index.
- [The layout page](/.claude/skills/ai-sdlc-handbook/references/layout.md) - the
  `paths.platformKnowledge` field of aisdlc.json.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).
