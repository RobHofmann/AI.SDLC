---
name: css-conventions
kind: knowledge
user-invocable: false
description: >
  The CSS rules: utility classes for a simple row, CSS grid for a layout, kebab-case class names, rem
  lengths, colours from design tokens without a fallback, and the style of a component in the
  .razor.css file next to it. Use when writing or reviewing a .css or .razor.css file, or layout
  classes in markup. Do NOT use for Razor markup (razor-conventions) or JavaScript
  (javascript-conventions).
---

# CSS conventions

This skill holds the CSS rules. It applies to each change to a `.css` or `.razor.css` file, and to the
layout classes in markup. Each item points at the page that holds the full rule; the page wins when
the two differ. The `builder` agent reads it when a change touches a style sheet.

## Before you write

- **The shared rules first.** Reuse, scope, the comment rule of clause C10 and the severity scale
  hold in every language. They live in
  [code-conventions](/.claude/skills/code-conventions/SKILL.md); this skill adds the CSS side only.
- **A point not decided** follows the style sheet you edit, and a new sheet follows its neighbours.
  The open points are on [not-decided.md](references/not-decided.md).
- **Token names are settings.** Read the token prefix from `css.tokenPrefix` and the colour scheme
  files from `css.colourSchemeFiles` in `aisdlc.json`. When a key is not set, use the prefix and the
  files that the style sheets next to your change use. No shared file names the tokens of a team.

## The rules

The full rules, with an example and a source each, are on [css.md](references/css.md).

- Where the repository uses a utility framework such as Bootstrap, a simple row of items takes its
  flex classes in the markup, such as `d-flex` and `gap-2`. Do not write a `display: flex` rule for it.
- A page or panel layout is a CSS grid rule in a style sheet.
- A class name is kebab-case: small letters and one hyphen between words. No BEM, so never a double
  underscore or a double hyphen in a class name.
- A length is in `rem`. Use `px` only for a border, a breakpoint or an element that must keep one
  fixed size.
- A colour comes from a design token, read with `var(...)`. No hex, `rgb()` or `rgba()` colour
  outside the colour scheme files.
- A token has no fallback value: `var(--prefix-name)`, never `var(--prefix-name, #fff)`.

## Scoped style sheets

- A `*.razor.css` file reaches only the elements its own component renders. A class name copied from
  another component brings none of that component's styling. Give a new component its own class.
- The style of a component or page lives in the `.razor.css` file next to it. It never goes in a
  shared site style sheet or in a `<style>` block.
- `@media` or `@container` follows the style sheet you edit.

## Security

The `security-reviewer` agent reads this section when a change touches a style sheet.

- **No `unsafe-inline` for styles.** An inline `style` attribute or `<style>` block forces the content
  security policy to allow inline styles. Keep every style in a style sheet.
- **No style sheet or font from an outside host** that the repository has not chosen. A new outside
  host is a decision for the team, not for one change.

## Before you call it done

- The change adds no inline `style` attribute; the markup takes a class instead
  (`razor-conventions`, when the blazor pack is installed).
- The shared checks, such as fixing the whole class of a finding, are in
  [code-conventions](/.claude/skills/code-conventions/SKILL.md).

## Sources

- [CSS rules](references/css.md) - each rule with its meaning, an example and a public source.
- [Not decided](references/not-decided.md) - the CSS points that are not decided.
- [Code conventions](/.claude/skills/code-conventions/SKILL.md) - the rules for every language.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).
