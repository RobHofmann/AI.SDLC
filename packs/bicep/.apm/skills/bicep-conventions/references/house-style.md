# Bicep house style

These are the Bicep conventions of the team. Write new and changed Bicep this way. Each rule is a
general rule with a public source, and the examples use made-up names.

The points the team has not decided yet are on [not-decided.md](not-decided.md). The order of the
declarations and the properties is on [bicep.md](bicep.md). Resource names and the 64-character limit
are on [modules-and-naming.md](modules-and-naming.md).

Three kinds of name come up on this page:

- The **code name** is the name of a parameter, variable, resource or module inside the Bicep code,
  such as `orderStorage`.
- The **resource name** is the name the resource gets in Azure. Its rules are on the naming page.
- The **deployment name** is the name of the nested deployment that each module call starts. It
  shows in the deployment history of the resource group or subscription.

## Team facts

A shared file names no fact of one team. Read each one here:

| Fact | Where to read it | When it is not set |
|---|---|---|
| The registry alias | `bicep.registryAlias` in aisdlc.json, a string | the alias under `moduleAliases` in `bicepconfig.json` |
| The deployment-name helper | `bicep.deploymentNameHelper` in aisdlc.json, a string | no helper: write the inline form below |
| The role ID lookup files | `bicep.roleLookupFiles` in aisdlc.json, a list of paths from the repository root | no lookup: the role ID gate does not apply |

## Registry modules through the alias, pinned to a dated tag

A registry module is a Bicep file that a team publishes to a container registry. The alias is a short
name for that registry, set once under `moduleAliases` in `bicepconfig.json`. A template writes
`br/<alias>:` instead of the full registry host. Each call pins the module to a dated tag: a fixed
version named after the day it was published, such as `2026.01.01.1-main`. It never uses `latest`,
so a release next month deploys the same module code.

```bicep
module orderStorage 'br/contoso:storage/account:2026.01.01.1-main' = {
  name: format('{0}-{1}', take(deployment().name, 51), 'orderstorage')
  params: {
    storageAccountName: orderStorageName
  }
}
```

