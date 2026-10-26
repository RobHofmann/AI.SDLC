---
units:
  - tools
---

# tools

The `tools` unit provides scripts, tests, and workflow templates for shared AI-SDLC maintenance and consumer repository workflows.

## What it contains

### Scripts

- `tools/Add-AiSdlcConsumer.ps1` sets up the shared AI-SDLC in a repository that does not have it yet. It selects the packs: always `github` and `github-issues`, plus `dotnet`, `blazor` or `bicep` when the repository holds that code. It writes `aisdlc.json` with `github.repository` from the git remote, `apm.yml` pinned to one release tag of the AI.SDLC source, and a starter pull request workflow. Its `tracker.acceptedRepositories` names the AI.SDLC source, so the story check of an update pull request accepts the release issue. It changes nothing in AI.SDLC. It also writes the update workflow `.github/workflows/ai-sdlc-update.yml`, so the repository pulls each release itself. AI.SDLC keeps no list of consumers.
- `tools/Check-RetiredSkillNames.ps1` fails when `core/`, `packs/`, `docs/`, `docs-functional/`, `README.md`, `AGENTS.md`, `.claude/settings.json`, `.claude/CLAUDE.md` or a root `CLAUDE.md` names a skill by a name that a release retired. In a Markdown heading it also catches an old name of two or more words written with spaces, such as `# Generate code`. The names are in `config/retired-skill-names.txt`. It runs as a blocking repo gate (`repoGates` in `aisdlc.json`).
- `tools/Check-PackageVersion.ps1` checks that the `version` in every `apm.yml` matches the newest `## vX.Y.Z` heading of `CHANGELOG.md`. When `apm.lock.yaml` exists at the root, it also checks that the lock file records that version for each local package (`./core`, `./packs/<name>`). Without the lock file it prints that it skipped this check. After a version bump, run `apm install` twice: APM 0.31.0 records the version of the old copy in `apm_modules/` on the first run. It runs as a blocking repo gate.
- `tools/Check-SharedAgentsPartSize.ps1` checks that shared `AGENTS.md` parts from all packages stay within a budget. It runs as a blocking repo gate.
- `tools/Invoke-PesterParallel.ps1` runs every test file under `core/`, `packs/` and `tools/` in its own process, several at once. The workflow and a local run both use it. With `-CoverageFile` each test file measures the scripts and modules in its own folder. The run then writes one coverage file in a generic XML format. `tools/PesterCoverage.psm1` picks the files and writes the XML. The run keeps the time of each file in `temp/pester-times.json`. The next run starts the slowest files first, so a slow file does not end the run alone. Each run gives its test processes their own temp folder, so two runs on one machine cannot delete each other's files. `-Changed` runs only the tests of the changed scripts, and `-ListOnly` prints the plan without running it. With `-Ci` each failure is also a GitHub Actions error annotation. `commands.test` in `aisdlc.json` runs it over `core/`, `packs/` and `tools/`, so the pre-flight runs those tests.
- `tools/Test-Consumers.ps1` installs this repository's packages into each test consumer under `test-consumers/`. Then it runs `Add-AiSdlcConsumer.ps1` on a generated repository, the `setup-script` consumer. With `-Upgrade` it installs each test consumer at the previous release tag. Then it moves it to the change with the `Update-AiSdlc.ps1` of that old version, as a real consumer does. Before the first release there is no older tag, so that pass says so and passes.
- `tools/Update-SyncManifest.ps1` writes the list of every file and hook each package delivers to a consumer, with its git hash, and the retired skill names. It can also check that the list is current. The core gate `Check-SyncManifest.ps1` reads it.
- `tools/Update-SkillCatalog.ps1` writes the list of every skill and agent in every AI.SDLC package. It can also check that the list is current.

### Tests

Most scripts have a matching test file:

