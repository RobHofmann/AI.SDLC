# AI-SDLC skill patterns

The shapes the skills in `.claude/skills/` follow. This is the shape made explicit, so a new skill is
written to a known shape and an existing one can be judged against it. It is the skill-level companion
to [node-templates.md](node-templates.md), the shape of each substrate *node* a skill produces. It also
goes with [artifact-graph.md](artifact-graph.md), the machine-readable edges between those nodes. The
hygiene gate `.claude/skills/ai-sdlc-gates/scripts/Check-SkillHygiene.ps1` enforces the parts of this
that are deterministically checkable. The rest is convention this document carries.

Every skill declares one of **two kinds** in its frontmatter. Both kinds are the same files for Claude
Code and GitHub Copilot ([plan.md](plan.md)):

- **`kind: workflow`** is a step the model runs. It holds the steps to follow, the gates, the stop
  list, and when to load which knowledge skill or hand off to which agent. It takes one of the four
  shapes below. A workflow skill is one of two things:
  - a **command** a person types as a slash command, such as `/implement` or `/wrap-up`;
  - an **internal step** that other skills call, such as `walk-substrate`, `run-preflight`,
    `check-pr-contract`, `write-platform-note` and `grilling`. It sets
    `user-invocable: false`, so it stays out of the slash-command list in Claude Code. It keeps its
    description, because the model loads it on that description.
