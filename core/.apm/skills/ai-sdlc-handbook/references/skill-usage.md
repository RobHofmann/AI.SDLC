# Which skills we actually use

The AI-SDLC holds workflow skills, knowledge skills and agents. Without a count, nobody can say which of
them a team really runs. A skill that nothing calls then looks the same as a skill everyone calls.
`.claude/skills/test-skills/scripts/Get-SkillUsage.ps1` answers that with counts, for all three kinds.
The [test-skills](/.claude/skills/test-skills/SKILL.md) skill owns the script.

```bash
pwsh .claude/skills/test-skills/scripts/Get-SkillUsage.ps1            # the table
pwsh .claude/skills/test-skills/scripts/Get-SkillUsage.ps1 -Detail    # plus the never-used and never-named lists
```

The `-ProjectFilter` parameter picks the transcript folders and the Copilot sessions to read, so pass the
one that matches your repository.

## What it counts, and why the two columns differ

The script reads the session transcripts Claude Code writes under `~/.claude/projects`, and the session
logs GitHub Copilot CLI writes under `~/.copilot/session-state` (in `COPILOT_HOME` when that is set). A
Copilot session counts when its first event names this repository. It counts two kinds of invocation,
because they answer different questions.

| Column | Meaning | What it tells you |
| --- | --- | --- |
| `Typed` | A person typed the slash command | People reach for this skill by name |
| `Agent` | The agent called the skill through its Skill tool (`skill` in Copilot) | A skill delegated to it, or the agent picked it for a plain request |
| `Total` | The two added up | How much the skill is used at all |
| `ReferencedBy` | How many OTHER skills name it in their own `SKILL.md` | The intended call graph, not a count of runs |
| `Kind` | `workflow`, `knowledge` or `agent` | Which rows to compare with each other |

Each agent in `.claude/agents/` gets a row of its own with the kind `agent`. Its `Agent` column counts the
Agent tool calls (`task` in Copilot) whose agent type names it. Its `ReferencedBy` counts the skills that name it in
backticks, which is how a workflow skill hands work to it. The [skill patterns](pattern.md) page
describes that hand-off. A knowledge skill is never typed, and an agent can preload it without a Skill
tool call. So a low count on a knowledge row means less than on a workflow row.

One skill calling another lands in `Agent`, because a delegated call goes through the same Skill tool as
any other. `ReferencedBy` is the other half of the picture: it separates "nobody calls it" from "nothing
even points at it". A skill with a high `ReferencedBy` and a zero `Total` is wired in but never reached.
A skill with zero on both is a candidate to retire.

## What it cannot see, by design

- **Copilot in VS Code or another IDE.** Those sessions are kept elsewhere, so a skill used only from an
  IDE reads as unused here.
- **A skill followed without the Skill tool.** An agent that reads a skill's instructions and does the
  work inline leaves no invocation record. The same holds for a knowledge skill an agent preloads.
- **An inline review.** When no agent could run, the skill does the review itself as its fallback. That
  shows in the pull request's evidence record, not here.
- **Sessions on another machine**, and transcripts a person has deleted.
- **A renamed skill's history.** Runs under a skill's old name are not counted for the new one.

Treat a zero as "no evidence of use here", not as proof that nobody uses it.

## What it reads out of a transcript

Only skill names and timestamps. No prompt, no answer, no argument, no file content. A test asserts that
nothing else reaches the output, so the report can be shared without giving any work away.

## How to act on a reading

- Check the IDE side by hand before you retire anything, because this report cannot see it.
- A wrapper skill around a script that a hook or a gate already runs adds little; its work can live in
  the gate and in `run-preflight`.
- A skill that nothing names and nothing runs is the first candidate to retire.
- A phase whose skills all read zero may simply not have had work yet. Match the reading to the work the
  team has done before you call a skill wrong.
- When you retire a skill, record the reason in the repository, with where the work lives now. To retire a
  shared skill, open a pull request on AI.SDLC, as the [autolearn page](autolearn.md) says.

## Related

- [The AI-SDLC](README.md) - the phases these skills belong to.
- [Skill pattern](pattern.md) - the shape every skill follows, and the advisory-then-blocking path.
- [Artifact graph](artifact-graph.md) - the artifacts the skills read and write.
- [Autolearn](autolearn.md) - where a change to a shared skill goes.
