---
name: guide-me
kind: workflow
phase: cross-cutting
persona: any
description: >
  Navigate the AI-SDLC workflow for a work item or artifact: report where it is in the lifecycle and
  what to do next. It is READ-ONLY: it resolves the anchor, walks the artifact graph and reports the
  current phase, the next skill and its persona, and the human checkpoint the work waits at. It never
  creates, edits, links or transitions anything. On explicit request it hands the next step to the
  owning skill, which runs up to its checkpoint. Use when the user asks "where are we on #42", "what
  is the next step for this story", "run the sdlc on <key or path>", "what is missing before this can
  ship", "which phase is this in", or hands over an issue key, a spec, a doc or an ADR and asks how to
  go on. Also use with no work item: "which skill do I use for this", "where do I start", "what is
  the command for". Do NOT use to author artifacts or to write to a GitHub issue.
---

# Guide me (navigator)

Owned by **any** persona (cross-cutting). Called as `/guide-me <artifact>`.

Given any work item or artifact, work out where it sits in the lifecycle and what comes next,
then report it. The work itself runs on its own between two human checkpoints
([orchestration](/.claude/skills/ai-sdlc-handbook/references/orchestration.md)); this navigator is
the one part that only reads and reports. It never writes, and by default does not run the next step:
the human decides whether to run it. On explicit request it dispatches the next step per
the handbook page `orchestration.md`, handing off to the owning step-skill, which runs up to its checkpoint.
Really independent steps may run side by side. It still does not author anything itself; it routes.

Skill names are bare (functional), not phase-prefixed; each skill carries its lifecycle position and
owner in its own frontmatter (`phase:` and `persona:`). Build the phase/persona map by reading the
skills' frontmatter, so it never drifts from the skills themselves. Skip every skill with
`kind: knowledge`: it is how we do one thing, loaded by a step, and never a next step itself.
The handbook [README](/.claude/skills/ai-sdlc-handbook/references/README.md) lists the phases and the
skills under "The lifecycle" and "The skills". The graph it walks (front-matter edges plus issue links) is defined in the handbook page
[artifact-graph.md](/.claude/skills/ai-sdlc-handbook/references/artifact-graph.md).

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).

## The lifecycle it reports against

Four phases in order, **discovery**, **elaboration**, **create** and **mature**, with a
**cross-cutting** track across all of them. Do not keep a list of the skills per phase here: it goes
stale with every release. Read the `phase:`, `persona:` and `description:` of each installed
`.claude/skills/*/SKILL.md` instead.

A skill with `user-invocable: false` is an **internal step**, such as `walk-substrate`,
`run-preflight`, `check-pr-contract`, `write-platform-note` or `grilling`. Another
skill calls it. Never offer it as a command; offer the command that calls it.

## Input

One of:
- a **GitHub issue key** in the issue repository (`tracker.repository` in aisdlc.json, or the `origin`
  remote), such as `#42` or `owner/repo#42`, the usual anchor;
