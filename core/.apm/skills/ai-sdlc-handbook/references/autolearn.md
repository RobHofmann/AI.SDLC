# Autolearn: turning a session lesson into a lasting rule

Every session teaches something. Most of it is about the work item in hand and dies with the session. A
small part is general: it would change how the next run works, whoever runs it. Autolearn is the loop
that moves that small part out of the chat and into a place that keeps it.

This page is the single definition of that loop. Every skill in `.claude/skills/` points here through
its `## Standing rules` block, so no skill carries its own copy of the rules. The runnable form is the
[capture-learning](/.claude/skills/capture-learning/SKILL.md) skill, which applies the filter and routes the lesson.
It has two entries: one for this session, and one that mines a finished pull request review. Both use
the same route table.

## Why it exists

A team keeps paying for the same correction. A reviewer fixes a pattern by hand, the lesson stays in
the thread, and the next agent run repeats it. The old answer was to remember to run a learning skill
at the end. Nobody remembers, so the loop only closed on the days someone had time. Autolearn makes the
moments explicit and makes two of them fire by themselves, the same way the change-completeness check
fires at the push.

## The moments it fires

| Moment | How it is noticed | What runs |
| --- | --- | --- |
| The user corrects the agent, or rejects an approach | The `UserPromptSubmit` hook matches a correction phrase and adds a note to the turn | `capture-learning`, in the same turn |
| The turn ends and that correction was never captured | The `Stop` hook redeems the flag once and blocks the stop | `capture-learning`, before the turn closes |
| The same avoidable failure happens twice in a session (a gate, a tool call, a wrong path) | The agent notices it while working | `capture-learning` |
| A change is finished | Step 9 of `wrap-up`, before its commit | `capture-learning` |
| A pull request review lands | The user asks, or `wrap-up` reaches its lessons step for `fix-pr-feedback` | `capture-learning`, from a pull request |

The hook is `.claude/skills/ai-sdlc-hooks/scripts/Invoke-AutolearnHook.ps1`, wired from
`.claude/settings.json`. It never decides whether a lesson is real. It only says "a correction just
happened here" and names this page. The judgement stays with the skill and the human.

## The filter: is this lesson general?

A lesson is general only when all three are true. Run them in this order, because the third one kills
most candidates.

1. **It would change a future run.** It is a rule, a route, or a trap, not a fact about this one work item.
2. **It has a durable home.** One of the rows in the route table below holds it. A lesson with no home
   is a note for the pull request, not a rule.
3. **It is not written down already.** Search first. Most corrections are an enforcement gap, not a
   missing rule. The rule exists and nobody read it, or the gate that would catch it runs advisory.
   Adding a second page saying the same thing makes the first one harder to find.

Then say how often you have seen it. Once is an anecdote, and an anecdote is recorded as one. Twice in
different places is a pattern and can become a rule.

## Shared or repo-only: the two routes

Before you pick a home, decide whose lesson it is. The [layout page](layout.md) says which files are
shared and which belong to the repository.

- **A lesson about a shared file** goes to AI.SDLC as a pull request. A shared file is one that
  `apm.lock.yaml` lists: a core or pack skill, an agent, a hook, a shared gate, or a handbook page. It is
  read-only in the repository, so never edit it in place. The fix reaches every repository with the next
  release.
- **A lesson about one repository** stays in that repository: its own docs, its ADRs, its own clauses,
  its own gates, or its own part of `AGENTS.md`.
- **A fact about how a system behaves** goes to the knowledge repository, through a branch and a pull
  request there. A rule about the way of working goes to AI.SDLC. Neither is part of the repository's own pull request.

A lesson can be general while its example comes from one repository. Then write the general rule in
AI.SDLC, and keep the example in the repository.

## Where each lesson goes

