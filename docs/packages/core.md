---
units:
  - core
---

# core

The `core` package provides shared AI-SDLC agents, skills, gates, hooks, workflow guidance, and documentation tools.

## What it contains

### Package files

- `core/apm.yml`
- `core/.apm/hooks/ai-sdlc-hooks.json`
- `core/.apm/skills/ai-sdlc-gates/skill-catalog.json`
- `core/.apm/skills/ai-sdlc-gates/scripts/apm-version.json`

### Agents

Agents live under `core/.apm/agents/`. Each names its model: `opus` for `architect` and `blind-judge`,
`sonnet` for `builder`, `docs-reviewer` and `substrate-walker`. `Check-AgentHygiene.ps1` allows only
`opus`, `sonnet` or `inherit`. An `opus` agent names the model it runs on in a `Model:` line of its
output. GitHub Copilot can run an agent on another model, and that line shows it. In Copilot the hand-off
must pass the model, such as `claude-opus-5.5`: without it, the `task` tool does not start an agent whose
file says `opus` or `sonnet`. Every agent is
read-only except `builder`, the one agent on the writer list of that gate. The agents carry no tracker
tools: they read issues with `gh` or the GitHub MCP read tools.

- `architect` writes the plan for `implement`, and reviews plans, ADR drafts, and API contracts against architecture rules. It also voices the Architect in the `grilling` and `convene-personas` panels. It returns text, but never edits a file or approves.
- `builder` builds a planned change test-first: it writes the tests and the code, and runs the build and the tests. It never commits, pushes or opens a pull request.
- `blind-judge` scores two task outputs without knowing which output used the tested skill. It reads and scores, but never edits.
- `docs-reviewer` checks both documentation layers, their links, related ADRs, and documentation gates. It runs gates only in check mode.
- `substrate-walker` gathers issue, architecture, spec, code, caller, reuse, and recent-change context. It reads but never writes. It reads issues with `gh` (read-only use) and greps the knowledge folder next to the repository docs when it exists.

### Skills

Each skill has a `SKILL.md` file under `core/.apm/skills/`.

A workflow skill is a command a person types, or an internal step that other skills call. An internal
step sets `user-invocable: false`, so Claude Code keeps it out of the slash-command list. The internal
steps of the core are `walk-substrate`, `run-preflight` and `grilling`.

Workflow skills include:

- `guide-me` reports the current lifecycle phase and next step. Without an issue, it reads the skill descriptions and names the command that fits a situation.
- `walk-substrate` gathers context before implementation. It is an internal step.
- `implement` runs the development flow from a refined story to a tested pull request.
- `refactor` improves code structure without changing observable behaviour. Like `implement`, it starts only from a refined issue: the `refined` label and a `size:<n>` label.
- `wrap-up` updates tests, documentation, issues, and gates after code works. Then it commits and runs the pre-flight on that commit. It works only on a branch named with an issue number (`42-short-name`).
- `run-preflight` runs local pull-request checks before a push. It is an internal step that `wrap-up` calls.

Documentation and decision skills include:

- `adopt-docs` brings a repository into line with the AI-SDLC wiki rules.
- `write-docs` maintains the technical and functional documentation layers after a change. Started by a person, it ends like `write-prd`: `wrap-up` commits the pages, then the skill pushes and opens or updates the pull request.
- `docs-wiki-conventions` defines rules for documentation layers, links, style, and checks.
- `write-adr` creates MADR-style records in `docs/adrs/`. Started by a person, it ends like `write-prd`.
- `adr-conventions` defines the repository format and rules for architecture decisions.
- `update-constitution` creates, changes, or checks the project constitution. Started by a person, a create or a change ends like `write-prd`.

Framework support skills include:

- `ai-sdlc-handbook` holds the full AI-SDLC rules and shared layout guidance.
- `ai-sdlc-gates` explains deterministic gates and their exit codes.
- `ai-sdlc-hooks` explains AI-SDLC hooks and clone setup.
- `add-gate` turns a plain-language rule into a deterministic gate and test. Started by a person, a repository gate ends like `write-prd` after you agree to the diff. A shared gate goes to AI.SDLC through its own pull request.
- `test-skills` checks skills with the layered test harness.
- `capture-learning` sends a lesson to the rule that owns it. It has one entry for the session and one for the feedback on a pull request. Started by a person, a change to the repository ends like `write-prd`.
- `handoff` writes the costly parts of a session to their own home, then a handoff document for the next session. Only a person starts it.
- `update-ai-sdlc` takes a new AI.SDLC release in the repository through one update pull request, then does the steps its description lists on the same branch. The scheduled update workflow opens the same pull request every Monday.
- `convene-personas` provides direct access to framework personas.
- `grilling` asks the roles that matter in rounds before another skill drafts an artifact. It is an internal step.
- `grill-me` runs `grilling` on a person's own plan. Only a person starts it.
- `wait-what` re-pitches the last answer that did not land. Only a person starts it.
- `summary` creates a single-page HTML summary.
- `write-prd` writes a Product Requirements Document for an initiative or epic. On a branch named with the issue number of the epic, `wrap-up` commits it; then the skill pushes and opens or updates the pull request.

