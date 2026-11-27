---
units:
  - packs/dotnet
---

# dotnet

The `dotnet` pack adds development rules, code graph tools, and gates for .NET repositories. It ships no agent.

## What it contains

### Rules the review agents read

The review agents `code-reviewer`, `test-analyzer` and `security-reviewer` live in [core](core.md). Each one reads the convention skills of the changed files from the table of file types in `code-conventions`. For a `.cs` file that table names `csharp-conventions` and `test-first-dotnet`.

- `csharp-conventions` holds the C# review checks, such as async and resources, errors through the pipeline and closed sets. Its `## Security` section and its page `references/security.md` hold the C# security checks: access control, Graph and ARM scope, queries built from input, deserialization and error bodies.
- `test-first-dotnet` holds the C# test rules that `test-analyzer` reads. A new test follows the test style on `csharp-conventions/references/csharp.md`, and proves the team's own logic, not the framework's ([ADR 0026](../adrs/0026-a-test-proves-the-teams-own-logic-not-the-frameworks.md)). Examples are one test class per type, the Story trait and real assertions. It also asks for a mock for every constructor dependency, and no controller test for an action that only forwards a call.

### Development skills

- `api-contract-conventions` defines REST wire rules at `packs/dotnet/.apm/skills/api-contract-conventions/SKILL.md`.
- `csharp-conventions` defines the C# rules at `packs/dotnet/.apm/skills/csharp-conventions/SKILL.md`. Its page `references/house-style.md` holds the house rules, each with an example and two public sources. Its page `references/not-decided.md` lists the points of taste: a change follows the file it edits, and a new file takes the default. The folders for a new interface, exception and options class come from `dotnet.folders` in `aisdlc.json`. Its asset `assets/recommended.editorconfig` is an opt-in `[*.cs]` block that sets fifteen code style rules to warning, and `references/code-style-block.md` says how a repository takes it. The rules for every language, such as reuse before you build, live once in `code-conventions` of core.
- `dotnet-code-graph` covers the local Graphify code graph at `packs/dotnet/.apm/skills/dotnet-code-graph/SKILL.md`.
- `dotnet-gates` covers .NET gates and local run steps at `packs/dotnet/.apm/skills/dotnet-gates/SKILL.md`.
- `nuget-vulnerability-remediation` covers vulnerable NuGet package fixes at `packs/dotnet/.apm/skills/nuget-vulnerability-remediation/SKILL.md`.
- `test-first-dotnet` covers test-first .NET development at `packs/dotnet/.apm/skills/test-first-dotnet/SKILL.md`.
- `write-api-spec` produces OpenAPI 3.x YAML specs at `packs/dotnet/.apm/skills/write-api-spec/SKILL.md`.

API reference material lives in `packs/dotnet/.apm/skills/api-contract-conventions/references/api.md`.

The .NET constitution clauses live in `packs/dotnet/.apm/skills/api-contract-conventions/references/clauses.md`.

C# conventions live in `packs/dotnet/.apm/skills/csharp-conventions/references/csharp.md`.

Analyzer-backed clean code rules live in `packs/dotnet/.apm/skills/csharp-conventions/references/clean-code.md`.

The Graphify code graph reference lives in `packs/dotnet/.apm/skills/dotnet-code-graph/references/code-graph.md`.

### Gates

The `dotnet-gates` skill defines these blocking gates:

- `The change adds no commented-out code, open TODO or AI tool name in a C# or Razor comment`
- `Test classes and methods that the change adds carry a Story trait with a real key`
- `JSON wire names in C# and in specs are PascalCase`
- `Docs match the code they cite`
- `Line coverage stays at the baseline, and a gain of a point is written to the baseline file`

It also defines the advisory gates `Added public C# types and members carry a doc comment` and `A change to an endpoint that has a spec also changes that spec`.

The `dotnet-code-graph` skill defines the advisory gate `Docs match the relationships the code graph has`.

Gate definitions live in `packs/dotnet/.apm/skills/dotnet-gates/gates.json` and `packs/dotnet/.apm/skills/dotnet-code-graph/gates.json`.

### Gate and setup scripts

The gate scripts live under `packs/dotnet/.apm/skills/dotnet-gates/scripts`.

