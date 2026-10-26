# AI-SDLC design

The design decisions behind the workflow, and why they hold. This page is for the reader who wants to
change the workflow, not use it. To use it, start at the [README](README.md). How the shared parts are
packaged and installed is on the [layout page](layout.md).

## The goal

Turn a loose set of prompts into a shared workflow that Claude Code and GitHub Copilot both run.
It has one set of skills, one constitution, and one artifact graph. The graph links every work product
(issues, specs, ADRs, docs, designs), so any person or tool can see what exists and what comes next. The target is the
AI-SDLC maturity model: L1 is prompt-driven, L5 is self-running. L3 is where gates hold the quality and
the contract lives in the repository as plain markdown that no vendor owns. The workflow runs at L4: the
steps run on their own between two human checkpoints ([orchestration.md](orchestration.md)).

## Cross-tool facts the design rests on

These were checked, not assumed. Each one decides where something lives.

- **A skill file is read by both tools.** GitHub Copilot (CLI, VS Code agent mode, cloud agent) loads
  project skills from `.claude/skills/`, `.github/skills/` and `.agents/skills/`. Claude Code loads
  `.claude/skills/`. So one committed `.claude/skills/<name>/SKILL.md` serves both. Codex CLI and Gemini
  CLI read the same format. (Sources: GitHub Docs "About agent skills", Copilot CLI "Add skills", GitHub
  changelog 2025-12-18.)
- **An agent file is read by all three tools from `.claude/agents/`.** Claude Code and Copilot in VS Code
  document that folder. Copilot CLI documents only `.github/agents/`. But a probe on version 1.0.88 on
  2026-09-23 showed it reads `.claude/agents/`. It delegates to an agent there without being told its
  name, and holds it to its `tools` list. `.agents/agents/` works in neither tool. `.claude/commands/` is the
  older Claude format and Copilot does not read it.
- **`AGENTS.md` is read by Copilot directly, and by Claude through `@../AGENTS.md` in `.claude/CLAUDE.md`.**
  Claude Code 2.1.304 also reads `AGENTS.md` on its own (probed 2026-10-20), but the import keeps older
  versions working. The import does not sit in a root `CLAUDE.md`: Copilot reads that file too, follows
  its import, and then loads `AGENTS.md` twice in every turn. Copilot does not read `.claude/CLAUDE.md`.
- **Rules that fire on a file path are not shared.** Claude uses `.claude/rules/*.md` with `paths:`;
  Copilot uses `.github/instructions/*.instructions.md` with `applyTo:`. A skill fires on its description
  instead, which both tools support.
- **Hooks are shared, with gaps.** Copilot CLI reads `.claude/settings.json`, maps its `bash` and
  `powershell` tools onto Claude's `Bash`, and honours a deny. It ignores Claude's `if` condition and runs
  every entry in turn, so a command filter has to live in the hook script, before anything slow. The
  arguments arrive under `tool_input` or `toolArgs`, sometimes as a JSON string. The `apply_patch` tool of
  a GPT model sends the text of the edit instead; `HookPayload.psm1` reads every shape. Found with probe
  repositories on Copilot CLI 1.0.82 and 1.0.100. After a prompt or an edit, Copilot reads
  `additionalContext` only at the top level of the output, so the hooks write it in both shapes. The
  `Stop` block works and forces one more turn. The compact hook fires before an edit, but its payload
  carries no transcript path, so in Copilot only its call count works
  ([context management](context-management.md)). A session that starts in a subfolder runs no hook.
  (Sources: GitHub Docs "Using hooks with GitHub Copilot CLI" and "GitHub Copilot hooks reference".)
- **`user-invocable: false` hides a skill in Claude Code only.** Claude Code keeps such a skill out of
  the slash-command list and the model still loads it. GitHub Copilot CLI 1.0.92 ignores the field,
  probed on 2026-10-20 with two probe skills, one with the field and one without. `copilot skill list`
  and `copilot skill list --json` list both the same way. `copilot -p "/probe-hidden"` ran the hidden
  skill. So an internal step still shows, and still runs when typed, in Copilot CLI, which does no
  harm. VS Code 1.142.0 reads the field and asks for a description when it is false.

## Decisions

1. **Everything for the agents is committed.** `.claude/`, with `.claude/CLAUDE.md`, is in the repository, not in
   `.gitignore`. The team contract is versioned like code. The shared part is installed from AI.SDLC and
   committed as well, so a fresh clone works without the installer ([layout.md](layout.md)).
2. **Skills live in `.claude/skills/`, as flat folders with plain names.** `write-story`,
   `walk-substrate`, `capture-learning`: a verb and a noun that say what the skill does. The phase and the
   owning role live in the skill's front matter, not in its name. Both tools find a skill only one folder
   deep, so the folders stay flat. A skill is one of two kinds. A **workflow** skill is a step: a
   command people type, or an internal step that other skills call (`user-invocable: false`). A
   **knowledge** skill is how we do one thing here, which a workflow skill or an agent loads.
   There is no separate command layer, because a skill already plays that role for both tools.
3. **Four phases and a cross-cutting track.** Discovery, elaboration, create, mature. Testing is not a
   phase: tests are written first inside create, and coverage is a gate.
4. **A convention is shared as a skill, and checked by a gate.** A skill fires on its description, which
   is a model's judgement, so the hard rule always sits in a `Check-*.ps1` gate. A generated pair of
   path-scoped rule files (one per tool) is the fallback for a convention the model keeps missing; none has
   needed it yet.
5. **The GitHub issue key is the spine of the artifact graph.** Every artifact carries it. The graph is not stored
   in one tool: it is the set of links, anchored on the key. Where an upstream tool cannot hold the key
   (Dovetail, Figma), the issue holds the link in one direction. Rules and front matter: [artifact-graph.md](artifact-graph.md).
