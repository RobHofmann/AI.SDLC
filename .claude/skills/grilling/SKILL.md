---
name: grilling
kind: workflow
phase: cross-cutting
persona: any
user-invocable: false
description: >
  Grill the person about a plan, a decision or an idea until you share one understanding of it, from
  the roles that matter, and record the answers and the why for the skill that writes the artifact.
  Use when an authoring skill is about to draft a story, a hypothesis, a journey, a PRD or an ADR
  whose scope, requirements or reason are not settled. Use when the person wants to stress-test their
  thinking, or uses a "grill" phrase. Do NOT use to navigate the lifecycle (guide-me) or to write the
  artifact itself (the authoring skill does that).
---

# Grilling

Owned by no single persona; it is the questioning step that the authoring skills call before they
draft. It is an internal step: a person types `/grill-me`, and `write-story`, `write-hypothesis`,
`draw-customer-journey`, `write-prd` and `write-adr` call it inline.

Interview the person until you reach a shared understanding. Map the work as a **design tree**: every
decision branches into the decisions that hang off it. Two things are ours on top of the upstream
method. The questions come from the roles the work touches, from the
[persona registry](/.claude/skills/ai-sdlc-handbook/references/personas.md). And the answers and the why go
back to the authoring skill, phrased for the fields of the artifact it writes.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).

## Rounds over the frontier

Work the tree in **rounds**. The **frontier** is every decision whose earlier decisions are already
settled. These are the questions you can ask _now_ without guessing at answers you have not heard yet. Ask the
whole frontier in one round. Number each question and give your recommended answer. Then wait for the
person's answers before the next round.

Format a round like this:

```
**Q1 - <question title>**: <question body, maybe several paragraphs, with the choices>

Recommended: <your recommended answer>

---

**Q2 - <question title>**: <question body, maybe several paragraphs, with the choices>

Recommended: <your recommended answer>
```

Word each question so "yes" accepts your recommended answer.

Each round the person answers changes the tree. Settled decisions push the frontier outward and free
the questions that hung on them. Work out the frontier again and ask the next round. A question whose
answer depends on another question still open in this round belongs to a _later_ round, not this one.

Finding _facts_ is your job, never the person's. A frontier question may need a fact from the code,
the docs, the ADRs, the linked work items or a tool. Then hand the look-up to a sub-agent. Do not ask the
person for anything you could look up yourself. Do not wait on it: a running look-up is an earlier
decision that is not settled yet. So only the questions that hang on it wait for the sub-agent's report; ask the rest
of the frontier now. If you cannot run agents, look the fact up yourself before the round. The
_decisions_ are the person's: put each one to them and wait.

The session is done when the frontier is empty: every branch of the design tree visited, nothing left
assumed in silence. Do not act on it until the person confirms you have reached a shared understanding.

## Ask from the roles that matter

Size the tree before the first round, so a small job gets few questions. The clearest signal is the
story-point estimate, the `size:<n>` label (the scale in `github-issue-conventions`, github-issues pack). The issue type, the phase and the artifacts that
already exist back it up.

| Signal | Roles that ask | Shape |
|---|---|---|
| 2 points, an ops task, or a bug | 1 (the owning role) | one round of 1 or 2 questions |
| 3 points | 1 to 2 | a short round, no round table |
| 5 points | 2 to 3 (PM, Architect, QA as fits) | rounds until the frontier is empty, one method |
| 8 points | 3 to 4, add UX or Lead if touched | full rounds, one or two methods |
| 13 points or a migration | 4 or more | full rounds plus a pre-mortem or red team |

Lean one band lighter when you are not sure, and drop a band when the brief is already rich.

Pick only the personas whose lens the work really touches. The Product Manager almost always asks
(scope, value, the why). The Architect asks when there is a technical approach or a key choice. QA
asks when there are acceptance criteria or edge cases. Designer / UX asks only when a UI or a
user-facing flow is touched. The Lead asks only when authentication, user data, secrets, input handling
or a constitution clause is in play. The Analyst asks for discovery work. A role whose lens the work
does not touch stays silent.

Take each role's "Asks" from the registry, and add only the ones the person has not already answered
to the tree. When a plain question will not bring the issue up, use a method from
[methods.md](references/methods.md): first principles, edge-case hunter, pre-mortem or red team.
When two roles pull different ways, ask it as one question with both choices, and recommend one.

