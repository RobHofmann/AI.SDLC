---
story: "#57"
phase: governance
step: write-adr
intent:
  assumption: "an agent that reads only the issue and the diff finds missing and unasked behaviour that a code review misses"
  decision-drivers:
    - "code can follow every rule and still build the wrong thing"
    - "a review that mixes both questions in one list hides the worst finding"
    - "the review agents have no shell, so they cannot read a GitHub issue themselves"
relates:
  agent: core/.apm/agents/spec-reviewer.agent.md
  implement: core/.apm/skills/implement/SKILL.md
  orchestration: core/.apm/skills/ai-sdlc-handbook/references/orchestration.md
because:
  agent: "the agent that runs the spec review"
  implement: "step 7 runs the spec review next to the code review, and step 8 keeps the reports apart"
  orchestration: "the review step, the stop list and the shape of the evidence record"
---

# ADR 0016: A spec review runs next to the code review

**Status:** Accepted
**Date:** 2026-11-26
**Supersedes:** none
**Superseded by:** none

## Context

The review step of `implement` asks whether a change is built right. The `code-reviewer` and
`test-analyzer` agents check the code and the tests against the convention skills. Nothing checks
whether the change builds the right thing. Code can follow every rule and still miss a criterion, or
add behaviour that nobody asked for. A test can also lead the builder to add a constructor parameter
or an interface that only the test uses.

The agents run with the tools `Read`, `Grep` and `Glob`. They have no shell, so they cannot read a
GitHub issue with `gh`.

## Decision

**A spec review runs next to the code review, in its own agent.** At step 7 of `implement`, the
`spec-reviewer` agent compares the diff with the approved issue and the governing ADRs. It reports
three kinds of finding: a criterion that is missing or partly built, behaviour no criterion asks for,
and a criterion that is built but wrong. Each finding quotes the criterion. The agent reads criteria
under `✅ Success Criteria` and under `✅ Acceptance Criteria`. An issue with neither heading gives
"no spec available", and the agent invents no criteria.

**The calling session reads the issue.** It runs `gh issue view <n> --json title,body,comments` and
passes the title, the body and the comments to the agent, with the governing ADRs from the context
block. The agent reads the issue as it is at the review, not as it was when the `refined` label was set.
A change to a refined issue goes through `write-story` with the person's go, so the issue as it is now
is the approved one.

**The two reports stay apart.** The evidence record holds the spec review and the code review as two
separate reports, never merged or reranked into one list. `refactor` keeps the behaviour, so it runs
no spec review.

**A test seam adds no product code.** A plan that adds product code only so a test can reach it is a
stop. So is a change where no acceptance criterion maps to a test or a check.

## Consequences

**Positive:**

- A missing criterion shows up before the pull request opens.
- Code that no criterion asks for is named, with the criterion nearest to it.
- The person at Checkpoint Bravo reads two short reports instead of one mixed list.

**Negative:**

- One more agent call per build, on Opus, which costs more than Sonnet.
- The agent only sees what the caller passes. A decision that lives outside the issue and the named
  ADRs does not reach it.

**Neutral:**

- Without agents, the main session answers the three questions itself, as a report of its own.

## Alternatives considered

1. **Add the spec questions to `code-reviewer`.** Rejected because one agent then mixes two questions,
   and the reasoning about how the code is built colours the question whether it is the right thing.
2. **Give the spec reviewer a shell so it reads the issue itself.** Rejected because a reviewer stays
   read-only. A shell is a write path, and the caller already has the issue.
3. **Read the issue as it was when the `refined` label was set.** Rejected for now. It needs the edit
   history of the body and the time of the label event from the GitHub GraphQL API, which the walk does
   not read today. The person's go on each change to a refined issue already guards the scope.

## Verification

- `tools/BuildLoopPackaging.Tests.ps1` checks that core ships the `spec-reviewer` agent.
- A check by hand: step 7 of `implement` runs the agent, and `refactor` does not.

## References

- `skills/engineering/code-review/SKILL.md` in [mattpocock/skills](https://github.com/mattpocock/skills) -
  the spec review, its three questions and the rule to keep the two reviews apart. MIT licence.
- `core/.apm/agents/spec-reviewer.agent.md` - the agent.

## Related

- [ADR 0004](0004-two-human-checkpoints-and-one-skill-model.md) - the two human checkpoints this review feeds.
- [ADR 0010](0010-the-story-key-is-a-github-issue-number.md) - the issue the agent compares the change with.
- [ADR index](README.md) - the list of decisions in this repository.
