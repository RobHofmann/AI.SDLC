# Deploy Workflow Patterns

`deploy.yml` is the reusable deploy workflow. `release.yml` calls it once per environment.

## Inputs

```yaml
on:
  workflow_call:
    inputs:
      environment:
        type: string
        required: true
      version:
        type: string
        required: true
      deploy-infra:
        type: boolean
        default: false
      run-migrations:
        type: boolean
        default: false
```

Every toggle of `release.yml` that a deploy job reads is an input here, with the same name and the same
default.

## Concurrency per environment

```yaml
concurrency:
  group: deploy-${{ inputs.environment }}
  cancel-in-progress: false
```

Two runs never deploy to the same environment at once, and a waiting run never stops one half way.

## Values per environment

Every deploy job sets `environment: ${{ inputs.environment }}`, so it reads that environment's
variables (`vars.*`) and secrets. See [variables-patterns.md](variables-patterns.md).

## Deploy job with a toggle

```yaml
infra:
  if: ${{ inputs.deploy-infra }}
  runs-on: ubuntu-24.04
  environment: ${{ inputs.environment }}
  permissions:
    contents: read
    id-token: write
  steps:
    - uses: actions/checkout@<full commit SHA> # v4
    - shell: pwsh
      run: ./deploy/Deploy-Infrastructure.ps1 -Environment '${{ inputs.environment }}'
```

## Conditional dependencies

A job after a toggled job lists it in `needs` and adds the status functions, so it runs when the toggle
was off:

```yaml
app:
  needs: [infra, migrate]
  if: ${{ !cancelled() && !failure() }}
```

Without them, a skipped `infra` skips `app` too.

## Outputs between jobs

```yaml
infra:
  outputs:
    app-target: ${{ steps.deploy.outputs.app-target }}
  steps:
    - id: deploy
      shell: pwsh
      run: |
        $target = ./deploy/Deploy-Infrastructure.ps1 -Environment '${{ inputs.environment }}'
        "app-target=$target" >> $env:GITHUB_OUTPUT
app:
  needs: infra
  steps:
    - run: ./deploy/Deploy-App.ps1 -Target '${{ needs.infra.outputs.app-target }}'
```

An output of a skipped job is empty. Fall back to the environment variable then:
`${{ needs.infra.outputs.app-target || vars.APP_TARGET }}`.

## Dev-only jobs

```yaml
smoke-test-dev:
  needs: app
  if: ${{ inputs.environment == 'dev' }}
```

## Scheduled run condition

A scheduled run has no inputs. When the schedule should deploy only one part, give that job
`if: ${{ github.event_name == 'schedule' || inputs.<toggle> }}`; `github` in a called workflow is the
context of the caller run.

## Job summary

```yaml
- shell: pwsh
  run: '"Deployed ${{ inputs.version }} to ${{ inputs.environment }}." >> $env:GITHUB_STEP_SUMMARY'
```

The summary shows on the run page, so a person sees what went where without reading the log.
