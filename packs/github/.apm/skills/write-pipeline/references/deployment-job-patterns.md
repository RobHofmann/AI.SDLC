# Deploy Job Patterns

The jobs of `deploy.yml`. Each job checks out or downloads what it needs, signs in to the target, and
calls a deploy script of the repository. The script holds the cloud-specific commands. So the same
script runs on your own machine and in the workflow, and the workflow stays the same when the target changes.

## Sign-in to the target

### OpenID Connect (preferred)

```yaml
permissions:
  contents: read
  id-token: write
steps:
  - uses: <login action of your cloud>@<full commit SHA> # vX
    with:
      client-id: ${{ vars.DEPLOY_CLIENT_ID }}
```

The target trusts tokens for this repository and this environment only. There is no stored secret.

### A secret

When the target has no OpenID Connect, keep its key as an environment secret and pass it to the script
through `env:`.

## Infrastructure deploy

```yaml
infra:
  if: ${{ inputs.deploy-infra }}
  environment: ${{ inputs.environment }}
  steps:
    - uses: actions/checkout@<full commit SHA> # v4
    - shell: pwsh
      run: ./deploy/Deploy-Infrastructure.ps1 -Environment '${{ inputs.environment }}' -NamePrefix '${{ vars.NAME_PREFIX }}'
```

For Bicep, the script follows `bicep-conventions`.

## App deploy with a staged swap

```yaml
app:
  needs: [infra, migrate]
  if: ${{ !cancelled() && !failure() }}
  environment:
    name: ${{ inputs.environment }}
    url: ${{ vars.APP_URL }}
  steps:
    - uses: actions/download-artifact@<full commit SHA> # v4
      with:
        name: package
        path: package
    - shell: pwsh
      run: ./deploy/Deploy-App.ps1 -Environment '${{ inputs.environment }}' -PackagePath package -Swap
```

The script deploys to a staging slot or a second instance, checks its health URL, then swaps. A failed
health check stops before the swap, so production keeps the old version.

## Direct deploy

The same job without `-Swap`, for a target with no staging place. Say in the pull request that a
failed deploy then means downtime.

## Function or worker app deploy

The same as the app deploy, with the `func` folder of the package.

## Secrets and configuration values from a file

```yaml
config:
  environment: ${{ inputs.environment }}
  steps:
    - uses: actions/checkout@<full commit SHA> # v4
    - shell: pwsh
      env:
        DATABASE_CONNECTION: ${{ secrets.DATABASE_CONNECTION }}
      run: ./deploy/Set-AppConfiguration.ps1 -SettingsFile 'deploy/settings/${{ inputs.environment }}.json'
```

The script writes each setting to the target, and reads each named secret from its environment variable.

## Database migrations

```yaml
migrate:
  needs: infra
  if: ${{ !cancelled() && !failure() && inputs.run-migrations }}
  environment: ${{ inputs.environment }}
  steps:
    - uses: actions/download-artifact@<full commit SHA> # v4
      with:
        name: package
        path: package
    - shell: pwsh
      env:
        DATABASE_CONNECTION: ${{ secrets.DATABASE_CONNECTION }}
      run: ./package/api/Contoso.Portal.Migrate --connection-env DATABASE_CONNECTION
```

Migrations run before the app deploy, and only with the toggle on. A migration that cannot be undone is
a one-way door: say so in the pull request.

## Recover a soft-deleted resource

The target can keep deleted resources for a while. Then the infrastructure script checks for one with the
same name and recovers it before it creates a new one. That check lives in the script, not in the workflow.

## Run link

Pass `${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}` to the deploy
script, so it can tag what it deploys with the run that deployed it.

## JSON values

Read JSON from a file or from an environment variable with `ConvertFrom-Json`; never paste JSON into
the script text with `${{ }}`, where a quote breaks the script.

```yaml
- shell: pwsh
  env:
    FLAGS_JSON: ${{ vars.FEATURE_FLAGS }}
  run: |
    $flags = $env:FLAGS_JSON | ConvertFrom-Json
    ./deploy/Set-FeatureFlags.ps1 -Flags $flags
```

## Dry run

```yaml
- shell: pwsh
  run: ./deploy/Deploy-Infrastructure.ps1 -Environment '${{ inputs.environment }}' -DryRun:$${{ inputs.dry-run == true }}
```

The script runs its what-if or plan and writes the result to `$GITHUB_STEP_SUMMARY`, then stops. A
dry run changes nothing, so it needs no approval; the real run does.
