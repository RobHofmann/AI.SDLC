---
name: csharp-generation-smells
kind: knowledge
user-invocable: false
description: >
  The ways generated C# and Razor drift from the house conventions where no analyzer catches it. They
  cover errors through the pipeline, async and resources, validation, logging, wire names, doc
  comments, naming, DI, closed sets and the C# security rules. They also cover Razor component shape
  and test shape. The rules for every
  language live in code-conventions. Use when writing or reviewing C# or Razor in this repository. Also use at the build and
  review steps of implement, refactor or fix-pr-feedback, or when the
  code-reviewer agent reads a diff. Do NOT use to run the build or the gates (run-preflight) or to
  decide the order of the build steps (implement).
---

# C# generation smells

This is a fast check for the mistakes generated C# really makes here. Most are judgement calls that no
analyzer enforces, so the build stays green while the code drifts. Each item points at the page that
holds the full rule; the page wins when the two differ. The rules that hold in every language live once in
[code-conventions](/.claude/skills/code-conventions/SKILL.md). Examples are reuse before you build,
build only what the story needs, a twin follows its sibling, and fix the class. This skill adds the C# and
Razor rules only. `implement`, `refactor` and `fix-pr-feedback`
load this at the build and review steps. The `builder`, `code-reviewer` and `security-reviewer` agents
read it through the table of file types in `code-conventions`.

## Before you write

- **One domain per controller.** Extend the controller that owns the resource; see
  [api.md](/.claude/skills/api-contract-conventions/references/api.md), "One Domain Per Controller".
- **A closed set in C#.** When the change branches on an enum or a sealed hierarchy, read the type and
  handle every member ([csharp.md](references/csharp.md), "Control flow over closed sets").

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

## Razor components

- `[Parameter]` and `[CascadingParameter]` go on their own line above the member.
- No `I*State` interface over a state class, not even to mock it; test with the real state object.
- Subscribe to state changes with the same `OnChangeHandler` / `HandleChange` shape as the other
  components. No inline `<style>` blocks.
- When markup moves between components, list what the old home also provided before you delete it,
  such as a `PageTitle`.
- The full rules: `blazor-conventions`, when the blazor pack is installed.

## Security

The `security-reviewer` agent reads this section when a change touches a C# file. The C# security
rules are on [security.md](references/security.md): access control, Graph and ARM scope, queries built
from input, deserialization and error bodies.

## Tests

- Mock every constructor dependency; never pass `null`.
- No controller tests for actions that only forward to a service. When a controller test is needed,
  assert the `ActionResult` type and status code, not the service call arguments.
- The rest of the test shape lives in the `test-first-dotnet` knowledge skill.

## Before you call it done

- **Infrastructure replaces, it does not pile up.** A Bicep template describes only the target state
  (`bicep-conventions`, when the bicep pack is installed).

## Sources

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
