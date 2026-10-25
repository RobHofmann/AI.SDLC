---
name: github-issue-conventions
kind: knowledge
user-invocable: false
description: >
  The house conventions for a GitHub issue in the tracker repository named in aisdlc.json. They cover the
  repository, the parent issue of an epic and its sub-issues, the size label, the emoji template and AC-n
  criteria. They also cover labels, priority, the size scale, the estimate as a comment, the duplicate
  scan, the readiness check and the gh commands.
  Use when drafting, sizing, reviewing or updating an issue in that repository. Also use when the
  draft-reviewer agent checks a draft, or when a build checks that its story is refined. Do NOT use to
  run the story workflow and its Checkpoint Alpha confirmation, or to write an existing issue (both
  write-story).
---

# GitHub issue conventions

Use this whenever an issue is drafted or judged. `write-story` (also in its update mode) and
`fix-bug` load it, and the `draft-reviewer` agent preloads it. The full template and a worked
example are in the story template reference.

## Constants

- The tracker repository is `tracker.repository` in aisdlc.json (`owner/name`), else the git remote.
- An issue key is `#42`; an issue in another repository is `owner/repo#42`. A pull request may name it
  only when `tracker.acceptedRepositories` in aisdlc.json lists that repository.
- An epic is a parent issue; its stories are its sub-issues, linked with `--parent`.
- The size is a label with the prefix `tracker.sizeLabelPrefix` (default `size:`). A new issue has none.
- On create, set the labels with `--label` and the parent with `--parent`.
- Always supply a body on create (`--body-file`), or an issue template may give a default body.

## The template

- Seven sections, with the emoji headings exactly as written, because automation keys off them:
  `📌 Background`, `🧒 ELI5`, `🎯 What's the Goal?`, `💡 Expected Value`, `✅ Success Criteria`,
  `🛠️ How we'll do it`, `⚠️ Risks & Blockers`. Dev-ready stories may add `🔧 Technical Implementation`.
- `🧒 ELI5` is required: plain words a newcomer gets at once, not a copy of the goal.
- Code names (files, classes, methods) go only in the technical sections: How we'll do it, Technical
  Implementation, Success Criteria and, where needed, Risks & Blockers. The narrative sections name
  facts and issue keys, not symbols.
- The goal is "As a ..., I want ..., So that ...".
- An update of an existing issue only adds to the person's text. The exception is a diff the person confirmed as shown in the run.
  That is at Checkpoint Alpha of `write-story` or `fix-bug`, or in the run's one list of issue updates. It may rewrite a title or a disproved claim.

## Acceptance criteria

- Number them `AC-1`, `AC-2`, ... and never renumber; append new ones.
- Each one is specific, observable, one assertion, about the result and not the code path.
- Cover the edges: the empty state, the same-on-both-sides case, the unaffected neighbour, the error path.
- Say how each is covered. Covering tests carry `[Trait("Story","#1234")]` or the test convention of the installed stack pack; there is no per-criterion `AC` trait. A criterion no unit test can check is marked as a check by hand.

## Labels, priority, kind

- The default priority needs no label. Add `priority-high` or `priority-critical` only for a production blocker.
- A new issue carries the label in `tracker.toRefineLabel` (default `to-refine`) and the labels in
  `tracker.labels` of aisdlc.json. Never the label in `tracker.refinedLabel` (default `refined`): a
  person sets that label and the size label when refining.
- Kinds: a story or a task is a plain issue. A bug carries the `bug` label. A spike carries the `spike`
  label. An epic is a parent issue with sub-issues. A spike is a research step. It uses the story
  template. Its Success Criteria say what the research must answer, each as one question with the
  evidence that settles it.
- A kind change (bug to story) is a label change (`--add-label`, `--remove-label`), plus `--type` when the repository uses issue types.

## The estimate

Leave the size label off and post the estimate as a comment right after create. Place the story among
3 to 5 comparable, recently closed issues. Find them with `gh issue list --state closed --search
"<keyword>" --json number,title,labels,closedAt`; the size is in the `labels` of each:

```
💰 Estimate proposal: size 5. Comparable to #2537 (5, reused an existing engine plus a
wiring layer); above a 3, below an 8. Set the size label during refinement.
```

Observed scale: **2** a very small fix or ops task; **3** a small multi-step task; **5** a medium task
such as a new endpoint. **8** is a substantial feature with a domain model, UI and tests; **13** is a
large migration.

## Before drafting and before Checkpoint Alpha

- **Duplicate scan, always first.** Search with more than one query (keyword, words with the same
  meaning, the component name), with `--state all`. Restrict `--json` to number, title, state, labels
  and createdAt. Surface a collision; the person decides reuse or new.
- **Readiness check**, each point pass, fail or unknown: criteria present; criteria testable; all seven
  sections filled; governing ADR, spec or PRD linked. Then: one concern; scope clean; estimate honest
  with `to-refine`; every technical claim read in the code or marked as an open question.
- Questions the substrate cannot answer go into an "Open questions" list for the person at Checkpoint Alpha.

## The start condition for a build

A build starts on its own only from an open issue with the `refined` label and a size label
([orchestration.md](/.claude/skills/ai-sdlc-handbook/references/orchestration.md)). A story without both stops the build; say what is missing.

## GitHub tools

Checked on 2026-10-23 against gh 2.97.0. The same commands run in Claude Code and in GitHub Copilot.

- Read: `gh issue view <n> --json number,title,body,state,labels,comments,parent,subIssues,blockedBy,url`
  and `gh issue list --search "<query>" --state all --json <fields>`.
- Write: `gh issue create`, `gh issue edit` (`--title`, `--body-file`, `--add-label`, `--remove-label`,
  `--parent`, `--add-sub-issue`, `--add-blocked-by`) and `gh issue comment --body-file`.
- **`gh issue edit --body-file` replaces the whole body.** Always start from the body you just read and
  splice into it; a blind write deletes everything already there.
- When a command fails, check `gh <command> --help`. Never edit this installed file: propose the fix as a
  shared lesson for AI.SDLC, as [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md) says.

## Sources

- [Story template and worked example](/.claude/skills/write-story/references/story-template.md) - the full template.
- [Node templates](/.claude/skills/ai-sdlc-handbook/references/node-templates.md) - the story as a node in the artifact graph.
- [Orchestration](/.claude/skills/ai-sdlc-handbook/references/orchestration.md) - the two human checkpoints and the start condition for a build.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).
