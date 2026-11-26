# PowerShell points not decided

These points are not decided. For each one:

- A change follows the form of the script it edits.
- A new script follows the scripts next to it in the same folder.
- Where a row below names a default, that default wins.

This is the rule "A point that is not decided" of
[code-conventions](/.claude/skills/code-conventions/SKILL.md). Do not pick a form because it looks
better, and do not change the form of code you do not need to touch.

| Point | Options | Default |
|---|---|---|
| A wildcard match | `-like` for a wildcard and `-match` only for a regular expression, or `-match` for both | The form of the script it edits |
| Long text | A here-string, or a chain of `+` | The form of the script it edits |
| The story key on a Pester test | A tag on the `It`, such as `-Tag '#42'`; the key in the `Describe` name; or no key, with the link in the pull request | The form of the test file it edits |

A script has a main function that calls helper functions, a function of one line is inlined, and a
shared helper goes into a `.psm1` module. Those are rules on [house-style.md](house-style.md).

The .NET tests carry the story key as a trait, which a gate of the dotnet pack checks (clause C04). No
gate reads a story key on a Pester test, so the form stays open until a team decides it.

## Related

- [The powershell-conventions skill](../SKILL.md) - the short rules.
- [House style](house-style.md) - the rules.
- [Code conventions](/.claude/skills/code-conventions/SKILL.md) - the rule for a point not decided.