- `Check-ApiPascalCase.ps1` enforces `DOTNET-01`.
- `Check-CommentHygiene.ps1` enforces `C10` on added C# and Razor comments: no commented-out code, no `TODO` without an issue key, no AI tool name.
- `Check-Coverage.ps1` enforces the `C04` coverage baseline, in the pre-flight and in the shared pull request step when the workflow passes `coverage-file`. It also fails when coverage is a point or more above the baseline and the change did not raise the baseline file. So a gain is kept. A gain of less than a point passes and prints the new figure.
- `Check-DocDrift.ps1` compares documentation claims with cited code. It judges only the lines the change adds, changes or removes. Drift that the change caused fails, and older drift is listed as not blocking.
- `Check-SpecDrift.ps1` checks whether an existing spec moves with its endpoint. It reads only the routes and DTO types on the lines the change adds or removes.
- `Check-StoryTraits.ps1` checks test classes for valid AI-SDLC Story traits, in xUnit, NUnit and MSTest. It judges only the lines the change adds or changes. A class or method that the change adds needs a real story key, and `LEGACY-0` stays allowed on older code.
- `Check-XmlDocs.ps1` reports added public or protected C# declarations without a `///` doc comment (`C10`, advisory).
- `CodeDiff.psm1` reads the C# and Razor lines a change adds, for the two `C10` gates.
- `DocSurface.psm1` provides shared page and cited-code rules for three documentation tools.
- `Initialize-Dotnet.ps1` checks the .NET SDK the way dotnet reads `global.json`, installs the `dotnet-coverage` global tool when it is missing, and restores the solution.
- `Invoke-DotnetPostEdit.ps1` builds the project that owns an edited C# or Razor file.
- `Invoke-DotnetPreflight.ps1` runs the build with analyzers, tests, and coverage. No coverage file is a FAIL row that names the fix.

The tests of these scripts sit under `packs/dotnet/tests/skills/dotnet-gates/scripts`, at the same names ([ADR 0015](../adrs/0015-the-tests-of-a-shared-package-live-outside-the-installed-package.md)).

### Code graph scripts

The code graph scripts live under `packs/dotnet/.apm/skills/dotnet-code-graph/scripts`.

- `CodeGraph.psm1` answers relational questions about the codebase.
- `Check-DocGraphClaims.ps1` checks documentation relationship claims against the code graph. It warns when the graph is older than the working tree, and the warning does not change its exit code.
- `Deny-StaleGraphQuery.ps1` refuses raw Graphify queries when the graph is behind the working tree.
- `Get-ProjectFacts.ps1` reads a .NET project's contents and connections.
- `Initialize-CodeGraph.ps1` installs the pinned Graphify CLI during setup.
- `Invoke-DocGraphLink.ps1` links documentation pages to their source files.
- `Invoke-GraphifyBenchmark.ps1` scores the graph against committed questions with known answers.
- `Invoke-GraphifyIndex.ps1` builds or refreshes the local Graphify graph.
- `Invoke-GraphifyQuery.ps1` asks one read-only question after reporting graph freshness.
- `Update-DocFromGraph.ps1` writes a facts file for one documentation page from the graph, for an agent to draft the additions from. It calls no model.

The pinned Graphify version is stored in `packs/dotnet/.apm/skills/dotnet-code-graph/scripts/graphify-version.json`.

Tests for these scripts live beside them under `packs/dotnet/.apm/skills/dotnet-code-graph/scripts`.

### Package configuration

The package manifest lives at `packs/dotnet/apm.yml`.

Hook configuration lives at `packs/dotnet/.apm/hooks/dotnet-hooks.json`.

## Changing the pack safely

Use `test-first-dotnet` when changing C# behavior or its tests. It uses red, green, and refactor with xUnit, Moq, and AutoFixture.

Each acceptance criterion needs a story-tagged test that asserts the promised behavior. Cover changed behavior and its error paths.

Use `csharp-conventions` when writing or reviewing C# or Razor. Check reuse, validation, logging, error flow, wire names, and test shape.

Use `api-contract-conventions` when a change affects a controller, route, request, or response.

JSON bodies use PascalCase under `DOTNET-01`. Query and path parameters use snake_case.

Controllers stay thin and cover one domain each. Successful business results use `200`, while real errors use `ProblemDetails`.

Move the OpenAPI spec under `specs/` when its endpoint moves.

Use `write-api-spec` before implementation when a slice adds or changes a REST endpoint. Started by a person, it ends like `write-adr`: `wrap-up` commits the spec, then the skill pushes and opens or updates the pull request.

Use `dotnet-code-graph` before changing a shared library or claiming relationships between callers, consumers, projects, or types.

Refresh the graph when `Deny-StaleGraphQuery.ps1` refuses a stale query.

Use `nuget-vulnerability-remediation` for NuGet advisories. Prefer updating the parent package before pinning a transitive package.

That process uses Central Package Management in `Directory.Packages.props` and tracked lock files.

Recheck packages with `dotnet list package --vulnerable --include-transitive`, then build and audit again.

Run the matching script tests when changing a gate, setup script, graph script, or shared PowerShell module.

## Dependencies

The setup scripts need the .NET SDK and restore the solution.

The code graph tools use a pinned Graphify CLI version.

The test guidance uses xUnit, Moq, and AutoFixture. Coverage uses a recorded baseline and includes an 80% target for new code in SonarCloud.

The `implement`, `refactor`, and `fix-pr-feedback` flows load the development skills at their build and review steps, through the table of file types in `code-conventions`. A bug fix from `fix-bug` reaches them inside `implement`.

## Related

- [How AI.SDLC is built](../overview.md) - where this pack sits among the packages.
- [core](core.md) - the package every repository installs next to this one.
- [Index](../index.md) - every page of this layer.
