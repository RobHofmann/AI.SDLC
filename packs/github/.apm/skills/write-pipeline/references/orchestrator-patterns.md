# Release Workflow Patterns

`release.yml` is the entry point: it builds once and deploys that build to each environment in order.
It holds the triggers, the toggles and the chain; the work itself is in the reusable workflows it calls.

## Run name

```yaml
run-name: release ${{ github.ref_name }} ${{ github.run_number }}
```

The build sets the version itself, for example `yyyy.MM.dd.<run number>`, and passes it on as a
workflow output, so every environment deploys the same version.

## Toggle inputs

One boolean input per part that deploys on its own. Work that can break things defaults to `false`:

```yaml
on:
  workflow_dispatch:
    inputs:
      deploy-infra:
        description: Deploy the infrastructure before the app.
        type: boolean
        default: false
      run-migrations:
        description: Run the database migrations before the app.
        type: boolean
        default: false
      skip-prd:
        description: Stop after acc.
        type: boolean
        default: false
```

Name a toggle for the step it switches: `deploy-*`, `run-*`, `create-*`, `enable-*`. A run from a push
has no inputs, so `inputs.deploy-infra == true` is false there: a push releases the code only.

## Dry-run input (infrastructure)

```yaml
dry-run:
  description: Show what would change and change nothing.
  type: boolean
  default: true
```

Pass it to the deploy script, which runs its what-if or plan instead of the deploy. A dry run defaults
to `true` in a run started by hand, so a person switches it off on purpose.

## Triggers

```yaml
on:
  push:
    branches: [main]
  workflow_dispatch:
```

The release never runs on a pull request; `pr.yml` does that. Add `paths:` only when a repository holds
parts that really release apart.

## Runners

```yaml
runs-on: ubuntu-24.04
```

Pin the runner image to a version, not `ubuntu-latest`, so a new image does not change a release by
surprise. A self-hosted runner is named by its labels: `runs-on: [self-hosted, linux, <label>]`.

## Add the build only when needed

```yaml
jobs:
  build:
    uses: ./.github/workflows/build-and-test.yml
    with:
      upload-package: true
```

An infrastructure repository has no build job; its deploy jobs read the templates from the checkout.

## Calling the deploy workflow per environment

```yaml
  dev:
    needs: build
    uses: ./.github/workflows/deploy.yml
    permissions:
      contents: read
      id-token: write
    with:
      environment: dev
      version: ${{ needs.build.outputs.version }}
      deploy-infra: ${{ inputs.deploy-infra == true }}
```

A called workflow gets only the permissions the caller job grants. Do not pass `secrets: inherit`: the
deploy jobs set `environment:`, and an environment's secrets reach a job of the called workflow that
names the environment.

## Conditional needs

A job cannot list a job in `needs` that does not exist, but it can list one that a toggle skips. Then
the job needs `if: ${{ !cancelled() && !failure() }}` to run after the skipped one:

```yaml
  app:
    needs: [infra, migrate]
    if: ${{ !cancelled() && !failure() }}
```

## Environment chain

```yaml
  acc:
    needs: [build, dev]
  prd:
    needs: [build, acc]
    if: ${{ inputs.skip-prd != true }}
```

Each environment waits for the one before. The required reviewers of the `prd` environment hold the
run until a person approves; `Wait-WorkflowRun.ps1` reports that as `approval`.

## Scheduled trigger

```yaml
on:
  schedule:
    - cron: "0 5 * * 1"
```

A scheduled run has no inputs, so every toggle reads as off. Give a job that must run on the schedule
its own condition: `if: ${{ github.event_name == 'schedule' || inputs.run-nightly }}`.

## More than one deploy workflow

A repository that releases two parts on their own, such as an app and a data job, gets one reusable
deploy workflow per part (`deploy-app.yml`, `deploy-data.yml`). It also gets one release workflow that calls both
per environment, each behind its own toggle. Keep one `release.yml` as the entry point, so a person
finds every release in one place.
