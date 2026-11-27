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

Agents live under `core/.apm/agents/`. Each names its model: `opus` for `architect`, `blind-judge`,
`security-reviewer` and `spec-reviewer`, `sonnet` for `builder`, `code-reviewer`, `docs-reviewer`, `substrate-walker` and `test-analyzer`. `Check-AgentHygiene.ps1` allows only
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
- `spec-reviewer` checks whether a change is the right thing. It compares the diff with the approved GitHub issue and the governing ADRs, and reports missing, unasked and wrong behaviour, each with the criterion quoted. It reads criteria under `✅ Success Criteria` and `✅ Acceptance Criteria`. It has no shell, so `implement` reads the issue with `gh` and passes it in. `refactor` does not run it. See [ADR 0016](../adrs/0016-a-spec-review-runs-next-to-the-code-review.md).
- `code-reviewer` reviews a change in any language against `code-conventions` and the convention skill of each changed file type. It looks for code no criterion asks for, swallowed failures and a second copy next to existing code. It also checks code rot, closed sets and comments that break C10.
- `test-analyzer` checks whether the tests of a change prove each acceptance criterion, and flags tests that assert nothing or are surplus. It reads the test rules of each changed file type.
- `security-reviewer` reviews a change in any language for security defects, and reads the `## Security` section of each changed file type's skill. It also voices the Lead in the `grilling` and `convene-personas` panels.
- The three review agents moved here from the dotnet pack, so a repository with only core has them. They use the one severity scale of `code-conventions`: HIGH and MEDIUM. `update-constitution` uses `code-reviewer` in check mode.
- `substrate-walker` gathers issue, architecture, spec, code, caller, reuse, and recent-change context. It reads but never writes. It reads issues with `gh` (read-only use) and greps the knowledge folder next to the repository docs when it exists.

### Skills

Each skill has a `SKILL.md` file under `core/.apm/skills/`.

A workflow skill is a command a person types, or an internal step that other skills call. An internal
step sets `user-invocable: false`, so Claude Code keeps it out of the slash-command list. The internal
steps of the core are `walk-substrate`, `run-preflight` and `grilling`.

Workflow skills include:

- `guide-me` reports the current lifecycle phase and next step. Without an issue, it reads the skill descriptions and names the command that fits a situation.
- `walk-substrate` gathers context before implementation. It is an internal step. For a change to C# or Razor it runs `scripts/Find-NearestExample.ps1`. That script names the test class of each touched type and the test doubles of its dependencies. When it finds nothing, it says "none found" and what it searched, and it always exits 0.
- `implement` runs the development flow from a refined story to a tested pull request. Every change gets a plan, a one-line fix too, and the plan opens with an `Approach:` line. `/implement <n> manual` is the step-by-step mode. It stops for the person after the walk and after the plan. It also stops before the code of each test and before the review fixes. The evidence record names the model of the session and of each agent step.
- `refactor` improves code structure without changing observable behaviour. Like `implement`, it starts only from a refined issue: the `refined` label and a `size:<n>` label.
- `wrap-up` updates tests, documentation, issues, and gates after code works. Then it commits and runs the pre-flight on that commit. It works only on a branch named with an issue number (`42-short-name`).
- `run-preflight` runs local pull-request checks before a push. It is an internal step that `wrap-up` calls.

Documentation and decision skills include:

- `adopt-docs` brings a repository into line with the AI-SDLC wiki rules.
- `write-docs` maintains the technical and functional documentation layers after a change. Started by a person, it ends like `write-prd`: `wrap-up` commits the pages, then the skill pushes and opens or updates the pull request.
- `docs-wiki-conventions` defines rules for documentation layers, links, style, and checks.
- `write-adr` creates MADR-style records in `docs/adrs/`. Started by a person, it ends like `write-prd`.
- `adr-conventions` defines the repository format and rules for architecture decisions.

Code skills include:

