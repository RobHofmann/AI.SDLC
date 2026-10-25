# GitHub issue template

The tracker repository in `tracker.repository` uses this 7-section markdown template for its issue body.
The emoji headers are house style and automation keys off them, so keep them exactly as written. Supply a
real body on create so a repository issue template does not leave it blank or default.

## The template

```
📌 Background

* [What happened, the current state, why this story exists. Plain terms, no code symbols:
  describe the situation, not the classes. Reference the originating issue key if this
  extends prior work.]

🧒 ELI5

* [Explain this story in plain language a non-technical reader gets instantly: no jargon,
  an analogy if it helps, two or three sentences on what this is and why it matters. Required.
  Keep it distinct from the Goal and Expected Value below, which stay in product and domain
  terms (still no code symbols).]

🎯 What's the Goal?

* As a [persona],
* I want [capability],
* So that [reason].

💡 Expected Value

* [Measurable or concrete impact: faster review, fewer incidents, cost, UX. Plain terms,
  no code symbols.]

✅ Success Criteria

* AC-1: [One checkable condition that makes this done.] Covered by: [a unit test, or a check by
  hand].

🛠️ How we'll do it

* [Approach, dependencies, the components touched. Name real files/classes for dev work.]

⚠️ Risks & Blockers

* [What might slow this down, what needs alignment, what is explicitly out of scope.]
```

## Technical vs non-technical sections

Code-level detail (files, classes, methods, API symbols) belongs in the technical
sections only: `🛠️ How we'll do it`, `🔧 Technical Implementation`, `✅ Success Criteria`,
and, where needed, `⚠️ Risks & Blockers`. The narrative sections - `📌 Background`,
`🧒 ELI5`, `🎯 What's the Goal?`, `💡 Expected Value` - describe the situation and the
value in plain terms with no code symbols. State the fact, not the identifier: write "the
order revision it was based on", not "`BaseRevisionId`". Referencing another
issue key (for example #2649) in a narrative section is fine; naming a class or file
is not. Success Criteria stays outcome-focused but may name a symbol when the check itself
is at that level, for example asserting a deployment payload.

## Optional: Technical Implementation section

For dev-ready stories (especially platform work), add a `🔧 Technical
Implementation` section after `🛠️ How we'll do it`. List the files reused as-is, the
new/changed components with their paths, the data sources (API methods), and the tests
to add. This is what makes a story pick-up-and-build ready. Name real symbols, for
example `Services/OrderRevisionDiffService.cs` and the method that does
the work, so the implementer does not have to find them again.

## Worked example

This example is made up, in the order portal of Contoso, a company that does not exist. It shows the shape a
story built from this pattern takes. Note the split. The narrative sections stay plain with no code
symbols. Concrete files and methods appear only in How we'll do it and Technical Implementation.
Also note the numbered success criteria, each with how it is covered, and the explicit out-of-scope.
The issue carries no size label. The estimate is 5, because the story reuses an existing diff
engine and only adds a version picker and the wiring. It is proposed in a comment for a person to
set during refinement.

```
📌 Background

* Today the order portal can compare two revisions of an order, but only one fixed pair: the
  change panel shows the revision being viewed against the revision it was based on. Built in
  #2328.
* The compare-and-show logic underneath already works for any two revisions, not just that pair.
* Users have no way to pick two revisions of their choice and compare them. Related: #2489.

🧒 ELI5

* The portal can already show what changed, but only for one fixed pair of revisions. This adds
  two dropdowns so you can pick any two saved revisions and see the differences, like laying two
  drafts of a document side by side. It reuses the existing compare view, so it looks and behaves
  the same.

🎯 What's the Goal?

* As an order administrator,
* I want to select any two revisions of an order and see the differences,
* So that I can audit how an order changed over time, not just the automatic pair.

💡 Expected Value

* Reviewers and auditors can inspect the change history when they need it.
* Reuses the existing, proven compare view, so behaviour stays consistent.

✅ Success Criteria

* AC-1: The user can choose a left and a right revision from the list of saved revisions.
  Covered by: a unit test.
* AC-2: Selecting two revisions shows the existing compare view with the differences of those two.
  Covered by: a unit test.
* AC-3: Selecting the same revision on both sides shows a clear "identical revision" empty state.
  Covered by: a unit test.
* AC-4: The existing automatic compare panel is unaffected. Covered by: a check by hand.

🛠️ How we'll do it

* Add a revision picker that lists the revisions through `GetOrderRevisionsAsync`.
* Fetch both revisions with `GetOrderRevisionByIdAsync`, serialize them, and call
  `OrderRevisionDiffService.BuildDiff(leftJson, rightJson)`.
* Pass the result to `OrderRevisionDiffView`.

🔧 Technical Implementation

* Reused as-is: `Services/OrderRevisionDiffService.cs`, `OrderRevisionDiffView.razor`
  (+ `.razor.css`).
* New: a small `OrderRevisionCompare.razor` with two pickers, which follows the fetch, serialize
  and diff steps in `OrderDetails.OnInitializedAsync`.
* Tests (the portal test project): the picker mapping, the compare of two chosen revisions and the
  same-revision short-circuit, each with the story trait.

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
- After create: name the source story and any placeholder under `🔗 Related & why` in the body, as `#2489 - <one-line why related>`.
