# Clean Code rules (analyzer-backed)

We use Robert C. Martin's *Clean Code* in a practical way, not as a whole. A style rule is only useful
when a tool checks it, or when it is left to judgement on purpose. So each Clean Code idea lands in one
of three buckets below. Analyzers check the first bucket, not gates we write ourselves.
`SonarAnalyzer.CSharp` is pinned as a `GlobalPackageReference` in `Directory.Packages.props`
(`paths.packagesProps` in aisdlc.json). The severities live in the `.editorconfig` next to the solution
(`paths.solution`). The same rule IDs run in the SonarCloud quality gate, so a finding fails the same
way on a developer machine and in the pipeline.

The C# detail lives in [C# conventions](csharp.md). This page is the Clean Code mapping.

## Bucket 1 - checked by analyzers

### Hard gates (build errors)

A rule becomes an error only after a full build shows zero violations. Then it blocks from a clean
state and cannot break every build on day one. Promoting a rule with a hidden backlog is the failure this
prevents. `S107`, `S134` and `S3776` are off by default, so their absence from a default build can be
mistaken for zero.

| Rule | Clean Code idea | Where |
|---|---|---|
| `CS8509`, `CS8524` | Handle every member of a closed set; no enum or union member silently dropped | `Directory.Build.props` (see [C# conventions](csharp.md), "Control flow over closed sets") |
| `S2068` | No hardcoded credentials (also clause C03) | `.editorconfig` |

### Visible backlog (warning, then error per rule)

These rules are the measurable core of "keep functions small and simple". They are off by default in
SonarAnalyzer and a codebase usually has a backlog, so they run at warning. Each one becomes a hard
gate as soon as a full build shows it at zero.

| Rule | Clean Code idea |
|---|---|
| `S3776` | The cognitive complexity of a method is too high |
| `S138` | A method has too many lines ("functions should be small") |
| `S107` | A method has too many parameters |
| `S134` | Control flow is nested too deeply |

Everything else in the SonarAnalyzer default profile also runs at warning. Examples are unused locals
and members, duplicated code, boolean literals that are not needed, and commented-out code. Treat the warning
list as the standing backlog, and do not add to it.

## Bucket 2 - advisory (checked in review and code generation, not gated)

No analyzer checks these rules well, so the plan, the build and the review check them. They hold in
every language, so they live once on the [clean code page of code-conventions](/.claude/skills/code-conventions/references/clean-code.md):
reuse before you build, build only what the story needs, and the rules for the shape of the code.

## Bucket 3 - judgement only

The author and the reviewer decide these; no rule replaces taste:

- **Names that show intent.** The analyzer checks casing, not whether a name is good.
- **Comments**, set by [the comments page](/.claude/skills/ai-sdlc-handbook/references/comments.md)
  (clause C10). Whether a why is worth writing down is the judgement call.

## Escalation path

1. A backlog rule is brought down to zero across a full build of the solution (`paths.solution`).
2. Its severity goes up to `error` in `.editorconfig`, with the clean build as the evidence.
3. A new rule of high value starts at warning, never straight at error.

This keeps the gate honest: the build only fails on a rule that was clean when it was promoted.

## Related

- [C# conventions](csharp.md) - the wider C# style these rules sit inside.
- [The csharp-generation-smells skill](../SKILL.md) - the C# review checks.
- [Clean code for every language](/.claude/skills/code-conventions/references/clean-code.md) - the Bucket 2 rules.
- [Comments](/.claude/skills/ai-sdlc-handbook/references/comments.md) - the Bucket 3 comment policy.
- [Constitution](/.claude/skills/ai-sdlc-handbook/references/constitution.md) - clause C03 on secrets and C10 on comments.
