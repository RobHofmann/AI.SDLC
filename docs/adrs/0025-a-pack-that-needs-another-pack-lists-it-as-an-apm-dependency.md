---
story: "#75"
phase: governance
step: write-adr
intent:
  assumption: "APM installs a pack that another pack lists under dependencies, also when a consumer installs that pack from git at a ref (checked by a probe)"
  decision-drivers:
    - "a repository with only CSS or JavaScript could not take those rules without the blazor pack"
    - "a Blazor repository needs the CSS and JavaScript rules too, and should not have to list them by hand"
relates:
  blazor: packs/blazor/apm.yml
  gate: core/.apm/skills/ai-sdlc-gates/scripts/Check-SyncManifest.ps1
  manifest: tools/Update-SyncManifest.ps1
because:
  blazor: "the first pack that lists other packs as APM dependencies"
  gate: "counts a pack that an installed pack depends on as installed"
  manifest: "writes the dependencies of each pack into the sync manifest"
---

# ADR 0025: A pack that needs another pack lists it as an APM dependency

**Status:** Accepted
**Date:** 2026-11-26
**Supersedes:** none
**Superseded by:** none

## Context

The Razor, CSS and JavaScript rules sat in one skill of the `blazor` pack. So a repository with only
CSS or JavaScript could not take those rules without the Blazor pack. Issue #75 puts CSS and JavaScript
in packs of their own. A Blazor app still has style sheets and JavaScript modules, so every repository
with the `blazor` pack needs the other two as well.

Until now no pack needed another pack. A probe with APM 0.31.0, the version that `Install-Apm.ps1`
pins, showed that APM installs a pack that a local package lists under `dependencies: apm:`. The lock
file records it with `resolved_by` and the `local_path` of the dependency.

## Decision

1. **A pack that always needs another pack lists it in its own `apm.yml`**, under `dependencies: apm:`,
   as a path next to it: `- ../css`. The `blazor` pack lists `css` and `javascript`.
2. **The sync manifest records the dependency.** `tools/Update-SyncManifest.ps1` writes each such list
   as `dependencies` of the pack. `Check-SyncManifest.ps1` counts a pack that an installed pack depends
   on as installed, so its files are expected and not reported as left over.
3. **The consumer lists only the pack it asked for.** A Blazor repository keeps `packs/blazor` in its
   `apm.yml`. A repository without Blazor lists `packs/css` or `packs/javascript` on its own.
   `tools/Add-AiSdlcConsumer.ps1` knows both packs, for `-AddPacks css,javascript`.

## Consequences

**Positive:**

- A repository with only JavaScript or CSS takes those rules on their own.
- A Blazor repository gets all three skills with one line in `apm.yml`, and the update moves one line.

**Negative:**

- `Get-AiSdlcApmPack` reads only `apm.yml`. So a pack that comes as a dependency does not count for the
  gate runner. The `css` and `javascript` packs ship no gate, so nothing is missed. A dependency pack
  that ships a gate needs that function to read the manifest too.
- A dependency pack needs the same source and ref as the pack that lists it. A second probe installed
  `packs/blazor` from git at a branch of AI.SDLC: APM took `../css` from the same repository and ref,
  as a git package (`virtual_path: packs/css`, no `local_path`). The `-Upgrade` run of
  `tools/Test-Consumers.ps1` for the `full` consumer checks the same form in every pull request.

**Neutral:**

- The test consumers `blazor-only` and `javascript-only` show both forms in every pull request build.

## Alternatives considered

1. **The setup script adds `css` and `javascript` with `blazor`.** Rejected, because an existing Blazor
   consumer would have to edit its `apm.yml` by hand, and a person who adds `blazor` later can forget
   the other two.
2. **Keep the CSS and JavaScript rules inside the `blazor` pack.** Rejected, because a repository
   without Blazor then gets no CSS or JavaScript rules.

## Sources

- The probes, on APM 0.31.0: a consumer with only the local `packs/blazor` got `css-conventions` and
  `javascript-conventions`, with `resolved_by: _local/blazor` in the lock file. A consumer with
  `packs/blazor` from git at a ref got both too, resolved from the same repository and ref.
- [APM dependencies](https://microsoft.github.io/apm/guides/dependencies/) - the `dependencies: apm:`
  list of a package. Single-sourced; the probe is the second, first-hand check.

## Related

- [ADR 0017](0017-the-shared-code-rules-and-the-review-agents-live-in-core.md) - the file type table
  that maps `.css` and `.js` to the new skills.
- [ADR 0001](0001-ai-sdlc-is-shared-as-apm-packages.md) - how the way of working is shared as packages.
- [blazor](../packages/blazor.md) - the first pack that lists other packs.