- a **repo artifact path** (a doc, spec, or ADR) that declares `story:` front-matter;
- a free description of a work item, in which case resolve it to a key first (`gh issue list --search`) or ask;
- **no work item at all**, only a situation ("I have a bug report", "the review is in", "the context is
  full", "I want to test my plan"). Then route by situation, below.

## Without a work item: route by situation

The person does not remember every command, so they ask. Name the one command that fits.

1. **Read the descriptions, not a copy.** List the installed skills from `.claude/skills/*/SKILL.md`.
   Skip each skill with `kind: knowledge` or `user-invocable: false`. Read the `description:` of the
   rest; that is where each skill says when it fits and when it does not.
2. **Match the situation.** Pick the command whose description names this situation, and whose "Do
   NOT use" lines do not rule it out. When two fit, say which one the situation picks and why.
3. **Read before you recommend.** Before you say what a command does, or that a step can be skipped,
   read that skill's `SKILL.md`. The description is for orienting only.
4. **Report** the command, the persona who owns it, and one sentence on why it fits now. Offer to run
   it; do not run it unasked. When the situation names a work item after all, go back to the workflow
   below with that key.

## Workflow (read-only)

1. **Resolve the anchor.**
   - Given an issue key: read the issue with `gh issue view <n> --json title,body,state,labels,comments` (title, open or closed, labels such as `refined`, `spike` and `size:<n>`, body and comments). List its sub-issues with `gh api repos/<owner>/<name>/issues/<n>/sub_issues`, and its parent from the issue page or the GraphQL `parent` field. Every tool runs the same `gh` command; the GitHub MCP server's read tools are an option.
   - Given a repo path: read its front-matter (`story`, `phase`, `step`, `relates`) and take `story` as the anchor. If it has no front-matter, treat the file as not yet in the graph and say so.
2. **Walk the graph (both sides).**
   - **Repo side:** find artifacts that declare `story: <key>` in a YAML front-matter block (the `story:` line between the leading `---` fences, not a match anywhere in the file). Search the doc roots (`paths.docsRoots` in aisdlc.json) and the specs root (`paths.specsRoot`). Ignore the illustrative examples in the handbook (they show the schema, they are not real artifacts). Collect each artifact's `phase`, `step`, and `relates` edges (spec, adr, design, research, docs).
   - **An old `step` value:** an older artifact can name its step by a skill name that a release retired. Look the value up in `retired` of `.claude/skills/ai-sdlc-gates/sync-manifest.json`, which maps each old name to the new one, and read it as the new skill. Never rewrite the old value; it is history.
   - **Issue side** (when the github-issues pack is installed): read the issue links, including **story-to-story** edges (e.g. a dev story's link back to its spike issue, a sub-issue's parent); GitHub Issues is the source of truth for those. Spec and ADR links are **markdown links inside the issue body** (added by `write-story` in update mode). So read the body for them, not just the linked issues.
   - **Knowledge side:** when the knowledge repository is cloned (`paths.knowledgeRoot`, `../Knowledge` by default), grep it for the systems the work item names, next to the repository docs. When the folder does not exist, say so in one line in the report.
3. **Place it in the lifecycle.** Take the anchor's phase (front matter, or worked out from the issue state and labels) and which artifacts exist. From those, decide the current phase and which expected edges are present or missing. Use the "intended required edges" in the handbook page `artifact-graph.md` as the checklist. For example: a Story entering `create` should link a machine-readable spec, and an architecture decision should have an ADR linked back from its story.
4. **Report (do not act).** Cover:
   - **Where it is:** the current phase and what exists (story, ACs, spec, ADRs, code/tests, docs), each with its link.
   - **Which checkpoint it waits at:** one of three states.
     - **Checkpoint Alpha:** a story, epic, PRD, synthesis, hypothesis, journey or triage result is drafted, and a person must confirm the write to a GitHub issue.
     - **In the loop:** a step is running between the checkpoints, up to and including the push and the pull request.
     - **Checkpoint Bravo:** the pull request is open, and a person reviews and merges it on GitHub.
   - **Start condition:** for a story heading into the build, say whether it carries the `refined` label and a `size:<n>` label. Without both, the build does not start on its own; route to refinement first.
   - **What's missing:** the expected edges or artifacts not yet present. Mark an expected edge **N/A (reason)** rather than missing when the work plainly does not need it (e.g. a Portal-only, UI-reuse story needs no API spec), so the report does not show false gaps.
   - **Options:** a numbered list of the next skills you could run from here. Each has the **persona** who owns it and a short why it is an option. Order by readiness: the earliest unmet step in the current phase first. Include a later-phase step only once the edges that apply in the current phase are present.
   - **Advice:** end with one recommended option (by its number) and a short, concrete why it is the best move now.
   - **Thin user story -> sharpen before build.** If the anchor is too thin, do not route it to build. Thin means a vague description, missing or untestable acceptance criteria, or no linked spec or artifacts. Recommend sharpening it first. Look into the codebase for the missing context, and put the story's open questions to the user. Then run `/write-story`, which refines the story and sharpens its acceptance criteria. A shallow story sent straight to `/implement` produces guesswork.
   - **A build that changes behaviour has one entry, and it is `/implement`.** Offer it only when the start condition holds. When the next step is to implement, the option you offer and the step you dispatch is `/implement`. Never start coding inline from here, and never route such a build to another skill. A story that keeps the behaviour goes to `/refactor` instead, under the same start condition. The build begins with a constitution-aware plan that scans the code involved before any edit. The plan lists every closed set the change touches and checks key assumptions against the code. The navigator points at that plan; it does not perform the scan itself.
   - **Caveat:** the graph is incremental, so artifacts without front-matter or issue links are hidden here; say the report is "based on what is linked".
5. **Offer to dispatch.** By default, stop here. If the user asks you to run the next step, dispatch it
   per the handbook page `orchestration.md`, and hand off to the owning step-skill. Run really
   independent steps side by side where the tool can, and one after the other elsewhere. That skill runs on its own up to
   Checkpoint Alpha or up to an open pull request, or stops on the stop list. The navigator does not author; it routes, then reports
   each dispatched step's result (done, waiting at a checkpoint, blocked, or needs a decision).

## Output shape

A short report, for example:

```
#42  -  "Compare two cloud configuration versions"
Phase:   elaboration  (story exists, acceptance criteria present)
Checkpoint: none yet; not refined (no refined label, no size label), so the build cannot start on its own
Linked:  story (issue #42), ADR 0007 (docs/adrs/0007-...md)
Missing: machine-readable spec (relates.spec) before it can enter create

Options:
  1. /write-api-spec          (Architect) - add the OpenAPI spec the build will consume
  2. /write-story         (PM/QA)    - tighten the ACs first if any are still thin

Recommendation: 1, /write-api-spec. The story is AC-complete but has no spec, and the spec is the entry condition for create; nothing downstream starts without it.

(Based on linked artifacts; the graph is incremental, so unlinked work is not shown.)
```

## Guardrails

- **Stories are issues, never pull requests.** A user story or work item is always a GitHub issue in the issue repository, read with `gh issue view`. Issues and pull requests share one number range, so `#42` can be a pull request. When it is, say so and ask for the story issue. If asked to resolve a story by name or number, search the issues (`gh issue list --search`), not the pull requests.
- **Read-only navigation.** The navigator never creates, edits, links, or transitions anything itself. It resolves and reports; the phase-step skills and `write-story` (for issues) do the writing. Dispatch (below) routes to those skills, it does not write here.
- **The navigator reports; the steps run.** The steps run on their own between the two human checkpoints. This navigator still does not start one unasked: it surfaces the next step and lets the human choose. Dispatch only on explicit request, and hand off to the owning step-skill rather than writing here. Running steps side by side follows the handbook page `orchestration.md` and never removes a checkpoint.
- **Be honest about coverage.** The graph is incremental; state that the report reflects only artifacts that have opted in (front-matter) or are linked in GitHub Issues. Do not assert a phase is "done" from absence of evidence.
- **No direct writes.** No creating work items, no front-matter edits, and no issue writes from the navigator itself. When the user wants to act, dispatch to (or point them at) the owning skill, which writes behind its own checkpoint.

## Failure modes

- **An expected artifact is absent** -> that means it was never linked, or it was never made, and the two look the same from here. Report the missing edge as unknown rather than concluding the work is undone.
- **The key matches more than one item** -> list key, summary and status and ask. Guessing which story the user meant sends the whole report to the wrong place.
- **A story key turns out to be a pull request** -> issues and pull requests share numbers on GitHub. A story is always an issue; report the mix-up and ask for the issue key.
- **A phase looks complete because nothing goes against it** -> the graph is incremental and only covers artifacts that opted in. Absence of evidence is not finish; say what the report can and cannot see.
- **The user asks for the next step and it gets run automatically** -> surface it and let them choose. Dispatch only on explicit request, and then hand to the owning skill, which runs up to its checkpoint.
- **A story without the `refined` label or a `size:<n>` label is routed to the build** -> the build loop stops at its start condition. Report the missing refinement and route to `/write-story` instead.
- **Several next steps are really independent and get dispatched together** -> running side by side never removes a checkpoint. Each dispatched skill still stops at Checkpoint Alpha for a GitHub issue write, and ends at a pull request a person reviews.
- **The report is asked to fix a broken link it found** -> it does not write. Offer `/write-story`, which writes the link in its update mode, and re-run.

## Observable signal

**Positive:** someone who picks up a work item they do not know sees which phase it is in and which skill runs next. They do not read the whole work item history or guess from the status field.

**Audit trail:** on purpose none. This skill writes nothing, so its output is a report, not a record; anything worth keeping is written by the skill it dispatches to.

**Drift signal:** if the report keeps coming back with missing edges on items that clearly did the work, artifacts are not joining the graph. The front-matter step is being skipped. If people keep asking "what now" after reading it, the output is naming phases rather than naming the next action.

## Next steps

- Run the skill this report found, owned by the named persona (for example `/write-api-spec`, then `/implement`).
- To run several really independent next steps at once, dispatch them as the handbook page `orchestration.md` says. Run them side by side where the tool can, and one after the other elsewhere. Each still stops at its checkpoint for the writes that leave the machine.
- An expected edge can be missing because it was never linked, not because the work is undone. Then fix the link with `/write-story`, which writes it in its update mode. Then re-run this navigator.
- Run `pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1` to validate that the repo-side `relates:` links really resolve.

## Sources

- The routing by situation follows the method of `skills/engineering/ask-matt/SKILL.md` in
  [mattpocock/skills](https://github.com/mattpocock/skills), MIT licence, Copyright (c) 2026 Matt Pocock.
  Read the skill before you recommend it, and do not trust a summary.
