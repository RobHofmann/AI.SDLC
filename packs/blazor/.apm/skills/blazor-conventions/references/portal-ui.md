# Blazor component conventions

This page is the reference for the components of a Blazor Server app. The short rules and the two
gates sit in [the blazor-conventions skill](../SKILL.md). A repository keeps its design system, its CSS
variables and the name of its API client on a page of its own.

## Styling

- **Blazor Server** with CSS isolation: component styles live in `*.razor.css`.
- **A scoped stylesheet does not travel with a class name.** `Foo.razor.css` only reaches elements that
  `Foo.razor` renders, because Blazor stamps those with a scope attribute. Copying a class name from
  another component gives you the name and none of its styling. A common symptom: the element has the
  right size and place but paints nothing, because it renders under a fixed background layer. Give a new
  component its own class and its own scoped stylesheet.
- Prefer a component of the design system when one exists. Fall back to layout utility classes for what
  the design system does not cover.
- Keep the styling of a component in its own `*.razor.css`, not in a global stylesheet.

## Component conventions

These rules often live only in the code, so reviewers have to teach them one by one. They are written
down here.

- **Put attributes on their own line**, above the member, not in front of it. This covers `[Parameter]`,
  `[CascadingParameter]`, `[Inject]` and the rest. The blazor gate `Check-RazorAttributePlacement.ps1`
  checks it.

  ```razor
  [Parameter]
  public RenderFragment ChildContent { get; set; }
  ```

- **Do not put an interface over a state class.** A `*State` class is registered and injected as the
  class itself. Do not add an `I*State` interface, not even to mock it in a test. Use the real state
  object in the test. It reads better and it cannot go out of date.

- **Subscribe to a state change event the same way as the other components.** Copy this form:

  ```razor
  private Action<TArg> OnChangeHandler => async (arg) => await HandleChange(arg);

  protected override void OnInitialized()
      => State.OnChange += OnChangeHandler;

  private async Task HandleChange(TArg arg)
  {
      // update fields
      await InvokeAsync(StateHasChanged);
  }
  ```

  There is one trap. That `OnChangeHandler` property returns a **new delegate every time you read it**,
  so `-=` removes nothing.

  This does not matter for a scoped page state. It dies with the circuit, and those components do not
  need `IDisposable`. It does matter when the state is a **singleton**. The subscription then stays alive
  after the circuit closes, and later fires into a component that is gone.

  So when you subscribe to singleton state and need to unsubscribe, store the delegate in a field first
  (`onChangeHandler ??= ...`). Then `+=` and `-=` use the same object.

- **Handle a null result from the API client; never dereference it.** The portal's API client may
  record the `ProblemDetails` body, return null for any error response, and turn the record into an
  error notification by itself. Then a call site has one job: leave state alone when the result is null.

  ```csharp
  var run = await apiClient.CreateRun(request);

  if (run is null)
  {
      return;
  }
  ```

  Skipping the check does not cause a small bug. The unhandled exception reaches the error boundary of
  the layout, which replaces the whole page. So a refused write looks to the user like the portal
  breaking. A refused write can happen in normal operation, for example while writes are switched off
  for maintenance.

- **No inline `<style>` blocks.** Put styles in the component's `*.razor.css`, or in a stylesheet under
  `wwwroot`. This follows the OWASP guidance, and it means no page needs `unsafe-inline`. The blazor gate
  `Check-RazorConventions.ps1` checks it.

- **Render a page the way the app renders pages:** a routable component, reached through `App.razor` and
  the router. Do not build a second way to deliver a page. Two examples are a minimal endpoint that
  returns a component, and a full HTML document inside a page. If the normal way really does not fit, write an ADR
  (clause C01).

## Related

- [The blazor-conventions skill](../SKILL.md) - the short rules and the two gates that hold them.
- [The blazor-authorization skill](/.claude/skills/blazor-authorization/SKILL.md) - authorization checks in the same app.
- [Constitution](/.claude/skills/ai-sdlc-handbook/references/constitution.md) - clause C01, and clause C10 on doc comments and comments.