### Handbook pages

Handbook references live under `core/.apm/skills/ai-sdlc-handbook/references/`.

They cover the artifact graph, constitution, documentation wiki, language rules, layout, orchestration, personas, plans, comments, and context management. `consumer-own.md` says where a consumer keeps its own skills, agents and hooks. `first-story.md` takes a newcomer through a first small story, and `pattern.md` holds the model of each agent and skill.

### Gates

Gate definitions live in `core/.apm/skills/ai-sdlc-gates/gates.json`.

Blocking gates check:

- source line-number references
- artifact graph links
- documentation links and indexes
- em-dash characters
- `AGENTS.md` size and shared content
- reading level
- skill and agent hygiene, which includes a skill description of at most 1024 characters, the limit at which GitHub Copilot stops loading a skill
- internal contributor names
- documentation rows
- pull-request hygiene
- section references
- documentation coverage: both layers and a page per unit
- the installed files against the sync manifest, including a skill folder or an agent file left behind under a retired name. When `apm.yml` installs the core from inside the repository (`- ./core`, as in AI.SDLC), it reads the source manifest there
- every local package that `apm.yml` or `apm.lock.yaml` names is a folder in git (`Check-LocalPackages.ps1`)
- no private term in a public repository: `Check-PrivateTerms.ps1` runs when `visibility` is `public` in `aisdlc.json`, or when GitHub Actions says the repository is public. In a public repository in CI, a missing list fails, except on a pull request from a fork. It reads the private list from outside the repository. It scans every tracked file, the commit messages, the branch name and the pull request text. It prints only the file, the line and the rule number

The one advisory gate checks change completeness. It reads the commits since the base and the edits that
are not committed yet. It also reads the new files git does not ignore, because `wrap-up` runs it before it commits.

`Invoke-LocalGates.ps1` runs gates from installed AI-SDLC packages and the repository.

`Invoke-Gate.ps1` runs one gate script in GitHub Actions or locally and produces a clear result.

`Invoke-PesterGate.ps1` runs Pester tests under the supplied paths.

### Documentation tools

Documentation scripts live under `core/.apm/skills/adopt-docs/scripts/` and `core/.apm/skills/ai-sdlc-gates/scripts/`.

- `Get-FolderFacts.ps1` reads the contents of a unit folder.
- `New-DocCandidate.ps1` collects the facts of each unit with no page into a facts file under `doc-candidates/`. It calls no model; `adopt-docs` hands each facts file to an agent that drafts the page.
- `Repair-DocsWiki.ps1` applies safe machine repairs to existing documentation.
- `Build-DocsIndex.ps1` generates `docs/index.md` and `docs-functional/index.md`.
- `Check-DocCoverage.ps1` checks both documentation layers and unit pages.
- `Check-DocsWiki.ps1` checks for orphans and broken relative links.
- `Check-DocReadingLevel.ps1` checks text against the required reading level.
- `Check-DocEmDashes.ps1` rejects the em-dash character.
- `Check-DocLineCitations.ps1` rejects source references by line number.
- `Check-DocPersonNames.ps1` checks for internal team member names.
- `Check-DocRowContent.ps1` requires each documentation line to carry a fact.
- `Check-DocSectionRefs.ps1` checks references to sections in other pages.

`DocCoverage.psm1` finds units that need pages and the pages that cover them.

`DocToolTestHarness.psm1` provides the temporary repository fixture used by documentation tool tests. `Invoke-ScriptInProcess` in it runs a script in the test process instead of a child `pwsh`, so the coverage of the Pester run measures that script.

### Hooks and setup

Hook files live under `core/.apm/skills/ai-sdlc-hooks/`.

Git hooks include:

- `git-lfs-hook`
- `graphify-refresh`
- `post-checkout`
- `post-commit`
- `post-merge`
- `post-rewrite`
- `pre-push`

`git-lfs-hook` is not a hook itself. `pre-push`, `post-checkout`, `post-commit` and `post-merge` call it
to hand on to Git LFS, because git ignores the LFS hooks in `.git/hooks` once `core.hooksPath` is set.
It does nothing in a repository whose `.gitattributes` never names `filter=lfs`.

Setup and hook scripts include:

