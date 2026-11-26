# GitHub issue template

The tracker repository in `tracker.repository` uses this six-section markdown template for its issue body.
The emoji headers are house style and automation keys off them, so keep them exactly as written. Supply a
real body on create so a repository issue template does not leave it blank or default.

Each section has a budget, so an issue fits on one screen. The budget is in the placeholder of the
section, and `github-issue-conventions` holds the rule (ADR 0023).

An issue whose criteria heading is `✅ Success Criteria` has the old form. That form has an ELI5, at
most 5 bullets in the background and at most 8 criteria. Keep that form for the issue. Do not change
it to the new form unless the person asks. Every new issue uses the form below.

## The template

```
🎯 What's the Goal?

* As a [persona],
* I want [capability],
* So that [reason].

📌 Background

* [At most 3 bullets. What happened, the current state, why this story exists. Plain terms, no
  code symbols: describe the situation, not the classes. Reference the originating issue key
  if this extends prior work. Times, log counts and run names go in the dated evidence comment.]

🛠️ How we'll do it

* [At most 5 bullets. The approach and what is reused. Name a file only to point at reuse or a
  trap. No code calls or release steps: the plan step of implement writes those. Test results
  and probes go in a dated evidence comment, not here.]

💡 Expected Value

* [At most 3 bullets. Measurable or concrete impact: faster review, fewer incidents, cost, UX.
  Plain terms, no code symbols.]

✅ Acceptance Criteria

* AC-1: [One checkable condition about behaviour, in plain words. A story, bug or task has at most 5 criteria; more means a split.]
* AC-2: [A criterion that no test can check says so.] Covered by: a check by hand.

⚠️ Risks & Blockers

* [At most 3 bullets. What might slow this down, what needs alignment, what is explicitly out of
  scope.]
```

The update mode of `write-story` adds `🔗 Related & why`, `🧭 Decisions & ADRs` and
`📎 Artifacts & references`. They stay after `⚠️ Risks & Blockers`.

## Technical vs non-technical sections

Code-level detail (files, classes, methods, API symbols) belongs in the technical
sections only: `🛠️ How we'll do it` and, where needed, `⚠️ Risks & Blockers`. The other sections
(`🎯 What's the Goal?`, `📌 Background`, `💡 Expected Value` and `✅ Acceptance Criteria`) describe the
situation, the value and the behaviour in plain terms with no code symbols. State the fact, not the
identifier: write "the order revision it was based on", not "`BaseRevisionId`". A plain section may
name another issue key (for example #2649). It does not name a class or a file. A criterion names no
file, class, setting or rule ID. It says what a person can observe.

There is no `🔧 Technical Implementation` section. The plan step of `implement` writes the build plan:
the files, the methods and the tests to add. It reads the code at build time.

## What is not a criterion

A criterion describes behaviour that a test or a person can observe. These belong to the definition
of done, so they are not criteria: the docs are updated, an ADR is written, the gates pass. Name a
needed ADR in `🛠️ How we'll do it` instead.

## Worked example

This example is made up, in the order portal of Contoso, a company that does not exist. It shows the
shape a story built from this pattern takes. Note the split. The plain sections stay without code
symbols. Concrete files appear only in How we'll do it, and only to point at what is reused. Also
note the numbered acceptance criteria, the one criterion that names its check by hand, and the
explicit out-of-scope. The issue carries no size label. The estimate is 5, because the story reuses
an existing diff engine and only adds a version picker and the wiring. It is proposed in a comment
for a person to set during refinement.

```
🎯 What's the Goal?

* As an order administrator,
* I want to select any two revisions of an order and see the differences,
* So that I can audit how an order changed over time, not just the automatic pair.

📌 Background

* Today the order portal can compare two revisions of an order, but only one fixed pair: the
  change panel shows the revision being viewed against the revision it was based on. Built in
  #2328.
* The compare-and-show logic underneath already works for any two revisions, not just that pair.
* Users have no way to pick two revisions of their choice and compare them. Related: #2489.

🛠️ How we'll do it

* Add a small compare page with two revision pickers on the existing order page.
* Reuse the diff engine in `Services/OrderRevisionDiffService.cs` and the view
  `OrderRevisionDiffView.razor` as they are.
* Follow the fetch, serialize and diff steps the order details page already uses.

💡 Expected Value

* Reviewers and auditors can inspect the change history when they need it.
* Reuses the existing, tested compare view, so behaviour stays consistent.

✅ Acceptance Criteria

* AC-1: The user can choose a left and a right revision from the list of saved revisions.
* AC-2: When the user selects two revisions, the portal shows the existing compare view with the differences of those two.
* AC-3: When the user selects the same revision on both sides, the portal shows a clear "identical revision" empty state.
* AC-4: The existing automatic compare panel is unaffected. Covered by: a check by hand.

⚠️ Risks & Blockers

* Scope creep on placement (a new route, deep links and authorization) could push 5 toward 8.
  Keep the first version on the existing page.
* Overlaps with #2489; named under Related & why.
* Out of scope: comparing revisions of two different orders, exporting the diff.
```

## Fields set when the story is created (for the worked example)

- `gh issue create -R <tracker.repository> --title "<title>" --body-file <body.md>`
- `--label "<a label from tracker.labels>" --label to-refine`
- `--parent 2518`, the epic this story belongs to. The size label (prefix `tracker.sizeLabelPrefix`) is left out on purpose; a human sets it during refinement.
- After create: post the estimate-proposal comment with `gh issue comment <n> --body-file <comment.md>`, e.g. `💰 Estimate proposal: size 5. Comparable to <key> (5, reused an existing engine + wiring layer); above a 3, below an 8. Set the size label during refinement.`
- After create, when `grilling` gave a docs impact that changes a page: post it as one comment, e.g. `📚 Docs impact 2026-11-26 14:05` with one line per page, such as `docs-functional/glossary.md: a release is the tag; the re-pin is the move to it.`
- After create: name the source story and any placeholder under `🔗 Related & why` in the body, as `#2489 - <one-line why related>`.