- `code-conventions` holds the code rules for every language once. Examples are reuse before you build, build only what the story needs, two scope cases, the comment rule of C10 and no new warning. It also holds one severity scale for every reviewer and the plan: HIGH and MEDIUM, with no LOW. Its page `references/skills-by-file-type.md` is a table that names the convention skill of each file type and its pack. A new language adds one row there. The `builder`, `architect`, `code-reviewer`, `test-analyzer`, `security-reviewer` and `spec-reviewer` agents preload it. See [ADR 0017](../adrs/0017-the-shared-code-rules-and-the-review-agents-live-in-core.md).
- `powershell-conventions` holds the PowerShell rules. Examples are the help block, strict mode, an exit-code check after each native call and a Pester test per script. It has a house style page with an example and a public source for each rule, and a page of points not decided. It follows clause C10, so a comment that says why is fine. `add-gate` links it for the script rules.
- `yaml-conventions` holds the rules for any YAML file. Examples are spaces and never tabs, one key once, quotes on text that looks like a number, and no secrets. A comment says why, as C10 asks. `github-actions-conventions` of the github pack links it for the general YAML rules.
- `Check-SkillHygiene.ps1` fails a model-visible skill description over 450 characters, and a description without trigger words such as `Use when`. A skill only a person starts keeps the 1024 limit ([ADR 0027](../adrs/0027-a-model-visible-skill-description-has-at-most-450-characters.md)).
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
- `grilling` asks the roles that matter in rounds before another skill drafts an artifact. An open decision always gets a round before the draft. Each question lists its choices as bullets and ends with an advice. It checks words against the functional glossary and claims against the code, and ends with a docs impact. It is an internal step.
- `grill-me` runs `grilling` on a person's own plan. With no issue and no branch it writes nothing, and shows the docs impact. Only a person starts it.
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
- skill and agent hygiene, which includes a skill description of at most 450 characters. A skill only a person starts may use 1024, the limit at which GitHub Copilot stops loading a skill
- internal contributor names
- documentation rows
- pull-request hygiene
- section references
- comments that the change adds to C# and Razor (`Check-CommentHygiene.ps1`, clause C10): no commented-out code, no `TODO` without an issue key and no AI tool name. The gate moved from the dotnet pack to core, together with `CodeDiff.psm1`, so every repository runs it
- documentation coverage: both layers and a page per unit
- the installed files against the sync manifest, including a skill folder or an agent file left behind under a retired name. When `apm.yml` installs the core from inside the repository (`- ./core`, as in AI.SDLC), it reads the source manifest there
- every local package that `apm.yml` or `apm.lock.yaml` names is a folder in git (`Check-LocalPackages.ps1`)
- no private term in a public repository: `Check-PrivateTerms.ps1` runs when `visibility` is `public` in `aisdlc.json`, or when GitHub Actions says the repository is public. In a public repository in CI, a missing list fails. A pull request from a fork gets no secrets, so the gate cannot check there (exit 2), and that fails the build too. Run `Check-PrivateTerms.ps1 -Required` on its branch before the merge. It reads the private list from outside the repository. It scans every tracked file, the commit messages, the branch name and the pull request text. It prints only the file, the line and the rule number

The advisory gates warn and never stop a push:

- change completeness. It reads the commits since the base and the edits that are not committed yet. It
  also reads the new files git does not ignore, because `wrap-up` runs it before it commits.
- comments that the change adds to YAML and PowerShell: the same three breaks as the C# entry, from a
  second entry of `Check-CommentHygiene.ps1` with `-Language YamlPowerShell`. It reads PowerShell with the
  parser and YAML outside quoted strings.
- a native call with no exit code check (`Check-NativeExitCode.ps1`, clause C13). It reports an added
  `git`, `az`, `dotnet` or `bicep` call with no `$LASTEXITCODE` check after it.
- PSScriptAnalyzer findings on the added PowerShell lines (`Check-ScriptAnalyzer.ps1`, clause C13). It
  passes its own settings, without `PSAvoidUsingWriteHost`, and exits 2 without PSScriptAnalyzer 1.21.0
  or newer.
- the size of a pull request (`Check-PrSize.ps1`, clause C14). It counts the added and removed lines
  against `pullRequest.sizeLimit`, read at the merge base, and leaves out `pullRequest.sizeExclude`.

The change gates skip the files that `apm.lock.yaml` lists as installed at the base commit, through
`Get-AiSdlcInstalledPath` in `ChangedFiles.psm1`. They read the lock at the base, so a change cannot add its
own files to that list.

A commit can carry a `No-Test` or `No-Docs` trailer with a listed reason and a why. Git reads the trailer, and it clears the finding for the files of that commit only. The check prints each waiver it used, did not use or did not need. Only `wrap-up` writes a trailer, after `test-analyzer` or `docs-reviewer` agrees with the reason.

