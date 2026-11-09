# Changelog

Every release of AI.SDLC gets one entry here, newest first. One tag covers the whole repository, so
one entry covers every package in it. The release steps are in the README.

A pull request writes its entry under the version it releases, never under `Unreleased`. So the
merge is ready to tag, and no second pull request is needed to name the version.

Each entry names its issue, as `#42`.

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

What a consumer does when it takes this release: run `tools/Add-AiSdlcConsumer.ps1` from a clone of
AI.SDLC, or add `apm.yml` by hand as the README says. Then switch on Issues, run
`Set-BranchRuleset.ps1` once, and set up the GitHub App of the update workflow.
