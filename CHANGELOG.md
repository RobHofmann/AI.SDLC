# Changelog

Every release of AI.SDLC gets one entry here, newest first. One tag covers the whole repository, so
one entry covers every package in it. The release steps are in the README.

A pull request writes its entry under the version it releases, never under `Unreleased`. So the
merge is ready to tag, and no second pull request is needed to name the version.

Each entry names its issue, as `#42`.

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
- `github`: pull requests through the GitHub CLI, review threads, the feedback loop, the GitHub Actions
  conventions and the ruleset on the main branch.
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
- `tools/`: the setup script for a new consumer, with a starter pull request workflow and the update
  workflow. Then the test consumers and the parallel Pester runner.

What a consumer does when it takes this release: run `tools/Add-AiSdlcConsumer.ps1` from a clone of
AI.SDLC, or add `apm.yml` by hand as the README says. Then switch on Issues, run
`Set-BranchRuleset.ps1` once, and set up the GitHub App of the update workflow.