`Invoke-LocalGates.ps1` runs gates from installed AI-SDLC packages and the repository.

A gate reports through its exit code: 0 pass, 1 finding, 2 could not check, 3 not applicable. Any other
code counts as 1. In the pull request action a Blocking gate that exits 2 fails the job. In a local run
and in the pre-push hook it is a warning (`UNVERIFIED`). A gate that exits 3 shows as `N/A` and never
blocks. A crashed Advisory gate is a warning. `GateContract.Tests.ps1` runs every gate in an empty
repository and checks its code. [ADR 0019](../adrs/0019-a-gate-reports-pass-finding-could-not-check-or-not-applicable.md)
records the contract.

Every gate entry has a name that says what passes, one clause, a `checks` text and a `fix` text. The
runner fails an entry without a text, or with a name used twice, and prints `checks` before the
output of a gate that failed. `references/gate-catalog.md` in the `ai-sdlc-gates` skill lists every
gate; `tools/Build-GateCatalog.ps1` writes it from the `gates.json` files.

A gate has the mode Blocking, Advisory or Off. A repository sets the mode of a shared gate in
`gateModes` of its own `aisdlc.json`, read by `Get-AiSdlcGateModeSetting` in `AiSdlcConfig.psm1`. An
Off gate runs in no hook, pre-flight or run, and shows as `OFF`. The secret scan, the private-terms gate
and the sync manifest check always run Blocking. A push hook counts a gate as Off only when every
pushed commit holds the same gate settings.

A gate may name its `inputs`, a list of path globs. A local run then starts it only when the change
touches one of them, and shows it as `NOT TOUCHED` otherwise; GitHub Actions and `-All` run every gate.
`Invoke-Preflight.ps1` measures a scoped run from the last green pre-flight (`Find-PreflightBase` in
`PreflightReceipt.psm1`) and runs `commands.testChanged` when it is set; `-Full` runs everything.
[ADR 0020](../adrs/0020-a-local-run-checks-what-the-change-touches.md) records the choice.

`Invoke-LocalGates.ps1 -SkipScript <file name>` leaves out the gates of that script and lists them as `SKIP`.
The gates, the pre-flight and `tools/Invoke-PesterParallel.ps1` compare a change with `origin/<github.trunk>`
through `Get-AiSdlcMainBranch` in `AiSdlcConfig.psm1`. It falls back to `origin/main`, `origin/master` or
`origin/HEAD` when that ref is not in the clone. `ChangedFiles.psm1` lists the files a change touched, for
every gate that judges the change.

`Invoke-Gate.ps1` runs one gate script in GitHub Actions or locally and produces a clear result.

`Invoke-PesterGate.ps1` runs Pester tests under the supplied paths.

### Documentation tools

Documentation scripts live under `core/.apm/skills/adopt-docs/scripts/` and `core/.apm/skills/ai-sdlc-gates/scripts/`.

- `Get-FolderFacts.ps1` reads the contents of a unit folder.
- `New-DocCandidate.ps1` collects the facts of each unit with no page into a facts file under `doc-candidates/`. It calls no model; `adopt-docs` hands each facts file to an agent that drafts the page.
- `Repair-DocsWiki.ps1` applies safe machine repairs to existing documentation.
- `Build-DocsIndex.ps1` generates `docs/index.md` and `docs-functional/index.md`. The summary of a page is the first whole sentence of its first paragraph. That holds when the sentence wraps over lines, or when a line starts with a code span.
- `Check-DocCoverage.ps1` checks both documentation layers and unit pages.
- `Check-DocsWiki.ps1` checks for orphans and broken relative links.
- `Check-DocReadingLevel.ps1` checks text against the required reading level.
- `Check-DocEmDashes.ps1` rejects the em-dash character.
- `Check-DocLineCitations.ps1` rejects source references by line number.
- `Check-DocPersonNames.ps1` checks for internal team member names. It looks for each full name as "First Last" and "Last, First", also when a word such as "van der" stands before the last name.
- `Check-DocRowContent.ps1` requires each documentation line to carry a fact.
- `Check-DocLastChecked.ps1` lists the pages whose `Last checked` date is older than `docs.lastCheckedMaxAgeDays`. It is advisory and off by default.
- `Check-DocSectionRefs.ps1` checks references to sections in other pages. It builds a link anchor the way GitHub does, with `-1` and `-2` for a repeated heading.

