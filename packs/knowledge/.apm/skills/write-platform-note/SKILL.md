---
name: write-platform-note
kind: workflow
phase: cross-cutting
persona: Operations engineer
user-invocable: false
description: >
  Write down or update a platform note: a short page about how a platform or system really behaves
  in production, such as a self-service path, a default or a limit. Use when an investigation, an
  issue, an incident or a merged change shows a platform behavior worth keeping, or when asked to write
  down, document or record how the platform behaves. Do NOT use to look a note up
  (platform-knowledge-conventions holds the look-up rules), to investigate an issue itself, or to
  write the technical or functional docs of the repository (write-docs).
---

# Write a platform note

Owned by the **Operations engineer** persona. It is an internal step.
`capture-learning` calls it when a lesson is about how the platform behaves. The model loads it on a
request to write a platform behaviour down, or when an investigation taught a reusable fact.

This is an author step. It drafts a new note or changes an existing one in the knowledge repository,
in the folder of `paths.platformKnowledge`. A person reviews it in the pull request there. A write
does not need an issue. Write the note when a platform pull request merges and changes what customers
can do or see. Then it is there before the first question arrives.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).

## Non-negotiables

- This skill writes only files in the knowledge repository. It never changes a live system or a
  cloud resource. Reading a pull request or a source file on GitHub to confirm a behavior is allowed.
  A check against a live system stays read-only.
- The note never joins the pull request of another repository. A fact about how a system behaves goes
  to the knowledge repository through its own branch and pull request there.
- Do not invent a platform behavior to fill a note. Every claim needs a source. If you are not sure,
  say so under Caveats instead of stating it as fact.

## What the skill reads

- Load [platform-knowledge-conventions](/.claude/skills/platform-knowledge-conventions/SKILL.md)
  first. It holds what goes in a note, what never does, the source rule, and the shape of a note.
- The knowledge repository: this repository when it installs this pack, else the folder of
  `paths.knowledgeRoot` in aisdlc.json (`../Knowledge` by default). When that folder does not exist,
  say so and stop.
- `paths.platformKnowledge` from the aisdlc.json of the knowledge repository, the folder of the notes.
  Its `README.md` is the index.
- When the folder or its `README.md` does not exist, stop and ask before you create them.

## Write the note

1. Read the index and search the folder for the role, resource and error terms, so you update a note
   rather than repeat it. When a change moves the behavior in an existing note, update that note and
   its "Last verified" date.
2. Create or update `<platformKnowledge>/<kebab-case-topic>.md` in the shape of
   [the note template](/.claude/skills/platform-knowledge-conventions/references/note-template.md).
   Fill in "Checks for this issue" with read-only commands. Set "Last verified" to today, with how you
   checked it. Leave "Discovered via" out when no issue, incident or question was involved. Link at least one other docs
   page from the Related section, and run `Check-DocsWiki.ps1 -Strict` before you show the note.
3. Add or update the entry in the index of the `README.md`, so the note can be found without reading
   every file.
4. Keep the note free of names and of details that only fit one issue.
5. Show the person the note and the index change before the commit. Inside a build loop of another
   repository (through `capture-learning` in `wrap-up`), the note stays out of that commit. It goes to
   the knowledge repository as in step 6, and the person sees it in that pull request.
6. In the knowledge repository, the note goes on a branch named with an issue number (`42-<topic>`).
   When you are not on such a branch, create it from the current state
   (`git switch -c <n>-<topic>`); the work moves with it. When you are on one, stay on it.
   `/write-story` makes the issue when there is none. Then `/wrap-up` commits it and runs the
   pre-flight. Push the branch and open or update the pull request through `github-pull-requests`
   (`New-PullRequest.ps1` for a new one, `Update-PullRequest.ps1` for an open one).

## Failure modes

- **A duplicate note.** A new note repeats an existing one under another name. Search the index and
  the folder for the role, resource and error terms first, and update the existing note.
- **An issue log instead of a fact.** The note tells the story of one issue, with names and dates.
  Rewrite it as what is true in general and how to recognize it.
- **No source.** A claim has no pull request, file or doc behind it. Move it to Caveats, or leave it
  out.
- **The folder is missing.** `paths.platformKnowledge` points at a folder that does not exist. Ask
  before you create it, because the repository may keep its notes somewhere else.
- **The note lands in the wrong pull request.** The note joins the commit of the repository you work
  in. Move it to a branch of the knowledge repository.

## Observable signal

- **Positive signal:** a changed note with a fresh "Last verified" date, a source for each claim, and
  a matching index entry.
- **Audit trail:** the note and the index change in the pull request.
- **Drift signal:** notes with no "Last verified" date, index entries that point at no file, or notes
  that name a person or a customer.

## Next steps

- `/wrap-up` (Developer) - commits the note in the knowledge repository and runs the pre-flight; then
  push and open or update the pull request. A person reviews it there.
- `wrap-up` runs [write-docs](/.claude/skills/write-docs/SKILL.md), which keeps the wiki in step when the
  docs index of the repository lists the folder.
- When the note came from an investigation, go back to that investigation.