- **`kind: knowledge`** is how we do one thing here. Nobody types it: a workflow skill or an agent loads
  it. It has its own shape, in [The knowledge shape](#the-knowledge-shape).

Agents are the third building block. They live in `.claude/agents/` and have their own shape, in
[The agent shape](#the-agent-shape).

There are **four workflow shapes**. Three of them (reader, author, discovery) are substrate skills.
The fourth (action / executor) does work or orchestrates other skills, and on purpose does not fit the
substrate walk.

## The two cross-cutting skills the shapes delegate to

Two rules recur across many skills. So each is owned by one cross-cutting skill that the others call
inline rather than re-implementing:

- **`grilling`** is the questioning step. **Authoring** skills call it before they draft. Then the
  roles that matter question scope, requirements, and the why, in rounds, before anything is written.
  Grill, then draft.
- **`walk-substrate`** is the substrate walk. **Action** skills call it before they build. Then the
  work is done against the assembled upstream and code-side context, not the story text in isolation.
  Walk, then act.

The symmetry is the point: authors *grill then draft*; doers *walk then act*. Each delegates the
cross-cutting step to one skill, so the rule lives in exactly one place. The walk and the grilling
are each run **once per work item per thread**. A skill that finds the context block (or the grilling
answers) already present in the conversation reuses it and does not repeat the work.

## The standing rules every skill carries

Two rules hold in every run of every shape. So every `SKILL.md` carries one short `## Standing rules`
block that points at the page which defines each. The block is the pointer, not the rule: the text
lives in one place and the skills link to it.

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words, and chat follows the
  language the user writes in. The rule is [language conventions](language.md).
- **Autolearn.** A lesson from the session that would change a future run goes to its durable home,
  proposed and never written in silence. The loop, the filter and the route table are
  [autolearn](autolearn.md), and the runnable step is `capture-learning`.

`Check-SkillHygiene.ps1` blocks when a skill has no `## Standing rules` section or when that section
does not link both pages. The pointer sits in every skill rather than in the hook alone. GitHub
Copilot CLI reads the same settings file and raises the prompt and stop events too. A Copilot session
started in a subfolder runs no hook; [autolearn](autolearn.md) says more.

## Shape 1: reader / walker (substrate, single-shot)

Takes an entry point, walks the substrate one or more hops, returns one structured result. Read-only;
mutates nothing. Four steps, always the same:

**resolve -> walk -> assemble -> return**

1. **Resolve** the entry point to exactly one thing. On multi-match, list the candidates and ask; never guess.
2. **Walk** the substrate: fetch the entry node, then its edges (concurrently where independent). On a
   failed fetch, continue with what loaded and record the broken edge by name. Never abort the whole
   walk for one dead link.
3. **Assemble** a structured result, **attention section first**.
4. **Return** it *before* the consuming action begins. A result returned after the agent has already formed a
   position is a result the agent silently ignores.

Examples: `walk-substrate` and `guide-me`.

## Shape 2: author (substrate, single-shot, produces a draft)

The producing mirror of the reader. It uses the same `resolve -> walk -> assemble -> return`. But step
3 assembles a **draft node** in its [node-templates.md](node-templates.md) shape rather than a context
block, and step 4 returns the draft. An author **writes to a GitHub issue only through Checkpoint Alpha**.
It shows the full draft, the open questions and the `draft-reviewer` result, and a person confirms the
named writes ([orchestration.md](orchestration.md)). It never transitions a work item. An author
that drafts a story, a hypothesis, a journey, a PRD or an ADR calls `grilling` first, so the draft is
built on real answers. It saves the why from those answers into the node's intent
fields and mandated text sections.

Examples: `write-story`, `write-prd`,
`write-api-spec`, `write-adr`, `write-hypothesis`,
`draw-customer-journey`, `write-research-summary`, `write-docs`.

## Shape 3: discovery (interactive, multi-turn)

Opens up, then narrows down, over several turns to turn a raw intent into a structured brief an author
can consume. This is **not** single-shot and does not fit `resolve -> walk -> assemble -> return`. The
shape is:

**look first -> open up -> narrow down -> hand off**

1. **Look first at the substrate.** Before exploring, check what the graph and the existing artifacts
   already hold, and point out what already exists up front. Then the discussion explores the gaps
   rather than finding things again or drifting out of scope.
2. **Open up.** Interactive, Socratic questioning, sized to how much depth the work needs.
3. **Narrow down.** Synthesize a brief shaped to the inputs the downstream author needs.
4. **Hand off** to the right author. Discovery does not draft the node and does not publish.

Examples: `grilling` (the engine; a person types it as `/grill-me`), `convene-personas` (talk to a
role or convene a panel).

## Shape 4: action / executor (does work, may orchestrate)

Does the work or coordinates other skills. It does not walk-and-return. Where it needs substrate
context, it **delegates the walk to `walk-substrate`** rather than re-implementing one. Its shape is:

**have the walk (delegate) -> act -> check -> hand off**

1. **Have the walk.** If the substrate walk for this work item has not run in this thread, call
   `walk-substrate` and build against its block; if it has, reuse it.
2. **Act.** Do the work (write code, run gates, route lessons). Between the two human checkpoints the work
   runs on its own. It stops only on the stop list in [orchestration.md](orchestration.md). Hard
   sequencing is first-class here, not noise to normalise away.
3. **Check.** Confirm the work meets its contract (tests, gates, the acceptance criteria). **Report
   evidence rather than self-certifying** the result (see "Never auto-green a human judgement" below).
4. **Hand off** to the next skill via `## Next steps`.

Examples: `implement`, `fix-pr-feedback`, `update-constitution`, `capture-learning`.
The build-for-a-work-item skills (`implement`, `fix-bug`, `refactor`) are the ones that
delegate to `walk-substrate`. An executor that touches no work item does not walk, for example
`run-preflight`, which runs scripts.

## Output rule (every shape that returns a block)

- **Attention section first.** The reader acts on the attention section; bury it and it gets skipped.
- **Write for the consumer**, the next agent turn or the human reading it. Keep a returned context block
  under about 3 KB. A large raw dump gets ignored; a tight block with a sharp attention section gets acted
  on. Fetch word for word substrate text on demand rather than building in whole bodies.
- **Fail where it can be seen.** Multi-match: ask. Broken edge: name it in the attention section and continue. Missing
  required upstream: stop and ask, do not invent.
- **One reading level, two languages.** Anything the skill writes into a page, a work item, or a system is
  English. The chat around it follows the language the user wrote in. This is the first standing rule:
  clause C11 of the [constitution](constitution.md), in full in [language conventions](language.md).

## The knowledge shape

A knowledge skill says how we do one thing, and points at the page that holds the full rule. That is
a page in its own `references/` folder, a handbook page, or a page of the repository. It never copies
that page, so a rule lives once and a knowledge skill cannot drift from it.

```
---
name: <topic-name>                 # e.g. csharp-generation-smells, adr-conventions
kind: knowledge
user-invocable: false              # stays out of the slash-command list
description: "<what it covers; Use when a change touches ...>"
---
# <title>
<when the skill applies, in two or three sentences>
## <the checklist>     <the mistakes that really happen, each pointing at its docs section>
## Sources             <REQUIRED: links to the pages that hold the full rule; every link resolves>
## Standing rules      <the language and autolearn pointers; REQUIRED>
```

A knowledge skill has no `phase`, no `persona` and no `## Next steps`, because it is not a step in the
flow. The workflow skill that loaded it decides what comes next. It stays at 120 lines or less. When
it grows past that, the detail belongs in the docs page it links.

## The agent shape

An agent is a helper with its own context and a fixed tool list. Claude Code, Copilot CLI and Copilot
in VS Code all read `.claude/agents/<name>.md`. Every agent is read-only except `builder`, which
writes code and tests and nothing else. A reviewer that can write is no longer independent, so the
review agents stay read-only. The builder exists so the build step runs on a chosen model, whatever
the model of the session is. The skills do every other write: `wrap-up` commits, and the workflow skill
that called the agent pushes and opens or updates the pull request.

The `builder` keeps three more rules, and `Check-AgentHygiene.ps1` checks them. It is on the writer list
of that script, it sets `model:`, and its `## Task` says it never commits or pushes. Edit and Write are
its only write tools. A hook still refuses its edit of a protected file, because hooks fire inside an
agent in both tools.

```
---
name: <agent-name>                 # the same as the file name
description: "<when to use it; both tools route on this>"
model: sonnet                      # opus, sonnet or inherit; see the model table below
tools: Read, Grep, Glob            # REQUIRED and explicit; no Edit, Write or MCP write tool, except for `builder`
skills:                            # knowledge skills Claude Code preloads
  - <knowledge-skill>
---
# <title>
Persona: <a role from personas.md>
## Read first          <links to the SKILL.md of every preloaded skill, for Copilot>
## Task                <what it checks or builds, and what it leaves alone>
## Shell use           <only for an agent with Bash or PowerShell: the read-only commands it may run>
## Output              <a fixed header, so a run shows the agent really ran>
## Standing rules      <the language and autolearn pointers>
```

Set `model:` to `opus`, `sonnet` or `inherit`, as the table in the next section says. Every reviewer
agent also follows four rules against false findings:

- a HIGH finding needs proof;
- zero findings is a valid result;
- it does not report what a gate already checks;
- it reports findings only, never an approve or block verdict (C09).

### The model of each step

Opus costs much more than the `sonnet` model, so it runs only where judgement matters. On Copilot, the same
one-word answer cost 1.51 AI credits on claude-sonnet-5 and 43.51 on claude-opus-5.5.

| Agent | Model | Why |
|---|---|---|
| `architect` | `opus` | judges fit with the architecture and the ADRs |
| `security-reviewer` (dotnet) | `opus` | a missed security defect costs the most |
| `blind-judge` | `opus` | scores two outputs on judgement alone |
| `draft-reviewer` (github-issues) | `opus` | judges whether a draft is ready for Checkpoint Alpha |
| `substrate-walker` | `sonnet` | collects and sums up context |
| `docs-reviewer` | `sonnet` | checks pages against the change and runs the doc gates |
| `code-reviewer` (dotnet) | `sonnet` | works through a fixed checklist |
| `test-analyzer` (dotnet) | `sonnet` | maps acceptance criteria to tests |
| `builder` | `sonnet` | writes the tests and the code to a plan the `architect` wrote |

The session model matters less now. The heavy steps run on their own model, so Sonnet is enough for
the main session.

For a skill, the model is advice that the person sets in the tool:

| Model | Skills |
|---|---|
| `opus` | `grilling`, `write-adr`, `write-api-spec`, `update-constitution`, `test-skills` |
| `sonnet` | `implement`, `write-docs`, `wrap-up`, `fix-pr-feedback` |
| Whatever the session runs | `guide-me`, `walk-substrate`, `handoff`, `wait-what`, `grill-me`, `summary` |

The plan, build and review steps of `implement` run in agents, so the agent table above sets their model.

A skill without an agent cannot force its model. Do not add `model:` to a `SKILL.md`: a Copilot skill
has no model field, and in Claude Code it switches the model of the whole session. A Copilot user sets
the default model in the tool.

Why only the Claude aliases, tested on 2026-10-06:

- **Claude Code 2.1.290** runs `opus` as claude-opus-5-5, and `sonnet` works the same way. It fails the
  agent on "Claude Opus 5.5" with `unrecognized_model`. On `claude-opus-5.5` it runs claude-opus-4-8,
  the wrong model, with no warning.
- **GitHub Copilot CLI 1.0.91** reads `.claude/agents/*.md` and honours `model:`. On `opus`, `sonnet`,
  `claude-opus-5-5` or an unknown value it prints
  `Warning: Custom agent "<name>" specifies model "<value>" which is not available; using "claude-sonnet-5" instead`. Then it runs its default model,
  and the run does not fail. It runs claude-opus-5.5 on "Claude Opus 5.5" and on `claude-opus-5.5`.
- No single value works on both tools. The alias is the safe choice: Claude Code honours it, and
  Copilot CLI warns and falls back to its default. So on Copilot CLI that warning is expected.
- Copilot CLI 1.0.100 behaves in two ways (probed 2026-10-20). An agent started with `--agent` or
  `/agent` warns and falls back to `claude-sonnet-5.5`. A skill hands work through the `task` tool, and
  that tool behaves differently. It refuses an agent whose file says `opus` or `sonnet` when the call
  passes no model, so the agent does not run. With `claude-opus-5.5` passed, it runs on Opus. So the hand-off sentence below must pass
  the Copilot name. Every `opus` agent also names the model it runs on in a `Model:` line of its output,
  and `Check-AgentHygiene.ps1` checks that the line is there. The evidence record then shows a run below
  its model. A repository cannot set the model of an agent for Copilot; only each user can, with `/subagents`.
- Copilot in VS Code with agents in the Claude format was not tested.

What a hand-off can pass, and what an agent can do, tested on 2026-10-06:

- **A model per call works in both tools**, for an agent with no `model:` line. In Claude Code 2.1.290
  the `model` parameter of the Agent tool ran claude-opus-5-5 for `opus` and claude-sonnet-5-5 for
  `sonnet`. In Copilot CLI 1.0.91 the `task` tool got `"model": "claude-opus-5.5"` or
  `"claude-sonnet-5.5"` and ran exactly that model. The main session stayed on its default.
- **Hooks fire inside an agent in both tools.** A `PreToolUse` hook that denies Edit and Write blocked
  the edit of a protected file by an agent, in Claude Code and in Copilot CLI.
- **Copilot CLI in non-interactive mode does not let a custom agent write a file**, even with
  `copilot -p --allow-all`: "Permission denied because no interactive user response was available".
  The hook is not the cause; the result is the same without it, and `COPILOT_ALLOW_ALL=true` does not
  change it. Claude Code with `-p` and the tools allowed let the agent write the file. On Copilot CLI
  1.0.100 the main session could not write a file in `-p` mode either, with `--allow-all-tools` and no
  hook at all (probed 2026-10-20).
- **Interactive Copilot CLI lets a custom agent write a file.** In Copilot CLI 1.0.92 an interactive
  session handed the edit to an agent on `claude-sonnet-5.5`, and the agent wrote the file (tested on
  2026-10-06). So `builder` writes in a normal session in both tools. Only a run with no person at the
  keyboard falls back to building in the session.

`Check-AgentHygiene.ps1` fails any other value, because it breaks the agent in Claude Code or runs
another model in silence.

### The hand-off sentence

A workflow skill hands work to an agent with a plain sentence that names the model, and names the
fallback in the next one. Neither tool promises to start an agent:

> Hand the review to the `code-reviewer` agent on Sonnet 5.5 (model `sonnet` in Claude Code,
> `claude-sonnet-5.5` in Copilot). If you cannot run agents, load the `csharp-generation-smells` skill
> and do the review yourself.

The sentence names both spellings, because each tool takes its own. The running model passes the value
to its own tool: the `model` parameter of the Agent tool in Claude Code, and of the `task` tool in
Copilot. The `model:` line in the agent file stays as the backstop. A hand-off to the `builder` adds one
more fallback: if the agent cannot write files, do the build in this session.

GitHub Copilot CLI offers its own agents next to ours, among them `code-review` and `security-review`.
They do not know the house rules, and their names are one letter away from `code-reviewer` and
`security-reviewer`. So a hand-off names the agent exactly, and in Copilot the running model passes that
exact name as the agent type of the `task` tool. The descriptions of the two pack agents say the same.

Do not use `context: fork`: it is Claude-only, and one way of doing it is simpler to check.
`.claude/skills/ai-sdlc-gates/scripts/Check-AgentHygiene.ps1` checks the agent shape.

## Never auto-green a human judgement

Verification reports what is and is not clearly true. It does not switch a human sign-off green on
the agent's own say-so, because the agent can be wrong or can hallucinate. A skill never does these
on its own judgement:

- mark an acceptance criterion done;
- close a GitHub issue;
- publish a draft;
- resolve a flagged conflict.

It surfaces the evidence (a test name, a response, a gate result) and leaves the sign-off to a human. This is the same boundary the authors honour (draft,
never publish), applied to verification: **surface, don't decide.**

## The body sections

```
---
name: <functional-name>            # bare verb-noun, no phase prefix (e.g. write-story, walk-substrate)
kind: workflow
phase: discovery | elaboration | create | mature | cross-cutting
persona: <owning role>             # e.g. Developer, PM, Architect, Lead, any
description: "<the trigger surface: long, probabilistic, in the team's own vocabulary; this is what
  fires the skill, plus the Do-NOT-use boundaries against its neighbours>"
---
# <human title>
<intro: what the skill is, the gap it closes, which shape it is, the persona that owns it>
## Standing rules      <the language and autolearn pointers; REQUIRED, both links checked>
## <when it fires vs its siblings; the entry point>
## <inputs / what it walks>
## <procedure, concretely; for the shape it is>
## <outputs: the block or draft; attention first; for readers/authors>
## Failure modes        <multi-match, dead edges, conflicts; REQUIRED>
## Observable signal     <positive signal, audit trail, drift signal; REQUIRED>
## Next steps            <which skill(s) and persona run next>
```

A workflow skill that may run only when a person calls it by name adds `disable-model-invocation: true`
to its frontmatter. Claude Code then never starts it on its own. So a hand-off from another skill asks
the person to run `/<name>`. Its description is for the person: one line that says what it does, plus
the "Use when" line that `Check-SkillHygiene.ps1` asks every skill for.

An internal step adds `user-invocable: false` instead. Claude Code keeps it out of the slash-command
list, and the model still loads it, so its description keeps the trigger branches. GitHub Copilot CLI
does not read the field: it lists the skill and runs it when typed ([plan.md](plan.md)). That does no
harm. A step that calls an internal skill names it in backticks, without a slash.

### Writing the description

The description is the pointer that decides when the model reaches the skill. It is always loaded, so
every word costs on every turn. Three rules keep it short and sharp:

- **Front-load the leading word.** Start with the word the team really says for the job, such as
  "Grill", "Triage" or "Hand off". The first words do the triggering work.
- **One trigger per branch.** A branch is a case the skill handles in its own way. Two phrases that
  name the same case are one branch written twice; keep one, and keep every case that is really
  different.
- **Cut identity the body already carries.** The description says when to load the skill, not how it
  works inside.

Every skill spends one of **two loads**. **Context load** is the cost on the model: a description sits
in the context window every turn, whether the skill fires or not. **Cognitive load** is the cost on
the person, who must remember which commands exist. A command a person types pays cognitive load; a
skill the model loads pays context load. Pick the model's reach only when the model, or another skill,
must find the skill on its own. That is why the internal steps keep a description, and `/guide-me`
helps a person who does not remember every command.

### Required vs recommended (the advisory-first path)

`Check-SkillHygiene.ps1` enforces the **always-required** core on every skill. It treats the richer
sections as **advisory** until the set has adopted them. That is the same advisory-then-blocking path
the other gates use:

- **Always required (blocking), for every skill:** a `kind:` of `workflow` or `knowledge`, and for a
  knowledge skill the rules of [The knowledge shape](#the-knowledge-shape). No plugin-style
  `namespace:skill` reference that only one machine has.
- **Always required (blocking), for a workflow skill:**
  - `name` matches the folder;
  - a `phase:` (one of the five) and a `persona:` in frontmatter, the lifecycle position and owner,
    since the bare name no longer encodes the phase;
  - a trigger-rich `description`, and the persona ownership line in the body;
  - a `## Standing rules` section that links both standing-rule pages, and a `## Next steps` section;
  - no em-dash, no source line sources, and cross-skill references that resolve.
- **Also required (blocking):** `## Failure modes` and `## Observable signal`. These were advisory
  while the set adopted them. Once every skill had both, the path closed. So
  `Check-SkillHygiene.ps1 -Strict` now blocks: a new skill without both sections fails the build.

Both sections must say something specific. A failure-modes entry names a way this step has really
gone wrong or could well go wrong, with what to do instead. An observable-signal entry names something
a reader can look at to confirm the step ran. A section can pass the check while telling the reader
nothing ("this step may fail"). That is worse than the honest empty state it replaced, because the
gate then reports the set as healthy. If a skill has really nothing to say in a section, that is a
signal about the skill, not about the section.

## Related

- [Which skills we actually use](skill-usage.md) - the invocation counts per skill, and the ones nothing calls.
- [node-templates.md](node-templates.md) - the shape of each substrate node an author produces.
- [artifact-graph.md](artifact-graph.md) - the machine-readable edges and the intent the skills save.
- [personas.md](personas.md) - the roles the skills frame their work as, and that the discovery skills voice.
- [language conventions](language.md) - the reading level and the language for everything a skill writes.
- [autolearn](autolearn.md) - the other standing rule: how a lesson from a session becomes a lasting rule.
- [context management](context-management.md) - where a long run can compact its context safely, and what a skill writes to a file first.
- [plan.md](plan.md) - the workflow these skills implement, and why skills have bare functional names with phase and persona in frontmatter.
- The hygiene gate and the layered eval harness that check this shape: the `test-skills` skill.

## Sources

- The description rules and the two loads come from `skills/productivity/writing-for-agents/SKILL.md`
  and its `SKILL-MECHANICS.md` in [mattpocock/skills](https://github.com/mattpocock/skills), MIT licence,
  Copyright (c) 2026 Matt Pocock.
