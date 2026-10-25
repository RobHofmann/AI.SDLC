# What the AI-SDLC gives a team

The AI-SDLC is one way of working that every repository shares. An agent does the work between two
moments where a person decides. It writes the plan, the code, the tests and the docs, and it checks
them with the same gates the pull request workflow runs. A person decides at two human checkpoints. The first is Checkpoint Alpha: a person
approves a story or another document, before it is written to an issue or a page. The second is the review and merge of the pull request.

## What you get

- **One way of working in every repository.** The skills, the agents and the gates come from this
  repository, so a developer who knows one repository knows them all. The core is the way of
  working; a pack adds what one technology needs ([what a pack adds](packs.md)).
- **Gates that give the same answer on your machine and in the workflow.** A push runs the blocking
  gates first, so a broken change stops before the pull request.
- **Docs that stay complete and true.** Every repository has a technical and a functional layer, and
  every part of the code has a page ([complete documentation](documentation.md)).
- **One place to fix a rule.** A fix to a shared rule is made here once. Each repository takes it with
  the next version ([taking a new version](new-version.md)).

## When you need it

- You start work on an issue: run `guide-me` in the repository, and it names the next step.
- You do not know which command fits: ask `guide-me` without an issue, and it names one.
- A bug is reported: run `fix-bug` on it. It reproduces and triages the bug, and fixes it once a person has refined it.
- The change works, on a branch named with the issue number (`42-short-name`): run `wrap-up`. It finishes the tests and docs, commits, and runs the pre-flight, so you only push and open or update the pull request.
- A new repository joins: [adding the AI-SDLC to a repository](joining.md).
- A new version is released: [taking a new version](new-version.md).

## What to know

- The shared files are read-only in a repository that installs them. A fix goes into AI.SDLC.
- A person signs off, never the agent ([C09](../core/.apm/skills/ai-sdlc-handbook/references/constitution.md)). The owner's merge is the approval.
- The words this layer uses are in the [glossary](glossary.md).

## Related

- [What a pack adds to a repository](packs.md) - the add-ons per technology, and what each one brings.
- [Glossary](glossary.md) - the words the AI-SDLC uses, in plain language.
- [Adding the AI-SDLC to a repository](joining.md) - how a new repository joins.
- [How AI.SDLC is built](../docs/overview.md) - the packages and the workflow behind this.
- [Index](index.md) - every page of this layer.
