---
name: blazor-authorization
kind: knowledge
user-invocable: false
description: >
  The checks to run before an authorization change in a Blazor portal. They keep closed the in-circuit
  navigation gap that has come back more than once. They cover render mode, router composition, page
  attributes, the three resource branches in a policy handler, the admin short-circuit, and the
  six-cell test matrix. Use when about to read or edit Routes.razor, App.razor, a page with an
  Authorize attribute, or an authorization requirement or its handler. Also use for a *PageState.cs
  that calls IsAuthorizedFor or AuthorizeAsync. Do NOT use for API controller policies alone or for a
  portal change that touches no authorization.
---

# Blazor authorization

A portal with page authorization should have its design recorded in an ADR in the ADR folder
(`paths.adrFolder` in aisdlc.json). Find that ADR and read it before you change anything in this area;
the rest of this skill assumes you have. The `security-reviewer` agent loads it when it reviews a
diff that touches the files below. `implement`, `refactor` and `fix-pr-feedback` load it
themselves when they review a security-relevant diff without agents.

## When it applies

- the portal's `Routes.razor`, or its `App.razor` (`dotnet.portalAppComponent` in aisdlc.json)
- any `*.razor` with `@attribute [Authorize`
- any authorization requirement or its handler, usually in a shared security project under the source
  root (`paths.sourceRoot`)
- any `*PageState.cs` that calls `IsAuthorizedFor` or `AuthorizeAsync`, or builds a resource object for
  a resource-based policy
- any code that wraps `<AuthorizeRouteView>` or `<AuthorizeView>`

Answer every item below before you propose code. "I think" is not an answer; "I read the symbol in
file X" is.

## The checklist

1. **Render mode.** Read `App.razor` and copy the `@rendermode` on `<Routes>`, for example
   `InteractiveServerRenderMode`. An interactive mode has a circuit, so endpoint routing covers only the
   first request; static SSR has no circuit.
2. **Router composition.** Read `Routes.razor`. `<RouteView>` ignores `[Authorize]`. `<AuthorizeRouteView>`
   honours it, but passes `Resource=null` to the policy unless `Resource="routeData"` is set, and a
   resource-based handler fails closed on null.
3. **Page declaration.** Read the `@page` line and the lines after it. Copy any `[Authorize(...)]` and any
   `@rendermode` on the page: a page directive overrides the inherited mode, and a missing attribute
   means no declared check.
4. **Handler branches.** Open the policy handler. A resource-based handler needs three
   `context.Resource is X` branches: `HttpContext` (first request), `RouteData` (in-circuit navigation)
   and the resource object a page state passes. A new policy plans for all three.
5. **Admin short-circuit.** Check whether the user type (and its mock for local runs) returns `true` for
   an admin at the top of each `IsAuthorizedFor` overload. A new policy that goes around
   `IsAuthorizedFor` loses that override, so flag it.

## The test matrix

Check all six cells before you say the change works:

|  | Authorized user | Unauthorized non-admin | Admin |
|---|---|---|---|
| Typed URL or refresh | renders | 403, no `InitialLoadData` | renders |
| Link click inside the portal (in-circuit) | renders | 403, no `InitialLoadData` | renders |
| `NavigationManager.NavigateTo(...)` | renders | 403, no `InitialLoadData` | renders |

"No `InitialLoadData`" is the cell that broke before. Confirm it with a breakpoint or a temporary log
line at the top of `InitialLoadData`. Handler unit tests cover the three branches in isolation, not the
three navigation paths. Without a local run as a non-admin mock user, the change is not checked. "We
tested it" says nothing until you know which path the test used: typing the URL does not prove
in-circuit navigation.

## Do not

- Remove `AuthorizeRouteView` while `<Routes>` stays interactive. That breaks in-circuit navigation.
- Remove `Resource="routeData"`. Resource-based handlers then fail closed for users who should get in.
- Bring back a per-page authorization gate component with inline `IsAuthorized` fields. If the
  authorization ADR removed it, amend the ADR first if you think it should return.

## Do

- Name the authorization ADR in the pull request for any change in this area.
- For a new resource-based policy, add all three branches and a test per branch, in the shape of the
  existing requirement tests.
- If a case is not covered by the ADR, propose an amendment next to the code change.

## Sources

- [Portal UI conventions](/.claude/skills/blazor-conventions/references/portal-ui.md) - the component rules the pages follow.
- [ADR conventions](/.claude/skills/adr-conventions/SKILL.md) - how the authorization ADR is amended when a case is not covered.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).
