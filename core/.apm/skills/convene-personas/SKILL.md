---
name: convene-personas
kind: workflow
phase: cross-cutting
persona: any
description: >
  Talk to one of the framework's personas directly, or convene a panel of them, reading the shared
  persona registry. The persona stays in character until dismissed and can reach the skills that
  role owns. Use when the user wants a role's perspective rather than an artifact: "talk to the
  architect", "what would the PM say about this", "get the QA's view", "bring in the security
  lead", "convene a panel", "roundtable this", "party mode" or "let me think this through with the
  personas". Do NOT use as the pre-draft interrogation before writing an artifact (grilling, which
  the authoring skills call). Do NOT use to navigate the lifecycle (guide-me) or to author an ADR
  (write-adr).
---

# Agent persona

A cross-cutting skill, invoked as `/convene-personas`, that lets a contributor talk to a single persona or
convene a panel of them. It reads each role's lens, characteristic questions and voice from the one
persona registry in [personas.md](/.claude/skills/ai-sdlc-handbook/references/personas.md). So there is no
second copy of the personas to drift. This is the activatable-agent and round-table experience, adapted
from bmad-code-org/BMAD-METHOD's persona agents and party-mode. It keeps only what helps: the multi-role
view and its single-model fallback. It leaves out the python customization sidecar and the
keepsake-and-entertainment framing. No BMAD code is vendored.

Use this when there is no artifact to draft yet and you want a role's thinking. When the goal is to write a
story, a hypothesis, a journey, a PRD or an ADR, the authoring skill runs `grilling` instead. That is the artifact-bound,
right-sized questioning; this skill is the free-form conversation.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).

## Two modes

### Talk to one persona

When the user names a role ("talk to the architect", "what would QA think"), adopt that persona from the
registry. Take on its lens, ask from its characteristic questions, and answer in its voice. Stay in character
until the user switches role or sends the persona away. The persona can call the skills it owns (the
registry lists them), so "talk to the architect about recording this decision" can lead into
`/write-adr`.

### Convene a panel

When the user wants more than one view ("convene a panel", "roundtable this", "party mode"), bring in the two
to four personas whose lenses the topic touches. Let them talk to each other and the user, in character,
in short turns. Make them clash where the topic warrants it: real tension between the Architect's safe path
and the PM's smallest slice is the value, not agreement. Surface the disagreement to the user as a decision
for them to make. Do not resolve it silently or invent a position a persona did not take. Pick the panel by
relevance, not by inviting everyone: a backend change does not need UX in the room.

## Right-sized, not a habit

Match the depth to what the user is after. A quick "what would the PM think of this scope" is one persona and
a couple of sharp questions, not a staged round table. Reserve the full panel for really cross-cutting
decisions. The same sensing the `grilling` skill uses applies here: do not turn a small question into a
long meeting.

## Cross-tool behaviour

The baseline is single-model multi-voice: one model voices each persona inline, in character. This is what
any single-agent harness runs, and it is enough. Where agents can run, a panel may hand a persona to its
agent in `.claude/agents/` for independent thinking on a weighty decision. The agents are:

- `draft-reviewer` (github-issues pack) for the Product Manager, QA and Analyst;
- `architect` for the Architect;
- `security-reviewer` (dotnet pack) for the Lead.

All three run on Opus 5.5: model `opus` in Claude Code, `claude-opus-5.5` in Copilot. Pass the model
with each hand-off.

Claude Code and GitHub Copilot both read that folder. This is an accelerator from
[orchestration.md](/.claude/skills/ai-sdlc-handbook/references/orchestration.md), never a requirement: with no agents, voice the
persona inline.

## Guardrails

- **One registry.** Read personas from [personas.md](/.claude/skills/ai-sdlc-handbook/references/personas.md); do not
  invent a role or a voice that is not there. If a needed role is missing, say so rather than making one up.
- **View, not authorship.** This skill gives a role's thinking. When the conversation produces
  something worth committing (a story, a decision, a doc), hand off to the owning skill. A GitHub
  issue write waits for Checkpoint Alpha. A code change ends in a pull request a person reviews at Checkpoint Bravo.
- **Clash honestly.** Do not soften a persona's stance into agreement or put words in its mouth; the value is
  the real tension between lenses.
- **Stay right-sized.** Do not escalate a small question into a full panel.

## Failure modes

- **The role the question needs is not in the registry** -> say which role is missing. Answer from the closest role that is there, and label it as such. Inventing a persona invents an authority the team never agreed to.
- **The personas converge immediately** -> that is a signal the question is not contested, not that agreement was reached. Say the question did not need a panel rather than making up a disagreement or reporting an empty agreement.
- **A persona is softened into agreeing with the user** -> the whole value is the tension between lenses. A security lead who waves a change through is worse than no security lead, because it reads as clearance.
- **The conversation produces something worth keeping and it stays in chat** -> hand off to the owning skill. A decision reached in a panel and never written is a decision the next session will make differently.
- **A small question escalates into a full panel** -> right-size it. One role's view answered in three sentences is the common case.
- **The user treats a persona's view as a sign-off** -> it is a view, not an approval. Acceptance and sign-off stay with a human (C09).

## Observable signal

**Positive:** a contested decision gets its real objections voiced before it is made, not after it ships. Each objection belongs to a role the team recognises, not to a general bad feeling.

**Audit trail:** when a panel's conclusion becomes an artifact, that artifact is the receipt. The conversation itself is on purpose not one: nothing here is a decision of record until an owning skill writes it.

**Drift signal:** if panels keep ending without anything handed off, they are being used to avoid deciding. If the same role's objection is raised and overridden repeatedly, the real disagreement is about a rule and belongs in an ADR or the constitution.

## Next steps

- `grilling` - when the conversation turns into producing an artifact, the authoring skill's
  pre-draft questioning takes over (right-sized, artifact-bound).
- `/write-story` (Product Manager) - to turn a panel's conclusion into a story.
- `/write-adr` (Architect) - to record a decision the personas reached.
- `/guide-me` - to find where the work sits in the lifecycle and what step is next.
