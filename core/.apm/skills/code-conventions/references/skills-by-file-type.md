# Convention skills by file type

The `builder` agent, the build step of `implement` and `refactor`, the `architect` agent, the
`code-reviewer` agent, the `test-analyzer` agent and the `security-reviewer` agent read this table. It says which convention skill holds the rules of each kind of file. A change loads the skills
of the file types it touches, and no others. A new language needs one row here and no other change in
core.

## How to read the table

1. List the files the change adds, changes or deletes. A test file counts too.
2. Match each file on its last ending: `Card.razor.css` is a CSS file, and `Card.razor.cs` is a C# file.
3. Load each skill in the row of that ending. A file that matches no row gets the shared rules of
   `code-conventions` only.
4. Load a skill only when its folder is installed: `.claude/skills/<skill>/SKILL.md` exists. When the
   pack of a row is not installed, skip that skill. This is no error and no finding, and the report
   does not name it.
5. `code-conventions` holds for every file, so it is not a row.

| File | Skills | Pack | Warning source |
|---|---|---|---|
| `.cs` | `csharp-conventions`, `test-first-dotnet` | dotnet | the .NET analyzers in the build, on the clean code page of `csharp-conventions` |
| `.razor` | `razor-conventions`; also `css-conventions` when the change adds layout classes in markup, and `javascript-conventions` when it adds a JavaScript call | blazor, css, javascript | the .NET build, and the Razor gates of `razor-conventions` |
| `.css` | `css-conventions` | css | none in the build |
| `.js` | `javascript-conventions` | javascript | none in the build |
| `.bicep`, `.bicepparam` | `bicep-conventions` | bicep | the Bicep linter, which `bicep build` runs |
| `.ps1`, `.psm1`, `.psd1` | `powershell-conventions` | core | the advisory gates `Check-ScriptAnalyzer.ps1` and `Check-NativeExitCode.ps1`, on the added lines |
| `.yml`, `.yaml` | `yaml-conventions` | core | none in the build |
| `.yml`, `.yaml` under `.github/workflows/` | `yaml-conventions`, `github-actions-conventions` | core, github | none in the build |

A YAML file outside `.github/workflows/` gets `yaml-conventions` only.

## Skills that follow a topic

Some skills follow what a change does, not the kind of file. They are not rows, because one file type
does not tell when they hold. Each one says in its own description when to load it. Examples are
`api-contract-conventions` (a change touches a route or a payload) and `blazor-authorization` (a
change touches authorization in a Blazor portal).

## Adding a row

A new convention skill adds its row in the same pull request. Run `tools/Update-SkillCatalog.ps1` in
AI.SDLC, so the list of skills per package names the skill that this core page names. A Pester test in
AI.SDLC fails when a row names a skill that no package holds.

## Related

- [Code conventions](../SKILL.md) - the rules for every language, and the warning rule.
- [Clean code](clean-code.md) - the shared clean code rules.
- [Layout](/.claude/skills/ai-sdlc-handbook/references/layout.md) - where core and pack skills live.
