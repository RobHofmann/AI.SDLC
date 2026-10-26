---
story: "#1"
phase: governance
step: write-adr
intent:
  assumption: "APM keeps installing a local package from a folder that git tracks, and Check-SyncManifest.ps1 keeps comparing the installed copy with the source manifest of that folder"
  decision-drivers:
    - "the repository that builds the way of working must follow it, with the same skills, hooks and gates as every other repository"
    - "a change to a shared file must be tested in daily work on the branch that makes it, not only after a release"
    - "the source and the installed copy must never drift apart in a merged change"
relates:
  docs: docs/overview.md
  manifest: apm.yml
  config: aisdlc.json
  gate: core/.apm/skills/ai-sdlc-gates/scripts/Check-SyncManifest.ps1
  local: core/.apm/skills/ai-sdlc-gates/scripts/Check-LocalPackages.ps1
because:
  docs: "the page that describes the self install"
  manifest: "the file that names the local packages"
  config: "the settings and the repository gates of AI.SDLC"
  gate: "the gate that fails a branch whose installed copy is behind its source"
  local: "the gate that allows a local package only when git tracks its folder"
---

# ADR 0003: AI.SDLC installs its own packages from its own source

**Status:** Accepted
**Date:** 2026-10-24
**Supersedes:** none
**Superseded by:** none

## Context

AI.SDLC is the source of the `core` package and the packs ([ADR 0001](0001-ai-sdlc-is-shared-as-apm-packages.md)).
Other repositories install them at a release tag. Suppose AI.SDLC installed none of them. Then the work here would
run without the story flow, the pull request loop, the pre-flight, the hooks and the language gates. A
change to a shared file would be seen the way a consumer sees it only after a release.

Three facts shape the choice:

- APM installs a package from a local folder as well as from a git repository and tag. It records the
  folder in `apm.lock.yaml` (APM manifest schema, APM lockfile spec).
- A local package is allowed only when git tracks its folder. The core gate `Check-LocalPackages.ps1`
  fails otherwise (the [consumer-own page](../../core/.apm/skills/ai-sdlc-handbook/references/consumer-own.md)).
- `Check-SyncManifest.ps1` compares `.claude/` with a manifest. By default it reads the manifest next to
  the installed gate, so an install that is out of date agrees with itself.

## Decision

**1. AI.SDLC installs its own packages from its own folders.** The root `apm.yml` names `./core` and the
packs every consumer gets, as local packages. The repository commits `apm.yml`, `apm.lock.yaml` and the
installed files under `.claude/`. So the work here runs the skills, hooks and gates of the branch itself.

**2. The installed copy must match the source in every pull request.** When `apm.yml` installs the core
from inside the repository, `Check-SyncManifest.ps1` reads the source manifest in `core/`. A branch that
changes a source file without `tools/Update-SyncManifest.ps1` and `apm install` fails the gate. It fails
in the pre-push hook and in the pull request check. `Deny-SharedFileEdit.ps1` stops an edit of the copy
and names the source file.

**3. The same process as a consumer.** `aisdlc.json` holds the settings of this repository, and its
`repoGates` list the checks of this repository, so the pre-push hook runs them. The pull request
workflow runs the shared composite action from `.claude/` ([ADR 0012](0012-ci-is-a-composite-action-inside-the-installed-core.md)).

**4. AI.SDLC is not a consumer.** It pins its own source and not a tag, and it has no update workflow,
so no update pull request ever touches it.

## Consequences

**Positive:**

- The repository that builds the way of working follows it, on every branch.
- A broken skill, hook or gate shows up in the work here before a release reaches a consumer.
- A merged change never has a copy that differs from its source.

**Negative:**

- A changed gate checks the branch that changes it, so a broken gate can pass itself. The Pester tests
  and `tools/Test-Consumers.ps1` stay the independent check; do not trim them.
- Every skill exists twice in the tree, once as the source and once as the copy. A search finds both.
- A change under `.apm/` takes two more commands: `tools/Update-SyncManifest.ps1` and `apm install`.
- APM refuses a local package inside its own repository for a consumer, so `tools/Test-Consumers.ps1`
  copies the test consumers to a temporary folder first.

**Neutral:**

- A pull request that changes a shared file also changes its copy, so the diff shows each change twice.

## Alternatives considered

1. **Pin AI.SDLC to its last release tag, like a consumer.** Rejected because the work would then use
   the previous version while it builds the next one. A change would be tested only after its release.
2. **Keep no install, and test only through the test consumers.** Rejected because the work here would
   follow none of the process it ships. The test consumers also do not show how the skills behave in
   daily work.
3. **Check the copy only with `-ManifestPath` in CI.** Rejected because the pre-push hook and a local
   run would miss a copy that is behind. The gate picks the source manifest on its own instead.

## Verification

- `Check-SyncManifest.Tests.ps1` proves the gate reads the source manifest and fails a stale copy.
- `Check-LocalPackages.Tests.ps1` proves a local package in an untracked folder fails.
- `Deny-SharedFileEdit.Tests.ps1` proves an edit of the copy is stopped and the source file is named.
- `pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1` runs the core gates, the pack gates
  and the repository gates of AI.SDLC.

## References

- `apm.yml`, `apm.lock.yaml` and `aisdlc.json` at the repository root.
- `core/.apm/skills/ai-sdlc-gates/scripts/Check-SyncManifest.ps1` and
  `core/.apm/skills/ai-sdlc-gates/scripts/Check-LocalPackages.ps1`.
- `core/.apm/skills/ai-sdlc-hooks/scripts/Deny-SharedFileEdit.ps1`.
- [Own skills, agents and hooks](../../core/.apm/skills/ai-sdlc-handbook/references/consumer-own.md) - the rule for local packages.
- APM manifest schema, local path dependencies: https://microsoft.github.io/apm/reference/manifest-schema/
- APM lockfile spec, `local_path` and the hash of a local package: https://microsoft.github.io/apm/reference/lockfile-spec/

## Related

- [ADR 0001](0001-ai-sdlc-is-shared-as-apm-packages.md) - the packages this repository installs.
- [How AI.SDLC is built](../overview.md) - the section on the self install.
- [ADR index](README.md) - the list of decisions in this repository.
