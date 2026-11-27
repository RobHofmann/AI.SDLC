# CSS points not decided

These points are not decided. For each one:

- A change follows the form of the style sheet it edits.
- A new style sheet follows the style sheets next to it in the same folder.
- Where a row below names a default, that default wins.

This is the rule "A point that is not decided" of
[code-conventions](/.claude/skills/code-conventions/SKILL.md). Do not pick a form because it looks
better, and do not change the form of code you do not need to touch.

| Point | Options | Default |
|---|---|---|
| Responsive CSS | A `@media` rule, which reacts to the size of the screen, or a `@container` rule, which reacts to the size of the element around it | The form of the style sheet it edits |

The rules are on [css.md](css.md).

Source: [MDN container queries](https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_containment/Container_size_and_style_queries)
and [MDN `@media` queries](https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_media_queries).

## Related

- [The css-conventions skill](../SKILL.md) - the short rules.
- [CSS rules](css.md) - the rules.
- [Code conventions](/.claude/skills/code-conventions/SKILL.md) - the rule for a point not decided.
