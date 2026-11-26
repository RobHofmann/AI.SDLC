# Changelog

Every release of AI.SDLC gets one entry here, newest first. One tag covers the whole repository, so
one entry covers every package in it. The release steps are in the README.

A pull request writes its entry under the version it releases, never under `Unreleased`. So the
merge is ready to tag, and no second pull request is needed to name the version.

Each entry names its issue, as `#42`.

## v1.6.0 - 2026-11-26

- The packages no longer ship the Pester tests of their scripts, so an update pull request holds only
  files a consumer runs ([ADR 0015](docs/adrs/0015-the-tests-of-a-shared-package-live-outside-the-installed-package.md), #45).
  The 104 test files and `DocToolTestHarness.psm1` moved from `<package>/.apm/` to `<package>/tests/`,
  at the same path. APM installs only `.apm/`. Each test finds its script under `.apm/` through one
  path swap, and still works when it sits next to an installed script.
- `tools/Update-SyncManifest.ps1` stops on a `*.Tests.ps1` or `*TestHarness.psm1` file under `.apm/`,
  and names the path under `tests/`. The sync manifest lists the names of the kept tests as
  `sharedTests`. `Check-DocDrift.ps1` of the dotnet pack reads that list, so a page that names such a
  test does not count it as a stale file.
- `tools/Invoke-PesterParallel.ps1 -Changed` finds the test of a package script under `tests/`, and
  `tools/PesterCoverage.psm1` measures the scripts under `.apm/` for each moved test.
- `tools/Test-Consumers.ps1` fails when an install puts a test file under `.claude/`. It then copies
  the tests next to the installed scripts of each test consumer and runs them, as before.
- The update pull request says that `.claude/` is a generated copy, reviewed and tested in AI.SDLC.
- The new core skill `code-conventions` holds the code rules for every language once: reuse before you
  build, build only what the story needs, two scope cases, the comment rule of C10 and no new warning.
  It also holds one severity scale, HIGH and MEDIUM, with no LOW. Its page `skills-by-file-type.md`
  names the convention skill of each file type. `csharp-generation-smells` keeps only the C# and Razor
  rules, and links to it. The `builder` and `architect` agents preload it (#55).
- `code-reviewer`, `test-analyzer` and `security-reviewer` move from the dotnet pack to core, and
  review every language. Each preloads `code-conventions` and reads the rules of each changed file type
  from its table. The C# checks move into `csharp-generation-smells`, with a new security page, and the
  Razor checks into `blazor-conventions`. The dotnet pack ships no agent. The names do not change, so a
  consumer with the dotnet pack gets each agent once, now from core. ADR 0017 records the move (#56).
- `walk-substrate` runs the new `Find-NearestExample.ps1` for a C# or Razor change. It names the test
  class of each touched type and the test doubles of its dependencies, or says "none found". The
  builder reuses, then extends, then writes new code, and reports a `Reused:` line. The plan names
  where the tests of each type go. A plan that adds product code only for a test seam, and a change
  where no criterion maps to a test, are on the stop list (#58).
- The new core agent `spec-reviewer` checks the change against the approved GitHub issue, next to the
  code review. `implement` reads the issue with `gh` and passes it in. The evidence record keeps the two
  reports apart, and `refactor` does not run it. ADR 0016 records the decision (#57).
- `/implement <n> manual` is a step-by-step mode that stops for the person at four points. The light
  path is gone: every change gets a plan, which opens with an `Approach:` line. The evidence record
  names the model of each step (#59).
- An issue body holds conclusions only. Test results, probes and measurements go in one evidence
  comment per run, which starts with `Evidence YYYY-MM-DD HH:mm`. `write-story` shows it at Checkpoint
  Alpha and posts it after the go. `draft-reviewer` fails an evidence comment that holds a requirement
  or a decision. The walk carries it into the context block as context, not as scope. Update mode
  rewrites a section the agent wrote, and only adds to a person's text. The triage comment of
  `fix-bug` keeps its form and holds the investigation (#62).
- A new issue has six sections, goal first, with a budget per section and at most 5 plain criteria
  under `✅ Acceptance Criteria`. An issue in the old form, with `✅ Success Criteria` and an ELI5,
  keeps a limit of 8 criteria and is still read and built as before. `draft-reviewer` fails a section
  over its budget and an issue over the limit. The `architect` plan has a `Proof:` line per criterion.
  `language.md` adds the ASD-STE100 writing rules as a third rule, and clause C11 points to them; the
  constitution is now version 1.1. ADR 0023 records it (#63).
- `grilling` gives every open decision a round before the draft, and the authoring skills ask no
  questions of their own. A question starts with `❓`, lists its choices as bullets and ends with
  `➡️ **Advice:**`. It checks words against the functional glossary and claims against the code, and
  ends with a docs impact. `write-story` posts that as one `📚 Docs impact YYYY-MM-DD HH:mm` comment,
  and `write-docs` applies it as docs scope. The word checks adapt the domain-modeling skill of
  mattpocock/skills (MIT), named in `THIRD-PARTY-NOTICES.md` (#64).
- The agent opens every pull request as a draft, and only the person publishes it. `New-PullRequest.ps1`
  passes `--draft` and puts a `## Before you publish` block at the top of the description.
  `Update-PullRequest.ps1` keeps that block while the pull request is a draft. `Deny-AgentMerge.ps1`
  also refuses `gh pr ready` and the `markPullRequestReadyForReview` mutation. Clause C09 and the
  Checkpoint Bravo text say so, and ADR 0024 records it. A person now clicks Ready for review before the
  merge (#67).
- The new `move-story` skill (github-issues pack) adds the in-review label to the open stories of a pull
  request. It does that only when the person says the draft is published and GitHub shows it is no longer
  a draft. It never moves a closed issue, and a failed move is a warning that the run summary names. The
  label is `tracker.inReviewLabel` in `aisdlc.json`, `in-review` by default, and the skill creates it when
  it is missing. Clause C09 and `orchestration.md` name it as the one status move the agent makes; the
  merge still closes the issue through `Fixes #n`. ADR 0022 records the choice (#69).
- `github-issue-conventions` and `github-pull-requests` move part of their text to a reference page,
  so each stays within 120 lines (#63, #68).
- The new `Request-CopilotReview.ps1` asks Copilot for a review with `gh pr edit --add-reviewer @copilot`.
  `New-PullRequest.ps1` asks for the first review right after the create, unless `-SkipCopilotReview` is
  passed. `fix-pr-feedback` asks again only after its own push, and only when 20 or more lines changed
  since the commit Copilot last reviewed; binary files do not count. A failed request is a warning. The
  script reads the request back, because gh exits 0 even when GitHub drops it, for example when Copilot
  code review is off for the repository (#68).

- The Bicep pre-flight builds the templates of a repository that sits in a git worktree under
  `.claude/worktrees/`. It left out every file whose full path held `.claude`, so it found no template
  and passed. The new `Test-AiSdlcPathExcluded` in `AiSdlcConfig.psm1` judges only the folders inside
  the repository (#88).
- The git hooks find Git LFS the way git does, with `git lfs version`, so a Git LFS in the program
  folder of git counts. The message now says git could not run `git lfs` (#91).
- The update pull request reads the steps for a consumer only under the line
  `What a consumer does when it takes this release:`, and reads `*` items as well as `- ` items.
  `tools/Check-ChangelogConsumerSteps.Tests.ps1` keeps this CHANGELOG in that form (#92).
- The docs index keeps the first sentence of a page whole when it wraps, or when a line starts with a
  code span. `Check-DocSectionRefs.ps1` builds a link anchor the way GitHub does, with `-1` and `-2`
  for a repeated heading. `Check-DocPersonNames.ps1` also finds "Last, First" and a name with a word
  such as "van der". `Check-AgentHygiene.ps1` fails an MCP tool of a connector whose name differs per
  person (#89).
- The edit hooks judge a file in a git worktree under the main checkout on that worktree. They use
  its root, its packs, its allow lists and its `apm.lock.yaml`. The scripts that run stay the hook's
  own (#50).
- Every agent hook command finds its script through `CLAUDE_PROJECT_DIR`, so a `cd` in the session no
  longer turns the hooks off. APM replaces the old commands in `.claude/settings.json` (#51).
- A new git `commit-msg` hook removes a `Co-authored-by` trailer that names a coding tool. A trailer
  that names a person stays, and a commit never fails on it (#53).
- The autolearn hook adds a softer note when the user asks the agent to update its advice. An open
  lesson proposal waits in `temp/autolearn/pending.md`, and the hook names the count on the first
  prompt of a session (#54).
- `Set-SonarMcpToken.ps1` of the sonarcloud pack sets the SonarCloud MCP token once, with hidden input
  and a check against SonarCloud, on Windows, macOS and Linux. The setup and each session say when it
  is missing. Every `apm install` of the shared scripts runs without the token variables, so
  `.mcp.json` keeps its placeholders. ADR 0018 records where the token lives (#84).
- `Update-AiSdlc.ps1` stages `.mcp.json` after the token check passes, and rebuilds and stages the
  index of each doc layer (#85).
- The `sonarqube` MCP server offers only the seven tool groups the skills use, through the header
  `SONARQUBE_TOOLSETS` (#86).

What a consumer does when it takes this release:

- Expect a larger update pull request once: it deletes the old test files under `.claude/`. No file
  or setting of your own needs a change for that.
- When one of your own tests checks that a script under `.claude/` has a `.Tests.ps1` file next to it,
  check that only for your own scripts outside `.claude/`. The scripts under `.claude/` no longer come
  with their tests.
- With the sonarcloud pack, each person runs
  `pwsh .claude/skills/sonarcloud-mcp/scripts/Set-SonarMcpToken.ps1` once in their own terminal, then
  restarts the terminal and the tool. On macOS and Linux, add the line it prints to the shell profile.
- Take this release with `New-AiSdlcUpdatePullRequest.ps1` or the update workflow, without
  `AISDLC_SONAR_MCP_TOKEN` set in that shell. An older `Update-AiSdlc.ps1` still writes a set token
  into `.mcp.json`; run `Check-McpToken.ps1 -Fix` before you commit when that happens.
- A repository with its own `sonarqube` entry in `.mcp.json` adds the header `SONARQUBE_TOOLSETS` by
  hand. Each person restarts their tool after the update pull request is merged.
- The update to this release still runs the old `Update-AiSdlc.ps1`, which does not rebuild the docs
  index. On the update branch, run `pwsh .claude/skills/ai-sdlc-gates/scripts/Build-DocsIndex.ps1`
  and commit the index. Then fix any link that `Check-DocSectionRefs.ps1` or any name that
  `Check-DocPersonNames.ps1` now reports.
- After `apm install`, `.claude/settings.json` has the new `Bash|PowerShell` hook block next to the
  old one, so the push check runs twice. Remove the old block, the one without the `*gh* *eady*`
  entries, in the update pull request (#67).
- The agent now opens every pull request as a draft. Click Ready for review before you merge it (#67).


## v1.5.1 - 2026-11-26

- A pull request in AI.SDLC now says `Fixes #42`, so the merge closes its issue. Before, it said
  `Refs #42` and a person closed the issue by hand after the tag. `AGENTS.md` and the Releasing part of
  `README.md` say so. An update pull request in a consumer still says `Refs RobHofmann/AI.SDLC#42` (#9).

## v1.5.0 - 2026-11-26

- `Check-PrivateTerms.ps1` and `Test-GitleaksBaseline.ps1` stop as "not checked" when `-RepoRoot` is
  not an existing folder. They exit 2 in a local run, and 1 in GitHub Actions or, for the private-terms
  gate, with `-Required`. Before, `git -C ''` read the current folder, so a gate could pass on another
  repository (#32).
- `Sync-AllowRules.ps1` only adds a knowledge folder below the parent folder of the repository, or of
  the main checkout in a linked worktree, and reached without a link. It skips the parent folder
  itself, a folder anywhere else such as a network share, and a repository at a drive or share root.
  It prints a FIX line and keeps exit 0, so the setup and the update do not fail. A repository that
  keeps its knowledge folder elsewhere adds it by hand to `.claude/settings.local.json` (#32).
- The new `Get-AiSdlcMainCheckoutRoot` in `AiSdlcConfig.psm1` finds the main checkout of a linked
  worktree. `Get-AiSdlcKnowledgeRoot` and `Sync-AllowRules.ps1` both use it (#32).

## v1.4.5 - 2026-11-26

- A relative `paths.knowledgeRoot` is found from a linked git worktree too. In a worktree under
  `.claude/worktrees/<name>`, `../Knowledge` pointed inside the main clone, so the private-terms gate
  found no list and blocked the pre-flight. The new `Get-AiSdlcKnowledgeRoot` in `AiSdlcConfig.psm1`
  falls back to the folder next to the main checkout, found through `git rev-parse --git-common-dir`.
  A folder next to the worktree still wins. `Check-PrivateTerms.ps1`, `Sync-AllowRules.ps1` and the
  knowledge folder hint of the setup use it (#31).

## v1.4.4 - 2026-11-26

- On a network share, the repository path is a UNC path, and PowerShell wrote it with a `FileSystem::`
  prefix that git cannot read. So the agent push hook and the gates now give git the plain path, and
  the hook reads `git.allowTrunkPush`. `Check-PrivateTerms.ps1` no longer fails to read the tracked
  files when its root has that prefix. The same holds for `Test-GitleaksBaseline.ps1`,
  `Sync-AllowRules.ps1`, `AiSdlcConfig.psm1` and `Add-AiSdlcConsumer.ps1` (#29).

## v1.4.3 - 2026-11-12

- In a local run, `Test-GitleaksBaseline.ps1` scans `<trunk>..HEAD`, where the trunk is the first of
  `origin/main`, `origin/master` and `origin/HEAD` that exists. A repository whose trunk is `master` had
  no `origin/main`, so the C03 gate scanned the whole history. On a network share, where every blob is
  read over the network, that made the pre-push hook run for a very long time. v1.4.2 made it visible:
  before, git refused the checkout and the scan read nothing (#20).

## v1.4.2 - 2026-11-12

- On a network share, the pre-push hook runs the gates in a local checkout whose git data stays on the
  share. Git refused that checkout as "dubious ownership", so the C03 secret scan read 0 commits and
  still passed. The hook now trusts the checkout folder through `GIT_CONFIG_COUNT` (`safe.directory`),
  only for the gates; the git config of the machine is not changed (#20).
- `Test-GitleaksBaseline.ps1` checks that git can read the folder before it scans. When it cannot, the
  gate exits 2 locally and 1 in GitHub Actions, so a blind scan never passes (#20).
- On a share, `Update-AiSdlc.ps1` runs `apm audit --ci` in the local worktree of the install, where
  `apm_modules` exists. On the share itself the audit failed after a good install. A failed audit now
  leaves the share as it was (#20).

## v1.4.1 - 2026-11-11

- On a network share, `Install-AiSdlc.ps1` and `Update-AiSdlc.ps1` run `apm install` in a local git
  worktree and copy the result back. On a share, APM 0.31.0 reported a good install but left the changed
  skill folders empty, and its lock listed those folders, so a second run skipped them. The new helper
  `Invoke-ApmInstall` in `AiSdlcSetup.ps1` copies each file of the new lock that differs from the share,
  and removes each file that only the old lock listed. `AISDLC_APM_LOCAL_INSTALL=1` forces it, `=0`
  turns it off. The share check is the one the pre-push hook uses (#20).

## v1.4.0 - 2026-11-10

- A repository can set `docs.lastCheckedMaxAgeDays` in `aisdlc.json` to a number of days (#24). Then a
  new advisory gate, `Check-DocLastChecked.ps1`, lists every `Last checked: <date>` in `AGENTS.md` and
  the doc layers that is older than that. The pre-push hook shows the same list as a warning, and never
  fails the push on it. The setting is off by default, and a page without such a date is left alone.

## v1.3.3 - 2026-11-09

- A `Test-GitleaksBaseline` test no longer fails when a test file that runs in parallel deletes its own
  temp file while the test reads the shared temp folder (#22).

## v1.3.2 - 2026-11-09

- On a network share, the pre-push git hook runs the blocking gates on a local checkout of the pushed
  commit: a detached git worktree in a temp folder, which it removes after the run (#20). A push of
  about 930 files went from 1,425 seconds in the gates to 15. The gates now check the pushed commit
  there, not the working tree. It is used only when one commit is pushed.
  `AISDLC_GATES_LOCAL_CHECKOUT=1` forces it, and `=0` turns it off.

## v1.3.1 - 2026-11-09

- The pre-push git hook now reads `git.allowTrunkPush` when `core.hooksPath` is relative, which is how
  `Initialize-AiSdlc.ps1` sets it (#18). Before, the hook could not load the config module, so it refused
  every push to `main`. A new test runs a real `git push` through that setup.
- On `main` or `master` in a repository that sets `git.allowTrunkPush`, the pre-flight issue-contract row
  is SKIP, not FAIL, because a change there has no story or pull request (#18).

## v1.3.0 - 2026-11-09

- A repository can set `git.allowTrunkPush` to `true` in `aisdlc.json` to update `main` or `master`
  with a plain push, without a pull request (#16). The pre-push git hook and `Deny-IncompletePush.ps1`
  still refuse a delete and a force push of `main`, and the blocking gates still run. The git hook
  prints one line that names the setting when it lets a push through. The agent hook now checks every
  push in a command, and with the setting it refuses `--no-verify`, a git option before `push`, and a
  push to `main` that is chained with other commands. Both hooks read the setting from `aisdlc.json` on
  the remote `main` branch, not from the working tree, so an edit that is not on `main` cannot switch
  it on. The git hook reads it from the remote tip that git passes during the push, so a local ref
  cannot switch it on either.

## v1.2.0 - 2026-11-07

- A reply, work item or page gives the full link to every pull request, issue or page that the reader
  must open or act on (#14). The rule is in `language.md` and in the `## Communication` part of
  `AGENTS.md`.
- A repository can name the paths that hold secrets on purpose in `secretScan.allowPaths` of
  `aisdlc.json` (#12). The secret scan skips them in the pre-flight, in the C03 gate and in a new
  baseline, through a second allowlist that `GitleaksConfig.psm1` writes. `Create-GitleaksBaseline.ps1`
  now also uses the allowlist of the AI-SDLC, so a new baseline holds no sync manifest hashes.

## v1.1.0 - 2026-11-07

- A consumer can install packs from a source of its own next to AI.SDLC (#10). `Check-SyncManifest.ps1`
  only checks the packages from the source of the core: the same `git:` URL, or the same prefix in the
  short or local form. A pack from another source no longer fails the gate, and its skills count as
  the repository's own. The gate now also reads the short form with a ref, such as
  `contoso/AI.SDLC/packs/bicep#v1.1.0`.

## v1.0.0 - 2026-10-24

The first release. It has no issue, because the issue tracker of this repository starts with it.

This release holds the whole AI-SDLC for repositories on GitHub:

- `core`: the workflow skills (`guide-me`, `implement`, `refactor`, `wrap-up`, `write-docs`,
  `adopt-docs`, `write-adr`, `capture-learning`, `handoff` and the others), the agents, the hooks, the
  core gates and the handbook. The gates give the same answer in the pre-push hook, the local
  pre-flight and CI.
- The shared CI step: the composite action `ai-sdlc-gates/assets/actions/ai-sdlc-pr`, which a pull
  request workflow runs after a full-depth checkout. It checks the installed files with APM, scans
  for secrets with gitleaks and runs every gate.
- The private term gate `Check-PrivateTerms.ps1`. The private list is kept outside the repository. In a public repository no file, commit message,
  branch name or pull request text may hold a term of that list. It
  never prints what it found.
- The private term gate fails closed in a public consumer (#2). In GitHub Actions it reads the event
  of the run: a repository that GitHub says is public is checked whatever `visibility` says, and a
  missing list fails, except on a pull request from a fork. `Add-AiSdlcConsumer.ps1` reads the
  visibility with `gh` and takes `-Visibility`.
- `github`: pull requests through the GitHub CLI, review threads, the feedback loop, the GitHub Actions
  conventions and the ruleset on the main branch. The ruleset also blocks a force push and the
  deletion of the branch, and a check name with a comma stays whole when the checks come as separate
  values (#7).
- `github-issues`: stories, bugs and epics as GitHub issues with the key `#42`, the PR-story contract
  gate and the issue pre-flight. The gate accepts a key of another repository only when
  `tracker.acceptedRepositories` lists it, such as the release issue of AI.SDLC in an update pull request.
  The gate accepts a closed issue with the `refined` label too.
- `discovery`: research summaries, journey maps and hypothesis canvases as pages in the repository.
- `knowledge`: notes on how a platform behaves, written to a private knowledge repository.
- `dotnet`, `blazor`, `bicep` and `sonarcloud`: the conventions, gates and tools of each stack.
- Clause C12, one source of truth: the core part of `AGENTS.md` imports `constitution.md` with an `@`
  line, so Claude Code loads every clause in each session and no copy of the list exists.
- Updates are pulled: each consumer runs `New-AiSdlcUpdatePullRequest.ps1`, through the
  `update-ai-sdlc` skill or its scheduled `ai-sdlc-update.yml` workflow. It opens one pull request per
  release, which names the release issue with `Refs`. AI.SDLC keeps no list of consumers.
  The README says so too (#4).
- `tools/`: the setup script for a new consumer, with a starter pull request workflow and the update
  workflow. Then the test consumers and the parallel Pester runner.

What a consumer does when it takes this release:

- Run `tools/Add-AiSdlcConsumer.ps1` from a clone of AI.SDLC, or add `apm.yml` by hand as the README
  says. Then switch on Issues, run `Set-BranchRuleset.ps1` once, and set up the GitHub App of the
  update workflow.
