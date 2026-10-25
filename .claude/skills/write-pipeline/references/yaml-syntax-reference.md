# GitHub Actions YAML Syntax Reference

The traps that break a workflow most often. Read this before you write any workflow file.

## Expressions and contexts

### `${{ }}` is the only expression form

GitHub works out `${{ }}` before a step runs. There is no separate compile-time and run-time form, but
there are contexts that exist only in some places:

| Context | Where it works | Use it for |
|---|---|---|
| `inputs` | `workflow_dispatch` and `workflow_call` workflows | toggles and parameters, typed |
| `github` | everywhere | the event, the ref, the run number |
| `vars` | everywhere except `workflow_call` inputs defaults | configuration variables of the repository or the environment |
| `secrets` | steps and `with:`, not `if:` | secrets; never print them |
| `needs` | a job that lists the job in `needs` | outputs and results of earlier jobs |
| `steps` | later steps of the same job | outputs of earlier steps |
| `env` | steps | values set with `env:` |

### Shell variables are not expressions

Inside `run:`, `$env:NAME` (pwsh) or `$NAME` (bash) is read by the shell at run time. Prefer it over
`${{ }}` for any value that comes from the event, such as a branch name or a title. An expression is
pasted into the script text, so untrusted text can inject a command.

```yaml
# WRONG - a crafted pull request title runs as code
- run: echo "${{ github.event.pull_request.title }}"

# CORRECT - the title reaches the shell as data
- env:
    TITLE: ${{ github.event.pull_request.title }}
  run: echo "$TITLE"
```

## Conditions

### On a job or a step

```yaml
if: ${{ inputs.deploy-infra }}
```

A job runs by default only when every job in `needs` succeeded. A skipped job counts as not
succeeded, so a job after a toggle that was off never runs. Add the status functions:

```yaml
needs: [infra, migrate]
if: ${{ !cancelled() && !failure() }}
```

### Combining

```yaml
if: ${{ inputs.environment == 'dev' && (github.event_name == 'push' || inputs.force) }}
```

A string compares without case. A missing input reads as empty, so `inputs.x == true` is false on a
push, where there are no inputs.

## Job and step names

Job ids are letters, digits, `-` and `_`, and start with a letter or `_`. Use `name:` for the text a
person reads, and keep the id stable: the ruleset names the check by the job name.

```yaml
jobs:
  build-and-test:
    name: build-and-test
```

A job of a called workflow shows as `<caller job> / <called job>`, for example `build-and-test / backend`.

## Deploy jobs

A deploy job is an ordinary job with `environment:`. The environment gives it its variables, its
secrets, its required reviewers and its deployment history.

```yaml
deploy:
  runs-on: ubuntu-24.04
  environment:
    name: ${{ inputs.environment }}
    url: ${{ vars.APP_URL }}
  steps:
    - run: ./deploy/Deploy-App.ps1
```

## Outputs

### A step output

```yaml
- id: version
  shell: pwsh
  run: '"version=1.2.3" >> $env:GITHUB_OUTPUT'
```

### A job output, read by a later job

```yaml
build:
  outputs:
    version: ${{ steps.version.outputs.version }}
deploy:
  needs: build
  steps:
    - run: echo "${{ needs.build.outputs.version }}"
```

### A reusable workflow output

Declare it under `on.workflow_call.outputs` with `value: ${{ jobs.<job>.outputs.<name> }}`, then read
it in the caller as `needs.<caller job>.outputs.<name>`.

## Inputs

### `workflow_dispatch` and `workflow_call` inputs are typed

```yaml
on:
  workflow_dispatch:
    inputs:
      deploy-infra:
        type: boolean
        default: false
      environment:
        type: choice
        options: [dev, acc, prd]
```

Read them as `inputs.<name>`. `github.event.inputs.<name>` holds the same values as strings, so
`github.event.inputs.deploy-infra == true` is always false.

## Permissions

The job token (`GITHUB_TOKEN`, `github.token`) gets only the rights in `permissions:`. Set them at the
top of the workflow and extend them per job:

```yaml
permissions:
  contents: read

jobs:
  deploy:
    permissions:
      contents: read
      id-token: write
```

A job that sets `permissions:` gets only what it lists; it does not add to the workflow level.

## Pinning actions

```yaml
# WRONG - a tag can be moved to other code
- uses: actions/checkout@v4

# CORRECT - a commit cannot change; the comment says which release it is
- uses: actions/checkout@<full commit SHA> # v4.2.2
```

## Multi-line values

A `run:` block with `|` keeps the line breaks; `>-` folds them into one line, which suits one long
command. JSON in a variable goes through a file or `ConvertFrom-Json` in the script, never pasted into
the script text with `${{ }}`.

```yaml
- shell: pwsh
  env:
    SETTINGS_JSON: ${{ vars.APP_SETTINGS }}
  run: |
    $settings = $env:SETTINGS_JSON | ConvertFrom-Json
    ./deploy/Set-AppSettings.ps1 -Settings $settings
```

## Scheduled triggers

```yaml
on:
  schedule:
    - cron: "0 5 * * 1-5"
```

The time is UTC. A scheduled run uses the default branch and has no inputs, so read a toggle as
`github.event_name == 'schedule' || inputs.x`. GitHub may start a scheduled run late, and turns the
schedule off in a repository with no activity for 60 days.
