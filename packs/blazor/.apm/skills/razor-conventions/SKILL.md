---
name: razor-conventions
kind: knowledge
user-invocable: false
description: >
  The Razor rules for a Blazor component and the two gates that hold them: attributes on their own
  line, no interface over a state class, no inline style block, one document root, state change
  events, null API results, dispose, and Razor security. Use when writing or reviewing a .razor file or
  a component's state class, or when a Razor gate failed. Do NOT use for a .css file (css-conventions)
  or authorization (blazor-authorization).
---

# Razor conventions

A Blazor component in this codebase follows one shape, so reviewers do not have to teach it one pull
request at a time. This skill holds the Razor rules: the markup and the `@code` block of a component.
The rules that can be checked by a script are gates in this skill's `scripts/` folder, registered in
`gates.json` for the `blazor` pack. Both read the source root from `aisdlc.json`, and exit 2 when it
is not configured.

The `blazor` pack brings the `css` and `javascript` packs, so `css-conventions` covers the style
sheets of a component and `javascript-conventions` its JavaScript modules.

## Before you write

- **The shared rules first.** Reuse, scope, the comment rule of clause C10 and the severity scale
  hold in every language. They live in
  [code-conventions](/.claude/skills/code-conventions/SKILL.md); this skill adds the Razor side only.
- **Team names are settings.** A design system, a CSS variable or the name of an API client belongs on
  a page of the repository, not in a shared file. When none names it, follow the components next to
  your change.

## The two gates

| Script | Mode | What it checks |
|---|---|---|
| `Check-RazorConventions.ps1` | Blocking | No `I*State` interface over a state class, no inline `<style>` block, and no `<!DOCTYPE` outside the one document root in `dotnet.portalAppComponent` of `aisdlc.json` |
| `Check-RazorAttributePlacement.ps1` | Blocking | `[Parameter]`, `[CascadingParameter]`, `[Inject]` and the other component attributes sit on their own line, above the member |

```bash
pwsh .claude/skills/razor-conventions/scripts/Check-RazorConventions.ps1
pwsh .claude/skills/razor-conventions/scripts/Check-RazorAttributePlacement.ps1
```

## The rules no script checks

- **Subscribe to a state change the same way as the other components.** The handler property returns
  a new delegate each time it is read, so `-=` removes nothing. For a singleton state, store the
  delegate in a field first, so `+=` and `-=` use the same object.
- **Handle a null result from the API client.** The client turns an error response into a
  notification and returns null. A call site that does not check for null lets the exception reach the
  error boundary, which replaces the whole page.
- **Render a page through the router.** Do not build a second way to deliver a page. If the normal way
  does not fit, write an ADR.
- **No inline style.** The style of a component lives in its `*.razor.css` file, as
  `css-conventions` says. A condition in the markup adds a class, not a `style` attribute.
- **Dispose what the component holds:** a subscription, a `DotNetObjectReference`, a JS module. No
  state change after dispose, and work that runs once in `OnAfterRender` checks `firstRender`.

## Security

The `security-reviewer` agent reads this section when a change touches a Razor file.

- **Read [blazor-authorization](/.claude/skills/blazor-authorization/SKILL.md) in full** for a change
  to authorization. It holds the checks on render mode, the router, page attributes and policy handlers.
- **No raw HTML from input** in a `MarkupString` or through JS interop.
- **A JS interop call never receives a secret**, such as a token or a connection string.

## Sources

- [Razor rules](references/razor.md) - every rule with its example and its reason.
- [CSS conventions](/.claude/skills/css-conventions/SKILL.md) - the style sheet of a component.
- [JavaScript conventions](/.claude/skills/javascript-conventions/SKILL.md) - the JavaScript module of a component.
- [Code conventions](/.claude/skills/code-conventions/SKILL.md) - the rules for every language.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).
