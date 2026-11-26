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

- Six sections, with the emoji headings exactly as written and in this order, because automation keys off them:
  `🎯 What's the Goal?`, `📌 Background`, `🛠️ How we'll do it`, `💡 Expected Value`, `✅ Acceptance Criteria`,
  `⚠️ Risks & Blockers`. There is no `🧒 ELI5` section and no `🔧 Technical Implementation` section.
- Each section has a budget, so an issue fits on one screen (ADR 0023). `📌 Background`: at most 3 bullets.
  `🛠️ How we'll do it`: at most 5. `💡 Expected Value`: at most 3. `⚠️ Risks & Blockers`: at most 3.
  Every section uses plain words, with no file, class, setting or rule ID, except as the next point says.
- Code names (files, classes, methods) go only in How we'll do it and, where needed, Risks & Blockers.
  How we'll do it holds the approach and what is reused. It names a file only to point at reuse or a
  trap, never code calls or release steps; the plan step of `implement` writes those.
- **The old form.** An issue whose criteria heading is `✅ Success Criteria` has the old form. Its order is
  `📌 Background` (at most 5), `🧒 ELI5` (at most 2 sentences), `🎯 What's the Goal?`, `💡 Expected Value`,
  `✅ Success Criteria` (at most 8), `🛠️ How we'll do it`, `⚠️ Risks & Blockers`, and it may add
  `🔧 Technical Implementation`. Keep that form for the issue and do not change it unless the person
  asks. Every reader accepts `✅ Acceptance Criteria` and `✅ Success Criteria`.
- The body holds conclusions only. Test results, probes and measurements go in one evidence comment per run, which starts with
  `Evidence YYYY-MM-DD HH:mm`. The body points to it by that date and time. A date alone is not enough, because two runs on one day give two comments.
  The evidence comment has no budget and holds facts only, never a requirement or a decision. The one other dated
  comment is the docs impact of `grilling` (`📚 Docs impact YYYY-MM-DD HH:mm`): per docs page what it will say, docs scope for the build.
- The goal is "As a ..., I want ..., So that ...".
- An update only adds to a person's text. The exception is a diff the person confirmed as shown in the run.
  That is at Checkpoint Alpha of `write-story` or `fix-bug`, or in the run's one list of issue updates. A section the agent wrote is rewritten, not added to, as `write-story` update mode says.

## Acceptance criteria

- Number them `AC-1`, `AC-2`, ... and never renumber; append new ones.
- Each one is specific, observable, one assertion, about behaviour and not the code path. It uses plain
  words and names no file, class, setting or rule ID. Docs, ADRs and gate results are the definition of
  done, not criteria.
- A story, bug or task has at most 5 criteria, or 8 in the old form. An epic and a spike have no limit.
  An issue that needs more is split before Checkpoint Alpha, unless the person keeps it whole on purpose.
- Cover the edges: the empty state, the same-on-both-sides case, the unaffected neighbour, the error path.
- A test covers a criterion unless the criterion says otherwise. Name the coverage only when it is not a
  test, for example `Covered by: a check by hand`. Covering tests carry `[Trait("Story","#1234")]` or the
  test convention of the installed stack pack; there is no per-criterion `AC` trait. An issue in the old
  form may still name the test for each criterion.

## Labels, priority, kind and the estimate

A new issue carries `to-refine` and no size label; a person sets `refined` and the size. The labels, the kinds,
the estimate comment and the size scale are in [labels and estimate](references/labels-and-estimate.md).

## Before drafting and before Checkpoint Alpha

- **Duplicate scan, always first.** Search with more than one query (keyword, words with the same
  meaning, the component name), with `--state all`. Restrict `--json` to number, title, state, labels
  and createdAt. Surface a collision; the person decides reuse or new.
- **Readiness check**, each point pass, fail or unknown. The points: criteria present; criteria testable;
  all sections of the form filled; governing ADR, spec or PRD linked. Then: one concern; scope clean;
  estimate honest with `to-refine`; every technical claim read in the code or marked as an open question.
  Last, the size: a section over its budget fails, and the fix is to trim. More than 5 criteria on a
  story, bug or task, or more than 8 in the old form, fails, and the fix is to split. The person may
  keep either on purpose at Checkpoint Alpha.
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
- [Labels and estimate](references/labels-and-estimate.md) - the labels, the kinds, the estimate comment and the size scale.
- [Node templates](/.claude/skills/ai-sdlc-handbook/references/node-templates.md) - the story as a node in the artifact graph.
- [Orchestration](/.claude/skills/ai-sdlc-handbook/references/orchestration.md) - the two human checkpoints and the start condition for a build.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).
