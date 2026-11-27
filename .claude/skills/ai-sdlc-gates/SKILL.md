---
name: ai-sdlc-gates
kind: knowledge
user-invocable: false
description: >
  The deterministic gates of the AI-SDLC and how to run them: the core gates, the gates of each pack,
  the repository's own gates from aisdlc.json, the exit codes 0, 1, 2 and 3, and the runner. Use when a
  gate failed and needs explaining, when checking a change before a push, or when reading aisdlc.json.
  Do NOT use to run the full pull request workflow locally (run-preflight), to write a new gate
  (add-gate) or to explain a hook (ai-sdlc-hooks).
---

# AI-SDLC gates

A gate is a script that checks one rule and reports through its exit code. Each gate is an entry in a
`gates.json` or in `repoGates`, never a workflow step. `Invoke-LocalGates.ps1` runs them all: on every
push, in a local run and in the pull request workflow. The core gates, the runner and the modules sit in `scripts/`.

## Run them

```bash
pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1             # every gate, side by side, one summary
pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1 -BlockingOnly # or -SkipTests: no Pester test gates
pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1 -List       # what would run, its clause and mode, and where it runs
pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1 -SkipScript Check-LocalPackages.ps1 # leave one gate out, shown as SKIP
pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-Preflight.ps1              # the whole pull request workflow, locally
```

## Which gates run

- **Each package lists its gates** in a `gates.json` in one of its skills; this skill's holds the core gates.
- **The runner reads `apm.yml` and `aisdlc.json`.** It runs the core gates, the gates of each pack that
  `apm.yml` installs, and the repository's own gates in `repoGates` of `aisdlc.json`. A pack that
  `apm.yml` does not list runs no gate.
- **A gate reads repository paths from `aisdlc.json`** through `AiSdlcConfig.psm1`: the docs roots,
  the solution, the ADR folder, the coverage baseline. A gate never names a repository's folders.
- **`-IncludeToolTests`** runs the Pester tests in the `scripts/` folder of every package that runs,
  and of each repository gate. The pre-flight does not pass it; a repository tests its own gates as add-gate says.
- **The private-terms gate** (`Check-PrivateTerms.ps1`) runs in a public repository, by `visibility` or by GitHub Actions.
  It names a finding by file, line and rule number, never by the matched text ([layout](/.claude/skills/ai-sdlc-handbook/references/layout.md)).

## The gates.json of a package

```json
{ "package": "dotnet",
  "gates": [ { "name": "Line coverage stays at the baseline ...", "script": "scripts/Check-Coverage.ps1",
               "clause": "C04", "mode": "Blocking", "args": { }, "requires": "CoverageFile",
               "checks": "It reads the coverage file of the test run. ... Exit 2 means ..., and exit 3 means ...",
               "fix": "Add tests to bring coverage back up." } ],
  "setup": "scripts/Initialize-Dotnet.ps1",
  "preflight": "scripts/Invoke-DotnetPreflight.ps1",
  "postEdit": { "extensions": [".cs", ".razor"], "script": "scripts/Invoke-DotnetPostEdit.ps1" },
  "allow": [ "dotnet test *", "PowerShell(./build.ps1 *)" ] }
```

- `gates` may be empty. Each entry needs a unique `name` that says what passes, a `clause` (a core
  clause, a pack clause or `AI-SDLC`), a `checks` text and a `fix` text. The runner fails an entry
  without them, or with a name used twice, and does not run it. It prints `checks` before the output
  of a gate that failed, and under each gate with `-List`. The [gate list](references/gate-catalog.md)
  shows every gate with both texts.
- `requires: CoverageFile` runs the gate only when the runner gets `-CoverageFile`. The shared
  composite action passes it when the workflow gives it the `coverage-file` input.
- `inputs` is an optional list of path globs, such as `**/*.md`. A local run starts the gate only when
  the change touches a file that matches, or the skill folder of its script; otherwise it shows
  `NOT TOUCHED`. Every gate runs on a delete, a change to the gate setup, an unreadable change, with
  `-All` and in GitHub Actions.
- `mode` is Blocking, Advisory or Off. No run, hook or pre-flight starts an Off gate. A repository
  sets the mode of a shared gate in `gateModes` of its own `aisdlc.json`, in any letter case. The
  summary shows where the mode comes from in its Source column. The secret scan, the private-terms gate
  and the sync manifest check always run Blocking. In a push hook a gate counts as Off only once the setting is in
  every pushed commit.
- `setup` runs from `Initialize-AiSdlc.ps1` in `ai-sdlc-hooks`, for each package that runs.
- `preflight` runs from `Invoke-Preflight.ps1`. It returns rows with Check, Status and Detail, and a
  FAIL row fails the pre-flight and writes no receipt.
- `postEdit` runs from `Invoke-PostEditCheck.ps1` for an edited file with one of those extensions.
  What it writes is handed to the agent.
- `docUnits` names the units that need a page, for `Check-DocCoverage.ps1`. `docFacts` names the
  script that `New-DocCandidate.ps1` reads the facts of a unit through.
- `allow` lists the commands the skills of the package run. `Sync-AllowRules.ps1` writes each one into
  `.claude/settings.json` as a `Bash(...)` and a `PowerShell(...)` rule; an entry that names its shell is
  written as it is. The advisory core gate runs it with `-Check`.

## Exit codes

| Code | Meaning | What the pull request build does | What a local run does |
|---|---|---|---|
| 0 | Checked, nothing found | Pass | Pass |
| 1 | Checked, and found a violation | Blocking: fail. Advisory: warn | The same |
| 2 | Could not check, for example a configured path is missing | Blocking: fail. Advisory: warn | Warn (UNVERIFIED), never pass |
| 3 | Not applicable: nothing here to check | `N/A`, no annotation, never blocks | The same |

Any other code counts as 1. A crashed gate fails the run when it is Blocking and warns when it is
Advisory. The agent push hook denies only on 1; after 2 it shows a note. ADR 0019 in the AI.SDLC
repository records the contract.

A gate prints each finding with two spaces in front, as `path:line  what`, and one line that starts
with `FIX: `. `Invoke-Gate.ps1` lifts both into a GitHub Actions annotation (`::error` or `::warning`), and names the command to
repeat the gate locally with the path of the script it ran.

## Helper scripts and modules

The modules and helper scripts next to the gates, such as `ChangedFiles.psm1`, `PreflightReceipt.psm1`,
`Sync-AgentsFile.ps1` and the gitleaks scripts, are listed on the [helper scripts page](references/helper-scripts.md).

## Sources

- [The layout of the shared AI-SDLC](/.claude/skills/ai-sdlc-handbook/references/layout.md) - core, packs, repo files and every field of `aisdlc.json`.
- [Documentation wiki](/.claude/skills/ai-sdlc-handbook/references/docs-wiki.md) - the rules the doc gates check.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).
