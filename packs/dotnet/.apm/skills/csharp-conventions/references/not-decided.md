# C# points not decided

These points are a matter of taste, and teams choose differently. For each one:

- A change follows the form of the file or class it edits.
- A new file follows the files next to it in the same folder.
- When the folder gives no answer, the default below holds.

This is the rule "A point that is not decided" of
[code-conventions](/.claude/skills/code-conventions/SKILL.md). Do not pick a form because it looks
better, and do not change the form of code you do not need to touch. A repository that has decided a
point writes it on its own constitution page (`paths.constitution`); that page wins.

| Point | Options | Default |
|---|---|---|
| A model that only carries data | A `class` with `{ get; set; }`, or a `record` | A `class` with `{ get; set; }` |
| Sealed and internal | `public` and not `sealed`, or `sealed` and `internal` where nothing outside needs it | `public`, not `sealed`; a sealed hierarchy that models a closed set stays sealed |
| The setters of an options class | `{ get; init; }`, or `{ get; set; }` | `{ get; init; }` for a new class |
| An empty string | `""`, or `string.Empty` | `""` |
| A `CancellationToken` | On every async method, or only where the story or an API needs one | Only where the story or an API we implement or call needs one |
| `ConfigureAwait(false)` | In library code, or never | Never in application code |
| The return type of a sequence | `IEnumerable<T>`, or `IReadOnlyList<T>` and `List<T>` | `IEnumerable<T>` where the callers allow it |
| How long a service lives | `AddScoped`, `AddTransient` or `AddSingleton` | `AddScoped`, unless the service holds state for the whole app |
| How a validator is created | In place, or injected | The form of the class it edits |

Sources: [Records](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/builtin-types/record),
[sealed](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/keywords/sealed),
[init](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/keywords/init),
[String.Empty](https://learn.microsoft.com/en-us/dotnet/api/system.string.empty),
[cancellation in managed threads](https://learn.microsoft.com/en-us/dotnet/standard/threading/cancellation-in-managed-threads),
[the ConfigureAwait FAQ](https://devblogs.microsoft.com/dotnet/configureawait-faq/),
[IEnumerable&lt;T&gt;](https://learn.microsoft.com/en-us/dotnet/api/system.collections.generic.ienumerable-1)
and [how long a service lives](https://learn.microsoft.com/en-us/dotnet/core/extensions/dependency-injection#service-lifetimes).
Each default is a single-sourced choice (clause C07): the page names the option, not a reason to pick it.

## Related

- [The csharp-conventions skill](../SKILL.md) - the short rules a build and a review check.
- [House style](house-style.md) - the C# rules.
- [C# conventions](csharp.md) - errors, logging, DI, closed sets and the test style.
