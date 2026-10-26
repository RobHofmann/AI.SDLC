---
units:
  - packs/blazor
---

# blazor

The `blazor` package provides checks and guidance for portal authorization and Blazor component conventions. It includes two blocking gates, scripts, and tests.

## What it contains

### Authorization guidance

The `blazor-authorization` skill lives at `packs/blazor/.apm/skills/blazor-authorization/SKILL.md`.

It covers render mode, router composition, page attributes, policy handler resource branches, the admin short-circuit, and a six-cell test matrix.

Use it before reading or changing:

- `Routes.razor`
- `App.razor`
- A page with an `Authorize` attribute
- An authorization requirement or its handler
- A `*PageState.cs` file that calls `IsAuthorizedFor` or `AuthorizeAsync`

Do not use it only for API controller policies. Do not use it for portal changes that do not affect authorization.

### Component conventions

The `blazor-conventions` skill lives at `packs/blazor/.apm/skills/blazor-conventions/SKILL.md`.

It covers these component rules:

- Put attributes on their own line.
- Do not place an interface over a state class.
- Do not use an inline style block.
- Use one document root.
- Follow the state change event pattern.
- Avoid the singleton trap in state change subscriptions.
- Handle a null API client result at the call site.

Use this skill when writing or reviewing a `.razor` file or a component state class. Also use it after a Razor gate fails.

Use it when a component subscribes to a state change. Use other guidance for portal authorization, unrelated C# rules, or writing a new gate.

The reference page `portal-ui.md` lives at `packs/blazor/.apm/skills/blazor-conventions/references/portal-ui.md`.

### Gates

The gate configuration lives at `packs/blazor/.apm/skills/blazor-conventions/gates.json`.

It defines these blocking gates:

- `Portal component conventions (razor)`
- `Portal: component attribute placement`

### Scripts and tests

`Check-RazorAttributePlacement.ps1` checks that component attributes appear on their own line above the member it marks.

It lives at `packs/blazor/.apm/skills/blazor-conventions/scripts/Check-RazorAttributePlacement.ps1`.

Its test file is `packs/blazor/.apm/skills/blazor-conventions/scripts/Check-RazorAttributePlacement.Tests.ps1`.

`Check-RazorConventions.ps1` enforces the mechanical portal component conventions from `portal-ui.md`.

It lives at `packs/blazor/.apm/skills/blazor-conventions/scripts/Check-RazorConventions.ps1`.

Its test file is `packs/blazor/.apm/skills/blazor-conventions/scripts/Check-RazorConventions.Tests.ps1`.

The package configuration file is `packs/blazor/apm.yml`.

## Dependencies

`Check-RazorConventions.ps1` uses the conventions documented in `portal-ui.md`.

Authorization changes to portal routing, pages, requirements, handlers, or page state use the checks in `blazor-authorization`.

Component and state class changes use `blazor-conventions`. The package gates apply its mechanical component rules and attribute placement rule.

## Related

- [How AI.SDLC is built](../overview.md) - where this pack sits among the packages.
- [core](core.md) - the package every repository installs next to this one.
- [Index](../index.md) - every page of this layer.