- `Install-AiSdlc.ps1`
- `Initialize-AiSdlc.ps1`
- `Update-AiSdlc.ps1`
- `New-AiSdlcUpdatePullRequest.ps1`
- `Find-RetiredSkillNames.ps1`
- `Deny-IncompletePush.ps1`
- `Deny-SharedFileEdit.ps1`
- `Invoke-AutolearnHook.ps1`
- `Invoke-CompactSuggestionHook.ps1`
- `Invoke-PostEditCheck.ps1`
- `HookPayload.psm1`
- `WindowsLongPaths.ps1`
- `AiSdlcSetup.ps1`

`Deny-SharedFileEdit.ps1` stops edits to files installed by APM from AI.SDLC. It also stops an edit through `apply_patch`, the edit tool of a GPT model in GitHub Copilot, when it names an installed file. In AI.SDLC itself it names the source file in the same repository, and says to run `apm install` again.

`Deny-IncompletePush.ps1` refuses a push that leaves tests or documentation behind. A push that names no folder is judged on the repository of the `cwd` field of the hook payload. In a session that works in a git worktree, that is the worktree, even though the hook runs from the main checkout. The hook also reads a folder in quotes after `cd`, `pushd` or `Set-Location`, so a folder with a space works.

The agent never merges, because the owner's merge is the approval (Checkpoint Bravo). A check in the same hooks refuses `gh pr merge` and a `gh api` call to a merge endpoint. Like the other hooks, it lets a command through when it cannot read it.

`Invoke-PostEditCheck.ps1` runs the house-style or build check that fits a file after an edit.

`HookPayload.psm1` reads the hook payload of Claude Code and of GitHub Copilot, including the text of an `apply_patch` edit. It also writes hook context in the shapes of both tools. Copilot reads `additionalContext` at the top level after a prompt or an edit, and Claude Code reads it in `hookSpecificOutput`.

GitHub Copilot ignores the `if` field of a hook and runs every hook entry in turn before each tool call. So each hook script checks the command or file before it loads a slow module. Only `HookPayload.psm1`, which reads the payload, may load first. The push check has one entry per tool. A Copilot session that starts in a subfolder of the repository runs no hook, so start it in the root folder.

`Sync-AllowRules.ps1` writes the commands that each installed package lists under `allow` in its `gates.json` into `.claude/settings.json`. When the knowledge folder exists, it writes its full path into `permissions.additionalDirectories` of `.claude/settings.local.json`, which stays on one machine. `Initialize-AiSdlc.ps1` and `Update-AiSdlc.ps1` run it, and an advisory gate runs it with `-Check`.

`Sync-AgentsFile.ps1`, which `Update-AiSdlc.ps1` runs, moves a root `CLAUDE.md` that only imports `AGENTS.md` to `.claude/CLAUDE.md`. Copilot reads a root `CLAUDE.md` and its import, so it loaded `AGENTS.md` twice.

`New-AiSdlcUpdatePullRequest.ps1` takes the newest AI.SDLC release on the branch `ai-sdlc-<tag>`, with `Update-AiSdlc.ps1 -NoGates`, and opens one pull request. It reads the story key from the tag message and the consumer steps from `CHANGELOG.md` of that tag, in a temporary bare clone of one commit. The description lists the old skill names in the repository's own files and the steps of each release since the pinned one. It stops when the working tree has changes, and does nothing when the branch is already on origin. It closes an open update pull request of an older release. The `update-ai-sdlc` skill and the workflow `ai-sdlc-update.yml` run it. `AiSdlcSetup.ps1` holds the reading of `apm.yml` (`Get-AiSdlcPin`) and the newest tag (`Get-AiSdlcReleaseTag`) that it shares with `Update-AiSdlc.ps1`.

`Find-RetiredSkillNames.ps1` lists the lines in the repository's own files that still use a retired skill name. `Update-AiSdlc.ps1` runs it after an update. It leaves out the ADR folder (`paths.adrFolder`), because an ADR is history. It also leaves out the files that `paths.historyPaths` marks as history, and prints one line with how many places it left out. A pattern that matches no file gives a warning, and the script still never fails.

## Changing it safely

Keep each PowerShell script in step with its matching `*.Tests.ps1` test where that pair exists.

Run `Invoke-LocalGates.ps1` for deterministic gates from installed packages and the repository.

Before you push, run the checks listed in the `## Commands` section of `AGENTS.md`. To see a change the way a consumer sees it, run `tools/Test-Consumers.ps1`, or install into a consumer from a local clone.

Run `test-skills` over a changed skill from a consumer that installs this clone. `README.md`, under Releasing, says when.

Use `add-gate` when a new plain-language rule must become a deterministic gate.

Do not edit an APM-installed shared file through an agent. `Deny-SharedFileEdit.ps1` blocks that edit and names the owning package.

