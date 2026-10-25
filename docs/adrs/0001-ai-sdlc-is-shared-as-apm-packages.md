---
story: "#1"
phase: governance
step: write-adr
intent:
  assumption: "APM keeps installing a subfolder of one git repository at a pinned tag, writes a lock file with a hash per file, and leaves a hand-written AGENTS.md alone"
  decision-drivers:
    - "every repository needs the same way of working, and a copy per repository drifts from the first change"
    - "every agent tool must read the same installed files, so they must land in the repository and not in a user folder"
    - "a hand edit to a shared file must fail a check, not show up months later as a quiet fork"
relates:
  manifest: core/apm.yml
  config: core/.apm/skills/ai-sdlc-gates/scripts/AiSdlcConfig.psm1
  agents: core/.apm/skills/ai-sdlc-gates/scripts/Sync-AgentsFile.ps1
  apm: core/.apm/skills/ai-sdlc-gates/scripts/Install-Apm.ps1
  layout: core/.apm/skills/ai-sdlc-handbook/references/layout.md
because:
  manifest: "the package that every consumer installs"
  config: "the one module that reads aisdlc.json for every shared script"
  agents: "the script that writes the shared parts of AGENTS.md between markers"
  apm: "the pinned, digest-checked APM install"
  layout: "the handbook page that shows where the installed files land and how to pin a version"
---

# ADR 0001: AI.SDLC is shared as APM packages

**Status:** Accepted
**Date:** 2026-10-24
**Supersedes:** none
**Superseded by:** none

## Context

AI.SDLC is a way of working for an agent and a person: skills, agents, hooks, gates and handbook pages.
Every repository that uses it needs the same files. A copy per repository drifts from the first
change, and nothing shows which copy is right.

Four facts shape the choice:

- Claude Code reads skills from `.claude/skills/` and agents from `.claude/agents/` inside the
  repository. GitHub Copilot CLI reads the same folders ([ADR 0004](0004-two-human-checkpoints-and-one-skill-model.md)).
- APM (Agent Package Manager) installs a package from a subfolder of a git repository at a pinned
  `ref`. It writes `apm.lock.yaml` with a content hash per package (APM manifest schema, APM lockfile spec).
- The gates and the git hooks must work in every repository, whatever its folder layout.
- GitHub Copilot reads `AGENTS.md`, not `.claude/rules/` (GitHub Copilot docs on repository instructions).

## Decision

**1. One repository holds the shared files as APM packages.** It has a `core/` package and one pack
per technology or tool in `packs/<name>/`. Each package has an `apm.yml` and `.apm/{skills,agents,hooks}`.
One version tag covers the whole repository.

**2. A consumer installs `core` and the packs it needs, pinned to a tag.** Its `apm.yml` names each
package with `git:`, `path:` and `ref:`. It targets `claude` only, because every agent tool reads
`.claude/`. The consumer commits `apm.yml`, `apm.lock.yaml` and the installed files. So a fresh clone
and the pull request view show them without running APM.

**3. Installed files are read-only.** A shared file is a path that `apm.lock.yaml` lists. The hook
`Deny-SharedFileEdit.ps1` stops an agent that edits one and names its source. `apm audit --ci` fails
on a hand edit, and `apm install --frozen` fails on a lock that does not match. The gate
`Check-SyncManifest.ps1` compares each installed file with `sync-manifest.json` by git blob hash. That
manifest exists because APM can skip a file and still write a clean lock.

**4. A repository says where it keeps its things in `aisdlc.json`.** It names the packs, the docs
roots, the build command, the tracker settings and its own gates. Shared scripts read it through
`AiSdlcConfig.psm1` and never name a repository's folders.

**5. Scripts live in the `scripts/` folder of a skill.** APM installs a skill with all its files. The
core gates and the gate runner are in the `ai-sdlc-gates` skill. The hook scripts and git hooks are in
the `ai-sdlc-hooks` skill. Each package lists its gates in a `gates.json`, and `Invoke-LocalGates.ps1`
runs the gates of the core and of the installed packs. A hook command calls its script by a path
relative to the repository. APM rewrites a hook path that points into a package. On Windows the
rewritten command failed under the shell Claude Code uses (APM hooks docs, Claude Code hooks reference).

**6. The shared part of `AGENTS.md` is written between markers.** APM never overwrites a hand-written
`AGENTS.md` (APM compile reference). So each package ships its part as `assets/agents-<package>.md`.
`Sync-AgentsFile.ps1` writes it between `<!-- ai-sdlc:<package>:start -->` and
`<!-- ai-sdlc:<package>:end -->`. Its `-Check` mode is a core gate. The shared parts count toward the
size limit of [ADR 0007](0007-agents-md-has-a-size-limit.md).

