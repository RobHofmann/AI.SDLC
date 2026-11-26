# CSS rules

These are the CSS rules. The [css-conventions skill](../SKILL.md) holds the short form. The code
examples use made-up names. `--brand-` stands for the token prefix that `css.tokenPrefix` in
`aisdlc.json` names.

## A simple row uses the utility classes in the markup

**What it means.** Flexbox is the CSS way to place items in a row or a column. A utility framework such
as Bootstrap offers it as classes, such as `d-flex`, `flex-wrap`, `align-items-center` and `gap-2`.
Where the repository uses such a framework, put these classes in the markup for a simple row. Do not
write your own `display: flex` rule in a style sheet for it. A repository without such a framework
writes the flex rule in the style sheet of the component.

Do:

```html
<div class="d-flex align-items-center gap-2">
    <span class="order-name">...</span>
    <button type="button" class="order-open">Open</button>
</div>
```

Not:

```css
.order-header {
    display: flex;
    align-items: center;
    gap: 0.5rem;
}
```

**Public source.** [Bootstrap flex](https://getbootstrap.com/docs/5.3/utilities/flex/), the parts on
enabling flex behaviours and on wrap, and
[MDN basic concepts of flexbox](https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_flexible_box_layout/Basic_concepts_of_flexbox).

## A page or panel layout uses CSS grid in a style sheet

**What it means.** CSS grid places items in rows and columns at the same time. Use it for the layout of
a whole page or panel, as a rule in a style sheet. Do not use a utility grid class, such as the
Bootstrap `d-grid`, for this. So a simple row is a flex row, and a layout is a grid rule.

Do:

```css
.order-overview {
    display: grid;
    grid-template-columns: repeat(2, minmax(20rem, 1fr));
    gap: 1rem;
}
```

Not:

```html
<div class="d-grid gap-3">...</div>
```

**Public source.** [MDN CSS grid layout](https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_grid_layout).

## Class names in kebab-case, no BEM

**What it means.** A class name is written in kebab-case: small letters, with one hyphen between
words, as in `order-card-title`. Do not use BEM. BEM is a naming method that marks parts of a component
with two underscores and variants with two hyphens, as in `order-card__title--active`. So a class name
never holds a double underscore or a double hyphen.

Do:

```css
.order-card { }
.order-card-title { }
.order-card-active { }
```

Not:

```css
.order-card__title { }
.order-card--active { }
.orderCardTitle { }
```

**Public source.** [BEM quick start](https://en.bem.info/methodology/quick-start/) explains the naming
method that these rules do not use, and the
[stylelint rule selector-class-pattern](https://stylelint.io/user-guide/rules/selector-class-pattern/)
uses kebab-case as its default.

## Lengths in rem; px only for borders, breakpoints and fixed sizes

**What it means.** A length is written in `rem`, a unit that grows with the font size the user chose
in the browser. `px` is used only in three places: a border line, a breakpoint and an element that
must keep one fixed size. A breakpoint is the screen size at which a `@media` rule starts.

Do:

```css
.order-card {
    margin-bottom: 1rem;
    border: 1px solid var(--brand-border-color);
}
```

Not:

```css
.order-card {
    margin-bottom: 16px;
    border: 0.0625rem solid var(--brand-border-color);
}
```

**Public source.** [MDN CSS length](https://developer.mozilla.org/en-US/docs/Web/CSS/length), the parts
on `rem` and on `px`, and the W3C
[understanding page on resize text](https://www.w3.org/WAI/WCAG22/Understanding/resize-text.html).

## Colours come from design tokens

**What it means.** A token is a CSS custom property: a named value read with `var(...)`. The design
system and the colour scheme files set the tokens. A style sheet takes each colour from a token with
the prefix in `css.tokenPrefix`. It does not write a raw colour such as `#fff` or
`rgba(0, 0, 0, 0.25)`. So a colour follows the colour scheme, also in dark mode. The colour scheme
files that `css.colourSchemeFiles` names are the exception, because they set the colours. When the key
is not set, take the tokens that the style sheets next to your change use.

Do:

```css
.order-card {
    background: var(--brand-background-white);
    color: var(--brand-color-primary);
}
```

Not:

```css
.order-card {
    background: #ffffff;
    color: rgba(0, 0, 0, 0.6);
}
```

**Public source.** [MDN using CSS custom properties](https://developer.mozilla.org/en-US/docs/Web/CSS/Using_CSS_custom_properties).

## Tokens have no fallback value

**What it means.** `var()` takes an optional second value, the fallback, which the browser uses when
the token is not set. Write a token without it. A fallback holds a fixed colour that does not follow
the colour scheme, and two fallbacks for the same token can differ.

Do:

```css
.order-card {
    background: var(--brand-background-white);
}
```

Not:

```css
.order-card {
    background: var(--brand-background-white, #fff);
}
```

**Public source.** [MDN var()](https://developer.mozilla.org/en-US/docs/Web/CSS/var), the part on the
fallback value.

## A scoped style sheet does not travel with a class name

**What it means.** With Blazor CSS isolation, `Foo.razor.css` only reaches the elements that
`Foo.razor` renders, because Blazor stamps those with a scope attribute. Copying a class name from
another component gives you the name and none of its styling. A common symptom: the element has the
right size and place but paints nothing, because it renders under a fixed background layer. Give a new
component its own class. Its styles go in its own `.razor.css` file, as the next rule says.

**Public source.** [Blazor CSS isolation](https://learn.microsoft.com/en-us/aspnet/core/blazor/components/css-isolation).

## The style of a component lives in the .razor.css file next to it

**What it means.** The style of a component or a page goes in the `.razor.css` file next to its
`.razor` file, such as `OrderCard.razor.css` next to `OrderCard.razor`. Blazor CSS isolation then keeps
the style inside that component. The style does not go in a shared site style sheet under `wwwroot`,
and not in a `<style>` block in the markup. A style sheet that exists stays where it is; do not move
its rules in a change that does not need it.

Do, in `OrderCard.razor.css`:

```css
.order-card {
    padding: 1rem;
}
```

Not a rule for `.order-card` in a shared `site.css`, and not a `<style>` block in `OrderCard.razor`.

**Public source.** [Blazor CSS isolation](https://learn.microsoft.com/en-us/aspnet/core/blazor/components/css-isolation).

## No inline style

**What it means.** An inline `style` attribute or a `<style>` block in the markup puts style where a
content security policy must allow `unsafe-inline` for it. Keep every style in a style sheet, and let a
condition in the markup add a class.

**Public source.** [MDN Content-Security-Policy style-src](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Content-Security-Policy/style-src)
and the [OWASP page on Content Security Policy](https://cheatsheetseries.owasp.org/cheatsheets/Content_Security_Policy_Cheat_Sheet.html).

## Related

- [The css-conventions skill](../SKILL.md) - the short rules.
- [Not decided](not-decided.md) - the CSS points that are not decided.
- [Code conventions](/.claude/skills/code-conventions/SKILL.md) - the rules for every language.
