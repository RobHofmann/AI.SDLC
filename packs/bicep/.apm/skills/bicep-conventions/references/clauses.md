# Constitution (bicep clauses)

These clauses hold in every repository that installs the bicep pack. They carry the `BICEP-` prefix,
which says they live in this pack. The core clauses and the ID scheme are in the
[core constitution](/.claude/skills/ai-sdlc-handbook/references/constitution.md).

**Version:** 1.0

## BICEP-01: A registry module is pinned to a dated tag

- **Statement:** A module call, an import or the `using` line of a `.bicepparam` file that takes a
  registry module names a dated tag, such as `2026.01.01.1-main`. It never names the tag `latest`.
- **Rationale:** The tag `latest` moves. The same template then deploys a different module on another
  day, and a review of the template no longer shows what runs. A dated tag keeps a deployment
  repeatable. [house-style.md](house-style.md) gives the module rules in full.
- **Enforcement:** `.claude/skills/bicep-conventions/scripts/Check-BicepConventions.ps1` with
  `-Rule ModuleTag` (advisory gate) - active. Code review - active.

## BICEP-02: A role ID comes from the lookup file

- **Statement:** A role definition ID is written once, in a lookup file that `bicep.roleLookupFiles` in
  `aisdlc.json` names. A template and a parameter file read it from there and never hold the GUID.
- **Rationale:** A GUID typed in many files hides which role it is, and a wrong digit gives a silent
  wrong grant. One lookup file gives each ID a name and one place to review. [security.md](security.md)
  gives the access rules.
- **Enforcement:** `.claude/skills/bicep-conventions/scripts/Check-BicepConventions.ps1` with
  `-Rule RoleId` (advisory gate) - active only where `aisdlc.json` sets `bicep.roleLookupFiles`. Code
  review - active.

## Related

- [House style](house-style.md) - every module rule with its reason and source.
- [Bicep security](security.md) - the access rules.
- [bicep-conventions](../SKILL.md) - the skill that carries these clauses into a build or a review.
- [Core constitution](/.claude/skills/ai-sdlc-handbook/references/constitution.md) - the core clauses and the
  clause ID scheme.