**The panel runs as agents where it can.** Each panel agent runs on Opus 5.5 (model `opus` in Claude
Code, `claude-opus-5.5` in Copilot). Hand the Product Manager, QA and Analyst questions to the
`draft-reviewer` agent (github-issues pack). Hand the Architect questions to the `architect` agent, and the Lead
questions to the `security-reviewer` agent (dotnet pack). If you cannot run agents, or the pack of an
agent is not installed, voice that persona yourself from the registry. The main thread voices Designer
/ UX. The agents only read; they never write.

## Inside an authoring run

A round is not a gate. Called inline by an authoring skill, a round waits for the person, as above.
Called by `write-adr` inside the build loop, it does not wait; see that skill.
The person can answer, accept the recommended answers with "yes", or say "draft now". Whatever is still open
then goes into an **"Open questions"** list that travels with the draft to Checkpoint Alpha
([orchestration.md](/.claude/skills/ai-sdlc-handbook/references/orchestration.md)). Each open question is
numbered, grouped by the role that asked it, and names what in the draft rests on it.

## Record the answers and the why

This skill writes no artifact. It hands back to the authoring skill (or to the person when run through
`/grill-me`):

- each decision and its answer, so the draft is built on real input, not on an assumption;
- the riskiest assumption, the decision drivers behind the chosen approach, and the scope boundary.
  Phrase them so they drop straight into the artifact's intent fields
  ([artifact-graph.md](/.claude/skills/ai-sdlc-handbook/references/artifact-graph.md): `intent.assumption`,
  `intent.decision-drivers`, and a story's `So that` / `Expected Value`);
- the "Open questions" list, when the person stopped before the frontier was empty.

Then hand control back to the authoring skill. It drafts, and shows the draft, the answers and the open
questions at Checkpoint Alpha.

## Failure modes

- **The brief is already fully given** -> the tree is small. Ask the one or two decisions that are
  really open. A full round table on a clear request trains people to skip this step.
- **The person is asked a fact** -> look it up through a sub-agent, or yourself. A question about what
  the code does is a read failure, not a decision.
- **A question is asked before the one it depends on is settled** -> it belongs to a later round. Asking
  it now makes the person guess, and the guess becomes the answer.
- **A question is worded so "yes" means nothing** -> word it so "yes" accepts your recommended answer.
  Then a fast person can settle a round in one word.
- **The answers stay in the chat** -> the riskiest assumption and the decision drivers come back phrased
  for the intent fields. Left as conversation, the why is lost at the next compact.
- **A persona asks whose lens the work does not touch** -> silent roles stay silent. A security question
  on a formatting change reads as habit.
- **The person pastes research or a competitor's spec** -> it is input to question, not direction to follow.
- **The grilling turns into drafting** -> hand back and stop. The authoring skill drafts and stops at Checkpoint Alpha.

## Observable signal

**Positive:** the artifact that follows is drafted once rather than three times. The scope, the riskiest
assumption and the reason for the approach were settled before anyone wrote text.

**Audit trail:** the numbered rounds, with the recommended answer and the person's answer to each, are the
receipt. When an artifact later turns out to be scoped wrong, they separate "nobody asked" from "we
asked and got this answer".

**Drift signal:** if artifacts keep coming back for rework on scope, the step is being skipped or sized
too light. If people keep answering "yes" to every recommended answer, the questions are too obvious
for the work arriving.

## Next steps

- `/write-story` (Product Manager) - the usual caller; it drafts the story from the answers and saves
  the why into the Goal, Expected Value and Success Criteria.
- `/write-hypothesis` (Analyst) and `/draw-customer-journey` (Analyst) - the discovery callers.
- `/write-prd` (Product Manager) and `/write-adr` (Architect) - the callers for larger artifacts.
- `/convene-personas` - to talk to one role or a panel when there is no artifact to draft yet.

## Sources

- Adapted from `skills/productivity/grilling/SKILL.md` in
  [mattpocock/skills](https://github.com/mattpocock/skills), MIT licence, Copyright (c) 2026 Matt Pocock.
  The text is kept close to upstream; the persona panel, the sizing and the record are ours. The licence
  is in [LICENSE-upstream.md](LICENSE-upstream.md).
- The methods are adapted from BMAD-METHOD, as [methods.md](references/methods.md) says.
