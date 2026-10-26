# Bicep property and decorator order

Reference: https://github.com/Azure/azure-quickstart-templates/blob/master/1-CONTRIBUTION-GUIDE/best-practices.md#sort-order-of-properties

The short rules sit in [the bicep-conventions skill](../SKILL.md). This page gives the full order and
the reasons.

## Order of the top-level declarations

```bicep
// 1. Target Scope
targetScope = 'resourceGroup'

// 2. Metadata (Optional)
metadata description = 'Deploys standard web application infrastructure.'

// 3. Parameters
@description('The name of the environment.')
param environmentName string

// 4. Variables
var uniqueStorageName = 'st${uniqueString(resourceGroup().id)}'

// 5. User-Defined Functions (Optional)
func buildResourceName(name string) string => '${environmentName}-${name}'

// 6. Existing Resources (References)
resource existingVnet 'Microsoft.Network/virtualNetworks@2024-01-01' existing = {
  name: 'hub-vnet'
}

// 7. New Resources and Modules (Interchangeable)
resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: 'plan-${environmentName}'
  location: resourceGroup().location
  sku: { name: 'F1' }
}

module webAppModule 'webApp.bicep' = {
  name: 'webAppDeployment'
  params: {
    planId: appServicePlan.id
  }
}

// 8. Outputs
output webAppUrl string = webAppModule.outputs.siteUrl
```

## Order inside resources and modules

### Decorators (before the resource or module declaration)

- `@description()` - always include a description.
- `@batchSize()` - only when a batch deployment is needed.

### Resource declaration order

```bicep
@description('Description goes here')
resource resourceName 'type@version' = {
  // Properties in this order:
  parent: parentResource        // Use parent property instead of / in name
  scope: managementGroup()      // For management group or subscription scope
  name: 'resourceName'          // Resource name (at storage, location level)
  location: 'eastus'            // Azure region
  extendedLocation: { }         // Only if using extended locations
  zones: ['1', '2', '3']        // Availability zones
  sku: { }                       // SKU configuration
  kind: 'TypeName'              // Kind property if applicable
  scale: { }                     // Scale settings
  plan: { }                      // Plan/pricing tier
  identity: { }                  // Managed identity configuration
  dependsOn: [ ]                // Explicit dependencies (prefer implicit)
  tags: { }                      // Tags for resource organization
  properties: { }               // Resource-specific properties

  // Nested resources go after the ordered properties.
  resource childResource 'childType' = {
    name: 'childName'
  }
}
```

### Module declaration order

```bicep
@description('Module description')
module moduleName 'path/to/module.bicep' = {
  // Properties in this order:
  scope: managementGroup()      // Scope declaration first
  name: 'deploymentName'        // REQUIRED - enables deployment tracking in Azure Portal
  params: { }                   // Module input parameters
}
```

## Key rules

- **Decorators** come straight before the resource or module declaration.
- **A module always has a `name`**, so each deployment can be traced and shows in the Azure Portal.
- **Use the `parent` property** for a child resource, not a `/` in the name.
- **Properties follow the order above**, for consistency and easy reading.
- **Nested resources go last**: an inner `resource` comes after the ordered properties of its parent.
- **Grouping by type is optional**: you can mix `resource` and `module` declarations.

## A template describes the target state, not the journey

When a change replaces one resource with another, the template ends up describing only the new one. Do
not carry both the old and the new resource through the templates for the length of a migration.

This is safe when a deployment runs in the incremental mode of ARM. A resource that stops appearing in a
template is left alone, not deleted. So the old resource keeps running and keeps serving whatever still
points at it. Only a destructive mode, such as the complete mode of ARM, would remove it. Check that the
repository's deployment workflows use no such mode. Deleting the old resource is a separate step, done by hand when
the team is ready.

Two things follow, and the pull request says both out loud:

- **The old resource becomes undeclared the moment the change merges.** Its private endpoint, DNS record
  and role assignments still exist, but no code describes them, so code cannot repair or recreate them.
  A rollback becomes a revert of that commit plus a deployment, not a variable edit. That is fine for a
  short migration, but not when you have no revert path.
- **A name that still says "old" now lies.** A parameter named for the old resource that now receives
  the new one reads as if it targets the resource being replaced. Rename the parameter to what it really
  receives. A reviewer cannot tell an intended migration state from a bug when names and values disagree.

The decision for a specific migration still needs an ADR (clause C01). The source of truth and the
rollback path are choices the architecture rests on. See
[the constitution](/.claude/skills/ai-sdlc-handbook/references/constitution.md).

### Chronological order (recommended)

Put resources and modules **in the order they really deploy**. Bicep works the order out by itself, but
a chronological order lets a person read the file like a story, from top to bottom.

- **Example:**
1. `resource` (Log Analytics Workspace)
2. `resource` (Key Vault - depends on Workspace)
3. `module` (Virtual Network)
4. `module` (Virtual Machine - depends on VNet and Key Vault)

## Automation script

- The script `.claude/skills/bicep-conventions/scripts/Reorder-BicepPropertyOrder.ps1` reorders
  existing Bicep files.
- Dry run, with no file changes: `pwsh .claude/skills/bicep-conventions/scripts/Reorder-BicepPropertyOrder.ps1 -Path <folder>`
- Apply the changes: `pwsh .claude/skills/bicep-conventions/scripts/Reorder-BicepPropertyOrder.ps1 -Path <folder> -Apply`
- The script treats an inner `resource` as a trailing part and keeps it after the ordered properties of
  its parent.
- After an apply, a new dry run reports `Files that would be updated: 0` and `Declarations to reorder: 0`.

## Related

- [The bicep-conventions skill](../SKILL.md) - the short rules and when to load them.
- [Modules and naming](modules-and-naming.md) - the module registry, the deployment-name limit and the resource names.
- [Constitution](/.claude/skills/ai-sdlc-handbook/references/constitution.md) - clause C01 on decisions that need an ADR.
- [Comments](/.claude/skills/ai-sdlc-handbook/references/comments.md) - clause C10 on comments: a comment says why, never what.
