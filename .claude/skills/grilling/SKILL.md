---
name: grilling
kind: workflow
phase: cross-cutting
persona: any
user-invocable: false
description: >
  Question the person about a plan, a decision or an idea until you share one understanding, from the
  roles that matter, and record the answers and the why for the skill that writes the artifact. Use
  when a story, hypothesis, journey, PRD or ADR is about to be drafted and its scope or reason is not
  settled, or when the person wants their thinking tested. Do NOT use to navigate the lifecycle
  (guide-me) or to write the artifact itself.
---

# Grilling

Owned by no single persona; it is the questioning step that the authoring skills call before they
draft. It is an internal step: a person types `/grill-me`, and `write-story`, `write-hypothesis`,
`draw-customer-journey`, `write-prd` and `write-adr` call it inline.

Interview the person until you reach a shared understanding. Map the work as a **design tree**: every
decision branches into the decisions that hang off it. Two things are ours on top of the upstream
method. The questions come from the roles the work touches, from the
[persona registry](/.claude/skills/ai-sdlc-handbook/references/personas.md). And the answers and the why go
back to the authoring skill, phrased for the fields of the artifact it writes. A docs impact names the
pages the answers change.

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
❓ **Q1** - **<question title>**: <question body, maybe several paragraphs>

- <choice A>
- <choice B>

➡️ **Advice:** <your recommended answer>

---

❓ **Q2** - **<question title>**: <question body, maybe several paragraphs>

- <choice A>
- <choice B>

➡️ **Advice:** <your recommended answer>
```

Word each question so "yes" accepts your recommended answer. The label follows the chat language, so a
Dutch chat writes `➡️ **Advies:**`.

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

## Check words and claims

Check the person's words and claims while the rounds run, not after them.

- **A word against the glossary.** The glossary is `glossary.md` in the folder that `paths.functionalDocs`
  in aisdlc.json names. The person may use a word that the glossary defines in another way. Then say so
  at once, and ask which is right: "The glossary says X. You seem to mean Y. Which is it?"
  When the repository has no glossary page, skip this check and say so. Never create the page here.
- **A vague word.** When a word is vague or means two things, propose one exact word: "You say
  'release': do you mean the tag or the re-pin? Those are different things." Prefer the word the
  glossary already uses.
- **A claim against the code.** When the person says how something works, check the code, as for any
  other fact: through a sub-agent, or yourself. When the code says otherwise, name the difference. Then
  ask which is right: "The code stops the whole run. You said one step can go on. Which is right?"
- **A case at the edge.** When the talk is about how two things relate, test it with a specific case.
  Then the person has to say where one thing ends and the other starts.

A word or a claim that is settled goes into the docs impact, in the words of the page that will hold
it. A settled word is its line on the glossary page. Grilling writes no page itself.

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
questions to the `security-reviewer` agent. If you cannot run agents, or the pack of an
agent is not installed, voice that persona yourself from the registry. The main thread voices Designer
/ UX. The agents only read; they never write.

## Inside an authoring run

An authoring skill loads this skill; it does not ask questions of its own. **An open decision always
gets a round before the draft.** This also holds in a skill that says it stops at Checkpoint Alpha:
that stop is for the writes, and it never replaces a round. When there is no open decision, ask no
round, and Checkpoint Alpha says that grilling found none, and why.

Called inline by an authoring skill, a round waits for the person, as above. Called by `write-adr`
inside the build loop, it does not wait; see that skill. The round is a stop, not a gate: the person
can answer, accept the recommended answers with "yes", or say "draft now". Whatever is still open
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
- the "Open questions" list, when the person stopped before the frontier was empty;
- the **docs impact**: each page of the two docs layers that the answers change. For each page, say
  what it will say, in the words of the docs. Write what a reader of the page needs after the change,
  not the questions and the answers pasted in. When no page changes, say "no page changes".

Then hand control back to the authoring skill. It drafts, and shows the draft, the answers and the open
questions at Checkpoint Alpha.

### Where the docs impact goes

Grilling writes no file and no comment. The run decides where the docs impact goes:

- **On a story branch** (a branch named with a story key, as `write-docs` says): hand it to
  `write-docs` at once. Then it lands in the docs on that branch.
- **Before the issue exists:** `write-story` posts it at Checkpoint Alpha as one comment that starts
  with `📚 Docs impact YYYY-MM-DD HH:mm`, never in the body. The build of that issue reads the comment
  as docs scope, and `write-docs` applies it on the story branch.
- **An issue exists, but this is not its branch:** `write-story` posts the same comment after the
  person confirms it.
- **No issue and no branch** (a `/grill-me` run): nothing is written. The person gets the docs impact
  and the way to keep it.

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
- **The draft comes before the round** -> a caller that "stops once, at Checkpoint Alpha" or asks its
  own questions drafts on a guess. An open decision gets its round first; with none, Checkpoint Alpha
  says so and why.
- **A settled word stays in the chat** -> it goes into the docs impact as its line on the glossary
  page. Left in the chat, the next session uses the old word again.
- **The docs impact repeats the answers** -> write what the page will say, in the voice of the page.
  A question and its answer pasted into a page read like minutes, not like docs.
- **A claim is taken from the person without a look at the code** -> check it. A clash found in review
  costs a second draft; a clash found in the round costs one question.

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

- `/write-story` (Product Manager) - the usual caller. It drafts the story from the answers. It saves
  the why into the Goal, Expected Value and Acceptance Criteria (`✅ Success Criteria` in an older issue).
- `/write-hypothesis` (Analyst) and `/draw-customer-journey` (Analyst) - the discovery callers.
- `/write-prd` (Product Manager) and `/write-adr` (Architect) - the callers for larger artifacts.
- `/convene-personas` - to talk to one role or a panel when there is no artifact to draft yet.

## Sources

- Adapted from `skills/productivity/grilling/SKILL.md` in
  [mattpocock/skills](https://github.com/mattpocock/skills), MIT licence, Copyright (c) 2026 Matt Pocock.
  The text is kept close to upstream, and the round format takes its `❓` and `➡️` marks. The choice
  bullets, the `Advice:` label, the persona panel, the sizing and the record are ours. The licence is in
  [LICENSE-upstream.md](LICENSE-upstream.md).
- The checks of words and claims adapt the session rules of `skills/engineering/domain-modeling/SKILL.md`
  in the same repository, under the same licence. We check against the glossary page of
  `paths.functionalDocs`, not a root `GLOSSARY.md`. A settled word goes into the docs impact for
  `write-docs`; grilling does not write it. Its ADR rule is not taken here.
- The methods are adapted from BMAD-METHOD, as [methods.md](references/methods.md) says.
