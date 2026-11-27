---
name: yaml-conventions
kind: knowledge
user-invocable: false
description: >
  The rules for any YAML file, whatever reads it: spaces never tabs, one key once, quotes on text that
  looks like a number or a boolean, the right block scalar, comments that say why, and no secrets.
  Use when writing or reviewing a .yml or .yaml file, such as apm.yml or a config file. Do NOT use for
  the layout of a GitHub Actions workflow (github-actions-conventions).
---

# YAML conventions

This skill holds the rules that hold for every YAML file, whatever tool reads it. Every repository
has YAML, such as `apm.yml`, so these rules come with core. A tool that reads YAML adds its own rules
in its own skill. For a GitHub Actions workflow that is `github-actions-conventions` of the github
pack, when it is installed. Each item points at the page that holds the full rule; the page wins
when the two differ.

## Before you write

- **The shared rules first.** Reuse, scope, the comment rule of clause C10 and the severity scale
  hold in every language. They live in
  [code-conventions](/.claude/skills/code-conventions/SKILL.md); this skill adds the YAML side only.
- **Follow the file you edit.** The number of spaces per level, the quote style and the order of
  the keys follow the file. A new file follows the YAML files next to it in the same folder.
- **Team facts are settings.** An environment name, a runner or a connection name in a shared YAML
  example is a placeholder. Read the real value from `aisdlc.json`, or ask.

## The rules

The full rules, with an example and a source each, are on [yaml.md](references/yaml.md).

- **A comment says why (clause C10).** A `#` comment that a change adds gives a reason that the value
  cannot show, such as a hard limit or a workaround with its issue. It never says what the next line
  does, and it is never a block of config that is switched off. A comment that is already there stays.
- **Spaces, never tabs, for the level of a line.** YAML does not allow a tab there. A tab inside
  a quoted value or a block scalar is content, and it may stay.
- **One key once.** A key appears once in each mapping. A second copy is an error, or one copy
  wins without a warning, depending on the tool.
- **Quote text that looks like another type.** Put quotes around a version such as `'1.10'`, a value
  such as `'yes'` or `'on'`, and a text with a leading zero. Without quotes, a tool reads a number or
  a boolean.
- **Pick the block scalar on purpose.** `|` keeps each line break, for a script or a multi-line
  value. `>` folds the lines into one, for a long sentence.
- **No secrets (clause C03).** A YAML file holds no password, key, token or connection string. It
  names the secret store or the variable that holds the value.

## Security

The `security-reviewer` agent reads this section when a change touches a YAML file.

- **A secret in plain YAML is a finding**, as the rule "No secrets" above says. This holds for a
  value that gitleaks does not match too, such as a password in a plain key.
- **A workflow file** also gets the security rules of `github-actions-conventions`, when the github
  pack is installed.

## Before you call it done

- Every comment the diff adds says why, and no line starts with a tab.
- Every quoted or unquoted value reads as the type you meant.
- The tool that reads the file accepts it, where you can run that check. Say which check you ran,
  or that you could run none.

## Sources

- [YAML rules](references/yaml.md) - each rule with its meaning, an example and a public source.
- [Code conventions](/.claude/skills/code-conventions/SKILL.md) - the rules for every language.
- [Code comments](/.claude/skills/ai-sdlc-handbook/references/comments.md) - clause C10 in full.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).
