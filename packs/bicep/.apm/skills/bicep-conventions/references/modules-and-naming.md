# Bicep modules, deployment names and resource names

Three rules about what a template points at and what it calls things. They come on top of the order
rules in [bicep.md](bicep.md). The registry, the real names and the environments of one repository are
facts of that repository. They live in the docs of that repository.

## Modules come from the registry

A production template takes its modules from the container registry, never from a local path. The
registry gets a short alias in `bicepconfig.json`, so a template does not repeat the full host name:

```bicep
// bicepconfig.json defines the alias
"moduleAliases": { "br": { "modules": { "registry": "contosomodules.azurecr.io" } } }

// A module always points at a version tag
module vnet 'br/modules:network/virtualnetworks:2024.01.18.2-main' = { ... }
```

- **Pin every module to a version tag.** A tag such as `2024.01.18.2-main` is fixed. A moving tag would
  change what a deployment does without a change in the repository.
- **A local path is fine while you build a module**, but not in a template that reaches production.

## A deployment name stays within 64 characters

Azure stops a deployment whose name is longer than 64 characters, and a fixed name makes two runs share
one deployment history. There is one form: the helper that `bicep.deploymentNameHelper` names, or the
inline form from `deployment().name` with a fixed module suffix. The deployment-name rule in
[house-style.md](house-style.md) holds both and how to cut them.

## Resource names follow one pattern

The pattern is `{abbreviation}-{purpose}-{environment}`. The abbreviation is the short form of the
resource type:

| Resource | Pattern | Example |
|----------|---------|---------|
| Virtual network | `vnet-{purpose}-{env}` | `vnet-contoso-dev` |
| Subnet | `snet-{name}-{env}` | `snet-app-dev` |
| Resource group | `{function}-{env}` | `contoso-dev` |
| Key Vault | `kv-{purpose}-{env}` | `kv-contoso-dev` |
| Managed identity | `id-{purpose}-{env}` | `id-automation-vm-updater-dev` |
| Storage account | letters and digits only | `stgvnetflowlogsdev` |

A storage account name allows no hyphen, so it joins the same parts without one. It is also at most
24 characters long and only lower case.

## Related

- [Bicep property and decorator order](bicep.md) - the order of the declarations and the properties.
- [The bicep-conventions skill](../SKILL.md) - the short rules and when to load them.
- [Bicep house style](house-style.md) - the other Bicep rules, with a source each.
