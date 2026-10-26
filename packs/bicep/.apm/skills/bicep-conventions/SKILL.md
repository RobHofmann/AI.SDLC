---
name: bicep-conventions
kind: knowledge
user-invocable: false
description: >
  How a Bicep template is laid out and changed. It covers the order of top-level declarations, the
  order of the properties in a resource or module, and decorators first. It also covers a name on
  every module and parent instead of a slash in a name. It covers modules from the registry pinned to
  a version tag, deployment names within 64 characters and the resource naming pattern. Then a template that describes the target
  state and not the journey, and the script that reorders a file. Use when writing or reviewing a .bicep or .bicepparam
  file, or when a template replaces one resource with another. Also use before a pull request that
  touches infrastructure code. Do NOT use for deploying a template, for the C#
  code that calls Azure (csharp-generation-smells) or to write a new gate (add-gate).
---

# Bicep conventions

A Bicep file reads top to bottom in one order, so a reviewer finds each part in the same place. The
full order is on the conventions page; this skill holds the rules and the script that applies them.

## Order and shape

- **Top-level declarations** follow the order on the conventions page: metadata and targets, then
  parameters, variables, resources and modules, then outputs.
- **Inside a resource or module**, decorators come first, right before the declaration, then the
  properties in the listed order. Nested resources go last, after the ordered properties.
- **Every module has a `name`**, so a deployment can be traced in the Azure portal.
- **Use the `parent` property** for a child resource, not a `/` in its name.
- **Order resources the way they deploy.** Bicep works out the order itself, but a reader follows the
  file like a story.

## Modules and names

- **Take modules from the registry**, through the alias in `bicepconfig.json`, and pin each one to a
  version tag. Never use a local module path in a template that reaches production.
- **Cut a deployment name to 64 characters**:
  `format('{0}-{1}', take('${deployment().name}', 45), take(resourceGroupName, 15))`.
- **Name a resource `{abbreviation}-{purpose}-{environment}`**, for example `kv-contoso-dev`. A storage
  account takes letters and digits only.
- The registry, the real names and the environments of a repository are in the docs of that
  repository. The full rules are on the modules and naming page.

## A template describes the target state

When a change replaces one resource with another, the template describes only the new one. Every
deployment runs in incremental mode, so a resource that leaves the template keeps running until a
person deletes it. Say two things in the pull request. First, the old resource is now described
nowhere. Second, any name that still points at the old resource must be renamed. The decision itself belongs in an ADR.

## The reorder script

`scripts/Reorder-BicepPropertyOrder.ps1` puts the declarations and properties of existing files in
order. It runs as a dry run unless you pass `-Apply`.

```bash
pwsh .claude/skills/bicep-conventions/scripts/Reorder-BicepPropertyOrder.ps1 -Path ./infra
pwsh .claude/skills/bicep-conventions/scripts/Reorder-BicepPropertyOrder.ps1 -Path ./infra -Apply
```

After `-Apply`, a second dry run reports no file left to update.

## The pre-flight step

With the bicep pack installed, the pre-flight runs `scripts/Invoke-BicepPreflight.ps1`. It builds every
`.bicep` file outside `.claude/`, so a template that does not compile fails before the push. It needs
the Bicep CLI or the Azure CLI, and reports NOT-AVAIL when neither is installed.

A workflow can call `Invoke-BicepPreflight.ps1` directly with `-FailOnError`. It then exits 1 when a
template does not build, and 2 when no tool is installed. `-ShowErrors` prints the build errors, and
is on by default in GitHub Actions.

## The facts of a building block

Each folder under `paths.bicepRoot` (default `building-blocks`) is a unit that needs a technical page.
`scripts/Get-BicepFacts.ps1 -Unit <folder>` reads its scope, parameters, outputs, resource types and
modules from the compiled templates. `adopt-docs` drafts the page from these facts.

## Sources

- [Bicep property and decorator order](references/bicep.md) - the full order, the rules and the reasons.
- [Bicep modules, deployment names and resource names](references/modules-and-naming.md) - the
  registry alias and version tags, the 64-character limit and the naming pattern.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).