`DocCoverage.psm1` finds units that need pages and the pages that cover them.

`DocToolTestHarness.psm1` provides the temporary repository fixture used by documentation tool tests. `Invoke-ScriptInProcess` in it runs a script in the test process instead of a child `pwsh`, so the coverage of the Pester run measures that script.

### Hooks and setup

Hook files live under `core/.apm/skills/ai-sdlc-hooks/`.

Git hooks include:

- `commit-msg`
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

`commit-msg` runs `Remove-AiCoAuthorTrailer.ps1`, which removes a `Co-authored-by` trailer that names a
coding tool, so nothing in git names a tool as an author. A trailer that names a person stays.

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

`Deny-IncompletePush.ps1` refuses a push that leaves tests or documentation behind, a push to `main`,
and a push it cannot check. It looks up the receipt for the tree of each pushed ref, and shows a note
when the completeness check could not check. The `ai-sdlc-hooks` skill lists the refused forms. A push that names no folder is judged on the repository of the `cwd` field of the hook payload. In a session that works in a git worktree, that is the worktree, even though the hook runs from the main checkout. The hook also reads a folder in quotes after `cd`, `pushd` or `Set-Location`, so a folder with a space works.

A `cwd` or a repository on a network share (a UNC path) works too, because the hook gives git the plain file path.

The agent never merges, because the owner's merge is the approval (Checkpoint Bravo). A check in the same hooks, `Deny-AgentMerge.ps1`, refuses `gh pr merge` and a `gh api` call to a merge endpoint. It also refuses `gh pr ready` and the `markPullRequestReadyForReview` mutation, because only the person publishes a draft ([ADR 0024](../adrs/0024-the-agent-opens-a-draft-pull-request-and-the-person-publishes-it.md)). Like the other hooks, it lets a command through when it cannot read it.

The language page of the handbook holds three rules. They are CEFR B2 sentences and B1 words, English for what we keep, and the ASD-STE100 writing rules ([ADR 0023](../adrs/0023-a-story-has-six-sections-with-budgets-at-most-5-criteria-and-ste100.md)). Clause C11 points to all three. The `architect` plan has a `Proof:` line that names the test or the check by hand for each acceptance criterion.

`Invoke-PostEditCheck.ps1` runs the house-style or build check that fits a file after an edit. Both edit hooks judge a file in a git worktree under the main checkout on that worktree. They use its root, its packs, its allow lists and its `apm.lock.yaml`. `Get-HookCheckoutRoot` in `HookPayload.psm1` finds that worktree.

`HookPayload.psm1` reads the hook payload of Claude Code and of GitHub Copilot, including the text of an `apply_patch` edit. It also writes hook context in the shapes of both tools. Copilot reads `additionalContext` at the top level after a prompt or an edit, and Claude Code reads it in `hookSpecificOutput`.

GitHub Copilot ignores the `if` field of a hook and runs every hook entry in turn before each tool call. So each hook script checks the command or file before it loads a slow module. Only `HookPayload.psm1`, which reads the payload, may load first. The push check has one entry per tool. Each hook command finds its script through `CLAUDE_PROJECT_DIR`, or the current folder when that is not set, so a `cd` in the session does not break it.

`Invoke-AutolearnHook.ps1` flags a correction and asks for `capture-learning`. When the user only asks the agent to update its advice, it adds a softer note with two lesson questions and no flag. Its phrase lists are tested with their "no" forms too. On the first prompt of a session it counts the open lesson proposals in `temp/autolearn/pending.md`, and never shows their text.

`Sync-AllowRules.ps1` writes the commands that each installed package lists under `allow` in its `gates.json` into `.claude/settings.json`. It also writes the full path of the knowledge folder into `permissions.additionalDirectories` of `.claude/settings.local.json`, which stays on one machine. It does so only for a folder below the parent folder of the repository that no link leads to. Any other knowledge folder is skipped with a FIX line. `Initialize-AiSdlc.ps1` and `Update-AiSdlc.ps1` run it, and an advisory gate runs it with `-Check`.

