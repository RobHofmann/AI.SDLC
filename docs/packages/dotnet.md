---
units:
  - packs/dotnet
---

# dotnet

The `dotnet` pack adds review agents, development rules, code graph tools, and gates for .NET repositories.

## What it contains

### Review agents

Review agents read changes and report findings. They never edit files or return approval or blocking verdicts.

- `code-reviewer` reviews C# and Razor changes for defects that gates may miss. It lives at `packs/dotnet/.apm/agents/code-reviewer.agent.md`.
- `security-reviewer` reviews .NET changes for security defects. It lives at `packs/dotnet/.apm/agents/security-reviewer.agent.md`.
- `test-analyzer` checks whether tests prove the acceptance criteria and changed behavior. It lives at `packs/dotnet/.apm/agents/test-analyzer.agent.md`.

`code-reviewer` checks async blocking, missing using statements, swallowed exceptions, Blazor lifecycle issues, and JavaScript interop clean-up.

It also checks for parallel service paths, code rot and generated code smells. Code rot is a fix on top of an earlier fix, or a second implementation of one job.

`code-reviewer` and `test-analyzer` run on `sonnet`, and `security-reviewer` runs on `opus`.

`security-reviewer` checks access control, `[AllowAnonymous]`, Blazor in-circuit authorization, RBAC scope, SSRF, injection, and not safe deserialization.

It also checks secrets or personal data in logs and internal details exposed through `ProblemDetails`.

`test-analyzer` checks story-tagged tests, acceptance criterion coverage, changed behavior, error paths, and tests without assertions.

### Development skills

- `api-contract-conventions` defines REST wire rules at `packs/dotnet/.apm/skills/api-contract-conventions/SKILL.md`.
- `csharp-generation-smells` defines C# and Razor generation rules at `packs/dotnet/.apm/skills/csharp-generation-smells/SKILL.md`.
- `dotnet-code-graph` covers the local Graphify code graph at `packs/dotnet/.apm/skills/dotnet-code-graph/SKILL.md`.
- `dotnet-gates` covers .NET gates and local run steps at `packs/dotnet/.apm/skills/dotnet-gates/SKILL.md`.
- `nuget-vulnerability-remediation` covers vulnerable NuGet package fixes at `packs/dotnet/.apm/skills/nuget-vulnerability-remediation/SKILL.md`.
- `test-first-dotnet` covers test-first .NET development at `packs/dotnet/.apm/skills/test-first-dotnet/SKILL.md`.
- `write-api-spec` produces OpenAPI 3.x YAML specs at `packs/dotnet/.apm/skills/write-api-spec/SKILL.md`.

API reference material lives in `packs/dotnet/.apm/skills/api-contract-conventions/references/api.md`.

The .NET constitution clauses live in `packs/dotnet/.apm/skills/api-contract-conventions/references/clauses.md`.

C# conventions live in `packs/dotnet/.apm/skills/csharp-generation-smells/references/csharp.md`.

Analyzer-backed clean code rules live in `packs/dotnet/.apm/skills/csharp-generation-smells/references/clean-code.md`.

The Graphify code graph reference lives in `packs/dotnet/.apm/skills/dotnet-code-graph/references/code-graph.md`.

### Gates

The `dotnet-gates` skill defines these blocking gates:

- `C10 the change adds no commented-out code, open TODO or AI tool name in a C# or Razor comment`
- `Story-trait coverage: every test class tagged with a well-formed key`
- `DOTNET-01 PascalCase JSON wire names`
- `Docs match the code they cite`
- `C04 coverage ratchet: must not drop below the recorded baseline`

It also defines the advisory gates `C10 added public C# types and members carry a doc comment` and `Spec drift: a described endpoint moved and its spec did not`.

The `dotnet-code-graph` skill defines the advisory gate `Docs match the relationships the code has (needs the code graph)`.

Gate definitions live in `packs/dotnet/.apm/skills/dotnet-gates/gates.json` and `packs/dotnet/.apm/skills/dotnet-code-graph/gates.json`.

### Gate and setup scripts

The gate scripts live under `packs/dotnet/.apm/skills/dotnet-gates/scripts`.

- `Check-ApiPascalCase.ps1` enforces `DOTNET-01`.
- `Check-CommentHygiene.ps1` enforces `C10` on added C# and Razor comments: no commented-out code, no `TODO` without an issue key, no AI tool name.
- `Check-Coverage.ps1` enforces the `C04` coverage baseline, in the pre-flight and in the shared pull request step when the workflow passes `coverage-file`.
- `Check-DocDrift.ps1` compares documentation claims with cited code.
- `Check-SpecDrift.ps1` checks whether an existing spec moves with its endpoint.
- `Check-StoryTraits.ps1` checks xUnit test classes for valid AI-SDLC Story traits.
- `Check-XmlDocs.ps1` reports added public or protected C# declarations without a `///` doc comment (`C10`, advisory).
- `CodeDiff.psm1` reads the C# and Razor lines a change adds, for the two `C10` gates.
- `DocSurface.psm1` provides shared page and cited-code rules for three documentation tools.
- `Initialize-Dotnet.ps1` checks the .NET SDK the way dotnet reads `global.json`, installs the `dotnet-coverage` global tool when it is missing, and restores the solution.
- `Invoke-DotnetPostEdit.ps1` builds the project that owns an edited C# or Razor file.
- `Invoke-DotnetPreflight.ps1` runs the build with analyzers, tests, and coverage. No coverage file is a FAIL row that names the fix.

Each of these scripts has its tests beside it under `packs/dotnet/.apm/skills/dotnet-gates/scripts`.

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

Use `csharp-generation-smells` when writing or reviewing C# or Razor. Check reuse, validation, logging, error flow, wire names, and test shape.

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

The `implement`, `refactor`, and `fix-pr-feedback` flows use the review agents and development skills at their review steps. A bug fix from `fix-bug` reaches them inside `implement`.

`update-constitution` uses `code-reviewer` in check mode.

The `grilling` and `convene-personas` panels use `security-reviewer` as the Lead voice.

## Related

- [How AI.SDLC is built](../overview.md) - where this pack sits among the packages.
- [core](core.md) - the package every repository installs next to this one.
- [Index](../index.md) - every page of this layer.