Keep tests and documentation with any behaviour change. The change-completeness gate checks this relationship.

Keep both documentation layers and a page for each unit. The documentation coverage gate checks this structure.

## Dependencies

`implement`, `fix-bug` (github-issues pack), and `refactor` use `walk-substrate` before implementation.

`implement` uses `architect` to write the plan and `builder` to build it test-first. `write-docs` uses `docs-reviewer` after documentation updates. Each hand-off names the model in both spellings: `opus` or `sonnet` for Claude Code, `claude-opus-5.5` or `claude-sonnet-5.5` for Copilot.

`wrap-up` uses tests, both documentation layers, issues, and gates to complete a change. It is the single owner of the docs, the ADR check, the story and pull request contract, the lessons step, the commit and the pre-flight. `implement`, `refactor`, `fix-pr-feedback` and `adopt-docs` call it. `write-prd`, `write-pipeline` of the github pack, and `write-hypothesis`, `draw-customer-journey` and `write-research-summary` of the discovery pack call it for the repository files they write. `write-platform-note` of the knowledge pack writes to the knowledge repository instead, through its own branch and pull request there. `write-adr`, `update-constitution`, `write-docs`, `add-gate`, `capture-learning` and `write-api-spec` of the dotnet pack call it only when a person starts them. When `wrap-up` calls `write-docs`, `write-adr` or `capture-learning` itself, they write the files and do not call it back. None of them runs those steps itself; they push the commit it made. It stops before its first step on `main`, `master` or a branch with no issue number.

`Invoke-CompactSuggestionHook.ps1` names `/handoff`, then `/compact`, when the context window fills up.

`run-preflight` runs deterministic gates, SonarCloud rules, tests, coverage checks, and gitleaks. A gitleaks finding outside the baseline is a FAIL row, so the pre-flight writes no receipt. The tests are `commands.test` of `aisdlc.json`, or the tests of a pack pre-flight that runs them itself, such as the dotnet pack. The pre-flight does not run the self-tests of the shared gate scripts, because AI.SDLC tests them before each release.

The git `pre-push` hook skips the blocking gates when a passing pre-flight receipt covers the tree of the tip commit of each pushed ref. `Test-PushReceipt.ps1` checks that. The pull request build still runs the gates.

`substrate-walker` reads GitHub Issues, the repository and, when it exists, the knowledge folder.

`Install-Apm.ps1` installs a pinned APM release and checks its SHA-256 value.

`Install-Gitleaks.ps1` installs the gitleaks release pinned in `gitleaks-version.json` and checks its SHA-256 value. The composite action `ai-sdlc-gates/assets/actions/ai-sdlc-pr/action.yml` runs it before the gate step. `Test-GitleaksBaseline.ps1` is the blocking C03 gate of `gates.json`, a secret scan against `gitleaks-baseline.json`. So `Invoke-LocalGates.ps1` runs it in the composite action, in the pre-push hook and in a local run. On a pull request in GitHub Actions it scans `PR_BASE_SHA..HEAD`, the commits of the pull request, as the pre-flight does. In a local run it scans `origin/main..HEAD`. A repository without a baseline counts every finding. In GitHub Actions a missing gitleaks, or rules that could not be downloaded, fail the gate. In a local run the gate reports "could not check" (exit 2), so a push still goes out.

`GitleaksConfig.psm1` writes the gitleaks configuration of each scan: the rule set plus an allowlist for `sync-manifest.json`, whose git blob hashes look like keys. The composite action and the pre-flight use it.

`GateAnnotation.psm1` turns gate results into GitHub Actions annotations (`::error` and `::warning`, with the file and the line), at most five per gate.

The composite action is the shared step of a pull request workflow. A consumer runs it after a full-depth checkout. It sets the pull request context from the event, installs the pinned APM, and runs `apm audit --ci` and `apm install --frozen`. Then it installs the pinned gitleaks and runs `Invoke-LocalGates.ps1`, with the C04 coverage ratchet when `coverage-file` is set. The secret scan is one of those gates. A gate is an entry in a `gates.json` or in `repoGates`, never a workflow step, so a local run checks the same rules.

The PowerShell tests use Pester.

## Related

- [How AI.SDLC is built](../overview.md) - where the core sits among the packages.
- [tools](../tools.md) - the scripts that check this repository and set up a consumer.
- [github](github.md) - the pack that opens the pull requests the gates check.
- [dotnet](dotnet.md) - the largest pack, which builds on the core gates.
- [Own skills, agents and hooks](../../core/.apm/skills/ai-sdlc-handbook/references/consumer-own.md) - the handbook page on what a consumer adds itself.
- [Index](../index.md) - every page of this layer.
