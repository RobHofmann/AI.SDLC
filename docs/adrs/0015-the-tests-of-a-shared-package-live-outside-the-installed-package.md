---
story: "#45"
phase: governance
step: write-adr
intent:
  assumption: "APM installs the whole skill folder and has no setting that leaves single files out of an install"
  decision-drivers:
    - "an update pull request in a consumer shows only the files that consumer runs"
    - "every test of a shared script still runs in AI.SDLC and in the test consumers"
    - "a test still finds its script without a helper it would first have to find"
relates:
  runner: tools/Invoke-PesterParallel.ps1
  coverage: tools/PesterCoverage.psm1
  manifest: tools/Update-SyncManifest.ps1
  consumers: tools/Test-Consumers.ps1
  update: core/.apm/skills/ai-sdlc-hooks/scripts/New-AiSdlcUpdatePullRequest.ps1
because:
  runner: "maps a changed script to its test in the tests tree"
  coverage: "maps a test back to the scripts it measures"
  manifest: "stops the build when a test file sits under a package folder APM installs"
  consumers: "copies the tests next to the installed scripts of a test consumer and runs them there"
  update: "tells the reviewer that the files under .claude/ are a generated copy, tested in AI.SDLC"
---

# ADR 0015: The tests of a shared package live outside the installed package

**Status:** Accepted
**Date:** 2026-11-26
**Supersedes:** none
**Superseded by:** none

## Context

A shared script kept its Pester test next to it, in `<package>/.apm/skills/<skill>/scripts/`. APM
installs that folder into every consumer, so each consumer got the test files and one test helper
under `.claude/`. No consumer runs them: its own gates run Pester only on its own folders.

So an update pull request in a consumer showed test changes that the consumer never runs, and a
reviewer had to read past them.

Two sources say APM v0.31.0, the version this repository pins, cannot leave single files out of an
install:

- The APM page on writing primitives says APM copies the whole skill folder, with `scripts/` and
  every other folder in it.
- The APM manifest schema has no field that leaves files out of an install. `compilation.exclude`
  only applies to `apm compile`, and `includes:` only to `apm pack`.

## Decision

**1. A test lives in a mirror tree.** The test of `<package>/.apm/<path>/X.ps1` is
`<package>/tests/<path>/X.Tests.ps1`. The test helper `DocToolTestHarness.psm1` lives in the tests
tree too. APM installs only `.apm/`, so no test reaches a consumer.

**2. A test finds its script through one path swap.** Each test sets `$script:ScriptFolder` from
`$PSScriptRoot`, with the `tests` folder before `skills` swapped for `.apm`. When the test sits next
to an installed script, the path holds no such folder, and the value stays `$PSScriptRoot`.

**3. The tools map the same way.** `Invoke-PesterParallel.ps1 -Changed` runs the test of a changed
script from the tests tree, and `PesterCoverage.psm1` measures the scripts in `.apm/` for each test.

**4. The build refuses a test in a package folder.** `Update-SyncManifest.ps1` stops on a
`*.Tests.ps1` or `*TestHarness.psm1` file under any `.apm/` folder, and names the mirror path. It
lists the names of the kept tests as `sharedTests`. So `Check-DocDrift.ps1` does not report a page
that names one of them as a file that is gone.

**5. The test consumers still run every test.** `Test-Consumers.ps1` checks that the install left no
test file. Then it copies the tests next to the installed scripts of its throwaway consumer copy. It
runs them there as before, because some tests read files of the consumer.

## Consequences

**Positive:**

- A change that only touches tests no longer reaches a consumer.
- An update pull request holds only files a consumer runs, and it says that `.claude/` is a generated
  copy, reviewed and tested in AI.SDLC.
- No test is lost: the pull request workflow and the test consumers run the same tests as before.

**Negative:**

- The path swap lives in two places: inline in each test, and in `PesterCoverage.psm1`.
- The first update after this change deletes the old test files in each consumer, so that one pull
  request is large.
- A test no longer sits next to its script, so a reader looks in the tests tree for it.

**Neutral:**

- A consumer changes no file or setting. A consumer's own tests stay next to its own scripts.

## Alternatives considered

1. **Keep the tests next to the scripts.** Rejected: every consumer keeps receiving and reviewing them.
2. **Leave the tests out at install time.** Rejected: APM v0.31.0 has no such setting.
3. **Delete the tests after the install.** Rejected: the files then differ from the sync manifest and
   the lockfile, and each `apm install` brings them back.
4. **One shared module for the path mapping.** Rejected: a test would have to find the module before
   it knows where the scripts are.

## Verification

Run `tools/Update-SyncManifest.Tests.ps1`, `tools/PesterCoverage.Tests.ps1`,
`tools/Invoke-PesterParallel.Tests.ps1` and `tools/Test-Consumers.Tests.ps1`. The test consumer job
of `.github/workflows/pr.yml` shows that an install leaves no test file and that the copied tests
pass. A change that ships tests to consumers again needs a new ADR that supersedes this one.

## References

- #45: the story.
- APM, writing primitives, https://microsoft.github.io/apm/producer/write-primitives/, read on 2026-11-26.
- APM manifest schema, https://microsoft.github.io/apm/reference/manifest-schema/, read on 2026-11-26.

## Related

- [ADR index](README.md) - every decision of this repository.
- [ADR 0003](0003-ai-sdlc-installs-its-own-packages-from-its-own-source.md) - the self install, which also loses the test copies.
- [How AI.SDLC is built](../overview.md) - the packages, the self install and the pipelines.
- [tools](../tools.md) - the scripts that run the tests and the test consumers.
