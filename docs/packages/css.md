---
units:
  - packs/css
---

# css

The `css` package provides the CSS conventions for style sheets. A repository with CSS takes it on its own, and the [blazor](blazor.md) pack brings it as an APM dependency ([ADR 0025](../adrs/0025-a-pack-that-needs-another-pack-lists-it-as-an-apm-dependency.md)).

## What it contains

The `css-conventions` skill lives at `packs/css/.apm/skills/css-conventions/SKILL.md`.

It covers:

- Utility classes in the markup for a simple row, where the repository uses a framework such as Bootstrap.
- A CSS grid rule in a style sheet for a page or panel layout.
- Class names in kebab-case, with no BEM.
- Lengths in `rem`, and `px` only for a border, a breakpoint or a fixed size.
- Colours from design tokens, with no fallback value.
- The style of a component in the `.razor.css` file next to it, and no inline style.

The package also contains these files:

- `packs/css/.apm/skills/css-conventions/references/css.md` holds each rule with an example and a public source.
- `packs/css/.apm/skills/css-conventions/references/not-decided.md` lists the CSS points that are not decided.

The package configuration file is `packs/css/apm.yml`. The pack ships no gate.

## Dependencies

The skill reads `css.tokenPrefix` and `css.colourSchemeFiles` from `aisdlc.json`. The layout page of the handbook lists both. A key that is not set means: follow the style sheets next to the change.

The shared rules for every language live in `code-conventions` of [core](core.md). Its file type table maps `.css` to this skill.

## Related

- [blazor](blazor.md) - the pack that brings this one, with the Razor rules.
- [javascript](javascript.md) - the other pack that the blazor pack brings.
- [core](core.md) - the package every repository installs next to this one.
- [Index](../index.md) - every page of this layer.
