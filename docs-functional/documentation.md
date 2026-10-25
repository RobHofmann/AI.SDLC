# Complete documentation

Every repository that uses the AI-SDLC has two layers of docs, and every part of its code has a page. A
reader, a person or an agent, then finds a true page for each part instead of guessing.

## What you get

- **A technical layer** that says how the repository is built. It has one page for each unit: a .NET
  project, a Bicep building block, or a package.
- **A functional layer** that says what the repository gives its users, in plain words.
- **A gate that keeps it complete.** `Check-DocCoverage.ps1` fails when a layer is missing or a unit has
  no page, and names the page to write.
- **A first draft of each missing page.** The `adopt-docs` skill collects the facts of the unit
  from the code into a facts file, and an agent drafts the page from it. You check each claim before it is merged.

## When you need it

- A repository has just joined the AI-SDLC: run `/adopt-docs` once, in its own pull request.
- A change adds a project or a building block: `write-docs` adds its page in the same change.
- A change touches an area that has no page yet, such as deployments. Then `write-docs`
  writes a page for the whole area in both layers. No gate checks this; `wrap-up` does.
- A page you wrote fails the reading level or another doc gate: `write-docs` rewrites that page.

## What to know

- A draft is a proposal from an agent. Nothing reaches a page until a person has checked it against the code.
- A page that covers a unit under another name says so in its front matter (`unit: <path>`).
- A unit that nobody uses can be left out, with the reason in the pull request.

## Related

- [What the AI-SDLC gives a team](overview.md) - where complete docs fit in the way of working.
- [core](../docs/packages/core.md) - the gate and the drafting tool live in the core.
- [Glossary](glossary.md) - what a unit and a layer are.
- [Index](index.md) - every page of this layer.
