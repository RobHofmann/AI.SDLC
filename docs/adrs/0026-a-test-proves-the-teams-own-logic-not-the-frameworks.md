---
story: "#78"
phase: governance
step: write-adr
intent:
  assumption: "a test of framework behaviour adds upkeep and no safety, while one registration test without the container catches a real gap"
  decision-drivers:
    - "tests that check what a framework already does break on a framework update while our behaviour stays the same"
    - "a missing registration fails only at the first resolution, which a unit test that builds the class by hand cannot see"
relates:
  clause: core/.apm/skills/ai-sdlc-handbook/references/constitution.md
  style: packs/dotnet/.apm/skills/csharp-conventions/references/csharp.md
  agent: core/.apm/agents/test-analyzer.agent.md
because:
  clause: "clause C04 now says a test proves the team's own logic"
  style: "the C# test style and the one registration test"
  agent: "flags a test that only checks framework behaviour as surplus"
---

# ADR 0026: A test proves the team's own logic, not the framework's

**Status:** Accepted
**Date:** 2026-11-27
**Supersedes:** none
**Superseded by:** none

## Context

Clause C04 asked for tests of changed code, but did not say what a test should prove. So a change
that only set up a framework, such as a stop mode on a validator, got tests that checked the
framework. Such a test passes on the day it is written and breaks when the framework changes, while
our behaviour stays the same.

Dependency injection is a special case. A new constructor parameter on a class that the container
builds changes every registration site. The build and the unit tests stay green, because each test
builds the class by hand. The container fails at the first resolution, which can be a user's first
click. The C# rules already asked for a registration test that reads a bare `ServiceCollection`.

## Decision

1. **A test proves the team's own logic.** Clause C04 lists what is own logic, such as a rule, a
   calculation or a branch on a value the team chose. It also lists what is framework behaviour, such
   as a stop mode, the order of rules or attribute routing. Wiring that holds a decision the team wrote is
   own logic; that decision gets the test. An acceptance criterion that names a visible result wins.
2. **One registration test is the only wiring test.** It checks that the team's own `Add*()` method
   registers every dependency of the team's own class, without building the container. A test that
   builds the container to see whether a service resolves stays out.
3. **The `test-analyzer` agent flags** a new test that only checks framework behaviour, or builds the
   container, as surplus, and asks for no test of wiring.
4. **The constitution version moves to 1.1**, because a core clause changed for every consumer.

## Consequences

**Positive:**

- Fewer tests that break on a framework update, and reviews that name the line between the two.
- The registration test keeps catching a missing registration before a user does.

**Negative:**

- No gate can tell own logic from wiring, so the line rests on code review and the agent.
- A missing registration outside the registration test shows only when the service is first resolved.

## Alternatives considered

1. **No registration test at all.** Rejected, because the container then fails at a user's first click
   for a gap the team could catch cheaply.
2. **A test that builds the container.** Rejected, because it tests the container, needs every outside
   dependency to be reachable, and fails for reasons that are not ours.

## Sources

- Microsoft [unit testing best practices for .NET](https://learn.microsoft.com/en-us/dotnet/core/testing/unit-testing-best-practices),
  which asks a test to check the behaviour of the code under test.
- Microsoft [dependency injection in .NET](https://learn.microsoft.com/en-us/dotnet/core/extensions/dependency-injection),
  which says a service is resolved when it is first asked for.

## Related

- [ADR 0017](0017-the-shared-code-rules-and-the-review-agents-live-in-core.md) - the `test-analyzer`
  agent that upholds the line.
- [ADR 0015](0015-the-tests-of-a-shared-package-live-outside-the-installed-package.md) - where the tests
  of AI.SDLC itself live.
