# Helper scripts and modules

These sit in the `scripts/` folder of the `ai-sdlc-gates` skill, next to the gates, but they are not
gates themselves.

- `Install-Apm.ps1` installs the pinned APM release for this machine (Linux, macOS or Windows) and
  refuses it on a SHA-256 mismatch. `-AddToPath` keeps it on the PATH.
- `GateAnnotation.psm1` turns a gate result into GitHub Actions annotations when `GITHUB_ACTIONS` is
  `true`, for `Invoke-Gate.ps1` and the runner.
- `Invoke-PesterGate.ps1` is a repository gate that runs the Pester tests under `args.Path`.
- `PreflightReceipt.psm1` writes and reads the pre-flight receipt that the push hook asks for.
  `Find-PreflightBase` finds the commit of the last green pre-flight on the branch.
- `ChangedFiles.psm1` gives one list of the files and lines a change touched, for the runner, the
  pre-flight and every gate that judges the change.
- `Test-PushReceipt.ps1` and `Test-PushSendsNothingNew.ps1` tell the pre-push hook whether a receipt or
  the remote already covers each pushed commit.
- `ToolOutput.psm1` prints numbers the same way on every machine, whatever its culture settings.
- `Create-GitleaksBaseline.ps1` makes a gitleaks baseline with the rule sets pinned in
  `gitleaks-rules.json`. `Test-GitleaksBaseline.ps1` runs gitleaks against that baseline, or without
  one when the repository has none. It is the blocking C03 gate of `gates.json`. On a pull request in
  GitHub Actions it scans `PR_BASE_SHA..HEAD`, the commits of the pull request. In a local run it scans
  `<main branch>..HEAD`, where `Get-AiSdlcMainBranch` gives `origin/<github.trunk>` or a fallback. When
  git cannot read the folder, for example as "dubious ownership", it scans nothing. It then exits 2
  locally and 1 in GitHub Actions, never 0.
- `Install-Gitleaks.ps1` installs the gitleaks release pinned in `gitleaks-version.json` and refuses
  it on a SHA-256 mismatch, as `Install-Apm.ps1` does for APM.
- `GitleaksConfig.psm1` writes the gitleaks configuration of a scan: the rules plus an allowlist for
  `sync-manifest.json`, whose git blob hashes look like keys.
- `DocCoverage.psm1` finds the units that need a page.

The test harnesses `DocToolTestHarness.psm1` and `GateContractTestHarness.psm1` live in AI.SDLC under
`core/tests/`, next to the tests that use them; APM does not install them.

## The shared part of AGENTS.md

`Sync-AgentsFile.ps1` writes the core part of `AGENTS.md`, and the part of each listed pack, between
`ai-sdlc:<package>:start` and `ai-sdlc:<package>:end` markers. Its `-Check` mode is a core gate: a
hand edit between the markers fails it. Change the shared text in AI.SDLC, then run the script:
`pwsh .claude/skills/ai-sdlc-gates/scripts/Sync-AgentsFile.ps1`.

## Related

- [AI-SDLC gates](../SKILL.md) - the gates, the exit codes and the runner.
- [Gate list](gate-catalog.md) - every gate with what it checks and how to fix it.