Not `'br:contoso.azurecr.io/storage/account:latest'`: it names the full host and a moving tag.
The advisory gate of clause BICEP-01 reports a call with `latest`; see [clauses.md](clauses.md).
Source: Microsoft explains how to call a module on the page
[Bicep modules](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/modules). It explains
how to set an alias on the page about the [module settings](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/bicep-config-modules).
Azure Verified Modules pin to a version in the same way; see the
[AVM Bicep rules](https://azure.github.io/Azure-Verified-Modules/specs/bicep/).

## A local module composes parts inside one repository

A local module is a Bicep file that a template calls by a file path in the same repository, not by a
registry address. Use one to compose parts inside one repository, such as the resources of one app. A
building block that more than one repository uses comes from the registry, through the alias above.
So do not copy a registry module into a repository as a local file.

```bicep
module orderApp 'modules/order-app.bicep' = {
  name: format('{0}-{1}', take(deployment().name, 51), 'orderapp')
  params: {
    orderStorageName: orderStorageName
  }
}
```

Source: [Bicep modules](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/modules),
the part on local files and the part on the registry.

## A role ID comes from the lookup file

A role ID is the GUID of an Azure role definition, such as Reader. When a repository keeps its role IDs
in a lookup file, a template imports them from that file and never writes the GUID by hand. Then a role
that changes is changed in one place. The paths of the lookup files are in `bicep.roleLookupFiles`.

```bicep
import { builtInRoleIds } from '../roles/builtin-roles.bicep'

var readerRoleDefinitionId = builtInRoleIds.Reader
```

Not `var readerRoleDefinitionId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'`: it is a second copy of the
lookup. The advisory gate of clause BICEP-02 reports it; see [clauses.md](clauses.md).
Source: the rule "reuse what exists; no second copy" in
[code-conventions](/.claude/skills/code-conventions/SKILL.md). Microsoft lists the IDs on the page
[Azure built-in roles](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles).

## camelCase code names

Parameters, variables, resources and modules get a camelCase code name: the first word starts with a
small letter, and each next word with a capital. This rule is about names in the code only.

```bicep
param orderStorageName string
resource orderStorage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: orderStorageName
}
```

Not `param order_storage_name string` or `resource OrderStorage`.
Source: [Bicep best practices](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/best-practices),
the part on names.

## Interpolation, not concat

Build a string with `${...}` inside the string. `concat()` joins strings too, but it is longer and
harder to read.

```bicep
var diagnosticsName = '${orderStorageName}-diagnostics'
```

Not `concat(orderStorageName, '-diagnostics')`. One case stays: `concat()` joins arrays, which
interpolation cannot do.
Source: [Linter rule prefer-interpolation](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/linter-rule-prefer-interpolation).

## A description on every parameter and output

Every parameter and every output in new and changed code has a `@description` decorator. Editors and
the Azure portal show its text. A parameter or output you do not touch keeps what it has.

```bicep
@description('The name of the storage account that holds the orders.')
param orderStorageName string

@description('The resource id of the order storage account.')
output orderStorageId string = orderStorage.id
```

Source: [Parameters in Bicep](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/parameters)
and [outputs in Bicep](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/outputs).

## A header block follows the file

Some files open with a header block: a comment in the form of a PowerShell help block, with parts
such as `.SYNOPSIS`, `.DESCRIPTION` and `.EXAMPLE`. A file that has one keeps it. When your change
makes a line of it wrong, such as a parameter name in an example, correct that line. A file without
a header block gets none, and a new file gets none either, because a comment says why and never
what (clause C10).

The comment rule is in [comments.md](/.claude/skills/ai-sdlc-handbook/references/comments.md).

## Deployment names: the helper, or inline from deployment().name

Azure allows a deployment name of at most 64 characters, and a fixed name makes two runs share one
deployment history. So a module call never has a fixed deployment name:

- **A repository with a deployment-name helper** uses it in every module call. The helper is a
  user-defined function that the repository imports. `bicep.deploymentNameHelper` in aisdlc.json
  names it; import it the way the files next to your change do.
- **A repository without one** derives the name inline from `deployment().name`, the name of the
  deployment that runs the current file. Cut it so the cut, the hyphen and the suffix stay within 64
  characters: 51 characters for a suffix of 12.

```bicep
module orderStorage 'br/contoso:storage/account:2026.01.01.1-main' = {
  name: format('{0}-{1}', take(deployment().name, 51), 'orderstorage')
  params: {
    storageAccountName: orderStorageName
  }
}
```

In a repository with a helper, the same call reads `name: <helper>('orderstorage')`, with the helper
name from the setting.

Not `name: 'orderstorage'`. Two runs then share one deployment name, and the later run overwrites
the history of the first. This rule joins the 64-character rule on the naming page: the helper or
the inline form is how a name stays within that limit.

Source: [the deployment() function](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/bicep-functions-deployment)
and [user-defined functions](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/user-defined-functions).

## Each build compiles the templates

`bicep build` turns a template into an ARM (Azure Resource Manager) JSON template and runs the
linter. A template that does not compile fails the build; a linter warning does not. With the bicep
pack installed, the pre-flight runs `Invoke-BicepPreflight.ps1` for this, as the
[skill](../SKILL.md) says.
Source: [Bicep CLI, the build command](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/bicep-cli)
and [the Bicep linter](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/linter).

## Related

- [The bicep-conventions skill](../SKILL.md) - the short rules and when to load them.
- [Bicep property and decorator order](bicep.md) - the order of the declarations and the properties.
- [Not decided](not-decided.md) - the Bicep points that are not decided.
- [Clauses](clauses.md) - BICEP-01 and BICEP-02, which the advisory gates check.
- [Modules and names](modules-and-naming.md) - resource names and the 64-character limit.
- [Code conventions](/.claude/skills/code-conventions/SKILL.md) - the rule for a point not decided.
