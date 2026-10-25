# AGENTS.md - AI.SDLC

The engineering instructions for this repository. GitHub Copilot reads this file on its own; Claude
Code reads it through `.claude/CLAUDE.md`. The README says what the repository holds and how a release works;
this file says how to change it without breaking a consumer.

<!-- ai-sdlc:core:start - installed from AI.SDLC; change it there, not here -->
## Communication

Say the main thing first: the answer, the decision, or the result. Give the reason after it, and only when the
reason changes what the reader does next. Lead with the action or the result, number the steps, and end with one
next action. Cut every word that adds nothing. Say what you assume, what can go wrong, and what you have not
checked. When a request can be read in more than one way, ask one question to make it clear before you start.
Inside a run, look up what the substrate holds. Before Checkpoint Alpha, `grilling` asks the rest in rounds, and
what the person leaves open goes to Checkpoint Alpha. In the build loop, an unclear story is a stop; any other open
point goes to Checkpoint Bravo. Write **sentences at CEFR B2 and words at CEFR B1**: one main idea per sentence,
never over 25 words. Use the word you would say in a meeting. Keep every name, number, path and code name exactly
as it is. Everything we keep is English: docs, ADRs, skills, work items, wiki pages, commits, branches, pull
requests, code and log messages. Chat follows the language the user writes in. Nothing we keep names an AI tool as
its author or helper. The full rule: `.claude/skills/ai-sdlc-handbook/references/language.md`.

## Constitution (core)

These rules never bend, in every change. Claude Code loads the full clauses through the import line below;
any other agent reads that file before it starts. A repository's own clauses live in `paths.constitution`.

@.claude/skills/ai-sdlc-handbook/references/constitution.md

## Shared AI-SDLC

The files under `.claude/` that `apm.lock.yaml` lists are installed from AI.SDLC and are read-only
here. Change one in AI.SDLC; `.claude/skills/ai-sdlc-handbook/references/layout.md` says how. A clone
is set up once with `pwsh .claude/skills/ai-sdlc-hooks/scripts/Install-AiSdlc.ps1`. The way of working
starts at `.claude/skills/ai-sdlc-handbook/references/README.md`; `guide-me` finds the next step.
<!-- ai-sdlc:core:end -->

## What this repository is

AI.SDLC is the source of the shared AI-SDLC. Other repositories install its packages with APM (Agent
Package Manager) and commit a copy under their `.claude/` folder. A file here is the original; a
file in a consumer is a copy that nobody edits by hand.

- `core/` is the package every repository installs. `packs/<name>/` is one package per technology, tool or purpose.
- Each package holds `apm.yml` and `.apm/` with `skills/`, `agents/` and `hooks/`.
- `tools/`, `config/`, `test-consumers/` and `.github/` belong to this repository only; APM never installs them.

This repository installs its own packages from its own folders: `apm.yml` names `./core` and
`./packs/<name>`. So the skills, agents, hooks and gates under `.claude/` are the current source, and a
change here follows the same process as in a consumer. Edit the source, never the copy; a hook stops
an edit of the copy. `tools/Test-Consumers.ps1` still shows a change the way a pinned consumer sees it.

## Rules that never bend

- **No shared file holds private information.** AI.SDLC is public. So no file, commit message, branch
  name or pull request text may name a consumer, a server, a domain, an address or a person.
  `Check-PrivateTerms.ps1` blocks the build on any term of the private list, which lives outside this
  repository: `<knowledgeRoot>/ai-sdlc/private-terms.txt` locally, and the secret
  `AISDLC_PRIVATE_TERMS` in CI. Here the gate runs with `-Required`, so a missing list fails. It prints
  the file, the line and the rule number, never the text. Read repository facts from `aisdlc.json`
  through `AiSdlcConfig.psm1` instead, and use made-up names in examples (`Contoso`, `contoso/portal`, `#42`).
- **A pull request from a fork gets no secrets**: run `Check-PrivateTerms.ps1 -Required` on its branch before you merge it.
- **A script lives in the `scripts/` folder of a skill**, so APM installs it with the skill. A gate
  is listed in the `gates.json` of its skill, and the runner runs only the gates of installed packs.
- **A link from one skill to another is written as `/.claude/skills/<skill>/...`.** APM rewrites a
  relative link between two skills of one package into `apm_modules/`, which a consumer ignores.
  Links inside one skill stay relative.
- **A core skill that names a pack skill** is listed in `core/.apm/skills/ai-sdlc-gates/skill-catalog.json`.
  Run `tools/Update-SkillCatalog.ps1` after you add, rename or remove a skill or an agent.
  A renamed skill also adds its old and new name to `config/retired-skill-names.txt`.
- **A core clause has one source (C12)**: its section in `constitution.md`. `agents-core.md` imports that
  page with an `@` line, so never copy a clause into `AGENTS.md` or a skill.
