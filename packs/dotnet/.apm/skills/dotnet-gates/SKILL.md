---
name: dotnet-gates
kind: knowledge
user-invocable: false
description: >
  The gates the dotnet pack adds for a .NET repository and how to run each one. They check comments
  and doc comments in C# and Razor, a story trait on every test class, and PascalCase JSON wire names. They
  check docs that match the code they cite. They also cover spec drift and the coverage ratchet. The skill also holds
  the dotnet steps of the pre-flight, the post-edit build and the restore at setup. Use when one of
  these gates failed, or when a change touches C#, Razor, tests or coverage. Also use when the
  pre-flight reports a build, test or coverage row. Do NOT use for the core gates (ai-sdlc-gates), for
  the code graph (dotnet-code-graph) or to write a new gate (add-gate).
---

# .NET gates

These gates check rules that only make sense where there is C# code. They sit in this skill's
`scripts/` folder, and `gates.json` registers them with the local runner for the `dotnet` pack. Every
gate reads the source root, the test root, the solution, the run settings and the coverage baseline
from `aisdlc.json`. A gate exits 2 when the path it needs is not configured,
except the C04 ratchet, which fails (exit 1) without a baseline.

## The gates

| Gate | Script | Mode | What it checks |
|---|---|---|---|
| C10 | `Check-CommentHygiene.ps1` | Blocking | An added comment in a `.cs` or `.razor` file holds no commented-out code, no `TODO`, `FIXME` or `HACK` without an issue key, and no AI tool name |
| C10 docs | `Check-XmlDocs.ps1` | Advisory | Each added public or protected declaration in a `.cs` file outside the test root has a `///` doc comment |
| Story traits | `Check-StoryTraits.ps1` | Blocking | Every test class carries a well-formed `[Trait("Story", ...)]`; the gate runs with `-Strict`, so an untagged class fails too |
| DOTNET-01 | `Check-ApiPascalCase.ps1` | Blocking | Every `[JsonPropertyName]` under the source root is PascalCase and needed; the allowed exceptions are in `dotnet.wireNameAllowlist` and `dotnet.externalContractPaths` |
| Doc drift | `Check-DocDrift.ps1` | Blocking | A reference page still names what the code has: constants, files, routes and services |
| Spec drift | `Check-SpecDrift.ps1` | Advisory | A changed endpoint that a spec describes moved with its spec |
| C04 | `Check-Coverage.ps1` | Blocking | Total line coverage does not drop below the baseline; runs only with a merged coverage file: in the pre-flight, and in the pull request workflow when it passes `coverage-file` to the `ai-sdlc-pr` action |

`DocSurface.psm1` holds the rules the doc tools share for reading a page and the C# it cites. The code
graph scripts import it from here. `CodeDiff.psm1` reads the lines a change adds for the two C10 gates.

## Run them

```bash
pwsh .claude/skills/dotnet-gates/scripts/Check-StoryTraits.ps1 -Strict
pwsh .claude/skills/dotnet-gates/scripts/Check-DocDrift.ps1 -Doc libraries/stock-level
pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1 -CoverageFile <merged coverage XML>
```

## The dotnet steps outside the runner

- **Pre-flight.** `Invoke-DotnetPreflight.ps1` builds the solution with the analyzers, runs the tests
  with the run settings, merges the coverage and runs the ratchet. No coverage file, or no
  `dotnet-coverage` tool, is a FAIL row that names the fix. With `-IncludeSonar` it also runs
  the SonarCloud scan. `Invoke-Preflight.ps1` runs it and folds its rows into one report.
- **Pull request.** The composite action `ai-sdlc-pr` runs the ratchet when the workflow passes
  `coverage-file`, the path of the merged coverage file. A test step earlier in the same job runs the
  tests and merges the coverage into that file.
- **After an edit.** `Invoke-DotnetPostEdit.ps1` builds the project that owns an edited `.cs` or
  `.razor` file, so a broken build shows while the file is open.
- **Setup.** `Initialize-Dotnet.ps1` checks the .NET SDK, installs the `dotnet-coverage` global tool
  when it is missing, and restores the solution. It reads `rollForward` in `global.json` without regard
  to capitals. When dotnet ignores `global.json` (a short version or an unknown `rollForward`), the check
  does too and names the newest SDK, which dotnet then uses.

## Sources

- [C# conventions](/.claude/skills/csharp-generation-smells/references/csharp.md) - the rules these gates hold the code to.
- [Test-first .NET](/.claude/skills/test-first-dotnet/SKILL.md) - story traits, coverage and the run settings.
- [Constitution](/.claude/skills/ai-sdlc-handbook/references/constitution.md) - DOTNET-01, C04 and C10.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).
