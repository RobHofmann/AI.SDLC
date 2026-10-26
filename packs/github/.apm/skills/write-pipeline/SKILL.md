---
name: write-pipeline
kind: workflow
phase: create
persona: Developer
description: >
  Create GitHub Actions workflows in the team layout: a release workflow, a reusable build-and-test
  workflow, a reusable deploy workflow per environment, GitHub environments for the per-environment
  values, and a pull request workflow with the shared AI-SDLC job. Use when asked to create a workflow
  or a pipeline, set up CI/CD, add a build, release or deploy workflow, add an environment to a
  workflow, or add a toggle or a deploy job to an existing workflow. Do NOT use to run or approve a
  workflow, to set the branch ruleset (github-pull-requests), or to write the Bicep a workflow
  deploys (bicep-conventions).
disable-model-invocation: true
---

# Write a GitHub Actions workflow

This skill writes GitHub Actions workflows that follow the team layout, so every repository deploys
the same way. It asks what the workflow needs, then writes the files in a fixed order. It is an
action skill: it writes files and checks them, and a person reviews them in a pull request.

Owned by the **Developer** persona. Called as `/write-pipeline`, by name only.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).

## What the skill reads

- Always: [github-actions-conventions](/.claude/skills/github-actions-conventions/SKILL.md), for the
  layout, the pins, the permissions, the toggles, the environments and the pull request workflow. Load it
  before the questions. Its rules win over an example or a reference page here.
- The workflows already in `.github/workflows/`, so a new file fits the ones there.
- When the workflow deploys Bicep: [bicep-conventions](/.claude/skills/bicep-conventions/SKILL.md).
- Facts of the platform, such as which environments a component really deploys: the knowledge folder
  (`paths.knowledgeRoot` in aisdlc.json) when it exists. Otherwise ask.

## Questions to ask first

Ask with the question tool of your agent (`AskUserQuestion` in Claude Code, `ask_user` in GitHub
Copilot) before you write anything, in phases. Skip a question the user already
answered.

1. **Workflow type.** Pick one of four. A web app has a .NET backend and a JavaScript frontend (`Angular` or `React`). A
   function or worker app is built and deployed the same way. Infrastructure only is Bicep, Terraform or
   PowerShell, with no build job. The last one is PR validation only.
2. **Project identity.** The project name and its short name (for example `contoso-portal` and
   `contoso`). The environments. The trigger branch: the main branch of the repository, `main` by
   default. The runner per job, `ubuntu-24.04` by default.
3. **Build** (not for infrastructure only). The .NET version. A frontend build (`Angular`) and its Node.js version.
   The test frameworks: xUnit or NUnit for the backend, Vitest, Jest or Karma for the frontend.
   SonarCloud analysis (only when the sonarcloud pack is installed). Frontend and backend as parallel jobs.
4. **Deploy.** Which steps to include; each one that can break things becomes a `workflow_dispatch` toggle that is off by default:
   - The infrastructure deploy, and the tool that runs it.
   - Secrets and configuration values from a file in the repository, written to the target by a script.
   - Database migrations.
   - The app deploy: a staged swap or a direct deploy.
   - A dry run (what-if or plan) input, and a scheduled trigger.
   - How the job signs in to the target: OpenID Connect (`id-token: write`) or an environment secret.

## Write the files in this order

Each file needs the ones above it:

1. The GitHub environments (`dev`, `acc`, `prd`, or the ones the user named) with their variables and
   secrets. You cannot write these as files: list them in the pull request description for the owner
   to create, with the required reviewers on production.
2. `deploy.yml`, the reusable deploy workflow with all deploy jobs.
3. `build-and-test.yml`, the reusable build and test workflow. Skip it for infrastructure only. In a .NET
   repository its test job merges the coverage and uploads the file as the artifact `coverage`; its
   `dotnet test` passes `--settings` with the file in `paths.runSettings`.
4. `release.yml`, the entry point that chains it all.
5. `pr.yml`, the PR validation with the shared AI-SDLC job. It calls `build-and-test.yml`. In a .NET
   repository the `ai-sdlc` job `needs` the build and test job, downloads the `coverage` artifact, and
   passes the file in the `coverage-file` input of the composite action.

Write each file with the `Write` tool under `.github/workflows/`. Show each file in its own code block
with the file name at the top. Put placeholders such as `<app-name>`, `<target-host>` and
`<full commit SHA>` where a real value goes. Never write a real host, account or resource name from an
example into a new file.

## Reference pages

| File | Load when |
|---|---|
| [yaml-syntax-reference.md](references/yaml-syntax-reference.md) | Always: the YAML and expression traps |
| [orchestrator-patterns.md](references/orchestrator-patterns.md) | You write the release workflow |
| [build-patterns.md](references/build-patterns.md) | The workflow has a build job |
| [release-patterns.md](references/release-patterns.md) | You write the deploy workflow |
| [variables-patterns.md](references/variables-patterns.md) | You set the environments, variables and secrets |
| [deployment-job-patterns.md](references/deployment-job-patterns.md) | You add a deploy job |
| [pr-validation-patterns.md](references/pr-validation-patterns.md) | You write the PR workflow |