- **Every file a package delivers is in `core/.apm/skills/ai-sdlc-gates/sync-manifest.json`**, with its
  hash. Run `tools/Update-SyncManifest.ps1` after any change under `.apm/`, after `Update-SkillCatalog.ps1`,
  then `apm install`, and commit both. The gate `Check-SyncManifest.ps1` fails each build whose `.claude/`
  differs from it. Here it reads the source manifest, so a `.claude/` behind the source fails too.
- **Hooks use paths relative to the repository root**: APM rewrites a hooks folder path, which breaks on Windows.
- **Every file keeps LF line endings** (`.gitattributes`): a CRLF file breaks `apm install --frozen` in a consumer.
- **The shared parts of AGENTS.md stay within 50 lines and 600 words together**, because each line is
  a line taken from every consumer's AGENTS.md. `tools/Check-SharedAgentsPartSize.ps1` blocks the build.
- **A shared script ships with a Pester test next to it** (`<Name>.Tests.ps1`), which the workflow runs.
- **Every third-party action in a workflow is pinned to a full commit SHA**, with its version in a
  comment. Every job runs on a GitHub-hosted runner.

## Commands

```bash
pwsh tools/Invoke-PesterParallel.ps1                    # every test file in its own process, in parallel
pwsh core/.apm/skills/ai-sdlc-gates/scripts/Check-PrivateTerms.ps1 -Required   # no private term anywhere
pwsh tools/Check-RetiredSkillNames.ps1                  # no shared file names a retired skill
pwsh tools/Update-SkillCatalog.ps1 -Check               # the skill catalog is current
pwsh tools/Update-SyncManifest.ps1 -Check               # the sync manifest is current
pwsh tools/Check-SharedAgentsPartSize.ps1               # the shared AGENTS.md parts stay within budget
pwsh tools/Check-PackageVersion.ps1                     # every apm.yml has the newest CHANGELOG version
pwsh tools/Test-Consumers.ps1                           # install into every test consumer, run its gates
pwsh tools/Add-AiSdlcConsumer.ps1 -TargetRepo <path>    # set up the AI-SDLC in a new repository
```

`repoGates` in `aisdlc.json` lists the gates above but the Pester runner and `Test-Consumers.ps1`, so the
pre-push hook runs them, unless a passing pre-flight receipt covers the push. `commands.test` runs the
tests of `core/`, `packs/` and `tools/` in the pre-flight. The pull request workflow,
`.github/workflows/pr.yml`, runs them all: the Pester shares, the test consumers and the shared AI-SDLC
step. That step runs every core, pack and repo gate once. `Test-Consumers.ps1` needs APM, gitleaks and, on Windows, long paths.

## How a change moves

1. Open an issue, then branch from `main` with its number (`42-short-name`). Change the file under
   `core/` or `packs/`, with its test.
2. Try it: run the commands above. To try it in a real consumer, point that consumer's `apm.yml` at
   this clone (`- ../AI.SDLC/core`) and run `apm install` there. Never commit that form.
3. Add a line to `CHANGELOG.md` under the version this pull request releases, never under
   `Unreleased`. When the newest heading has no tag yet, add to it. Otherwise start a new heading
   `## vX.Y.Z - <date>`. Raise Z for a fix or a change in `tools/`. Raise Y for a new skill, gate or
   behaviour. Raise X for a change a consumer must act on. Set `version` in every `apm.yml` to the
   same version; `tools/Check-PackageVersion.ps1` fails the build when one differs. Then open a pull
   request with `Refs #42`, never `Fixes #42`, so the merge leaves the issue open. `main` only changes
   through a pull request with green checks; the owner's merge is the approval.
4. A release is an annotated tag on `main` whose message names the issue, and a GitHub release on that
   tag. Write the message as `Release v1.2.0 for #42`, because git drops a line that starts with `#`. Then a person closes
   the issue and keeps its `refined` label. AI.SDLC pushes nothing to a consumer: each one pulls the
   release with its update workflow or the `update-ai-sdlc` skill, in a pull request that says
   `Refs RobHofmann/AI.SDLC#42`. The README has the steps.

A lesson that a consumer learns about a shared file comes here as a pull request. The handbook page
`core/.apm/skills/ai-sdlc-handbook/references/autolearn.md` says how to tell a shared lesson from
one that stays in the consumer. A fact about a system goes to the knowledge repository instead.

## Adding a consumer

Run `tools/Add-AiSdlcConsumer.ps1 -TargetRepo <path>` from this clone; the README says what it writes.
It writes the update workflow `.github/workflows/ai-sdlc-update.yml`, which signs in as a GitHub App that
the consumer sets up once. It lists AI.SDLC in the consumer's `tracker.acceptedRepositories`, so an
update pull request passes its story check. AI.SDLC keeps no list of consumers.

- The AI.SDLC source URL, the main branch and the starter runner live in `config/defaults.json`; change them there.
- AI.SDLC is not a consumer: it pins its own source, and it has no update workflow.

The detail lives in `README.md`, the handbook (`layout.md` and `README.md` under
`core/.apm/skills/ai-sdlc-handbook/references/`), `docs/`, `docs-functional/` and `CHANGELOG.md`.
