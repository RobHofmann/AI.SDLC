# YAML rules

These rules hold for any YAML file, whatever tool reads it. Each rule says what it means, shows a
short example and names its source. The examples use made-up names. A rule that only one tool
needs, such as `permissions` in a GitHub Actions workflow, is not here: it is in the skill of that tool.

There is no "not decided" page for YAML. A point that is open for one tool belongs in the skill of
that tool.

## A comment says why

**What it means.** A `#` comment that a change adds, on its own line or after a value, gives a reason
that the value cannot show. Good reasons are a hard limit, a workaround with its issue or link, and a
decision that is not obvious. A comment never says what the next line does, and it is never a block
of config that is switched off; git keeps the history. A longer reason goes in an ADR, a docs page,
the pull request or the work item. A comment that is already there stays; taking it out is a change
nobody asked for.

Do:

```yaml
retentionDays: 30 # the audit asks for a month of logs, see #42
```

Not:

```yaml
# Set the retention days to 30
retentionDays: 30
# retentionDays: 60
```

**Source.** Clause C10 and its exceptions, in
[code comments](/.claude/skills/ai-sdlc-handbook/references/comments.md). A `#` line inside a block
scalar, such as an inline script, follows the comment rule of the language of that script.

## Spaces, never tabs

**What it means.** The level of a line in YAML comes from the spaces in front of it. A tab is not
allowed there. A tab inside a quoted value or a block scalar is content, not indentation, so it
may stay. The number of spaces per level follows the file you edit.

Do:

```yaml
storage:
  name: orders
```

Not, with a tab in front of `name`:

```text
storage:
	name: orders
```

**Source.** [YAML 1.2.2, section 6.1](https://yaml.org/spec/1.2.2/#61-indentation-spaces), which says
a tab must not be used there, and the
[yamllint rule indentation](https://yamllint.readthedocs.io/en/stable/rules.html#module-yamllint.rules.indentation).

## One key once

**What it means.** Each key appears once in a mapping. A second copy of a key is an error in some
tools. In other tools the last copy wins without a warning, so the first value is lost.

Do:

```yaml
timeoutMinutes: 30
retries: 2
```

Not:

```yaml
timeoutMinutes: 30
retries: 2
timeoutMinutes: 60
```

**Source.** [YAML 1.2.2, section 3.2.1.1](https://yaml.org/spec/1.2.2/#3211-nodes): the keys of a
mapping are unique. The
[yamllint rule key-duplicates](https://yamllint.readthedocs.io/en/stable/rules.html#module-yamllint.rules.key_duplicates)
reports a second copy.

## Quote text that looks like another type

**What it means.** A tool reads a value without quotes as a number, a boolean or null when it looks
like one. So `1.10` becomes the number 1.1, and `007` loses its zeros. Older tools that follow YAML 1.1
also read `yes`, `no`, `on` and `off` as booleans. Put quotes around such a value when you mean text.

Do:

```yaml
version: '1.10'
answer: 'yes'
code: '007'
```

Not:

```yaml
version: 1.10
answer: yes
code: 007
```

**Source.** [YAML 1.2.2, section 10.3](https://yaml.org/spec/1.2.2/#103-core-schema), the core
schema, and [the YAML 1.1 boolean type](https://yaml.org/type/bool.html).

## Pick the block scalar on purpose

**What it means.** A value over more than one line is a block scalar. `|` keeps each line break, so
use it for a script or any value where the lines matter. `>` folds the lines into one line with
spaces, so use it for a long sentence.

Do:

```yaml
script: |
  dotnet restore
  dotnet build
description: >
  The order service takes orders
  and sends them on to the store.
```

Not, because the two commands become one line:

```yaml
script: >
  dotnet restore
  dotnet build
```

**Source.** [YAML 1.2.2, section 8.1.2](https://yaml.org/spec/1.2.2/#812-literal-style) for `|`, and
[section 8.1.3](https://yaml.org/spec/1.2.2/#813-folded-style) for `>`.

## No secrets

**What it means.** A YAML file holds no password, key, token or connection string. It names the
secret store or the variable that holds the value, and the tool reads it there.

Do:

```yaml
connectionStringSecretName: orders-connection-string
```

Not:

```yaml
connectionString: Server=orders;User Id=app;Password=<the real password>
```

**Source.** Clause C03 in the
[constitution](/.claude/skills/ai-sdlc-handbook/references/constitution.md).

## Related

- [The yaml-conventions skill](../SKILL.md) - the short rules.
- [Code conventions](/.claude/skills/code-conventions/SKILL.md) - the rules for every language.
