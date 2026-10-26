---
story: "#1"
phase: governance
step: write-adr
intent:
  assumption: "a composite action that ships inside the installed core can be called by a local path after checkout, so the installed copy is the version and needs no second pin"
  decision-drivers:
    - "every consumer must run the same checks in CI, the same way as the pre-push hook and the pre-flight"
    - "a second version pin for the CI step drifts from the pin of the packages"
    - "the PR title, body and branch are in the workflow event, so no API call is needed to read them"
relates:
  action: core/.apm/skills/ai-sdlc-gates/assets/actions/ai-sdlc-pr/action.yml
  runner: core/.apm/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1
  apm: core/.apm/skills/ai-sdlc-gates/scripts/Install-Apm.ps1
  gitleaks: core/.apm/skills/ai-sdlc-gates/scripts/Test-GitleaksBaseline.ps1
  annotation: core/.apm/skills/ai-sdlc-gates/scripts/GateAnnotation.psm1
because:
  action: "the composite action every consumer calls"
  runner: "the gate runner the action calls, the same one the push hook calls"
  apm: "the pinned APM install the action runs first"
  gitleaks: "the secret scan over the pull request commits"
  annotation: "the writer of the GitHub workflow commands"
---

# ADR 0012: CI is a composite action inside the installed core

**Status:** Accepted
**Date:** 2026-10-24
**Supersedes:** none
**Superseded by:** none

## Context

Every consumer needs the same pull request checks: the APM integrity checks, the secret scan and the
gates. The pre-push hook and the pre-flight already run the gates through `Invoke-LocalGates.ps1`. A
CI check that runs something else hides a failure until merge.

GitHub Actions has three ways to share steps. They are a reusable workflow in another repository, an action in
another repository, and a composite action at a local path. A reusable workflow or a remote action
needs its own version reference, next to the pin of the packages in `apm.yml`. Two pins drift.

The installed core is committed in each consumer ([ADR 0001](0001-ai-sdlc-is-shared-as-apm-packages.md)).
So after `actions/checkout`, the action is already on disk at the version the consumer pinned.

## Decision

**1. The shared pull request step is a composite action in the core.** It lives at
`core/.apm/skills/ai-sdlc-gates/assets/actions/ai-sdlc-pr/action.yml`. A consumer calls it after
`actions/checkout` with `fetch-depth: 0`:

```yaml
- uses: ./.claude/skills/ai-sdlc-gates/assets/actions/ai-sdlc-pr
  with:
    private-terms: ${{ secrets.AISDLC_PRIVATE_TERMS }}
```

The installed copy is the version, so there is no second pin.

**2. Its inputs.** `coverage-file` (optional), `pre-gate-command` (an optional `pwsh` command run before
the gates) and `private-terms` (optional, but a public repository fails without it).

**3. Its steps, in `pwsh`.**

1. Set the pull request environment from `github.event.pull_request`: `PR_ID`, `PR_TITLE`,
   `PR_DESCRIPTION`, `PR_SOURCE_BRANCH`, `PR_TARGET_BRANCH`, and `CHANGED_FILES` from
   `git diff --name-only <base sha>...HEAD`. `GH_TOKEN` is `github.token`, for reads of issues and pull
   requests.
2. Install the pinned APM with `Install-Apm.ps1`, then run `apm audit --ci` and `apm install --frozen`.
3. Install the pinned gitleaks.
4. Run `Invoke-LocalGates.ps1`, with `-CoverageFile` when given. Its C03 gate `Test-GitleaksBaseline.ps1`
   scans the pull request commits, so the secret scan runs once, as a gate and not as a step.

**4. Results are exit codes and annotations.** When `GITHUB_ACTIONS` is `true`, `GateAnnotation.psm1`
writes `::error` and `::warning` workflow commands ([ADR 0005](0005-the-gate-contract.md)).

**5. Third-party actions are pinned by full commit SHA**, in the action and in a consumer workflow.

**6. GitHub-hosted runners only.** A self-hosted runner behind a public repository can run code from a
fork pull request, so the starter workflows never use one.

## Consequences

**Positive:**

- The local run, the push hook and CI run the same gates with the same runner.
- A version bump of the packages also moves the CI step, in the same pull request.
- No REST call reads the pull request, so the step needs no token beyond `github.token`.

**Negative:**

- A consumer that edits its workflow can skip the action. The ruleset's required status check is the
  guard.
- The action runs from the consumer's own checkout, so a pull request that changes `.claude/` also
  changes the action it runs. `apm audit --ci` fails a hand edit of an installed file before the gates run.

**Neutral:**

- AI.SDLC calls the same action from its own `.claude/` ([ADR 0003](0003-ai-sdlc-installs-its-own-packages-from-its-own-source.md)).

## Alternatives considered

1. **A reusable workflow in AI.SDLC.** Rejected because it needs its own version reference, which drifts
   from the package pin.
2. **A published action referenced as `owner/repo/path@tag`.** Rejected for the same reason: a second pin.
3. **Each consumer writes its own steps.** Rejected because the copies drift, and a gate added to the
   core would not reach CI.
4. **A self-hosted runner.** Rejected because a fork pull request could run code on it.

## Verification

- `tools/PrPipeline.Tests.ps1` checks that the repository's own pull request workflow calls the action
  and lists no gate step by hand.
- `GateAnnotation.Tests.ps1` covers the workflow command format.
- `tools/Test-Consumers.ps1` runs the gates in the test consumers.
- Not covered by a test: the action on a real pull request. That is checked on the first pull request
  after the first push.

## References

- `core/.apm/skills/ai-sdlc-gates/assets/actions/ai-sdlc-pr/action.yml` - the action.
- `core/.apm/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1` - the runner.
- Creating a composite action: https://docs.github.com/en/actions/tutorials/create-actions/create-a-composite-action
- Using an action in the same repository by a local path: https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/find-and-customize-actions
- Pin actions to a full commit SHA, and self-hosted runners with public repositories: https://docs.github.com/en/actions/reference/security/secure-use
- Workflow commands: https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands

## Related

- [ADR 0005](0005-the-gate-contract.md) - what the gates report.
- [ADR 0011](0011-the-public-repository-holds-no-private-information.md) - the private-terms input.
- [ADR index](README.md) - the list of decisions in this repository.