## Example files

Each folder has the file names of the team layout, so it reads like a `.github/workflows/` folder of a
real repository. Every `uses: ./.github/workflows/...` link in it points at a file that is there. Copy
and change them; never copy a value without checking it. A file marked PARTIAL in its header shows the
pattern, not every job. The `<full commit SHA>` placeholders stand for the SHA of the release you pin.

| Folder | Files | Use for |
|---|---|---|
| [web-app](examples/web-app/) | [release.yml](examples/web-app/release.yml), [build-and-test.yml](examples/web-app/build-and-test.yml), [deploy.yml](examples/web-app/deploy.yml) (PARTIAL), [pr.yml](examples/web-app/pr.yml) | A web app or function app: a .NET and `Angular` build as parallel jobs, deploy jobs per environment, and a PR workflow with the shared AI-SDLC job next to the tests |
| [infrastructure](examples/infrastructure/) | [release.yml](examples/infrastructure/release.yml) (PARTIAL), [pr.yml](examples/infrastructure/pr.yml) | Infrastructure only: no build job, jobs behind toggles, a dry run, a job for dev only |

## Common mistakes

1. **An action pinned to a tag or a branch.** `@v4` can move under you. Pin the full commit SHA and
   keep the version as a comment.
2. **No `permissions` block.** The default token may then have write rights. Start every workflow
   with `permissions: contents: read`.
3. **A toggle read as a string.** A `workflow_dispatch` input of `type: boolean` is a boolean in
   `inputs`, but a string in `github.event.inputs`. Read `inputs.<name>`, and compare with `== true`.
4. **A job after a skipped job never runs.** Add `if: ${{ !cancelled() && !failure() }}` to it.
5. **A secret passed to a reusable workflow by accident of `secrets: inherit`.** Pass each secret by
   name, or keep the secret on the environment of the called job.
6. **A deploy job without `environment:`**, so it skips the required reviewers and the environment values.
7. **`cancel-in-progress: true` on a deploy**, which can stop a deploy half way. Use it only on the PR workflow.

## Check

1. Lint the workflows when you have the tools: `actionlint` for syntax and expressions, and `zizmor`
   for patterns that are not safe. Say which one you ran, or that you could run neither.
2. Check that each toggle reaches the job it guards, and that each `needs` names a job that
   exists when its toggle is off.
3. Check that every `uses:` of a third-party action has a full commit SHA, and that each workflow has a
   `permissions` block and a `concurrency` group.
4. Check that the PR workflow holds the `ai-sdlc` job with the composite action and `fetch-depth: 0`.
   In a .NET repository, check that the job gets `coverage-file`.
5. Report what you checked and what you could not check. Never say the workflow works before a run
   shows it.

## Hand the files to a pull request

The files go on a branch named with the story number. When you are not on a branch named with a story
number, create it from the current state (`git switch -c <number>-<topic>`); the work moves with it. When you
are on one, stay on it. When there is no story yet, `/write-story` makes one first. Then `/wrap-up`
commits the files and runs the pre-flight. Push the branch and open or update the pull request through `github-pull-requests` (`New-PullRequest.ps1` for a new one, `Update-PullRequest.ps1`
for an open one), as
`implement` does. A person reviews the files there, at Checkpoint Bravo.

## Failure modes

- **A job after a skipped job never runs.** The `if:` left out `!cancelled() && !failure()`. Add it to
  every job whose `needs` a toggle can skip.
- **A deploy job reads an empty variable.** The value is on another environment, or on the repository
  instead of the environment. Check that the job sets `environment:` and that the variable is there.
- **A copied example names a host, account or runner of another team.** Replace every value with a
  placeholder or with the value the user gave. Ask when you are not sure.
- **The new files drift from the starter layout** (another file name, a second build). The starter
  layout wins; rename to match it.
- **The PR workflow has no AI-SDLC job**, so the gates never run on a pull request. Add the `ai-sdlc`
  job with the composite action.

## Observable signal

- `.github/workflows/` holds the files in the order above, and each toggle shows as an input in the
  Run workflow dialog of GitHub.
- The PR workflow run shows the `ai-sdlc` job and its gate annotations.
- The pull request lists the placeholders and the environments the user still has to fill in.

## Next steps

- `/wrap-up` (Developer) - commits the workflow files and runs the pre-flight; then push and open or update
  the pull request. A person reviews the files there (Checkpoint Bravo).
- Make the PR checks required with `github-pull-requests` (its `Set-BranchRuleset.ps1`), after a person
  reviewed the files and the first run named the checks. **Developer**.
- Write or review the Bicep the workflow deploys with `bicep-conventions`.
