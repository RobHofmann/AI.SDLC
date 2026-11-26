# Labels, priority, kind and the estimate

The detail behind the `github-issue-conventions` skill for the labels of an issue and its estimate comment.

## Labels, priority, kind

- The default priority needs no label. Add `priority-high` or `priority-critical` only for a production blocker.
- A new issue carries the label in `tracker.toRefineLabel` (default `to-refine`) and the labels in
  `tracker.labels` of aisdlc.json. Never the label in `tracker.refinedLabel` (default `refined`): a
  person sets that label and the size label when refining.
- The label in `tracker.inReviewLabel` (default `in-review`) says a published pull request waits for
  review. Only the `move-story` skill adds it, after the person published the draft (ADR 0022). The
  view of waiting work is `is:open label:in-review`.
- Kinds: a story or a task is a plain issue. A bug carries the `bug` label. A spike carries the `spike`
  label. An epic is a parent issue with sub-issues. A spike is a research step. It uses the story
  template. Its Acceptance Criteria say what the research must answer, each as one question with the
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

## Related

- [github-issue-conventions](../SKILL.md) - the skill this page belongs to.