| The lesson is about | Its home | The skill that writes it |
| --- | --- | --- |
| How we write code or documents | the right conventions page: a stack pack's reference page when shared, the repository's own page when not | `write-docs`, or a pull request on AI.SDLC |
| A key decision, with alternatives | a new record in the ADR folder (`paths.adrFolder` in aisdlc.json) | `write-adr` |
| A rule that must never bend | a clause in the constitution: a core clause in the [handbook constitution](constitution.md), a repository clause in the repository's page | `update-constitution` |
| Something a script can check | a `Check-*.ps1` gate, advisory first | `add-gate` |
| How a step of the workflow runs | the `SKILL.md` that owns the step, through a pull request on AI.SDLC | edit it there, then `test-skills` |
| How the product behaves | a page in the functional docs layer (`paths.functionalDocs`) | `write-docs` |
| How a system behaves (a fact about a cloud service, a server, the network or a tool) | the knowledge repository (`paths.knowledgeRoot`), through a branch and a pull request there, never in this repository's own pull request | `write-platform-note` when the knowledge pack is installed, otherwise a pull request on the knowledge repository |
| An existing gate that catches it but runs advisory | the escalation advice, with the backlog count | report it, the team decides |
| One machine, one account, one person's tools | the agent's own memory, never the repository | the agent's memory tool |
| Nothing general after the filter | nowhere | say so in one line and stop |

The last two rows matter as much as the others. A fact about one machine, written into a team
convention, wastes everyone's time. A loop that always finds something to write turns into noise the
team learns to skip.

## What autolearn never does

- **It never writes on its own.** It proposes, names the home, and waits for one confirmation. Writing
  to a GitHub issue, a pull request, or any other outward system needs explicit confirmation as well (clause
  C09). Inside a build loop (the lessons step of `wrap-up`), it does not wait. A lesson for a file in
  this repository reaches the person in the diff at Checkpoint Bravo. A GitHub issue write joins the one
  list of updates for the run. A shared lesson goes into the evidence record as a proposal. A new or
  changed clause is still a stop.
- **It never edits the skill it is running inside without saying so.** A skill that quietly rewrites
  itself mid-run leaves the user with a process they never agreed to.
- **It never turns one anecdote into a rule in silence.** The count is part of the proposal.
- **It never lands a claim without its source** (clause C07). The lesson says where it came from: the
  session, the review thread, the gate output.
- **It never blocks the work.** The capture is short. If the lesson needs a real discussion, it becomes
  a work item, not a delay.

## How the automatic trigger works

The hook script handles both events and is safe by design. Any payload it cannot read, and any error
inside it, exits zero and stays silent.

- **`UserPromptSubmit`**: it matches the prompt against a short list of correction phrases in English
  and Dutch. On a match it writes a flag file for the session in the temporary folder `ai-sdlc-autolearn`.
  It also returns `additionalContext`, which tells the agent to run `capture-learning` once the user's
  request is handled.
- **`Stop`**: it looks for that flag. When the flag is there it deletes it first, then blocks the stop
  once with the same instruction. Deleting first is what stops a loop: the flag can only be redeemed one
  time, so the agent can always finish its turn.

GitHub Copilot CLI reads the same `.claude/settings.json` and raises both events (probed on 1.0.100,
2026-10-20). It reads the prompt context only at the top level of the hook output, so the script writes
it in both shapes. It honours the `Stop` block too. A session that starts in a subfolder runs no hook,
and an agent may run where no hook fires. That is why the `## Standing rules` block sits in every skill
and not only in the hook.

## Related

- [The AI-SDLC](README.md) - the lifecycle these skills run, and the full skill index.
- [The layout of the shared AI-SDLC](layout.md) - which files are shared, and how a change to one reaches AI.SDLC.
- [AI-SDLC skill patterns](pattern.md) - the shapes a skill follows, including the standing-rules block
  the hygiene gate checks.
- [Language and reading level](language.md) - the other standing rule, and the level every
  captured lesson is written at.
- [The constitution](constitution.md) - the clauses a lesson can become, and the sign-off boundary in
  C09.
- [The documentation wiki](docs-wiki.md) - where a lesson lands when its home is a page.
- [Your first story](first-story.md) - where a newcomer first meets `capture-learning`.
- [Context management](context-management.md) - the other loop that fires by itself, and why a lesson
  is written down before the session context is compacted.
