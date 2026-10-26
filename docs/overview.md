# How AI.SDLC is built

AI.SDLC holds the shared AI-SDLC as APM packages: one core and one pack per technology, tool or purpose. A repository
installs the packages it needs with APM (Agent Package Manager), pinned to one release tag. This page
says how the repository is built. The [functional overview](../docs-functional/overview.md) says what a
team gets from it.

## The packages

| Package | Page | Who installs it |
|---|---|---|
| `core/` | [core](packages/core.md) | Every repository |
| `packs/dotnet/` | [dotnet](packages/dotnet.md) | A repository with a .NET solution |
| `packs/blazor/` | [blazor](packages/blazor.md) | A repository with a Blazor app |
| `packs/bicep/` | [bicep](packages/bicep.md) | A repository with Bicep templates |
| `packs/github/` | [github](packages/github.md) | A repository hosted on GitHub |
| `packs/github-issues/` | [github-issues](packages/github-issues.md) | A repository that tracks its work in GitHub Issues |
| `packs/discovery/` | [discovery](packages/discovery.md) | A team that does discovery work: research, journeys, hypotheses |
| `packs/knowledge/` | [knowledge](packages/knowledge.md) | A repository that keeps notes in a knowledge repository |
| `packs/sonarcloud/` | [sonarcloud](packages/sonarcloud.md) | A repository with a SonarCloud project |

Each package folder holds an `apm.yml` and a `.apm/` folder with `skills/`, `agents/` and `hooks/`. A
script always lives in the `scripts/` folder of a skill, so APM installs it with the skill. A skill
that has gates names them in its `gates.json`, and `Invoke-LocalGates.ps1` in the core runs every gate
of the installed packages.

## What a pack can hold

A pack is a package like the core, with the same folder shape. Everything in it is optional, and the
core finds each part by its place or its file name, so a pack never registers itself anywhere.

| Part | Where in the pack | What the core does with it |
|---|---|---|
| Skills | `.apm/skills/<name>/SKILL.md`, workflow or knowledge | Installed to `.claude/skills/`; a workflow skill is a command a person types or an internal step another skill calls (`user-invocable: false`), a knowledge skill is rules an agent reads |
| Agents | `.apm/agents/<name>.agent.md` | Installed to `.claude/agents/`; a skill hands work to it by name, for example `code-reviewer` in the `dotnet` pack |
| Hooks | `.apm/hooks/<pack>-hooks.json` | APM merges the entries into `.claude/settings.json`; the `dotnet` pack adds the stale-graph stop this way |
| Gates | `gates` in a skill's `gates.json`: name, script, mode `Blocking` or `Advisory`, args, and `clause`: a clause id, a rule family such as `AI-SDLC`, or left out, and then the runner shows the package name | `Invoke-LocalGates.ps1` runs them in the push hook, the pull request workflow and a local run |
| Setup step | `setup` in `gates.json`, a script | `Install-AiSdlc.ps1` runs it once per clone, for example the .NET restore or the Graphify install |
| Pre-flight step | `preflight` in `gates.json`, a script | `Invoke-Preflight.ps1` runs it before the receipt, for example the .NET build and tests or the Bicep build |
| Post-edit step | `postEdit` in `gates.json`, a script | `Invoke-PostEditCheck.ps1` runs it after an edit of a matching file |
| Doc units | `docUnits` in `gates.json`: a glob, what a unit folder contains, its kind and its page folder | `Check-DocCoverage.ps1` asks for a page per unit; `dotnet` names projects, `bicep` names building blocks |
| Doc facts | `docFacts` in `gates.json`, a script | `New-DocCandidate.ps1` reads the facts of a unit through it and writes them to a facts file, from which an agent drafts the missing page |
| `AGENTS.md` part | `assets/agents-<pack>.md` in one skill | `Sync-AgentsFile.ps1` writes it between the `ai-sdlc:<pack>` markers of the repository's `AGENTS.md` |
| Workflow assets | `assets/actions/<name>/action.yml` in one skill | A repository uses the composite action by path; today only the core ships one |
| References | `references/*.md` in a skill | Read by the skill and linked from the docs of a repository |
| MCP servers | `dependencies.mcp` in the pack's `apm.yml` | Nothing: APM writes the server into `.mcp.json` of the repository; the `sonarcloud` pack ships one this way |

