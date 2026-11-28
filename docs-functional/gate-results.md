# How a gate answers

A gate is a check that can stop a change. This page says what its answer means for you. It also says
how a repository makes a gate stricter or softer. Last, it says how an agent states that a test, a
page or a decision record is not needed. The technical detail is on the [core package page](../docs/packages/core.md).

## What you get

- **Four answers, not two.** A gate passes, finds a problem, could not check, or has nothing to check.
  A run shows them as `PASS`, `FAIL` (or `ADVISORY` for a gate that only warns), `UNVERIFIED` and `N/A`.
- **A green pull request build you can trust.** When a blocking gate could not check, for example
  because a tool or a setting is missing, the pull request build fails. On your own machine the same
  answer is a warning, so a missing tool does not stop your push.
- **A fast check on your machine.** A local run checks only what your change touches. A gate it left
  out shows `NOT TOUCHED`. The pull request build always runs every gate, so nothing is lost before a
  merge.
- **One list of every gate.** The [gate list](../core/.apm/skills/ai-sdlc-gates/references/gate-catalog.md)
  says what each gate checks and how to fix what it finds. A gate that fails prints the same text
  before its own output.

## When you need it

- A gate shows `UNVERIFIED` in the pull request build: read the line that starts with `FIX:` and set up
  what it names, such as a setting in `aisdlc.json`.
- A shared gate does not fit your repository: set its mode in `gateModes` of your own `aisdlc.json` to
  `Advisory` or `Off`, and say why in the pull request. Every run shows the choice, and a weaker mode
  gives a warning, so a reviewer sees it. Three gates always run Blocking, whatever you set: the secret
  scan, the private-terms gate and the sync manifest check.
- You see `No-Test:`, `No-Docs:` or `No-ADR:` at the end of a commit message: that is a waiver. The agent
  states why the change needs no new test, no page or no decision record. Only `wrap-up` writes it,
  after a reviewer agent agrees with the reason. The gate prints each waiver it used.

## What to know

- You, the person who reviews the pull request, judge each waiver. The gate checks only that the reason
  has the right form, never that it is true.
- A gate that is `Off` checks nothing in your repository. Turn a gate off only for a reason you can
  defend, and turn it back on when the reason is gone.
- A decision record (ADR) is needed only for a decision that is hard to undo, surprising without
  context, and a real trade-off. [ADR 0021](../docs/adrs/0021-a-stated-waiver-clears-a-test-doc-or-adr-finding.md)
  describes the waiver for it.

## Related

- [What the AI-SDLC gives a team](overview.md) - the way of working that these gates check.
- [Taking a new version](new-version.md) - version 2.0.0 changes how the pull request build reads a gate.
- [Glossary](glossary.md) - the words gate, gate mode and waiver.
- [Index](index.md) - every page of this layer.
