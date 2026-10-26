# PR Validation Workflow Patterns

`pr.yml` runs on every pull request to the main branch. It builds and tests, and it runs the shared
AI-SDLC job. The branch ruleset makes its checks required.

## Basic structure

```yaml
name: pr

on:
  pull_request:
    branches: [main]

permissions:
  contents: read

concurrency:
  group: pr-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  build-and-test:
    uses: ./.github/workflows/build-and-test.yml
```

## The shared AI-SDLC job

```yaml
  ai-sdlc:
    name: ai-sdlc
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      issues: read
      pull-requests: read
    steps:
      - uses: actions/checkout@<full commit SHA> # v4
        with:
          fetch-depth: 0
      - uses: ./.claude/skills/ai-sdlc-gates/assets/actions/ai-sdlc-pr
        with:
          private-terms: ${{ secrets.AISDLC_PRIVATE_TERMS }}
```

The composite action ships in the core at the same version as the rest of the AI-SDLC. It installs the
pinned APM and gitleaks, scans the commits of the pull request for secrets, and runs every gate.
`fetch-depth: 0` keeps the history the diff and the gates read. `issues: read` and
`pull-requests: read` let the gates read the story and the pull request with `gh`.

### With the coverage ratchet (.NET)

The test job uploads the merged coverage file as the artifact `coverage`. The `ai-sdlc` job needs the
build and test job, downloads the artifact and passes the file in `coverage-file`:

```yaml
  ai-sdlc:
    needs: build-and-test
    steps:
      - uses: actions/checkout@<full commit SHA> # v4
        with:
          fetch-depth: 0
      - uses: actions/download-artifact@<full commit SHA> # v4
        with:
          name: coverage
          path: coverage
      - uses: ./.claude/skills/ai-sdlc-gates/assets/actions/ai-sdlc-pr
        with:
          coverage-file: coverage/coverage.xml
          pre-gate-command: dotnet restore src/Contoso.Portal.sln
          private-terms: ${{ secrets.AISDLC_PRIVATE_TERMS }}
```

A missing coverage file fails the job, so a broken test job cannot pass the ratchet by accident.

## Parallel backend and frontend jobs

The called `build-and-test.yml` runs them in parallel; see [build-patterns.md](build-patterns.md). Each
shows as its own check: `build-and-test / backend` and `build-and-test / frontend`.

## Required checks

After the first run, name the checks in the ruleset of the default branch:

```powershell
pwsh .claude/skills/github-pull-requests/scripts/Set-BranchRuleset.ps1 -RequiredCheck "build-and-test / backend","build-and-test / frontend",ai-sdlc
```

The ruleset asks for a pull request with zero required approvals; the owner's merge is the approval.
It also blocks a force push and the deletion of the branch.

## Test scripts

When the repository has its own test script, call it in one step (`shell: pwsh`,
`run: ./tests/Invoke-Tests.ps1`), so the pre-flight and the workflow run the same thing.

## No path filter

Do not put `paths:` on the pull request trigger. A required check that does not run leaves the pull
request waiting forever, and a change outside the filter still needs the gates.

## Pull requests from forks

GitHub gives no secrets to a run from a fork. The `ai-sdlc` job then runs without the private terms
list, and a gate that needs it reports that it could not check. Run the pre-flight locally before you
merge such a pull request.

## Per-job runner

Every job sets its own `runs-on:`. Use a larger or self-hosted runner only for the job that needs it,
not for the whole workflow.