`Sync-AgentsFile.ps1`, which `Update-AiSdlc.ps1` runs, moves a root `CLAUDE.md` that only imports `AGENTS.md` to `.claude/CLAUDE.md`. Copilot reads a root `CLAUDE.md` and its import, so it loaded `AGENTS.md` twice.

`New-AiSdlcUpdatePullRequest.ps1` takes the newest AI.SDLC release on the branch `ai-sdlc-<tag>`, with `Update-AiSdlc.ps1 -NoGates`, and opens one pull request. It reads the story key from the tag message and the consumer steps from `CHANGELOG.md` of that tag, in a temporary bare clone of one commit. The description lists the old skill names in the repository's own files and the steps of each release since the pinned one. It stops when the working tree has changes, and does nothing when the branch is already on origin. It closes an open update pull request of an older release. The `update-ai-sdlc` skill and the workflow `ai-sdlc-update.yml` run it. `AiSdlcSetup.ps1` holds the reading of `apm.yml` (`Get-AiSdlcPin`) and the newest tag (`Get-AiSdlcReleaseTag`) that it shares with `Update-AiSdlc.ps1`.

`AiSdlcSetup.ps1` also runs every `apm install` of the shared scripts without `AISDLC_SONAR_MCP_TOKEN`, `AISDLC_SONAR_ORG` and `SONAR_TOKEN` (`Invoke-WithoutSonarToken`). APM writes the value of such a variable into `.mcp.json`, and the update pull request must keep the placeholders.

`Update-AiSdlc.ps1` also stages `.mcp.json`, so a new shared MCP server reaches the update pull request. It does so when git tracks the file, or when it exists and git does not ignore it. With the sonarcloud pack it runs `Check-McpToken.ps1` first, and a written-out token stops the update. Then it rebuilds the index of each doc layer with the new `Build-DocsIndex.ps1` and stages it, so the index gate passes on the update.

`Find-RetiredSkillNames.ps1` lists the lines in the repository's own files that still use a retired skill name. `Update-AiSdlc.ps1` runs it after an update. It leaves out the ADR folder (`paths.adrFolder`), because an ADR is history. It also leaves out the files that `paths.historyPaths` marks as history, and prints one line with how many places it left out. A pattern that matches no file gives a warning, and the script still never fails.

## Changing it safely

Keep each PowerShell script in step with its matching `*.Tests.ps1` test where that pair exists. The test of a script under `core/.apm/skills/<skill>/scripts` sits under `core/tests/skills/<skill>/scripts`, so APM does not install it ([ADR 0015](../adrs/0015-the-tests-of-a-shared-package-live-outside-the-installed-package.md)).

Run `Invoke-LocalGates.ps1` for deterministic gates from installed packages and the repository.

Before you push, run the checks listed in the `## Commands` section of `AGENTS.md`. To see a change the way a consumer sees it, run `tools/Test-Consumers.ps1`, or install into a consumer from a local clone.

Run `test-skills` over a changed skill from a consumer that installs this clone. `README.md`, under Releasing, says when.

Use `add-gate` when a new plain-language rule must become a deterministic gate.

Do not edit an APM-installed shared file through an agent. `Deny-SharedFileEdit.ps1` blocks that edit and names the owning package.

Keep tests and documentation with any behaviour change. The change-completeness gate checks this relationship.

Keep both documentation layers and a page for each unit. The documentation coverage gate checks this structure.

## Dependencies

`implement`, `fix-bug` (github-issues pack), and `refactor` use `walk-substrate` before implementation.

`implement` uses `architect` to write the plan and `builder` to build it test-first. The plan names the test class each touched type's tests go in (`Tests go in:`), and the builder reports what it reused (`Reused:`). The order is reuse, then extend, then new code, as `code-conventions` says. Two things stop the loop. One is a plan that adds product code only for a test seam. The other is a change where no acceptance criterion maps to a test or a check. `write-docs` uses `docs-reviewer` after documentation updates. Each hand-off names the model in both spellings: `opus` or `sonnet` for Claude Code, `claude-opus-5.5` or `claude-sonnet-5.5` for Copilot.

