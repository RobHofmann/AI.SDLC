---
name: ai-sdlc-gates
kind: knowledge
user-invocable: false
description: >
  The deterministic gates of the AI-SDLC and how to run them. It covers the core gates every
  repository runs, the gates each pack adds, and the repository's own gates from aisdlc.json. It also covers the exit
  codes 0, 1 and 2, and the runner that runs only the gates of the installed packs. Use when a gate failed and needs
  explaining, when checking a change before a push, when adding a gate, or when reading aisdlc.json.
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
- **The private-terms gate** (`Check-PrivateTerms.ps1`) runs when `visibility` is `public`, or when
  GitHub Actions says the repository is public. In a public repository in CI, no list fails. It names
  a finding by file, line and rule number, never by the matched text ([layout](/.claude/skills/ai-sdlc-handbook/references/layout.md)).

## The gates.json of a package

```json
{ "package": "dotnet",
  "gates": [ { "name": "C10 ...", "script": "scripts/Check-CommentHygiene.ps1", "clause": "C10",
               "mode": "Blocking", "args": { }, "requires": "CoverageFile" } ],
  "setup": "scripts/Initialize-Dotnet.ps1",
  "preflight": "scripts/Invoke-DotnetPreflight.ps1",
  "postEdit": { "extensions": [".cs", ".razor"], "script": "scripts/Invoke-DotnetPostEdit.ps1" },
  "allow": [ "dotnet test *", "PowerShell(./build.ps1 *)" ] }
```

- `gates` may be empty. `requires: CoverageFile` runs the gate only when the runner gets `-CoverageFile`.
  The shared composite action passes it when the workflow gives it the `coverage-file` input.
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

| Code | Meaning | What CI does |
|---|---|---|
| 0 | Checked, nothing found | Pass |
| 1 | Checked, and found a violation | Blocking: fail the build. Advisory: warn |
| 2 | Could not check, for example a configured path is missing | Warn, never pass |

A gate prints each finding with two spaces in front, as `path:line  what`, and one line that starts
with `FIX: `. `Invoke-Gate.ps1` lifts both into a GitHub Actions annotation (`::error` or `::warning`), and names the command to
repeat the gate locally with the path of the script it ran.

## The shared part of AGENTS.md

`Sync-AgentsFile.ps1` writes the core part of `AGENTS.md`, and the part of each listed pack, between
`ai-sdlc:<package>:start` and `ai-sdlc:<package>:end` markers. Its `-Check` mode is a core gate: a
hand edit between the markers fails it. Change the shared text in AI.SDLC, then run the script:
`pwsh .claude/skills/ai-sdlc-gates/scripts/Sync-AgentsFile.ps1`.

## Helper scripts and modules

These sit in the same `scripts/` folder but are not gates:

- `Install-Apm.ps1` installs the pinned APM release for this machine (Linux, macOS or Windows) and
  refuses it on a SHA-256 mismatch. `-AddToPath` keeps it on the PATH.
- `GateAnnotation.psm1` turns a gate result into GitHub Actions annotations when `GITHUB_ACTIONS` is `true`, for `Invoke-Gate.ps1` and the runner.
- `Invoke-PesterGate.ps1` is a repository gate that runs the Pester tests under `args.Path`.
- `PreflightReceipt.psm1` writes and reads the pre-flight receipt that the push hook asks for.
- `Test-PushReceipt.ps1` and `Test-PushSendsNothingNew.ps1` tell the pre-push hook whether a receipt or the remote already covers each pushed commit.
- `ToolOutput.psm1` prints numbers the same way on every machine, whatever its culture settings.
- `DocToolTestHarness.psm1` builds the throwaway repository that the tests of the doc tools share. Its `Invoke-ScriptInProcess` runs a script in the test process, so the coverage of the Pester run measures it.
- `Create-GitleaksBaseline.ps1` makes a gitleaks baseline with the rule sets pinned in
  `gitleaks-rules.json`. `Test-GitleaksBaseline.ps1` runs gitleaks against that baseline, or without
  one when the repository has none. It is the blocking C03 gate of `gates.json`. On a pull request in
  GitHub Actions it scans `PR_BASE_SHA..HEAD`, the commits of the pull request, and in a local run `origin/main..HEAD`.
- `Install-Gitleaks.ps1` installs the gitleaks release pinned in `gitleaks-version.json` and refuses
  it on a SHA-256 mismatch, as `Install-Apm.ps1` does for APM.
- `GitleaksConfig.psm1` writes the gitleaks configuration of a scan: the rules plus an allowlist for
  `sync-manifest.json`, whose git blob hashes look like keys.
- `DocCoverage.psm1` finds the units that need a page.

## Sources

- [The layout of the shared AI-SDLC](/.claude/skills/ai-sdlc-handbook/references/layout.md) - core, packs, repo files and every field of `aisdlc.json`.
- [Documentation wiki](/.claude/skills/ai-sdlc-handbook/references/docs-wiki.md) - the rules the doc gates check.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).
