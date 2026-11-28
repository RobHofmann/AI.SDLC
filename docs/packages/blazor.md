---
units:
  - packs/blazor
---

# blazor

The `blazor` package provides checks and guidance for portal authorization and the Razor conventions of a Blazor component. It includes one blocking gate and its script; the test of the script stays in AI.SDLC ([ADR 0015](../adrs/0015-the-tests-of-a-shared-package-live-outside-the-installed-package.md)). Its `apm.yml` lists the [css](css.md) and [javascript](javascript.md) packs as APM dependencies, so a Blazor repository gets their skills too ([ADR 0025](../adrs/0025-a-pack-that-needs-another-pack-lists-it-as-an-apm-dependency.md)).

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
- Keep the parts of a Razor file in a fixed order, with one `@code` block.
- Keep component code in the `@code` block, never in a `.razor.cs` file.
- Build a form as an `EditForm` with a validator component and a `ValidationMessage`.
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

It defines this blocking gate:

- `Components have no inline style block, I*State interface or DOCTYPE outside the app component, and attributes sit above members`

### Scripts and tests

`Check-RazorConventions.ps1` enforces the mechanical component conventions from `razor.md`.

It fails on an `I*State` interface, an inline style block, a `<!DOCTYPE` outside the app component, and an attribute that shares a line with its member. It reads the app component from `dotnet.appComponent` in `aisdlc.json`, and exits 2 while the old key `dotnet.portalAppComponent` is set.

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