6. **One script, two callers.** Each gate is a committed script in the `scripts/` folder of the skill that
   ships it. A gate of one repository alone is a script that repository lists under `repoGates` in
   `aisdlc.json`. A skill runs it locally for the author; the pull request workflow runs the same file for enforcement.
   The rule lives once.
7. **Every skill ends with the next step.** A skill names the skill and the role that come next, so the
   flow guides itself. `guide-me` gives the same answer from the outside, because both read the
   `phase:` and `persona:` front matter of the skills.
8. **Authors ask first, builders look first.** A skill that drafts an artifact calls `grilling` before it
   writes, so the roles that matter question scope and the why. A skill that builds calls `walk-substrate`
   first, so it works from the assembled context and not from the story text alone. Each of the two lives
   in one skill that the others call. Shapes: [pattern.md](pattern.md).
9. **The why is data, not only text.** Front matter carries `intent:` (hypothesis, assumption, decision
   drivers) and `because:` on a link. A hypothesis and a journey are repository artifacts with front
   matter, not pages that live only in an outside wiki. `Check-ArtifactGraph.ps1 -Strict` can need the `because`.
10. **Personas are generic roles in one registry.** Analyst, Product Manager, Architect, Scrum Master,
    Developer, QA, Tech Writer, Operations engineer, Lead, and Designer / UX. They live in [personas.md](personas.md) as
    plain markdown, read by `grilling`, `convene-personas` and every skill's role line. No character names,
    no script that resolves them. The agents in `.claude/agents/` speak for these personas;
    no persona was added for them.
11. **The work runs on its own between two human checkpoints.** A person confirms at Checkpoint Alpha, before a draft is
    written to a GitHub issue. At Checkpoint Bravo, a person reviews the pull request the loop pushed and
    opened for a tested change. Nothing is pushed to `main` or `master` by an agent. Between them the
    steps run without asking, and they stop only on the stop list. Agents are an accelerator, never a
    requirement: every hand-off names how to do the step without one. Contract:
    [orchestration.md](orchestration.md).
12. **A human signs off.** An agent reports evidence. It never marks a criterion done or moves a work item
    to done. It never resolves a flagged conflict, and never approves or merges a pull request. Constitution C09
    ([constitution.md](constitution.md)).
13. **One source, many repositories.** The core and the packs are shared from AI.SDLC and installed with
    APM. A repository installs the packs that fit its stack and keeps its own facts in `aisdlc.json`, so
    no shared file names one repository's folders ([layout.md](layout.md)).

## Where the ideas came from

Four sources shaped the design. None contributed code, and adapted text keeps its licence notice.

- **BMAD-METHOD v6** (bmad-code-org) gave the questioning method registry and personas as data. It also
  gave the story as a context container with `[Source: file#symbol]` references, and the multi-role
  questioning of party mode. We left out its Python sidecar and layered configuration (the constitution and the
  conventions do that job), its installer, and its entertainment framing.
- **An earlier example repository** with the same tracker-anchored idea. It
  gave the four skill shapes in [pattern.md](pattern.md) and the node templates in
  [node-templates.md](node-templates.md). It gave the "walk before you build" step, and the
  definition-of-ready rubric (now the readiness check in `github-issue-conventions`, github-issues pack). It also gave the
  "mandatory only where a downstream step needs it" rule for artifacts, and the gate generator
  `add-gate`. We left out its Claude-only command layer, because skills already play that role for
  both tools.
- **ECC** (affaan-m/ECC, MIT licence) gave parts of six agents. They are the review gate that makes a
  reviewer prove a serious finding, and the architect's trade-off format. They are also the reading
  budget of its code explorer and the judge's rules. We left out its approve and block verdicts, its checks that our gates already run, and
  every language we do not use. Its `strategic-compact` skill shaped the context-size hook in
  [context management](context-management.md).
- **mattpocock/skills** (Matt Pocock, MIT licence) gave the `grilling`, `grill-me`, `wait-what` and
  `handoff` skills. It also gave methods: the feedback loop of `fix-bug` and the vertical slices of
  `write-story`. It gave the checklist of `capture-learning`, the routing of `guide-me`, and the merge
  danger in the evidence record. It gave the seams and test anti-patterns of `test-first-dotnet`, and
  the description rules in [pattern.md](pattern.md). The root `THIRD-PARTY-NOTICES.md` of
  AI.SDLC lists each one.

## What we watch

- **Being used is the real gate.** A contract nobody uses checks nothing. The gates started advisory and
  turned blocking one by one, after each one's old findings were cleared.
- **Front matter is only as good as the edges people fill.** The graph is tied to artifacts people touch
  anyway (stories, pull requests), and the linter reports the gaps.
- **Questioning must stay in proportion.** `grilling` sizes its depth on the story points (the `size:<n>` label). Too many questions
  on a small task makes people skip it; too few on a large one defeats it.
- **Everything must work without agents.** A single model voicing several roles is the baseline. An agent
  is an extra that both tools can run, and nothing may depend on it.
- **Links to outside tools are not checked.** The gate accepts any URL and does not notice a missing
  one, and CI cannot read what a Dovetail or Figma link says.

## Related

- [The AI-SDLC](README.md) - the working guide.
- [Layout](layout.md) - core, packs and repo-only files.
- [AI-SDLC artifact graph](artifact-graph.md), [node templates](node-templates.md),
  [skill patterns](pattern.md), [personas](personas.md), [orchestration](orchestration.md),
  [docs wiki](docs-wiki.md) - the detailed contracts this design points at.
- [Constitution](constitution.md) - the rules that never bend.
