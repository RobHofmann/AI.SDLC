---
units:
  - packs/blazor
---

# blazor

The `blazor` package provides checks and guidance for portal authorization and the Razor conventions of a Blazor component. It includes two blocking gates, scripts, and tests. Its `apm.yml` lists the [css](css.md) and [javascript](javascript.md) packs as APM dependencies, so a Blazor repository gets their skills too ([ADR 0025](../adrs/0025-a-pack-that-needs-another-pack-lists-it-as-an-apm-dependency.md)).

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

### Razor conventions

The `razor-conventions` skill lives at `packs/blazor/.apm/skills/razor-conventions/SKILL.md`.

It covers these component rules:

- Put attributes on their own line.
- Do not place an interface over a state class.
- Do not use an inline style block.
- Use one document root.
- Follow the state change event pattern.
- Avoid the singleton trap in state change subscriptions.
- Handle a null API client result at the call site.
- Dispose what the component holds.

The style sheet of a component follows `css-conventions`, and its JavaScript module follows `javascript-conventions`.

Use this skill when writing or reviewing a `.razor` file or a component state class. Also use it after a Razor gate fails.

Use it when a component subscribes to a state change. Use other guidance for portal authorization, unrelated C# rules, or writing a new gate.

The reference page `razor.md` lives at `packs/blazor/.apm/skills/razor-conventions/references/razor.md`.

### Gates

The gate configuration lives at `packs/blazor/.apm/skills/razor-conventions/gates.json`.

It defines these blocking gates:

- `Razor components have no interface over a state class, no inline style block and no document type`
- `Component attributes sit on their own line above the member they mark`

### Scripts and tests

`Check-RazorAttributePlacement.ps1` checks that component attributes appear on their own line above the member it marks.

It lives at `packs/blazor/.apm/skills/razor-conventions/scripts/Check-RazorAttributePlacement.ps1`.

Its test file is `packs/blazor/tests/skills/razor-conventions/scripts/Check-RazorAttributePlacement.Tests.ps1`.

`Check-RazorConventions.ps1` enforces the mechanical portal component conventions from `razor.md`.

It lives at `packs/blazor/.apm/skills/razor-conventions/scripts/Check-RazorConventions.ps1`.

Its test file is `packs/blazor/tests/skills/razor-conventions/scripts/Check-RazorConventions.Tests.ps1`.

The package configuration file is `packs/blazor/apm.yml`. It lists `../css` and `../javascript` under `dependencies`.

## Dependencies

`Check-RazorConventions.ps1` uses the conventions documented in `razor.md`.

Authorization changes to portal routing, pages, requirements, handlers, or page state use the checks in `blazor-authorization`.

Component and state class changes use `razor-conventions`. The package gates apply its mechanical component rules and attribute placement rule.

## Related

- [How AI.SDLC is built](../overview.md) - where this pack sits among the packages.
- [core](core.md) - the package every repository installs next to this one.
- [css](css.md) - the CSS pack that this pack brings.
- [javascript](javascript.md) - the JavaScript pack that this pack brings.
- [Index](../index.md) - every page of this layer.
