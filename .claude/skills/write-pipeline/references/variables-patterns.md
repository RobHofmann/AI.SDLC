# Variables Patterns

A workflow has three places for a value. Pick the place by who may see the value and whether it differs
per environment.

| Place | Holds | Read as |
|---|---|---|
| `env:` at the top of the workflow | values every environment shares, such as the .NET version | `env.NAME`, `$env:NAME` |
| Environment variables of a GitHub environment | values that differ per environment and are not secret, such as a URL or a name prefix | `vars.NAME` |
| Environment secrets of a GitHub environment | secrets, such as a connection string | `secrets.NAME` |

A repository variable or secret (`vars.*`, `secrets.*` at repository level) holds a value that is the
same everywhere but is not code, such as `AISDLC_PRIVATE_TERMS`.

## Shared values

```yaml
env:
  DOTNET_VERSION: "9.0.x"
  NODE_VERSION: "22"
  SOLUTION: src/Contoso.Portal.sln
```

## Values per environment

Create the environments `dev`, `acc` and `prd` under Settings, Environments. Give each the same
variable names with its own values:

| Variable | dev | prd |
|---|---|---|
| `NAME_PREFIX` | `contoso-dev` | `contoso-prd` |
| `APP_URL` | `https://dev.portal.contoso.example` | `https://portal.contoso.example` |
| `APP_TARGET` | `<dev target>` | `<prd target>` |

A job reads them only when it sets `environment:`. The values are settings, not files, so the workflow
pull request lists them for the owner to create.

## Secrets

- Keep every secret in an environment secret or a repository secret, never in a workflow file or a
  file in the repository (constitution C03).
- Pass a secret to a step through `env:`, never into the script text.
- Prefer a cloud login through OpenID Connect (`id-token: write`) over a stored key, so there is no
  long-lived secret at all.

## Naming

Name the resources a workflow creates as `<prefix>-<env>-<part>`, with the prefix from `NAME_PREFIX`:
`contoso-dev-api`, `contoso-prd-web`. Keep the names in the deploy scripts or the templates, built from
the prefix, so the workflow passes only the prefix.

## Structured values

A list or a map that is not secret lives in a JSON file in the repository per
environment (`deploy/settings/dev.json`). App settings and feature flags are examples. The deploy script reads the file for its
environment. A secret value in such a list is named in the file and read from a secret at run time.

```json
{
  "featureFlags": { "NewCheckout": false },
  "settings": { "Api:PageSize": "50" },
  "secrets": [ "DATABASE_CONNECTION" ]
}
```

## Infrastructure values

An infrastructure repository keeps its parameters per environment next to the templates
(`infra/params/dev.json`, `infra/params/prd.json`). The workflow passes the environment name, never the
values.

## Run links

The URL of the run is `${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}`.
Pass it to the deploy script as a tag or a label on what it deploys. Then a person can trace a resource
back to the run that made it.
