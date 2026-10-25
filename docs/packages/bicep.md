---
units:
  - packs/bicep
---

# bicep

The `bicep` package provides conventions and scripts for writing, reviewing, checking, and reordering `.bicep` and `.bicepparam` files.

## What it contains

The `bicep-conventions` skill lives at `packs/bicep/.apm/skills/bicep-conventions/SKILL.md`.

It covers:

- The order of top-level declarations.
- The order of properties in resource and module bodies.
- Decorators before declarations.
- A name on every module.
- Parent references instead of slashes in names.
- Templates that describe the target state rather than the journey.
- Modules from the registry alias in `bicepconfig.json`, pinned to a version tag, never a local path in production.
- The deployment name cut to 64 characters, and the resource naming pattern.

The package also contains these files:

- `packs/bicep/.apm/skills/bicep-conventions/references/bicep.md` defines Bicep property and decorator order.
- `packs/bicep/.apm/skills/bicep-conventions/references/modules-and-naming.md` covers the module registry, the deployment name limit and the resource names.
- `packs/bicep/.apm/skills/bicep-conventions/scripts/Get-BicepFacts.ps1` reads a building block's scope, parameters, outputs, and resources.
- `packs/bicep/.apm/skills/bicep-conventions/scripts/Get-BicepFacts.Tests.ps1`
- `packs/bicep/.apm/skills/bicep-conventions/scripts/Invoke-BicepPreflight.ps1` builds every Bicep template in the repository.
- `packs/bicep/.apm/skills/bicep-conventions/scripts/Invoke-BicepPreflight.Tests.ps1`
- `packs/bicep/.apm/skills/bicep-conventions/scripts/Reorder-BicepPropertyOrder.ps1` reorders declarations and resource or module body properties.
- `packs/bicep/.apm/skills/bicep-conventions/scripts/Reorder-BicepPropertyOrder.Tests.ps1`
- `packs/bicep/.apm/skills/bicep-conventions/gates.json`
- `packs/bicep/apm.yml`

## Changing Bicep safely

Use `bicep-conventions` when writing or reviewing a `.bicep` or `.bicepparam` file.

Also use it when a template replaces one resource with another. Apply it before a pull request that changes infrastructure code.

Run `Reorder-BicepPropertyOrder.ps1` to reorder a Bicep file. Run `Invoke-BicepPreflight.ps1` to build every Bicep template in the repository.

Use `Get-BicepFacts.ps1` to read a building block's scope, parameters, outputs, and resources.

Do not use `bicep-conventions` to deploy a template, call Azure from C# code, or write a new gate.

## Related

- [How AI.SDLC is built](../overview.md) - where this pack sits among the packages.
- [core](core.md) - the package every repository installs next to this one.
- [Index](../index.md) - every page of this layer.