`wrap-up` uses tests, both documentation layers, issues, and gates to complete a change. It is the single owner of the docs, the ADR check, the story and pull request contract, the lessons step, the commit and the pre-flight. `implement`, `refactor`, `fix-pr-feedback` and `adopt-docs` call it. `write-prd`, `write-pipeline` of the github pack, and `write-hypothesis`, `draw-customer-journey` and `write-research-summary` of the discovery pack call it for the repository files they write. `write-platform-note` of the knowledge pack writes to the knowledge repository instead, through its own branch and pull request there. `write-adr`, `update-constitution`, `write-docs`, `add-gate`, `capture-learning` and `write-api-spec` of the dotnet pack call it only when a person starts them. When `wrap-up` calls `write-docs`, `write-adr` or `capture-learning` itself, they write the files and do not call it back. None of them runs those steps itself; they push the commit it made. It stops before its first step on `main`, `master` or a branch with no issue number.

`Invoke-CompactSuggestionHook.ps1` names `/handoff`, then `/compact`, when the context window fills up.

`run-preflight` runs deterministic gates, SonarCloud rules, tests, coverage checks, and gitleaks. A gitleaks finding outside the baseline is a FAIL row, so the pre-flight writes no receipt. The tests are `commands.test` of `aisdlc.json`, or the tests of a pack pre-flight that runs them itself, such as the dotnet pack. The pre-flight does not run the self-tests of the shared gate scripts, because AI.SDLC tests them before each release.

The git `pre-push` hook skips the blocking gates when a passing pre-flight receipt covers the tree of the tip commit of each pushed ref. `Test-PushReceipt.ps1` checks that. The pull request build still runs the gates.

`substrate-walker` reads GitHub Issues, the repository and, when it exists, the knowledge folder.

`Install-Apm.ps1` installs a pinned APM release and checks its SHA-256 value.

`Install-Gitleaks.ps1` installs the gitleaks release pinned in `gitleaks-version.json` and checks its SHA-256 value. The composite action `ai-sdlc-gates/assets/actions/ai-sdlc-pr/action.yml` runs it before the gate step. `Test-GitleaksBaseline.ps1` is the blocking C03 gate of `gates.json`, a secret scan against `gitleaks-baseline.json`. So `Invoke-LocalGates.ps1` runs it in the composite action, in the pre-push hook and in a local run. On a pull request in GitHub Actions it scans `PR_BASE_SHA..HEAD`, the commits of the pull request, as the pre-flight does. In a local run it scans `<main branch>..HEAD`, where `Get-AiSdlcMainBranch` gives `origin/<github.trunk>` or a fallback. A repository without a baseline counts every finding. In GitHub Actions a missing gitleaks, or rules that could not be downloaded, fail the gate. In a local run the gate reports "could not check" (exit 2), so a push still goes out.

`GitleaksConfig.psm1` writes the gitleaks configuration of each scan: the rule set plus an allowlist for `sync-manifest.json`, whose git blob hashes look like keys. A repository can add its own paths in `secretScan.allowPaths` of `aisdlc.json`, as a second allowlist. The composite action, the pre-flight and `Create-GitleaksBaseline.ps1` use it.

`GateAnnotation.psm1` turns gate results into GitHub Actions annotations (`::error` and `::warning`, with the file and the line), at most five per gate.

The composite action is the shared step of a pull request workflow. A consumer runs it after a full-depth checkout. It sets the pull request context from the event, installs the pinned APM, and runs `apm audit --ci` and `apm install --frozen`. Then it installs the pinned gitleaks and runs `Invoke-LocalGates.ps1`, with the C04 coverage ratchet when `coverage-file` is set. The secret scan is one of those gates. A gate is an entry in a `gates.json` or in `repoGates`, never a workflow step, so a local run checks the same rules.

The PowerShell tests use Pester.

## Related

- [How AI.SDLC is built](../overview.md) - where the core sits among the packages.
- [tools](../tools.md) - the scripts that check this repository and set up a consumer.
- [github](github.md) - the pack that opens the pull requests the gates check.
- [dotnet](dotnet.md) - the largest pack, which builds on the core gates.
- [ADR 0017](../adrs/0017-the-shared-code-rules-and-the-review-agents-live-in-core.md) - why the shared code rules and the review agents live in core.
- [Own skills, agents and hooks](../../core/.apm/skills/ai-sdlc-handbook/references/consumer-own.md) - the handbook page on what a consumer adds itself.
- [Index](../index.md) - every page of this layer.
