---
story: "#63"
phase: governance
step: write-adr
intent:
  assumption: "a story that fits on one screen and has at most 5 plain criteria makes one small pull request"
  decision-drivers:
    - "an issue with seven or eight unbounded sections does not fit on one screen at Checkpoint Alpha"
    - "an issue with many criteria makes one big pull request that is hard to review"
    - "many readers of kept text are not native English speakers"
    - "every open issue in the backlog uses the old form, so the old form must still build"
relates:
  language: core/.apm/skills/ai-sdlc-handbook/references/language.md
  constitution: core/.apm/skills/ai-sdlc-handbook/references/constitution.md
  conventions: packs/github-issues/.apm/skills/github-issue-conventions/SKILL.md
  template: packs/github-issues/.apm/skills/write-story/references/story-template.md
  reviewer: packs/github-issues/.apm/agents/draft-reviewer.agent.md
  architect: core/.apm/agents/architect.agent.md
  test: core/tests/skills/ai-sdlc-gates/scripts/StoryTemplate.Tests.ps1
  docs: docs/packages/github-issues.md
because:
  language: "holds the ASD-STE100 rules in two lists, in our own words"
  constitution: "clause C11 now names the ASD-STE100 rules (version 1.1)"
  conventions: "sets the section order, the budgets and the limit of 5 criteria"
  template: "shows the six sections and the old form"
  reviewer: "fails a section over its budget, a criterion that names code, and an issue over the limit"
  architect: "the plan carries a Proof line for each criterion"
  test: "checks the template, the limits, the readers and the Proof line"
  docs: "the technical page of the github-issues package"
---

# ADR 0023: A story has six sections with budgets, at most 5 plain criteria, and follows ASD-STE100

**Status:** Accepted
**Date:** 2026-11-26
**Supersedes:** none
**Superseded by:** none

## Context

An issue had seven sections with no size limit, and a dev-ready story could add an eighth. Such an
issue often did not fit on one screen, so it read slowly at Checkpoint Alpha. An issue with many
criteria made one big pull request. The conventions also let a criterion name code when the check was
at that level. So a refinement talked about build detail and not about the result.

The template started with the background and an ELI5, and the goal came third. Clause C11 set the
CEFR levels for kept text, but gave no rule for the shape of a sentence.

ASD-STE100 is a controlled language for technical text. ASD holds the copyright and the trademark of
the standard and its dictionary. We read two public articles about Issue 9 of January 2025, not the
standard itself.

Every open issue in this backlog uses the old form, with `✅ Success Criteria`. A reader that stops on
the old form stops the build loop.

## Decision

1. **A new issue has six sections in this order:** goal, background (at most 3 bullets), approach (at
   most 5), value (at most 3), acceptance criteria, risks (at most 3). It has no ELI5 and no Technical
   Implementation section; the plan step of `implement` writes the build plan. The update sections
   stay after the risks.
2. **The criteria heading is `✅ Acceptance Criteria`.** An issue with the heading `✅ Success Criteria`
   has the old form, with its ELI5, its 5 background bullets and its limit of 8 criteria. Every skill
   and agent that reads an issue accepts both headings. An issue in the old form keeps its form unless
   the person asks.
3. **A story, bug or task has at most 5 criteria, or 8 in the old form.** An epic and a spike have no
   limit. A criterion uses plain words and names no file, class, setting or rule ID. Docs, ADRs and
   gate results are the definition of done, not criteria. `draft-reviewer` fails a section over its
   budget and an issue over the limit; the person may keep either on purpose at Checkpoint Alpha.
4. **The plan names the proof of each criterion.** The `architect` plan has a `Proof:` line. A
   criterion with no proof is a HIGH finding. The `builder` reports each new test with the criterion
   it proves.
5. **The ASD-STE100 rules are part of C11.** `language.md` states them in our own words, with links,
   in two lists: rules for every language and rules for English only. We do not add the dictionary.
   Where an STE rule is stricter than the CEFR rule, the STE rule wins. No gate checks the rules except
   the limit of 25 words a sentence; code review checks the rest. The constitution moves to version 1.1.

## Consequences

**Positive:**

- A refinement reads a short issue that starts with the goal and talks about the result.
- Every new criterion has a proof in the plan, so none passes unseen.
- Kept text follows one simple set of sentence rules.

**Negative:**

- A story with more than 5 criteria needs a split.
- Code review, not a gate, checks the STE rules, so some slips pass.
- The backlog has two forms of issue for some time.
- We did not read the standard, so a rule may differ from Issue 9 in a detail.

## Alternatives considered

1. **Keep the limit of 8 criteria for both forms.** Rejected, because a story with 8 criteria is slow
   to refine and often holds more than one concern.
2. **Use 5 criteria for the old form too.** Rejected, because every open port issue uses the old form
   and some have 5 to 8 criteria. A new limit on them would stop issues that a person already refined.
3. **Change every old issue to the new form.** Rejected, because a person owns the text of an issue,
   and a rewrite gives no gain to an issue that is already refined.
4. **Keep the ELI5.** Rejected, because the goal first already gives the plain reading.
5. **Add the STE dictionary.** Rejected, because ASD holds its copyright.

## Verification

- `core/tests/skills/ai-sdlc-gates/scripts/StoryTemplate.Tests.ps1` checks the six headings in order,
  no ELI5, the budgets, the limit of 5, both headings in the readers, and the `Proof:` line.
- `Check-DocReadingLevel.ps1` checks the sentence length of the pages.
- By hand: read the rules in `language.md` against the sources. The test does not cover this.

## References

The two articles were read on 2026-11-26. The claims about the standard rest on them, so they are
weakly sourced (clause C07).

- ASD-STE100, Issue 9, <https://www.asd-ste100.org>. Free on request; not read.
- Simplified Technical English, <https://en.wikipedia.org/wiki/Simplified_Technical_English>. It
  backs the issue date of January 2025, the 53 writing rules and the limits of 20 and 25 words. It also
  backs the noun cluster of 3 words, the paragraph of 6 sentences, the verb forms, and that ASD holds the copyright.
- tcworld, ASD-STE100 Issue 9,
  <https://www.tcworld.info/e-magazine/column/asd-ste100-issue-9-setting-a-standard-for-technical-documentation>.
  It backs the date of 15 January 2025, the 53 writing rules, and that a free copy comes on request.
- `core/.apm/skills/ai-sdlc-handbook/references/language.md` and `constitution.md`, clause C11.

## Related

- [ADR index](README.md) - the list of decisions in this repository.
- [ADR 0010](0010-the-story-key-is-a-github-issue-number.md) - the story is a GitHub issue.
- [github-issues](../packages/github-issues.md) - the package that holds the template, the conventions and `draft-reviewer`.
- [core](../packages/core.md) - the package that holds the language rules.
