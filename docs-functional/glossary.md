# Glossary

The words the AI-SDLC uses, each with one plain sentence.

- **AI-SDLC**: the shared way of working in which an agent does the work and a person decides at two human checkpoints.
- **APM**: the Agent Package Manager, the tool that installs the packages into a repository.
- **Artifact**: a document that records the work. It is a page in the docs of a repository, such as an ADR or a discovery page. It can also be a story, bug or epic in GitHub Issues. The code is not an artifact; the tests link it to the story.
- **Checkpoint Alpha**: the moment a person approves a story or another document, before it is written to an issue or a page.
- **Checkpoint Bravo**: the moment a person checks the draft pull request, publishes it with Ready for review, and merges it. The merge is the approval.
- **Docs impact**: the comment that `grilling` leaves on an issue, starting with `📚 Docs impact` and a date and time. It says per docs page what the page will say, and the build applies it.
- **Draft pull request**: the state in which the agent opens every pull request. Only a person publishes it.
- **Consumer**: a repository that installs the AI-SDLC from AI.SDLC.
- **Core**: the package every consumer installs, with the workflow skills, the agents, the hooks and the core gates.
- **Functional layer**: the docs that say what a repository gives its users, in plain words.
- **Gate**: a check that a script runs the same way on a machine and in the workflow, and that can stop a change.
- **Human checkpoint**: a moment where a person decides and no script does. There are two: Checkpoint Alpha and Checkpoint Bravo.
- **Evidence comment**: the one comment per run, starting with `Evidence` and a date and time, that holds the test results and probes behind an issue. The issue body holds only the conclusions.
- **In-review label**: the label (`in-review` by default) that says a story has a published pull request that waits for review. The agent adds it only after a person publishes the draft.
- **Grilling**: the questions an agent asks, in rounds and each with a recommended answer, before it writes a story or another document. An open decision always gets a round.
- **Handoff**: a short document that lets a fresh session go on with the work after a compact.
- **Internal step**: a skill that other skills call and that a person does not type, such as the pre-flight.
- **Issue key**: the number of a GitHub issue, such as `#42`, or `owner/repo#42` for an issue of another repository. A branch starts with it (`42-short-name`) and a pull request says `Fixes #42`.
- **Knowledge repository**: a private repository next to the others that holds the facts about what you run, such as servers and notes. A shared file never holds such a fact.
- **Pack**: a package for one technology, such as .NET or Bicep, that a consumer installs when it needs it.
- **Pre-flight**: the local run of the pull request checks before a push.
- **Private term list**: the private list of names and patterns that no file of a public repository may hold. It lives in the knowledge repository and in a repository secret.
- **Section budget**: the most bullets a section of an issue may hold, so an issue fits on one screen. A story, bug or task also has at most 5 acceptance criteria.
- **Skill**: a set of instructions an agent follows for one kind of work.
- **Technical layer**: the docs that say how a repository is built.
- **Unit**: a part of a repository that a reader looks for by name and that has its own technical page.
- **Update pull request**: the pull request that moves a consumer to a new release tag of AI.SDLC. The consumer opens it itself, on the branch `ai-sdlc-<tag>`.

The [overview](overview.md) says what the AI-SDLC gives a team.

## Related

- [What the AI-SDLC gives a team](overview.md) - where these words are used.
- [Complete documentation](documentation.md) - what the two layers and a unit mean in practice.
- [Index](index.md) - every page of this layer.