**7. Every file has LF line endings.** `.gitattributes` holds `* text eol=lf`. APM hashes a package over
its raw bytes (APM lockfile spec). With `* text=auto`, a Windows checkout writes CRLF (git attributes
docs), so the hash differs from the one CI computes and `apm install --frozen` refuses the install.

**8. APM itself is pinned.** `Install-Apm.ps1` downloads one pinned release over HTTPS and checks its
SHA-256 against `apm-version.json`. On a mismatch it installs nothing and fails. It never pipes an
install script into a shell. A new APM version is a change to that file, in a pull request.

**9. Handbook pages live inside a skill.** APM installs skill files into the repository, where they are
committed. A docs page outside a skill would not be installed. So the process pages are in
`references/` of the `ai-sdlc-handbook` skill, and the doc gates treat `.claude/skills/*/references/`
as read-only pages a repository page may link to.

**10. A clause ID shows where the clause lives.** A core clause keeps its C number. A pack clause
carries the pack prefix, such as `DOTNET-01`. A retired C number is never given to another clause
(the [constitution](../../core/.apm/skills/ai-sdlc-handbook/references/constitution.md)).

## Consequences

**Positive:**

- One copy of every shared file. A fix reaches each repository through a version bump.
- A new repository gets the whole way of working with `aisdlc.json`, `apm.yml` and one install.
- A repository gets only the gates and pages of the technologies it uses.
- A hand edit to a shared file fails the check in the consumer, and names its source.
- A changed or tampered APM download fails before it runs, because its digest is checked.

**Negative:**

- A fix to a shared file takes two pull requests: one here with a tag, then a version bump in each
  consumer.
- The work depends on APM, a young tool. A breaking change in APM can stop installs. The installed
  files are committed, so work goes on while it is fixed.
- The installed files in each consumer are copies, so a version bump has a large diff.
- On Windows with long paths switched off, a deep install fails. `Install-AiSdlc.ps1` checks for it and
  says how to switch it on.

**Neutral:**

- `.claude/settings.json` and `AGENTS.md` are owned by the repository. Only their shared parts are
  checked.

## Alternatives considered

1. **Copy the files into each repository.** Rejected because each copy drifts from the first change,
   and nothing shows which copy is right.
2. **Git submodules with a sync script.** Rejected. A fresh clone needs `git submodule update --init`
   before any skill exists, and a skill must sit in `.claude/skills/`. The sync script would copy files
   anyway, which is APM's install without its lock file and drift check.
3. **A plugin marketplace alone.** Rejected because Claude Code copies a plugin into a cache outside
   the repository. CI, the pull request view and another agent tool then see different files.

## Verification

- `Check-SyncManifest.Tests.ps1`, `Deny-SharedFileEdit.Tests.ps1`, `Sync-AgentsFile.Tests.ps1` and
  `Install-Apm.Tests.ps1` next to their scripts cover the drift check, the edit stop, the markers and
  the digest check.
- `Invoke-LocalGates.ps1 -List` shows which gates a repository runs. A repository without the `dotnet`
  pack lists no .NET gate.
- `tools/Test-Consumers.ps1` installs the packages into test consumers and runs their gates.
- Not covered by a test: a breaking change in a new APM release. The pinned version guards against it.

## References

- `core/apm.yml` and `packs/*/apm.yml` - the packages.
- `core/.apm/skills/ai-sdlc-gates/scripts/Check-SyncManifest.ps1` and `sync-manifest.json` - the drift check.
- `core/.apm/skills/ai-sdlc-hooks/scripts/Deny-SharedFileEdit.ps1` - the edit stop.
- `core/.apm/skills/ai-sdlc-gates/scripts/Install-Apm.ps1` and `apm-version.json` - the pinned APM.
- `.gitattributes` - the LF rule.
- APM documentation: https://microsoft.github.io/apm/
- APM manifest schema: https://microsoft.github.io/apm/reference/manifest-schema/
- APM lockfile spec, hashes and line endings: https://microsoft.github.io/apm/reference/lockfile-spec/
- APM hook path rewrite: https://github.com/microsoft/apm/blob/main/docs/src/content/docs/producer/author-primitives/hooks-and-commands.md
- APM never overwrites a hand-written file: https://github.com/microsoft/apm/blob/main/docs/src/content/docs/reference/cli/compile.md
- Claude Code hooks reference: https://code.claude.com/docs/en/hooks
- Which files GitHub Copilot reads: https://docs.github.com/en/copilot/how-tos/configure-custom-instructions/add-repository-instructions
- Git line endings: https://git-scm.com/docs/gitattributes
- Git submodules: https://git-scm.com/book/en/v2/Git-Tools-Submodules

## Related

- [ADR 0002](0002-distribution-auth-and-updates-on-github.md) - how a consumer gets the packages and a new version.
- [ADR 0003](0003-ai-sdlc-installs-its-own-packages-from-its-own-source.md) - AI.SDLC installs its own packages.
- [ADR index](README.md) - the list of decisions in this repository.
