---
story: "#66"
phase: governance
step: write-adr
intent:
  assumption: "a description of at most 450 characters still routes each prompt to the same skill"
  decision-drivers:
    - "every session loads the description of each skill the model can pick, before the person types anything"
    - "many descriptions used most of the 1024 characters the specification allows"
relates:
  gate: core/.apm/skills/ai-sdlc-gates/scripts/Check-SkillHygiene.ps1
  pattern: core/.apm/skills/ai-sdlc-handbook/references/pattern.md
  prompts: config/skill-routing-prompts.txt
because:
  gate: "fails a model-visible description over 450 characters"
  pattern: "the section Writing the description states the limit"
  prompts: "the routing prompt set that measured the cut"
---

# ADR 0027: A model-visible skill description has at most 450 characters

**Status:** Accepted
**Date:** 2026-11-27
**Supersedes:** none
**Superseded by:** none

## Context

Claude Code and GitHub Copilot load the name and description of every skill the model can pick into
each session. The Agent Skills specification allows up to 1024 characters, and 46 of the 56 shared
skills used more than 450. That text costs context in every session, whether the skill is used or not.

## Decision

1. **A skill the model can load has a description of at most 450 characters**, counted once its YAML
   block is folded. `Check-SkillHygiene.ps1` fails a longer one, in AI.SDLC and in every consumer.
2. **A skill with `disable-model-invocation: true` keeps the 1024 limit**, because no session loads its
   description; only a person starts it.
3. **The gate looks for the trigger words in the description only**, not in the body. The model reads
   the description when it picks a skill.
4. **A cut keeps the `Use when` triggers.** A `Do NOT use` line stays only for a neighbour that a
   repository installs next to the skill.
5. **The routing prompt set lives in `config/skill-routing-prompts.txt`**, with made-up names. A change
   to a description runs the routing layer of `test-skills` on it, before and after.

## Consequences

**Positive:**

- The descriptions of the 51 model-visible skills with a folded block go down from about 34,400 to
  about 22,100 characters, a third less in every session. The routing set of the 28 workflow skills
  goes down from 21,434 to 12,820 bytes.
- A gate keeps the descriptions short, also for a skill added later.

**Negative:**

- A consumer with a skill of its own over 450 characters fails the skill check after it takes this
  release, so the CHANGELOG lists that step.
- A short description has less room for a `Do NOT use` line, so a neighbour can win a prompt that
  baits it. The routing check is the guard.

## Routing result

Three independent judges (Sonnet) picked one skill per prompt from the descriptions only. Two runs
were made, each before and after the cut:

| Run | Skills in the set | Prompts | Before the cut | After the cut |
|---|---|---|---|---|
| Workflow skills | 28 | 66: 56 direct, 9 bait, 1 that fits no skill | 198 of 198 | 198 of 198 |
| Workflow and knowledge skills | 52 | 78: the 66 above, and 12 bait prompts at the line between a workflow and a knowledge skill | 234 of 234 | 234 of 234 |

The knowledge skills are in the second run because the model sees them too; only a person does not.
The set is small, many prompts use the words of a description, and the judges read descriptions only.
So a full score is a signal, not proof, and the set cannot show a gain. A routing miss
after a later change is a reason to sharpen that description, not to raise the limit.

## Alternatives considered

1. **Keep the 1024 limit.** Rejected, because the cost falls on every session of every consumer.
2. **A lower limit, such as 300 characters.** Rejected for now, because the triggers of the larger
   workflow skills did not fit, and the routing result at 450 shows no loss on this set.

## Sources

- [Agent Skills specification](https://agentskills.io/specification), the `description` field and its
  limit of 1024 characters.
- [Claude Code skills](https://docs.claude.com/en/docs/claude-code/skills). It says the name and
  description of each skill load at the start, and the body only when the skill is used.
- The routing run of #66, with the prompt set in `config/skill-routing-prompts.txt`.

## Related

- [ADR 0014](0014-every-rule-has-one-source-of-truth.md) - the limit lives in the gate and in one
  handbook section.
- [ADR 0017](0017-the-shared-code-rules-and-the-review-agents-live-in-core.md) - the code skills whose
  descriptions this cut shortened.