The `gates.json` fields in use today, per skill: `dotnet-gates` carries `setup`, `preflight`,
`postEdit` and `gates`; `dotnet-code-graph` carries `setup`, `docUnits`, `docFacts` and `gates`;
`bicep-conventions` carries `preflight`, `docUnits`, `docFacts` and `gates`; `check-pr-contract` in
`github-issues` carries `preflight` and `gates`; `github-pull-requests` carries `setup` and `gates`;
`blazor-conventions` and `sonarcloud-mcp` carry `gates`. The `discovery` and `knowledge` packs ship skills only. The core
reads every field through `AiSdlcConfig.psm1`. A pack holds nothing a consumer must edit:
the values a repository sets live in its `aisdlc.json`, which
[the layout page](../core/.apm/skills/ai-sdlc-handbook/references/layout.md) lists per field. The
packs it uses are not in that file: `AiSdlcConfig.psm1` reads them from its `apm.yml`.

## What stays in this repository

Four folders are never installed:

- `tools/` holds the scripts that check this repository and set up a consumer ([tools](tools.md)).
- `config/` holds the retired skill names (`retired-skill-names.txt`) and the defaults of a new
  consumer (`defaults.json`): the AI.SDLC source URL, the main branch and the runner. It holds no consumer
  list and no private term list: both are private, so they live in the knowledge repository.
- `test-consumers/` holds the test consumers. `tools/Test-Consumers.ps1` installs the packages into each one and
  runs its blocking gates. It also moves each one from the previous release to the change, the way a
  consumer takes a new version.
- `.github/` holds the pull request workflow of this repository.

## This repository installs its own packages

AI.SDLC installs its packages into its own `.claude/`, so the work here uses the same skills, hooks and
gates as every consumer. Its `apm.yml` names `./core` and the packs every consumer gets (`github` and
`github-issues`) as local packages, plus `discovery`. So the copy is always the source of the
branch, not a release. `aisdlc.json` holds the settings, also the two doc layers and the units of this page.

Two parts keep the copy and the source the same:

- `Check-SyncManifest.ps1` reads the source manifest in `core/` when `apm.yml` installs the core from
  inside the repository. A branch that changes a source file without a new `apm install` fails it.
- `Deny-SharedFileEdit.ps1` stops an edit of a copy and names the source file in this repository.

AI.SDLC is not a consumer: it has no update workflow, so no update pull request moves it. A change to a gate is checked by that changed gate on its
own branch. So the Pester tests and the test consumers stay the independent check of a change.

## The pull request workflow

It lives in `.github/workflows/pr.yml`. `tools/PrPipeline.Tests.ps1` checks its layout, its jobs, the
SHA pins of its actions, and that every script and action it names exists. It runs on every pull
request to `main` and on every push to `main`, with read rights only.

It runs three kinds of parallel jobs on GitHub-hosted runners:

- seven jobs run the Pester shares: four for `core/`, two for `packs/` and one for `tools/`. Each
  uploads the coverage it measured;
- two jobs per test consumer run the fresh install and the update from the previous release. Each
  installs the pinned gitleaks first, because the gates of a test consumer include the C03 secret scan;
- one job runs the shared AI-SDLC step through the composite action of the core, as in a consumer. It
  gets the private term list from the secret `AISDLC_PRIVATE_TERMS`.

The shared AI-SDLC step runs every gate once: the core gates, the pack gates and the `repoGates` of
`aisdlc.json`. So no job lists a gate step by hand. The `repoGates` hold the checks of this repository
only. They check the private terms, the retired skill names, the skill list and the sync manifest.
They also check the size of the shared `AGENTS.md` parts, the package versions and the reading level.
They run the em-dash and the line number checks over a wider path than the core gates do, for example
`tools/` and `CHANGELOG.md`.

So the run takes as long as its slowest job. A public repository never uses a self-hosted runner,
because a pull request from a fork could run code on it.

A release has no workflow. AI.SDLC does not know its consumers, so each consumer pulls a release
itself ([ADR 0002](adrs/0002-distribution-auth-and-updates-on-github.md)). `Add-AiSdlcConsumer.ps1`
writes `.github/workflows/ai-sdlc-update.yml` there. Every Monday it runs
`New-AiSdlcUpdatePullRequest.ps1` of the core, which opens one update pull request. The starter pull request workflow
it writes runs the same composite action as this repository. The [README](../README.md) holds
the steps to change a shared file and to release.

## Related

- [core](packages/core.md) - the package every repository installs.
- [tools](tools.md) - the scripts that check this repository and set up a consumer.
- [ADR 0003](adrs/0003-ai-sdlc-installs-its-own-packages-from-its-own-source.md) - why AI.SDLC installs its own packages from its own source.
- [ADR 0012](adrs/0012-ci-is-a-composite-action-inside-the-installed-core.md) - why the shared CI step is a composite action inside the installed core.
- [What the AI-SDLC gives a team](../docs-functional/overview.md) - the same repository seen from the team that uses it.
- [Index](index.md) - every page of this layer.