- `tools/Add-AiSdlcConsumer.Tests.ps1`
- `tools/Check-PackageVersion.Tests.ps1`
- `tools/Check-RetiredSkillNames.Tests.ps1`
- `tools/Check-SharedAgentsPartSize.Tests.ps1`
- `tools/Invoke-PesterParallel.Tests.ps1`
- `tools/PesterCoverage.Tests.ps1`
- `tools/Test-Consumers.Tests.ps1`
- `tools/Update-SkillCatalog.Tests.ps1`
- `tools/Update-SyncManifest.Tests.ps1`

The unit also contains `tools/PrPipeline.Tests.ps1`. It checks the pull request workflow `.github/workflows/pr.yml`: its triggers, its read rights, the SHA pins of its actions, and its jobs and matrices. It also checks that every script and action it names exists. It checks that the workflow runs no gate by hand, because the composite action runs every core, pack and repo gate once.

When changing a script, keep its matching test file in step with the change.

### Workflow templates

`tools/templates/workflows/` holds the starter workflow of a new repository. `Add-AiSdlcConsumer.ps1`
writes it once, when the repository has no `.github/workflows/pr.yml`. It fills the `{{Token}}`
placeholders: the repository name, the main branch, the runner and, for a .NET solution, the first `.sln`
it finds. The main branch and the runner come from `config/defaults.json`. After that the file belongs to
the repository; a later release does not touch it. The shared step it runs is not a template here: it
is the composite action of the core, in `ai-sdlc-gates/assets/actions/ai-sdlc-pr/`, so it moves with
each release.

| Template | Written as | What it is |
| --- | --- | --- |
| `pr.yml` | `.github/workflows/pr.yml` | The pull request workflow: a full-depth checkout, then the composite action of the core with the private term list from the secret `AISDLC_PRIVATE_TERMS`. Read rights only, and one run per pull request at a time. Other build and test jobs of the repository go next to it. |
| `ai-sdlc-update.yml` | `.github/workflows/ai-sdlc-update.yml` | The update workflow: every Monday and on demand, it signs in as a GitHub App (the variable `AISDLC_UPDATE_APP_CLIENT_ID` and the secret `AISDLC_UPDATE_APP_PRIVATE_KEY`) and runs `New-AiSdlcUpdatePullRequest.ps1` of the core, which opens one pull request for a newer AI.SDLC release. It fails with a message that names what to set when the App is not set up. |
| `dotnet-test-steps.yml` | steps inside `pr.yml`, only with the `dotnet` pack and a solution | The .NET SDK from `global.json`, then restore, build, test with coverage and the run settings, and merge the coverage files with `dotnet-coverage`. The workflow then passes the merged file to the action as `coverage-file`, which runs the C04 coverage ratchet. |

The script leaves the rest for the person, and prints it. Switch on Issues and add the labels, set up the GitHub App of the update workflow, and commit. Then `Set-BranchRuleset.ps1` from the `github`
pack makes the check of the workflow required on the main branch. The printed command names the check with
`-RequiredCheck`. That is the job name of the starter workflow. In an existing workflow, it is the job
that runs the shared step. The script prints that step apart from the others, also with `-NoWorkflows`, because without it no gate has to pass on a pull request.
`-NoWorkflows` skips both templates, and an existing workflow file is never overwritten. The tests in `tools/Add-AiSdlcConsumer.Tests.ps1` cover the
placeholders and the files written.

## Dependencies

`tools/Test-Consumers.ps1` uses test consumers under `test-consumers/`.

`tools/Check-RetiredSkillNames.ps1` and `tools/Update-SyncManifest.ps1` read `config/retired-skill-names.txt`.

`tools/Add-AiSdlcConsumer.ps1` and `tools/Test-Consumers.ps1` read `config/defaults.json`.

## Related

- [How AI.SDLC is built](overview.md) - the packages, the workflow and the test consumers.
- [core](packages/core.md) - the package whose setup `Add-AiSdlcConsumer.ps1` installs.
- [Index](index.md) - every page of this layer.
