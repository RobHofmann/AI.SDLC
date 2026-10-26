---
story: "#1"
phase: governance
step: write-adr
intent:
  assumption: "a coverage bar is ignored because the number is wrong or cannot be met, not because the bar is too high, so the fix is the denominator and the shape of the check, never the threshold"
  decision-drivers:
    - "an advisory gate that can never pass is read by nobody, and costs build time to say nothing"
    - "two tools that report two numbers for the same thing leave a reviewer trusting neither"
    - "lowering a threshold to a figure already met records untested code as acceptable"
relates:
  constitution: core/.apm/skills/ai-sdlc-handbook/references/constitution.md
  ratchet: packs/dotnet/.apm/skills/dotnet-gates/scripts/Check-Coverage.ps1
  pester: tools/PesterCoverage.psm1
because:
  constitution: "clause C04, which this decision shapes"
  ratchet: "the ratchet gate as the dotnet pack runs it"
  pester: "the coverage of the Pester runs of this repository"
---

# ADR 0009: Coverage is a ratchet against a baseline

**Status:** Accepted
**Date:** 2026-10-24
**Supersedes:** none
**Superseded by:** none

## Context

A fixed coverage bar on the total of a repository, such as 80%, is a debt figure. In an older code base
it can take years to reach. A gate on it can never pass, so it is set to advisory, and then nobody reads
it. Setting the bar lower to a figure already met is no better: it records untested code as acceptable.

The number itself is often wrong, in two ways:

- **The coverage tool measures code the team does not own.** Without a run settings file, the tool
  instruments every loaded library that has symbols. Third-party packages pull the figure down, and test
  code pulls it up. The two do not cancel out.
- **Files with no agreed way to test them sit in the count.** UI components without a rendering test
  library, browser scripts, program start-up and dependency wiring are in this group. They carry no behaviour worth asserting,
  or a unit test cannot reach them.

A code-quality service and a local gate that count different files report different numbers, and a
reviewer then trusts neither.

## Decision

**1. Fix the denominator. Never lower the threshold.** Both sides use one shared list of left-out files.
The run settings file (`paths.runSettings`) scopes what the coverage tool measures. The exclusions of the
code-quality service scope what it counts. Business logic, controllers, services, validators and
repositories are never left out ([constitution](../../core/.apm/skills/ai-sdlc-handbook/references/constitution.md), C04).

**2. The local gate is a ratchet.** It compares total line coverage with the figure in the baseline file
(`paths.coverageBaseline`). It fails when coverage drops below it, with a small tolerance for the
wobble between runs. A run that beats the baseline passes and prints the figure to record. So raising
the floor is a reviewed commit, not a silent drift.

**3. The fixed target moves to new code.** Coverage on the lines a pull request changes targets 80%. A
code-quality service reports it. Whether that blocks a merge is a setting of the repository.

**4. The ratchet lands blocking.** It is defined to pass on today's code, so it cannot break the build on
the day it ships. Its only failure is a real drop.

**5. Missing configuration fails closed.** No baseline file, a file that is not valid JSON, or no
numeric figure in it fails the gate. A gate that cannot tell a drop from the current state must not
report success. A missing coverage report fails too, because it means the tests did not run.

A pack carries the ratchet for its stack. The `dotnet` pack ships `Check-Coverage.ps1`. AI.SDLC itself
measures its Pester runs with `tools/PesterCoverage.psm1`.

## Consequences

**Positive:**

- The two numbers describe the same code, so a reviewer can act on either.
- A drop blocks, where a fixed bar on the total blocked nothing.
- A new dependency can no longer move the figure.
- 80% on new code is reachable in an ordinary pull request.

**Negative:**

- The left-out files have no automatic coverage check. The real answer for them is a test library that
  can reach them, which is its own decision.
- The list of left-out files exists twice and can drift. A drift shows as the two numbers differing
  again, which is visible but not caught by a gate.
- The baseline is a number in a file, so it can be turned down to make a failing build pass. The pull
  request review is the control on that.
- A wrong pattern in the run settings fails in silence: the coverage tool measures nothing, or everything.
  So the patterns need their own tests.

**Neutral:**

- On the day the denominator is fixed, the total often falls with no test deleted. That is a correction,
  not a drop.

## Alternatives considered

1. **Lower the threshold to a number already met.** Rejected because it records untested code as
   acceptable and leaves the wrong denominator in place.
2. **Remove the coverage condition.** Rejected because it removes the control instead of fixing it.
3. **An exclusion attribute on each left-out type.** Rejected because a code-quality service may read the
   report and not the attribute, and hundreds of attributes cannot be reviewed. One line of patterns can.
4. **Keep the local gate advisory and rely on the service alone.** Rejected because the service judges
   new code only, so nothing would notice the total sliding.
5. **A ratchet with no tolerance.** Rejected because a small wobble would fail a build for a reason
   unrelated to the change.

## Verification

- `packs/dotnet/.apm/skills/dotnet-gates/scripts/Check-Coverage.Tests.ps1` covers the ratchet at, above
  and below the baseline, the tolerance in both directions, and every fail-closed path.
- `tools/PesterCoverage.Tests.ps1` covers how the Pester runs of this repository turn into a coverage file.
- Not covered by a test: whether a code-quality service and the local gate still count the same files.
  Compare the two numbers after a change to the exclusion list.

## References

- [Constitution](../../core/.apm/skills/ai-sdlc-handbook/references/constitution.md) - clause C04.
- `packs/dotnet/.apm/skills/dotnet-gates/scripts/Check-Coverage.ps1` - the ratchet.
- `tools/PesterCoverage.psm1` - the coverage of this repository's own tests.
- Customizing code coverage analysis, run settings: https://learn.microsoft.com/en-us/visualstudio/test/customizing-code-coverage-analysis
- What `sonar.coverage.exclusions` does and does not affect: https://docs.sonarsource.com/sonarqube-server/instance-administration/analysis-functions/analysis-scope/exclude-from-coverage-duplication

## Related

- [ADR 0005](0005-the-gate-contract.md) - the contract the ratchet follows.
- [ADR 0006](0006-hooks-enforce-what-must-happen-every-time.md) - the completeness check, which asks whether tests moved at all.
- [ADR index](README.md) - the list of decisions in this repository.
