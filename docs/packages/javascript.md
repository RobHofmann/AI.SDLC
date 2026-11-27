---
units:
  - packs/javascript
---

# javascript

The `javascript` package provides the JavaScript conventions for the browser modules of a repository. A repository with JavaScript takes it on its own, and the [blazor](blazor.md) pack brings it as an APM dependency ([ADR 0025](../adrs/0025-a-pack-that-needs-another-pack-lists-it-as-an-apm-dependency.md)).

## What it contains

The `javascript-conventions` skill lives at `packs/javascript/.apm/skills/javascript-conventions/SKILL.md`.

It covers:

- One module per component, imported once after the first render.
- No call to a function that a global script put on `window`, apart from a boot script.
- `export function` in a module, and no `var`.
- A listener on `document` or `window` removed through the cleanup helper when its element leaves the page.
- A broken call fixed, not hidden in a `try` block.
- No HTML or code from input.

The package also contains `packs/javascript/.apm/skills/javascript-conventions/references/javascript.md`, which holds each rule with an example and a public source.

The package configuration file is `packs/javascript/apm.yml`. The pack ships no gate.

## Dependencies

The skill reads `javascript.cleanupHelper` from `aisdlc.json`. The layout page of the handbook lists it. When it is not set, the skill follows the modules next to the change.

The shared rules for every language live in `code-conventions` of [core](core.md). Its file type table maps `.js` to this skill.

## Related

- [blazor](blazor.md) - the pack that brings this one, with the Razor rules.
- [css](css.md) - the other pack that the blazor pack brings.
- [core](core.md) - the package every repository installs next to this one.
- [Index](../index.md) - every page of this layer.
