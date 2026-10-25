# Your first story

This page takes you through one small story, from the work item to a merged pull request. Read it
once before your first run. The [handbook start page](README.md) has the full picture.

## Pick a small story

Your first story is about learning the flow, not about the change. So pick one that is small and clear:

- a small fix with a known cause, such as a wrong message or a missing check;
- a small task, such as one setting, one log line or one page of documentation.

Leave out a story that changes a contract, a data model or the architecture, because it needs an ADR
(Architecture Decision Record) and more people. Leave out a story whose acceptance criteria you
cannot test yet.

## Run it

1. Run `/guide-me #42`. It reads the story and the repository, and names the next step. It
   writes nothing.
2. If it says the story is thin, run `/write-story` (github-issues pack) to improve it. You answer a few
   questions. Then you check the draft at Checkpoint Alpha.
3. A person refines the story issue: the `refined` label and a `size:<n>` label. `/implement` starts
   only then.
4. Build the change with `/implement #42`. The tests come first. It runs `/wrap-up`, which
   commits and runs the pre-flight, then it pushes and opens or updates the pull request.
5. If you made the change by hand, make sure it is on a branch named with the story key, such as
   `42-<topic>`, never on `main`. Then run `/wrap-up` instead; it stops on a branch with no
   story key. It finds what still refers to what you
   changed, and brings the tests, both documentation layers and the story up to date. Then it commits
   and runs the pre-flight on that commit: the checks of the pull request workflow, run locally. A green run writes
   the receipt the push hook asks for. A commit is not a sign-off; you still review at Checkpoint Bravo. Then
   push and open or update the pull request yourself.

## What you check at the two human checkpoints

At **Checkpoint Alpha** you check the story draft before it is written to the tracker:

- every acceptance criterion can be tested;
- the open questions are answered, or left open on purpose;
- the scope is the small change you picked, and no more.

At **Checkpoint Bravo** you check the pull request before it is merged:

- the diff does what the story asks, and nothing else;
- each acceptance criterion has a test, or is marked as a check by hand;
- the evidence record in the description matches the diff (when it does not, trust the diff and ask why);
- both documentation layers describe the change.

A green build is a request for review, not proof. You or a reviewer decide ([C09](constitution.md),
[orchestration](orchestration.md)).

## Capture what went wrong

Something will go wrong on your first story, and that is useful. Write it down where the next run
will find it:

- After the review, run `/fix-pr-feedback` on the pull request. It fixes the comments, and its
  `wrap-up` step runs `/capture-learning` on the review before the push. That turns the comments into
  rules and routes each one to its home. Run `/capture-learning` by hand only for a review you worked
  another way.
- When you corrected the agent during the work, run `/capture-learning` too. It checks whether the
  lesson is general, and proposes where it goes.

Both runs follow [autolearn](autolearn.md). When you type `/capture-learning`, it waits for your go
before it writes. Inside `wrap-up` it does not wait. A lesson for a file in this repository is part of
the commit, and you see it in the diff at Checkpoint Bravo. A new or changed clause still stops for you.

## Related

- [The AI-SDLC](README.md) - the phases, the skills and the worked examples after this first one.
- [Orchestration](orchestration.md) - the two human checkpoints, and when the run stops to ask.
- [Autolearn](autolearn.md) - how a lesson from your story becomes a lasting rule.
- [Language and reading level](language.md) - how the story, the pages and the pull request are written.
