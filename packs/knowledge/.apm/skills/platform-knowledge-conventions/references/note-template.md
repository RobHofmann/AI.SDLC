# The shape of a platform note

One markdown file per topic in the folder of `paths.platformKnowledge` of the knowledge repository,
named `kebab-case-topic.md`.
The `README.md` of the folder is the index: one entry per note, with a line that says what it answers.
Every note has this shape:

```markdown
# Short, searchable title

- **Applies to**: which environments, resource types, or roles this affects
- **Source**: PR link, commit, or doc that proves this (dated)
- **Discovered via**: the issue, incident or question that first raised it, such as `#42` (optional)
- **Last verified**: date, and how (code read, live test)

## What it does

Plain description of the behavior or capability, in the same terms a requester would use.

## When this answers an issue

The kind of request this solves, so it is easy to match against the text of a new issue, incident or
question.

## Checks for this issue

Read-only commands or lookups that confirm the note applies to this issue, and what result means
"applies" against "does not apply".

## Caveats

Anything the evidence did not confirm, or conditions that must hold for this to apply.

## Related

- [<a docs page this note supports>](<relative path>) - <why it is related>.
```

Leave out `Discovered via` when no issue, incident or question was involved. The checks are read-only
commands, so anyone can run them during an investigation without a change. The Related section links at least one other docs
page, because the docs wiki gate fails a page with no cross-link. A link from the index does not count.

## Related

- [platform-knowledge-conventions](../SKILL.md) - the rules for looking up and writing a note.
