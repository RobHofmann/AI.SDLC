---
name: powershell-conventions
kind: knowledge
user-invocable: false
description: >
  The PowerShell rules: a help block, strict mode and Stop, an exit-code check after each native call,
  a main function with helpers, fail loudly, splatting and a Pester test per script. Use when writing
  or reviewing a .ps1, .psm1 or .psd1 file, or a script step in a workflow. Do NOT use to write a gate
  (add-gate) or for the layout of a workflow (github-actions-conventions).
---

# PowerShell conventions

This skill holds the rules of the PowerShell language: how a script, a module and its test are
written. Every repository runs PowerShell gates, so these rules come with core. Each item points at
the page that holds the full rule; the page wins when the two differ.

## Before you write

- **The shared rules first.** Reuse, scope, the comment rule of clause C10 and the severity scale
  hold in every language. They live in
  [code-conventions](/.claude/skills/code-conventions/SKILL.md); this skill adds the PowerShell side only.
- **A point not decided** follows the script you edit, and a new script follows the scripts next to
  it in the same folder. The PowerShell points not decided are on [not-decided.md](references/not-decided.md).
- **Team facts are settings.** A subscription, a resource group, a runner or a folder name in a shared
  example is a placeholder. Read the real value from `aisdlc.json`, or ask.

## House style

The full rules, with an example and a source each, are on [house-style.md](references/house-style.md).

- **Every script has a help block** with `.SYNOPSIS`, `.DESCRIPTION`, a `.PARAMETER` per parameter, an
  `.EXAMPLE`, and `.OUTPUTS` or `[OutputType()]` when it returns something. A public function of a
  module has one too; an inline helper function has none.
- **A script starts with `[CmdletBinding()]` and a typed `param` block**, then sets `Set-StrictMode
  -Version 3.0` and `$ErrorActionPreference = 'Stop'`. A parameter is `Mandatory` only without a good default.
- **Check the exit code after each native call.** A native call is a program outside PowerShell, such
  as `git`, `gh` or `dotnet`. Right after it, `throw` when `$?` is false or `$LASTEXITCODE` is not 0,
  so a tool that did not start also reads as failed.
- **Every script that a workflow or a gate runs has a Pester test.** One test covers one case; merge
  copies of the same case. The test proves the script's own logic, not PowerShell or a module (clause C04).
- **A main function calls helper functions.** A function of one line, or one that only wraps one
  cmdlet, is inlined. A helper that more than one script uses goes into a `.psm1` module.
- **Fail loudly.** Throw as soon as an input or result is wrong, and use no default that hides a
  missing value. Catch only the error you expect. End a `switch` over a fixed set with a default that throws.
- **Output:** `Write-Host` for the person, `Write-Verbose` for detail, and a plain value for data. In
  GitHub Actions, report a finding with a workflow command such as `::warning::` or `::error::`. A
  `Get-*` function writes nothing.
- **Every module a script needs is pinned to a version**, in a `#Requires -Modules` line or the
  repository's own requirements file.
- **The brace on the same line, 4 spaces, Verb-Noun with an approved verb and full cmdlet names.** Use
  single quotes unless the string expands, camelCase locals and PascalCase parameters.
- **Splat a long command** with a hashtable; never write a backtick line break.
- **Put `$null` on the left** of a comparison: `$null -eq $value`.
- **A comment says why, never what (clause C10).** The help block is the doc comment that C10 asks for.
  Directives such as `#Requires` are not comments.

## Tests

The `test-analyzer` agent reads this section when a change touches a PowerShell file. The full rule
is the section "A Pester test per script" of [house-style.md](references/house-style.md).

- **A changed script that a workflow or a gate runs, without a Pester test, is a finding.**
  The test is `<Script>.Tests.ps1` at the mirrored path: next to the script or in the test folder the
  repository uses.
- **One test covers one case.** Merge copies of the same case into one test, or one `It` with
  `-ForEach`.
- **Each `It` asserts with `Should`.** An `It` with no `Should` checks nothing.
- **Replace a cmdlet or a native tool with Pester `Mock`**, not with a new wrapper function in the
  script that exists only for the test.
- **Test the script's own logic** (clause C04), not PowerShell, a module or the tool it calls.

## Security

The `security-reviewer` agent reads this section when a change touches a PowerShell file.

- **A secret never goes into an environment variable in plain text** that the script sets itself.
  Read the secret from the secret store where the script needs it, or keep it in a `SecureString` or
  a `PSCredential` (clause C03).
- **No `ConvertTo-SecureString -AsPlainText` on a secret** that the script holds as text. Source:
  [PSScriptAnalyzer rule AvoidUsingConvertToSecureStringWithPlainText](https://learn.microsoft.com/en-us/powershell/utility-modules/psscriptanalyzer/rules/avoidusingconverttosecurestringwithplaintext).
- **A secret never reaches the console or a log**: not through `Write-Host`, `Write-Output`,
  `Write-Verbose` or a native call that prints its arguments. In GitHub Actions, hide a value that the
  script builds with the `::add-mask::` command before anything prints it.
- **No `Invoke-Expression` on input.** Build the command with parameters, so input cannot run as code. Source:
  [PSScriptAnalyzer rule AvoidUsingInvokeExpression](https://learn.microsoft.com/en-us/powershell/utility-modules/psscriptanalyzer/rules/avoidusinginvokeexpression).

## A shared script in AI.SDLC

These rules hold only for a script that a package of AI.SDLC delivers. A consumer repository keeps
its scripts and tests where it already keeps them.

- **The script lives in the `scripts/` folder of its skill**, so APM installs it with the skill.
- **Its Pester test lives at the mirrored path under `<package>/tests/`** (ADR 0015), so no consumer gets it.
- **A gate follows the shape of `add-gate`**, with the exit codes and the `FIX:` line it names.

## Before you call it done

- Every comment the diff adds says why, the diff adds no tab, and every new script has its help block.
- Every native call in the diff is followed by a check of `$?` and `$LASTEXITCODE`.
- Every new or changed script that a workflow or a gate runs has a Pester test that fails without the
  change, and you ran it. Say which tests you ran.

## Sources

- [House style](references/house-style.md) - the PowerShell rules, with an example and a public source each.
- [Not decided](references/not-decided.md) - the PowerShell points not decided.
- [Code conventions](/.claude/skills/code-conventions/SKILL.md) - the rules for every language.
- [Code comments](/.claude/skills/ai-sdlc-handbook/references/comments.md) - clause C10 and the help block.
- [add-gate](/.claude/skills/add-gate/SKILL.md) - the shape of a gate script and its test.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).
