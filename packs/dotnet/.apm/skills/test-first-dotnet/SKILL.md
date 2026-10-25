---
name: test-first-dotnet
kind: knowledge
user-invocable: false
description: >
  How tests are written first and coverage is measured in a .NET repository. It covers red, green,
  refactor; xUnit with Moq and AutoFixture; tests that mirror src/; the Story trait. It also covers the Arrange,
  Act, Assert markers, the coverage ratchet with the run settings, and 80% on new code in SonarCloud.
  Use when writing or changing C# behaviour and its tests, or when mapping acceptance criteria to
  tests. Also use when reading a coverage result, or when the test-analyzer agent reviews a diff. Do
  NOT use to run the whole pipeline locally (run-preflight) or to decide the order of the build steps
  (implement).
---

# Test first in .NET

Use this when a change adds or changes C# behaviour. `implement`, `refactor` and `fix-pr-feedback`
load it when they build, the `builder` agent reads it, `fix-bug` loads it at its reproduce step, and
the `test-analyzer` agent preloads it.

## The loop

1. **Red.** Write the test for one acceptance criterion first, and run it. See it fail, for the reason
   you expect. A test written after the code tends to encode the bug as the intended behaviour.
2. **Green.** Write the least code that makes it pass.
3. **Refactor.** Clean up with the tests green. Then take the next criterion.

A defect fix starts with a failing test that reproduces the defect.

**Test only at agreed seams.** A seam is the public boundary where you observe behaviour without reaching
inside. The plan names the seams under test, with what each one catches and misses. Write tests there,
never against internals. A seam the plan does not name is a scope question for the plan, not a test.
The one exception is the reproduction test of `fix-bug`, written at triage before a plan exists, at
the seam that reaches the bug. The plan then names that seam.

## Anti-patterns

- **Tied to the implementation**: it mocks an internal class, tests a private method, or checks
  through a side channel. A database query instead of the interface is one. The tell: it breaks on a
  refactor while the behaviour stays the same.
- **Tautological**: the assertion works out the expected value the way the code does, so it passes by
  construction. Take the expected value from an independent source: a known literal, a worked example,
  the spec.
- **Horizontal slicing**: all tests first, then all code. The tests then check imagined behaviour.
  Work in vertical slices: one test, one minimal change, repeat.

## The shape of a test

- **Framework.** xUnit, Moq for mocks, AutoFixture for data. Do not let AutoFixture pick the value the
  test is about; set it by hand so the assertion reads.
- **Layout.** Test projects under the test root (`paths.testRoot` in aisdlc.json) mirror the source
  root (`paths.sourceRoot`), for example `tests/Shared.StockLevel.Tests` for `src/Shared.StockLevel/`.
- **Story trait.** Every new test class carries `[Trait("Story","#42")]` with the story key, the
  number of the issue (`owner/repo#42` for an issue in another repository). `LEGACY-0` marks a test
  class that predates the rule. `Check-StoryTraits.ps1` blocks a class without one.
  There is no per-criterion `AC` trait; the Success Criteria section of the story says how each criterion is covered.
- **AAA markers.** Every test has `// Arrange`, `// Act` and `// Assert`; C10 keeps them. A test
  project needs no doc comments. A pure construction test may merge `// Arrange` and `// Act`.
- **Real assertions.** Assert on behaviour. A test that only runs a Moq `Verify` on a call proves the
  call happened, not that the result is right.
- **Constructors.** Mock every dependency; never pass `null`.
- **Controller scope.** No controller test for an action that only forwards to a service. When one is
  needed, assert the `ActionResult` type and the status code.
- **Private members.** Drive a class through its public API. No reflection into our own private
  members.
- **Logging and nullable traps.** A logging extension that checks `IsEnabled` first needs `IsEnabled`
  stubbed in the test. In a nullable-enabled test project, use the annotated `Verify` form. Both
  are in the Testing section of [the C# conventions page](/.claude/skills/csharp-generation-smells/references/csharp.md#testing).
- **DI registration.** A new `Add*()` method joins the registration tests, when the repository has
  a test that builds every `Add*()` method.

## Coverage (clause C04)

- **The ratchet blocks.** Total line coverage must not drop below the baseline
  (`paths.coverageBaseline` in aisdlc.json). Do not move the baseline in the same change to make a drop pass.
- **New code targets 80% or more** in SonarCloud. The ratchet is a floor, not the target.
- **Always pass the run settings**, or the figure counts test code and third-party packages:

```bash
dotnet test <paths.solution> --collect "Code Coverage" --settings <paths.runSettings>
```

- That run writes binary `.coverage` files, which `Check-Coverage.ps1` cannot read. Merge them to
  XML first: `dotnet-coverage merge --output coverage.xml --output-format xml <files>`.
- Read the result with `Check-Coverage.ps1 -CoverageFile coverage.xml`. The pre-flight at the end of
  `/wrap-up` does all three steps.
- Do not add `[ExcludeFromCodeCoverage]` to lift a number. Say in the pull request why a part cannot be
  tested.

## Mapping criteria to tests

For the evidence record at Checkpoint Bravo, list each acceptance criterion with the test that asserts it. A
criterion that no unit test can check is marked as a check by hand, and says what was checked. Never
mark a criterion done on your own judgement (C09); show the test and leave the sign-off to a person.

## Sources

- [C# conventions, Testing](/.claude/skills/csharp-generation-smells/references/csharp.md) - the full test style.
- [Run pre-flight](/.claude/skills/run-preflight/SKILL.md) - running the PR checks locally.
- [Constitution](/.claude/skills/ai-sdlc-handbook/references/constitution.md) - C04, C09, C10.
- The seams rule and the anti-patterns come from `skills/engineering/tdd/SKILL.md` in
  [mattpocock/skills](https://github.com/mattpocock/skills), MIT licence, Copyright (c) 2026 Matt Pocock.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).
