---
name: csharp-conventions
kind: knowledge
user-invocable: false
description: >
  The C# rules: the house style, errors through the pipeline, async and resources, validation,
  logging, wire names, DI, closed sets, C# security and test shape. The rules for every language are
  in code-conventions. Use when writing or reviewing C#, at the build and review steps of implement,
  refactor and fix-pr-feedback. Do NOT use for Razor markup (razor-conventions) or to run the gates
  (run-preflight).
---

# C# conventions

This skill holds the C# rules. Most are judgement calls that no analyzer enforces, so the build stays
green while the code drifts. Each item points at the page that holds the full rule; the page wins when
the two differ. The rules that hold in every language live once in
[code-conventions](/.claude/skills/code-conventions/SKILL.md). Examples are reuse before you build,
build only what the story needs, a twin follows its sibling, and fix the class. This skill adds the C#
rules only. `implement`, `refactor` and `fix-pr-feedback` load this at the build and review steps. The
`builder`, `code-reviewer` and `security-reviewer` agents read it through the table of file types in
`code-conventions`.

## Before you write

- **A point of taste** follows the file or class you edit, and a new file follows its neighbours. The
  C# points of taste, with the default for a new file, are on [not-decided.md](references/not-decided.md).
- **Folder names are settings** in `dotnet.folders` of `aisdlc.json`: `contracts`, `exceptions` and
  `options`. Without a key, a new type goes where the types of its kind next to the change sit. A file
  that exists stays where it is.
- **One domain per controller.** Extend the controller that owns the resource; see
  [api.md](/.claude/skills/api-contract-conventions/references/api.md), "One Domain Per Controller".
- **A closed set in C#.** When the change branches on an enum or a sealed hierarchy, read the type and
  handle every member ([csharp.md](references/csharp.md), "Control flow over closed sets").

## House style

The full rules, with an example and two public sources each, are on
[house-style.md](references/house-style.md).

- A primary constructor, with its parameters used directly; no `_field` copies.
- One top-level type per file, with the same name.
- An options class ends in `Options` and comes in through `IOptions<T>`, never `IConfiguration`.
- A method that returns a task ends in `Async`, except a controller action.
- A null check is `is null` or `is not null`; no null check on a value that cannot be null.
- `nameof` when a string must equal a C# name; a literal when the name is a contract.
- A controller action has a `[ProducesResponseType]`, a route `Name` and a kebab-case route.
- No `#region`. Target-typed `new()`, `[]`, `var`, expression bodies, a file-scoped namespace and the
  `is` pattern; a switch expression with a default arm, also for two cases. The build can check these
  with the opt-in `.editorconfig` block of [code-style-block.md](references/code-style-block.md).

## While you write

- **Errors through the pipeline.** Services throw typed domain exceptions. Controllers do not
  null-check-then-`NotFound()`, return anonymous error bodies or wrap actions in `try/catch`. No
  defensive catch-and-log around a best-effort step unless it is a stated decision
  ([csharp.md](references/csharp.md)).
- **Async and resources.** Use `await` on a task, never `.Result` or `.Wait()`; `async void` only for
  an event handler; `using` on what you create ([csharp.md](references/csharp.md), "Async and resources").
- **Validation.** `ValidateAsync` plus the validation exception the repository already uses, never
  `ValidateAndThrowAsync`.
- **Logging.** Log the way the repository's own rules say (its constitution page, `paths.constitution`
  in aisdlc.json). A repository gate in `repoGates` may block the rest; catch it here first.
- **`[JsonPropertyName]`** only when the wire name must differ from the property name (DOTNET-01).
- **The doc comment of C#.** Clause C10 holds as `code-conventions` says. In C# the doc comment is a
  `/// <summary>`; in Razor, a summary at the top of a component with parameters. `Check-CommentHygiene.ps1` blocks a
  breach, and `Check-XmlDocs.ps1` reports a missing doc comment.
- **Naming and noise.** Names that say what a thing is (not `u`, `t`, `cs`); `using` directives
  instead of full type names inline; no `!` that is not needed; target-typed `new()` and collection expressions.
- **DI construction.** Non-trivial construction belongs in a class you can test, not inline in an
  `Add*` lambda. An `Add*()` method registers every dependency its type needs
  ([csharp.md](references/csharp.md), "Dependency injection").
- **Rename the old twin too.** When a new twin of a method mirrors its sibling (`code-conventions`),
  the old sibling is renamed to the same convention.
- **Infrastructure replaces, it does not pile up.** A Bicep template describes only the target state
  (`bicep-conventions`, when the bicep pack is installed).

## Razor components

The rules of a Razor component, also of its `@code` block, live in `razor-conventions` (blazor pack).

## Security

The `security-reviewer` agent reads this section when a change touches a C# file. The C# security
rules are on [security.md](references/security.md): access control, Graph and ARM scope, queries built
from input, deserialization and error bodies.

## Tests

- Mock every constructor dependency with a loose `new Mock<T>()` named `mock...`; never pass `null`.
  A setup names the exact input. Name the class under test after what it is, never `sut`.
- Name a test `Method_Condition_Should_Result` and act once. Literals first.
- A test proves the team's own logic, not the framework (clause C04). The one wiring test is the
  registration test without the container. No test of a controller action that only forwards.
- The rest is in the [test style](references/csharp.md#test-style) and
  [test-first-dotnet](/.claude/skills/test-first-dotnet/SKILL.md), which `test-analyzer` reads.

## Sources

- [House style](references/house-style.md) - the C# house rules, with an example and two sources each.
- [Not decided](references/not-decided.md) - the C# points of taste, with the default for a new file.
- [Code style block](references/code-style-block.md) - the recommended `.editorconfig` block and what it leaves out.
- [C# conventions](references/csharp.md) - language, DI, testing and closed sets.
- [Code conventions](/.claude/skills/code-conventions/SKILL.md) - the rules for every language.
- [Clean Code rules](references/clean-code.md) - the analyzer rules of C#.
- [Security](references/security.md) - the C# security rules.
- [Code comments policy](/.claude/skills/ai-sdlc-handbook/references/comments.md) - clause C10 and its gates.
- [API conventions](/.claude/skills/api-contract-conventions/references/api.md) - thin controllers, one domain each.
- [Constitution](/.claude/skills/ai-sdlc-handbook/references/constitution.md) - C01 and C10.
- [Dotnet clauses](/.claude/skills/api-contract-conventions/references/clauses.md) - DOTNET-01.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).
