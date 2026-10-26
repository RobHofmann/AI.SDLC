# Compacting the context at a boundary

A long session fills the context window. At some point it has to be compacted, and the conversation
so far is replaced by a summary. This page says where that is safe, what a compaction takes with it,
and what to write down first. The runnable form is the
[handoff](/.claude/skills/handoff/SKILL.md) skill. It writes the costly parts to their own home, then a
handoff document a fresh session can pick up. The nudge that tells you the window is filling up is
`.claude/skills/ai-sdlc-hooks/scripts/Invoke-CompactSuggestionHook.ps1`, and it names `/handoff`.

## Why it matters here

The AI-SDLC runs work in phases. A build walks the substrate, plans, writes tests first, brings
coverage up, updates both documentation layers, and opens a pull request. Each phase reads a lot and
keeps little.

Auto-compaction fires where the harness decides. That point has nothing to do with the phase you are
in. When it lands in the middle of a build, the run loses the file paths, the partial edits and the
reasoning it was working from. When it lands between two phases, it costs almost nothing, because
the phase that just ended already wrote its output to a file.

So the goal is not to compact less. It is to compact at a boundary you chose.

## Where a compaction is safe

| Moving from | To | Compact? | Why |
| --- | --- | --- | --- |
| `walk-substrate` | the plan | Yes | The walk is long. The plan is the part of it you still need. |
| The plan | the build | Yes | The plan is in a file by then, so the build can read it back. |
| The build | `wrap-up` | Maybe | Keep the context if the docs and the tests read code you just wrote. Compact if you are switching focus. |
| Debugging | the next piece of work | Yes | A stack trace and a dead end help nobody on the next task. |
| A failed approach | a second try | Yes | The reasoning that did not work makes the next try worse, not better. |
| Anywhere | the middle of a build | No | You lose the file paths, the names and the half-finished edit. That is the expensive case. |

## What a compaction keeps, and what it drops

| It survives | It is gone |
| --- | --- |
| `AGENTS.md` and `.claude/CLAUDE.md`, which load every session | The substrate walk, and every file you read |
| Every file on disk: the story file, the plan, specs, ADRs, both documentation layers | The reasoning between the steps |
| Git state: the branch, the commits, the working tree | Tool output you did not act on |
| The agent's own memory files | Anything you only said in chat |

The pattern in that table is simple. What is written to a file survives. What is only in the
conversation does not.

## Write it down before you compact

This is the one rule that makes the rest work. Before you compact, make sure the costly part of the
session is in a file:

- **The plan.** Take a story of about 5 points or more, or one that touches more than one component.
  For it, `implement` writes a story file under `docs/stories/` and saves the plan in its `## Tasks` section.
  That is what makes the plan-to-build boundary cheap. For a smaller story the plan stays in the chat,
  so write it to a file before you compact.
- **A decision you made along the way.** It belongs in an ADR in the ADR folder (`paths.adrFolder` in
  aisdlc.json), not in the chat.
- **A lesson about how we work.** That is the [autolearn](autolearn.md) route, so run `capture-learning` first.
- **A finding you have not acted on.** Put it in the work item or the pull request description.

A plan that lives only in the conversation is simply gone after a compaction. Do not rely on a task
list to carry it. The tool that holds one is not present in every agent or every version. So a file
is the only record that always survives.

## How the nudge works

The hook runs before an Edit or a Write and stays quiet almost all of the time. It reads the last
usage record in the session transcript and adds three numbers. They are the input tokens, the tokens
read from cache, and the tokens written to cache. Together they are the real size of the context on that
turn.

It speaks once the total passes a threshold that scales with the context window: 160000 tokens on a
200k window, and 250000 on a 1M window. After that it stays silent until the context has grown by
another 60000 tokens. It also offers a checkpoint at the fiftieth Edit or Write, and every 25 after that. That is a much
weaker signal. It fires in every session, and it stays because it still works when the transcript
cannot be read.

It works the window size out from evidence rather than from the model name. A person can set the size with the environment
variable `AISDLC_CONTEXT_WINDOW_TOKENS`; the hook reads it first. The message names a window of a
million tokens or more in millions, so 2000000 reads as `2M`. Claude Code writes the
model id into the transcript without the `[1m]` marker, and nothing else there names the window. So
the hook uses what it can prove: a turn holding more than 200000 tokens cannot be running on a 200k
window. It remembers that largest size per model in the temporary folder `ai-sdlc-compact`, so the
proof from one session is still there in the next. The first long session on a new machine still gets
one early nudge, and every session after it is right.

Its message names `/handoff`, then `/compact`. Three things it never does. It never compacts anything,
because only a person can type `/compact`.
It never blocks an edit. It never says how full the window is while it is still guessing the size.
A share measured against a guess reads as a fact, and it can be five times too high.

The design is ported from the `strategic-compact` skill in the open-source
[ECC repository](https://github.com/affaan-m/ECC), which pairs the same two signals with a hook that
reads the transcript. Two parts of it were left out on purpose. Its token-optimisation figures carry
no source that clause C07 accepts, and its table of environment variables is tied to one version of
one tool.

Three design rules sit behind this hook. A rule is defined once and fired by a hook wherever a hook can
fire it. A hook fires a step instead of asking someone to remember it. And a hook may report a
measurement while it leaves the choice to a person.

## Related

- [The AI-SDLC](README.md) - the phases this page names, and the skill that runs each one.
- [AI-SDLC skill patterns](pattern.md) - the shapes a skill follows, including the standing-rules block.
- [Autolearn](autolearn.md) - the other loop that fires by itself, and the pattern this hook follows.
- [The constitution](constitution.md) - clause C07 on sources, which is why two parts of the
  upstream skill were dropped.
