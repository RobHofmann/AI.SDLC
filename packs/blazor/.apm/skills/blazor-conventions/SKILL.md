---
name: blazor-conventions
kind: knowledge
user-invocable: false
description: >
  The Blazor component conventions and the two gates that hold them. They cover attributes on their
  own line, no interface over a state class, no inline style block, one document root. It also covers the state
  change event pattern and its singleton trap, and a null result from the API client handled at the
  call site. Use when writing or reviewing a .razor file or a component's state class, or when a Razor
  gate failed. Also use when a component subscribes to a state change. Do NOT use for authorization in
  the portal (blazor-authorization), for C# rules that are not about components
  (csharp-generation-smells) or to write a new gate (add-gate).
---

# Blazor conventions

A Blazor component in this codebase follows one shape, so reviewers do not have to teach it one pull
request at a time. The rules that can be checked by a script are gates in this skill's `scripts/`
folder, registered in `gates.json` for the `blazor` pack. Both read the source root from
`aisdlc.json`, and exit 2 when it is not configured.

## The two gates

| Script | Mode | What it checks |
|---|---|---|
| `Check-RazorConventions.ps1` | Blocking | No `I*State` interface over a state class, no inline `<style>` block, and no `<!DOCTYPE` outside the one document root in `dotnet.portalAppComponent` of `aisdlc.json` |
| `Check-RazorAttributePlacement.ps1` | Blocking | `[Parameter]`, `[CascadingParameter]`, `[Inject]` and the other component attributes sit on their own line, above the member |

```bash
pwsh .claude/skills/blazor-conventions/scripts/Check-RazorConventions.ps1
pwsh .claude/skills/blazor-conventions/scripts/Check-RazorAttributePlacement.ps1
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
- **Keep styling in the component's `*.razor.css`.** A scoped stylesheet does not travel with a class
  name copied from another component.

## Sources

- [Portal UI conventions](references/portal-ui.md) - every rule with its example and its reason.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).
