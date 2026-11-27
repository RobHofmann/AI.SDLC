# Bicep points not decided

These points are not decided yet. For each one:

- A change follows the form of the file it edits.
- A new file follows the files next to it in the same folder.
- Where a row below names a default, that default wins.

This is the rule "A point that is not decided" of
[code-conventions](/.claude/skills/code-conventions/SKILL.md). Do not pick a form because it looks
better, and do not change the form of code you do not need to touch.

| Point | Options | Default |
|---|---|---|
| The property order inside a resource | The order on [bicep.md](bicep.md) and the reorder script, or the order the existing code already uses | The order on [bicep.md](bicep.md) and the reorder script |
| `-preview` API versions | Allowed, not allowed, or an allow list in aisdlc.json | Use the API version that the files next to the change use for the same resource type |

A team that decides a point records it in an ADR (Architecture Decision Record) and then removes its
row here.

## Related

- [The bicep-conventions skill](../SKILL.md) - the short rules.
- [House style](house-style.md) - the rules that are decided.
- [Resource names and deployment names](modules-and-naming.md) - the naming rules.
- [Code conventions](/.claude/skills/code-conventions/SKILL.md) - the rule for a point not decided.
