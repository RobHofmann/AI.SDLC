---
units:
  - packs/github
---

# github

The `github` package supports opening, updating, checking, and reviewing pull requests on GitHub, and the GitHub Actions workflows of a repository.

## What it contains

### Skills

- `fix-pr-feedback` resolves pull request feedback from human reviews, bots, `gitleaks`, and SonarCloud.
- It fixes the findings, then `wrap-up` records the lessons before any thread is resolved.
- It waits for the checks of the pull request, then fixes findings and pushes changes.
- It repeats this loop until no bot finding remains open.
- It lives at `packs/github/.apm/skills/fix-pr-feedback/SKILL.md`.
- `github-pull-requests` explains how to open and check pull requests with the GitHub CLI (`gh`).
- It covers `gh auth status`, description handling, read-back checks, and pull request updates.
- It also covers the review threads of a pull request, read and resolved through the GraphQL API.
- It lives at `packs/github/.apm/skills/github-pull-requests/SKILL.md`.
- `write-pipeline` writes the GitHub Actions workflows of a repository in the shared layout.
- It runs only when a person calls it by name, and it loads `github-actions-conventions`.
- The files go on a branch named with the issue number. `wrap-up` commits them and runs the pre-flight; then the skill pushes and opens or updates the pull request.
- It lives at `packs/github/.apm/skills/write-pipeline/SKILL.md`, with its patterns in `references/`.
- `github-actions-conventions` is a knowledge skill: the layout and rules of a workflow. These are the files, the triggers, the read rights and the actions pinned to a full commit SHA. They also cover the pull request workflow with the composite action of the core.
- It applies to every change to workflow YAML, and it lives at `packs/github/.apm/skills/github-actions-conventions/SKILL.md`.

### Configuration and guidance

- `apm.yml` lives at `packs/github/apm.yml`.
- `gates.json` lives at `packs/github/.apm/skills/github-pull-requests/gates.json`.
- `delivery-metrics.md` asks whether the workflow delivers.
- It lives at `packs/github/.apm/skills/github-pull-requests/references/delivery-metrics.md`.

### Scripts

Scripts live under `packs/github/.apm/skills/github-pull-requests/scripts`.

- `Get-PrMetrics.ps1` reports weekly pull request metrics for how quickly changes reach `main`.
- `Get-PullRequestFeedback.ps1` reports whether the checks of a pull request are complete, and which review threads are open. With `-Wait` it polls every 20 seconds. When no check has registered on the new commit yet, it waits 3 minutes before it says `ready`, with a note that no check ran.
- `Initialize-GitHub.ps1` is the GitHub setup step used by `Install-AiSdlc.ps1`. It checks that `gh` is installed and signed in (`gh auth status`), and only advises. The allow rules of the pull request scripts and the `gh` calls are in the `allow` list of `gates.json`, which `Sync-AllowRules.ps1` of the core writes.
- `New-PullRequest.ps1` creates a GitHub pull request with a complete description.
- `PullRequestDescription.psm1` passes a pull request description to `gh` through a file and checks that it arrived intact.
- `PullRequestFeedback.psm1` provides shared helpers for the pull request feedback loop.
- `Set-BranchRuleset.ps1` sets the ruleset on the default branch: a pull request and the required status checks, and no force push or deletion. It asks for no approval, because the owner's merge is the approval. Pass more than one check as separate values to keep a comma in a check name.
- `Reply-PullRequestThread.ps1` replies to a pull request review thread. It resolves the thread only when SonarQube Cloud or gitleaks opened it. A thread from any other bot stays open for a person.
- `Update-PullRequest.ps1` changes only the title or description of an existing pull request.
- `Wait-WorkflowRun.ps1` waits for one or more workflow runs that are not pull request checks. It returns `ready` with each result. It polls every 20 seconds and fits one call in a ten-minute shell limit.

### Tests

Each test lives beside the related script, as `<Name>.Tests.ps1`.

## Dependencies

The pull request workflow uses the GitHub CLI (`gh`), signed in with the owner's own account. GitHub then sees the owner as the author, so the owner cannot approve; the owner's merge is the approval, and the agent never merges.

`github-pull-requests` reads the repository from `github.repository` in `aisdlc.json`, or from the git remote when it is empty.

`fix-pr-feedback` runs after `implement` opens a pull request and review results become available.

`fix-pr-feedback` calls `wrap-up` after it fixes the findings and before it pushes. `wrap-up` runs `capture-learning`, through its pull request entry, on the review while no thread is resolved yet. Then it commits and runs the pre-flight.

Use `wrap-up`, which runs `run-preflight`, for local gates instead of `fix-pr-feedback`.

Use `implement` to author changes instead of `fix-pr-feedback`.

## Related

- [How AI.SDLC is built](../overview.md) - where this pack sits among the packages.
- [core](core.md) - the package every repository installs next to this one.
- [github-issues](github-issues.md) - the tracker pack every repository installs next to this one.
- [Index](../index.md) - every page of this layer.
