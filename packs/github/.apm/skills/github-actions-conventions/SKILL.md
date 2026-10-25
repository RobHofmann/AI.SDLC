---
name: github-actions-conventions
kind: knowledge
user-invocable: false
description: >
  How a GitHub Actions workflow is laid out and written here: the files in .github/workflows, the
  release workflow that builds once and deploys per environment, workflow_dispatch toggles with risky
  work off by default, actions pinned to a full commit SHA, least-privilege permissions, concurrency,
  environments with required reviewers for production, and the pull request workflow with the shared
  AI-SDLC job. Use when writing, changing or reviewing workflow YAML, for example a new toggle, a new
  deploy job or a new environment. Do NOT use to run or approve a workflow, or to set the branch
  ruleset (github-pull-requests).
---

# GitHub Actions conventions

How a workflow of a team repository is written. `write-pipeline` loads this for every new workflow,
and any change to workflow YAML follows it. The starter workflows that the AI.SDLC setup script writes
are the reference: when an example elsewhere differs, the starter layout wins.

## The layout

GitHub reads workflows only from `.github/workflows/`:

| File | What it is |
|---|---|
| `release.yml` | The entry point. It triggers on the main branch and on `workflow_dispatch`, builds once, then deploys that build to each environment in order. |
| `build-and-test.yml` | The build and test job, a reusable workflow (`on: workflow_call`), only when there is code to build. |
| `deploy.yml` | One deploy workflow (`on: workflow_call`), called once per environment. |
| `pr.yml` | The pull request workflow. |

The environments are the ones in the team defaults, today `dev`, `acc` and `prd`, in that order. They
are GitHub environments of the repository, and a repository deploys only the ones it has. The
run name is `run-name: ${{ github.workflow }} ${{ github.ref_name }} ${{ github.run_number }}`.

## The rules

- **Pin every action to a full commit SHA**, with the version as a comment:
  `uses: actions/checkout@<40-character SHA> # v4.2.2`. A tag can move; a SHA cannot. A local action
  (`./...`) needs no pin. Dependabot or Renovate keeps the SHAs current.
- **Least-privilege `permissions`.** Set `permissions: contents: read` at the top of every workflow.
  Give a job more only when it needs it, such as `id-token: write` for a cloud login through OpenID
  Connect, or `pull-requests: read` for the shared job.
- **`concurrency` on every workflow.** A pull request workflow cancels its older run:
  `group: pr-${{ github.event.pull_request.number }}` with `cancel-in-progress: true`. A deploy never
  cancels a run in progress: `group: deploy-${{ inputs.environment }}`, `cancel-in-progress: false`.
- **A toggle per part that deploys on its own.** A boolean `workflow_dispatch` input named for the step
  it switches, such as `deploy-infra`, `run-migrations` or `enable-*`. Work that can break things defaults to `false`:
  a plain run releases the code only, and infrastructure goes out only when someone asks for it. A run
  from a push has no inputs, so read a toggle as `inputs.deploy-infra == true`, which is false there.
- **A job after a skipped one must still run.** Use
  `if: ${{ !cancelled() && !failure() }}` on a job whose `needs` can be skipped by a toggle.
- **Environments carry the per-environment values and the approvals.** A deploy job sets
  `environment: <env>`. Its values are environment variables (`vars.*`) and environment secrets
  (`secrets.*`) of that GitHub environment. Production has required reviewers, and only the main branch
  may deploy to it (deployment branch policy).
- **Secrets live in GitHub secrets**, never in a workflow file or a file in the repository. A cloud login
  uses OpenID Connect with `id-token: write`, not a stored key.
- **Build once, deploy the artifact.** The build uploads one artifact; every deploy job downloads that
  artifact. No deploy job builds again.
- **The pull request workflow** triggers on `pull_request` to the main branch. Its `ai-sdlc` job checks
  out with `fetch-depth: 0` and runs the composite action
  `./.claude/skills/ai-sdlc-gates/assets/actions/ai-sdlc-pr`. The build and test job of the repository runs next
  to it. It names no gate as a step of its own. A gate is an entry in `repoGates` of `aisdlc.json`, and
  the shared action and a local run both run it. For the C04 coverage ratchet, the test job uploads the merged coverage file as an artifact. The
  `ai-sdlc` job `needs` the test job, downloads the artifact, and passes its path in the `coverage-file`
  input. The ruleset makes both jobs required: `Set-BranchRuleset.ps1 -RequiredCheck` in `github-pull-requests`.
- **Running a deploy is a human act.** The agent writes workflows and waits for runs; it never approves a
  deployment and never runs a production deploy.

## Sources

- [The patterns of write-pipeline](/.claude/skills/write-pipeline/references/orchestrator-patterns.md) -
  the release, deploy, variables and pull request patterns in full, with examples.
- [The layout page](/.claude/skills/ai-sdlc-handbook/references/layout.md) - the paths in aisdlc.json.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).
