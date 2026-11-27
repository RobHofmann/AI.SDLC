---
name: bicep-conventions
kind: knowledge
user-invocable: false
description: >
  Every Bicep language rule of the team: declaration and property order, registry modules pinned to a
  dated tag, role IDs from a lookup, code names, descriptions, deployment names and target-state
  templates. Use when writing or reviewing a .bicep or .bicepparam file. Do NOT use for deploying a
  template or for C# that calls Azure (csharp-conventions).
---

# Bicep conventions

A Bicep file reads top to bottom in one order, so a reviewer finds each part in the same place. This
skill holds the short rules and the scripts that apply them. Each item points at the page that holds
the full rule; the page wins when the two differ.

## Before you write

- **The shared rules first.** Reuse before you build, build only what the story needs, and the
  severity scale hold in every language. They live in
  [code-conventions](/.claude/skills/code-conventions/SKILL.md); this skill adds the Bicep side only.
- **A point not decided** follows the file you edit, and a new file follows the files next to it. The
  list is on [not-decided.md](references/not-decided.md).
- **Team facts are settings.** Read the registry alias from `bicep.registryAlias`, the
  deployment-name helper from `bicep.deploymentNameHelper` and the role lookup files from
  `bicep.roleLookupFiles` in aisdlc.json. No shared file names them.

## House style

The full rules, with an example and a source each, are on [house-style.md](references/house-style.md).

- **Take a registry module through its alias**, `br/<alias>:`, and pin it to a dated tag such as
  `2026.01.01.1-main`. Never `latest`, and never the full registry host where the alias exists.
- **A local module composes parts inside one repository.** A building block that more than one
  repository uses comes from the registry.
- **A role ID comes from the lookup file** that `bicep.roleLookupFiles` names; never write its GUID by hand.
- **Code names are camelCase**: parameters, variables, resources and modules.
- **Build a string with interpolation**, `'${name}-suffix'`, not with `concat()`.
- **Every parameter and output in new and changed code has a `@description`.**
- **A header block follows the file.** A file that has one keeps it; a file without one gets none.
- **A module call never has a fixed deployment name.** Use the helper from
  `bicep.deploymentNameHelper`, or derive the name inline from `deployment().name`. The name stays
  within 64 characters, as the naming page says.

## Order and shape

- **Top-level declarations** follow the order on the conventions page: metadata and targets, then
  parameters, variables, resources and modules, then outputs.
- **Inside a resource or module**, decorators come first, right before the declaration, then the
  properties in the listed order. Nested resources go last, after the ordered properties.
- **Every module has a `name`**, so a deployment can be traced in the Azure portal.
- **Use the `parent` property** for a child resource, not a `/` in its name.
- **Order resources the way they deploy**, so a reader follows the file like a story.
- **Name a resource `{abbreviation}-{purpose}-{environment}`**, for example `kv-contoso-dev`; the
  [naming page](references/modules-and-naming.md) has the rest.

## A template describes the target state

When a change replaces one resource with another, the template describes only the new one. Every
deployment runs in incremental mode, so a resource that leaves the template keeps running until a
person deletes it. Say two things in the pull request. First, the old resource is now described
nowhere. Second, any name that still points at the old resource must be renamed. The decision itself
belongs in an ADR.

## The reorder script

`scripts/Reorder-BicepPropertyOrder.ps1` puts the declarations and properties of existing files in
order. It runs as a dry run unless you pass `-Apply`.

```bash
pwsh .claude/skills/bicep-conventions/scripts/Reorder-BicepPropertyOrder.ps1 -Path ./infra
pwsh .claude/skills/bicep-conventions/scripts/Reorder-BicepPropertyOrder.ps1 -Path ./infra -Apply
```

After `-Apply`, a second dry run reports no file left to update.

## The pre-flight step and the gates

With the bicep pack installed, the pre-flight runs `scripts/Invoke-BicepPreflight.ps1`. It builds every
`.bicep` file except in the repository's own `.claude`, `.git`, `apm_modules` and `node_modules`
folders, so a worktree under `.claude/worktrees/` builds too. A template that does not compile fails
before the push. It needs the Bicep CLI or the Azure CLI, and reports NOT-AVAIL when neither is
installed.

A workflow can call it with `-FailOnError`: it exits 1 when a template does not build, and 2 when no
tool is installed.

`scripts/Check-BicepConventions.ps1` runs as two advisory gates, and both skip comments. BICEP-01
reports a registry module call with the tag `latest`, in a `.bicep` file or on the `using` line of a
`.bicepparam` file. BICEP-02 reports a role ID written by hand that a file in `bicep.roleLookupFiles`
holds.

## The facts of a building block

Each folder under `paths.bicepRoot` (default `building-blocks`) is a unit that needs a technical page.
`scripts/Get-BicepFacts.ps1 -Unit <folder>` reads its scope, parameters, outputs, resource types and
modules from the compiled templates. `adopt-docs` drafts the page from these facts.

## Sources

- [House style](references/house-style.md) - the Bicep conventions the team follows, with a source each.
- [Not decided](references/not-decided.md) - the Bicep points that are not decided.
- [Security](references/security.md) - the Bicep security rules that the `security-reviewer` agent reads.
- [Clauses](references/clauses.md) - BICEP-01 and BICEP-02, which the two advisory gates check.
- [Bicep property and decorator order](references/bicep.md) - the full order, the rules and the reasons.
- [Bicep modules, deployment names and resource names](references/modules-and-naming.md) - the
  registry alias and version tags, the 64-character limit and the naming pattern.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).
