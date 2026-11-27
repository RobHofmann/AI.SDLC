# The recommended code style block

The dotnet pack ships a recommended `.editorconfig` block,
[recommended.editorconfig](../assets/recommended.editorconfig). It turns on the .NET code style rules
for the house style. Then the build reports a style break, and a reviewer no longer has to write the
same comment again. A repository takes the block when it wants; nothing installs it into a solution.

The block is one `[*.cs]` section. Each rule runs at warning, so a style break does not fail the build,
unless the build turns warnings into errors. Read step 3 before you copy the block, because that case
fails the build. The block holds no rule for a point of taste, see [not-decided.md](not-decided.md).

## How a repository takes the block

1. Copy the section into the `.editorconfig` next to the solution (`paths.solution` in `aisdlc.json`).
   Merge it into an existing `[*.cs]` section when there is one.
2. Set `EnforceCodeStyleInBuild` to `true` in `Directory.Build.props`. Without it, a command-line
   build does not run the code style rules at all.
3. Check that the build does not turn warnings into errors, through `TreatWarningsAsErrors` or
   `-warnaserror`. If it does, every style break fails the build. Then list the rule IDs of the
   block in `WarningsNotAsErrors`, which keeps them at warning.
4. Run a full build and keep the warning count as the backlog. The builder agent fixes each warning
   in a line its change adds or changes ("Leave no new warning" in
   [code-conventions](/.claude/skills/code-conventions/SKILL.md)).
5. Raise a rule to `error` only after a full build shows it at zero, as the escalation path on
   [the Clean Code page](clean-code.md) says.

## The rules in the block

Each rule ID fired as a warning in a test build with the block, and that build passed. The Pester test
`RecommendedEditorconfig.Tests.ps1` in AI.SDLC repeats that build.

| Rule | Convention | Option in the block |
|---|---|---|
| [IDE0290](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/style-rules/ide0290) | A primary constructor | `csharp_style_prefer_primary_constructors = true` |
| [IDE0090](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/style-rules/ide0090) | Target-typed `new()` | `csharp_style_implicit_object_creation_when_type_is_apparent = true` |
| [IDE0028](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/style-rules/ide0028) | `[]` to build a list | `dotnet_style_prefer_collection_expression = true` |
| [IDE0300](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/style-rules/ide0300) | `[]` to build an array | `dotnet_style_prefer_collection_expression = true` |
| [IDE0007](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/style-rules/ide0007-ide0008) | `var` for a local variable | the three `csharp_style_var_*` options set to `true` |
| [IDE0022](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/style-rules/ide0022) | An expression body for a method | `csharp_style_expression_bodied_methods = when_on_single_line` |
| [IDE0025](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/style-rules/ide0025) | An expression body for a property | `csharp_style_expression_bodied_properties = when_on_single_line` |
| [IDE0161](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/style-rules/ide0161) | A file-scoped namespace | `csharp_style_namespace_declarations = file_scoped` |
| [IDE0019](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/style-rules/ide0019) | The `is` pattern, not `as` and a null check | `csharp_style_pattern_matching_over_as_with_null_check = true` |
| [IDE0066](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/style-rules/ide0066) | A switch expression, not a `switch` statement that returns or sets a value, also for two cases | `csharp_style_prefer_switch_expression = true` |
| [IDE0041](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/style-rules/ide0041) | `is null`, not `ReferenceEquals(value, null)` | `dotnet_style_prefer_is_null_check_over_reference_equality_method = true` |
| [IDE0150](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/style-rules/ide0150) | `is null`, not a type check that only tests for null | `csharp_style_prefer_null_check_over_type_check = true` |
| [IDE0130](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/style-rules/ide0130) | The namespace is the root namespace of the project plus the folder path | `dotnet_style_namespace_match_folder = true` |
| [CA1507](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/quality-rules/ca1507) | `nameof` for a parameter name in a string | the severity line only |
| [CA2208](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/quality-rules/ca2208) | An argument exception names a real parameter | the severity line only |

Two choices in the options keep the number of warnings low:

- `dotnet_style_prefer_collection_expression = true` asks for `[]` only when the types match exactly.
  The value `when_types_loosely_match` also flags `IEnumerable<T> items = new List<T>()`, and its
  fix can change what the code does.
- `when_on_single_line` asks for an expression body only when the member fits on one line. A body that
  needs several lines may keep its braces.

Three facts about the rules:

- **No rule checks `== null`.** IDE0041 and IDE0150 report two rarer forms of a null check. A test build
  showed that neither reports `value == null`, so the reviewer checks that form.
- **The root namespace is not the folder name of the project.** IDE0130 compares with the
  `RootNamespace` of the project, or the project file name when the project sets none. A file without
  a namespace gets no message.
- **A command-line build of a recent SDK needs no extra setup for IDE0130.** The rule page says a
  command-line build needs `CompilerVisibleProperty` items. The .NET 10 SDK adds them itself, and a test
  build showed the warning without them. An older SDK was not tested.

## What the block leaves out

| Rule | Why it is not in the block |
|---|---|
| IDE0045 and IDE0046, a conditional expression | They push an `if` with two branches to `? :`. The house style asks for a switch expression, not for `? :` |
| A naming rule (IDE1006) for the `Async` suffix | It fires on every `async` method, so it would also flag a controller action, which has no suffix ([house-style.md](house-style.md)). It also misses a method that returns a task without the `async` keyword |
| [IDE0005](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/style-rules/ide0005) and IDE0060, unused `using` lines and parameters | IDE0005 only runs in a build with `GenerateDocumentationFile` on |
| No `#region` | No .NET code style rule checks it |
| [S2302](https://rules.sonarsource.com/csharp/RSPEC-2302/), `nameof` for a parameter name | A SonarAnalyzer rule acts only where the project references `SonarAnalyzer.CSharp`. CA1507 covers the same case in every project |

A point that a team decides later can add its rule to its own `.editorconfig`, at warning first.

Sources: [code analysis in .NET](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/overview),
the part "Enable on build", and
[EditorConfig for code style](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/code-style-rule-options).

## Related

- [House style](house-style.md) - the conventions the block checks, with an example each.
- [Not decided](not-decided.md) - the C# points of taste.
- [Clean Code rules](clean-code.md) - the analyzer rules of SonarAnalyzer and the escalation path.
- [The csharp-conventions skill](../SKILL.md) - the short rules a build and a review check.
