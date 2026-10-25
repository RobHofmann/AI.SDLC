# Code comments

## Rule

**Code is documented.** A public or shared type, function or member carries a doc comment in the
form of its own language. The rule holds for people and agents alike:

| Language | Doc comment |
|---|---|
| C# | An XML doc comment (`/// <summary>`), with `<param>` and `<returns>` where they add something. |
| Python | A docstring on the module, the class and the function. |
| PowerShell | The comment-based help block, ALWAYS, on every script: `.SYNOPSIS`, a short `.DESCRIPTION`, a `.PARAMETER` per parameter, and an `.EXAMPLE`. |
| TypeScript | A JSDoc or TSDoc block (`/** ... */`). |
| Razor | A summary at the top of a component that has parameters: what it shows and what each parameter does. |

A doc comment says what the thing is for and what a caller must know: inputs, results, errors and
limits. It does not retell how the body works.

**Inside a body, a comment says why, never what.** Good reasons for a comment are a hard limit, a
workaround with its issue or link, and a decision that is not obvious.
A comment that says what the next line does repeats the code. Try a better name first: rename the variable or the
method, pull out a method, or add a named constant. Write the comment only when a name cannot carry it.

**Never in a comment:**

- commented-out code; git keeps the history;
- the ADR, the pull request or the issue retold at length; link it instead, for example `see #42`;
- a `TODO`, `FIXME` or `HACK` without an issue key such as `#42`;
- the name of an AI tool, or of a person.

**Do not strip comments that are already there.** The rule governs what a change adds. Cleaning up old
comments is a separate change that someone asks for.

### What is not a comment

**Language directives are not comments**: `#Requires`, `#pragma`, `#region`, `#nullable`, shebangs.
They are instructions to a tool.

**Machine marker lines are not comments.** `Sync-AgentsFile.ps1` writes `ai-sdlc:<package>:start` and
`ai-sdlc:<package>:end` lines around each shared part of `AGENTS.md`. A tool writes and reads them,
so they stay.

**The `// Arrange`, `// Act`, `// Assert` markers in tests stay.** They are a structural convention, the
same across the whole test suite.

## Why

A doc comment on a public type or member is part of its contract. The IDE shows it at every call, and
a reader of the API does not have to open the body. That makes it the one comment that pays for
itself every day.

Text inside a body is different. It rots without anyone noticing, because nobody compares a comment
with the code it sits next to. A comment that says what the code does goes stale at the next edit. A
comment that says why stays true as long as the reason does, so it is worth keeping.

A name beats a comment. Everyone who touches the code reads a well-named symbol, such as the constants
`LivenessPath` and `ReadinessPath`. A comment is read only by whoever opens that one file.

## Where the longer reasoning goes

A comment holds one or two lines. Longer reasoning goes somewhere it can be found, reviewed and linked:

- A decision that would otherwise be undone: an ADR in the ADR folder (`paths.adrFolder` in `aisdlc.json`).
  The ADR is the home of a decision; the code links it.
- How an area works or is operated: the matching page in the docs roots (`paths.docsRoots`).
- Why this change, right now: the pull request description and the commit message.
- What the work is about: the work item.

## Enforcement

Clause C10 in the [constitution](constitution.md). For C# and Razor the dotnet pack ships two gates.
Both read only the lines a change adds, and both skip generated files:

- `.claude/skills/dotnet-gates/scripts/Check-CommentHygiene.ps1` (blocking) fails on commented-out
  code, on a `TODO`, `FIXME` or `HACK` without an issue key, and on a comment that names an AI tool.
- `.claude/skills/dotnet-gates/scripts/Check-XmlDocs.ps1` (advisory) names each added public or
  protected type and member without a `///` doc comment. It skips the test root (`paths.testRoot`) and
  types marked `[GeneratedCode]`.

They run in `Invoke-LocalGates.ps1`, in the pre-push hook and in the pull request workflow. The
`code-reviewer` agent of the dotnet pack flags a missing doc comment on public API and a comment that
says what. For the other languages, code review and the review agents are the enforcement, as the
human checkpoints in [orchestration.md](orchestration.md) describe.

## Related

- [Constitution](constitution.md) - clause C10, the short form of this rule.
- [Language and reading level](language.md) - the reading level and the language of every comment.
- [Documentation wiki](docs-wiki.md) - the pages where the longer explanation goes.
- [Skill patterns](pattern.md) - the shape of a skill, and where its scripts live.
