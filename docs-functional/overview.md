# What the AI-SDLC gives a team

The AI-SDLC is one way of working that every repository shares. An agent does the work between two
moments where a person decides. It writes the plan, the code, the tests and the docs, and it checks
them with the same gates the pull request workflow runs. A person decides at two human checkpoints. The first is Checkpoint Alpha: a person
approves a story or another document, before it is written to an issue or a page. The second is Checkpoint Bravo: the agent opens the pull request as a draft, and a person checks it, publishes it and merges it.

## What you get

- **One way of working in every repository.** The skills, the agents and the gates come from this
  repository, so a developer who knows one repository knows them all. The core is the way of
  working; a pack adds what one technology needs ([what a pack adds](packs.md)).
- **Gates that give the same answer on your machine and in the workflow.** A push runs the blocking
  gates first, so a broken change stops before the pull request. A green pull request build means
  every blocking gate really checked. A blocking gate that could not check fails the build, and a
  gate with nothing to check shows as `N/A`. A repository can make a shared gate stricter, softer or
  Off in its own `aisdlc.json`, and every run shows that choice. The secret scan always stays on
  ([how a gate answers](gate-results.md)).
- **Docs that stay complete and true.** Every repository has a technical and a functional layer, and
  every part of the code has a page ([complete documentation](documentation.md)).
- **One place to fix a rule.** A fix to a shared rule is made here once. Each repository takes it with
  the next version ([taking a new version](new-version.md)).

## When you need it

- You start work on an issue: run `guide-me` in the repository, and it names the next step.
- You want to watch the build step by step, for example to tune it on a real issue: run
  `/implement <n> manual`. It stops for you after the walk, after the plan, before the code of each
  test and before the review fixes.
- You do not know which command fits: ask `guide-me` without an issue, and it names one.
- A bug is reported: run `fix-bug` on it. It reproduces and triages the bug, and fixes it once a person has refined it.
- The change works, on a branch named with the issue number (`42-short-name`): run `wrap-up`. It finishes the tests and docs, commits, and runs the pre-flight, so you only push and open or update the pull request.
- A new repository joins: [adding the AI-SDLC to a repository](joining.md).
- A new version is released: [taking a new version](new-version.md).

## What to know

- The shared files are read-only in a repository that installs them. A fix goes into AI.SDLC.
- A person signs off, never the agent ([C09](../core/.apm/skills/ai-sdlc-handbook/references/constitution.md)). The agent opens a draft pull request, only a person publishes it, and the owner's merge is the approval.
- Two reviews run before the pull request opens. One checks the change against the issue: a missing
  criterion, or code nobody asked for. The other checks how it is built. You read them as two short
  reports in the pull request.
- The build reuses before it builds. Before the code, the walk names the code and the tests that
  already exist for what the change touches. The builder extends those first, so a review rarely has
  to ask for a second copy to be removed.
- A story fits on one screen: six short sections, goal first, and at most 5 acceptance criteria. The test results behind it sit in a dated comment, not in the body.
- Copilot reviews the pull request when the agent opens it, and again only after a change of 20 lines or more.
- After you publish the draft, the agent adds the `in-review` label to its open stories. So a team sees with one search which stories wait for review.
- The words this layer uses are in the [glossary](glossary.md).

## Related

- [What a pack adds to a repository](packs.md) - the add-ons per technology, and what each one brings.
- [Glossary](glossary.md) - the words the AI-SDLC uses, in plain language.
- [Adding the AI-SDLC to a repository](joining.md) - how a new repository joins.
- [How AI.SDLC is built](../docs/overview.md) - the packages and the workflow behind this.
- [Index](index.md) - every page of this layer.
