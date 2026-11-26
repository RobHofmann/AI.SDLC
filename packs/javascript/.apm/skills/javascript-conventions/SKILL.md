---
name: javascript-conventions
kind: knowledge
user-invocable: false
description: >
  The JavaScript rules: a component imports its own module after the first render, a module shares
  its functions with export function and has no var, a listener on document or window is removed
  when its element leaves the page, and a broken call is fixed, not hidden. Use when writing or
  reviewing a .js file or a JavaScript call from a component. Do NOT use for CSS (css-conventions) or
  Razor markup (razor-conventions).
---

# JavaScript conventions

This skill holds the JavaScript rules for the browser code of a repository. It applies to each change
to a `.js` file, and to a component that calls JavaScript. Each item points at the page that holds the
full rule; the page wins when the two differ. The `builder` agent reads it when a change touches
JavaScript.

## Before you write

- **The shared rules first.** Reuse, scope, the comment rule of clause C10 and the severity scale
  hold in every language. They live in
  [code-conventions](/.claude/skills/code-conventions/SKILL.md); this skill adds the JavaScript side
  only.
- **A point not decided** follows the file you edit, and a new file follows its neighbours.
- **The helper name is a setting.** Read the name of the cleanup helper from
  `javascript.cleanupHelper` in `aisdlc.json`. When it is not set, use the helper that the modules next
  to your change use. No shared file names the helper of a team.

## The rules

The full rules, with an example and a source each, are on [javascript.md](references/javascript.md).

- A component that needs JavaScript keeps it in its own module next to it, such as
  `OrderDialog.razor.js`. It imports the module once, after the first render, keeps the reference in
  a field and calls the module through it.
- A component does not call a function that a global script put on `window`. A boot script that runs
  before the app starts may still use globals.
- A module shares each function with `export function`, and has no `var`.
- A module that adds a listener to `document` or `window` also removes it when its element leaves the
  page, through the cleanup helper in `javascript.cleanupHelper`.
- A broken JavaScript call is fixed, not hidden. Do not wrap it in a `try` block that ignores the
  error, and do not catch a JS interop exception in a component to hide it.

## Security

The `security-reviewer` agent reads this section when a change touches a JavaScript file.

- **No `innerHTML`, `outerHTML` or `insertAdjacentHTML` with input.** Set `textContent`, or build the
  element with `createElement`, so input cannot run as script.
- **No `eval`, `new Function` or a string passed to `setTimeout`.** They run text as code.
- **A module never holds or logs a secret**, such as a token or a connection string.

## Before you call it done

- No listener on `document` or `window` stays behind when its element leaves the page.
- The shared checks, such as fixing the whole class of a finding, are in
  [code-conventions](/.claude/skills/code-conventions/SKILL.md).

## Sources

- [JavaScript rules](references/javascript.md) - each rule with its meaning, an example and a public
  source.
- [Code conventions](/.claude/skills/code-conventions/SKILL.md) - the rules for every language.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).
