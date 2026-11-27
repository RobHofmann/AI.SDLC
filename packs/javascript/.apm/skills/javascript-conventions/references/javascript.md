# JavaScript rules

These are the JavaScript rules for the hand-written browser code of a repository. The
[javascript-conventions skill](../SKILL.md) holds the short form. The code examples use made-up names.
`whenRemoved` stands for the cleanup helper that `javascript.cleanupHelper` in `aisdlc.json` names.

Two words come back on this page. A component module is a JavaScript file that belongs to one
component, such as `OrderList.razor.js` next to `OrderList.razor`. A global script is a JavaScript
file that the host page loads for the whole application.

## A component imports its own module after the first render

**What it means.** A component that needs JavaScript keeps it in its own `.razor.js` module. The
component loads the module once, in `OnAfterRenderAsync(firstRender)` when `firstRender` is true. It
keeps the result in an `IJSObjectReference` field and calls the module's functions through that field.
It does not call a function that a global script put on `window`. A boot script is the one exception:
a global script that sets up the page before the first component renders may use globals.

Do:

```razor
@inject IJSRuntime JS

<div @ref="dialog">...</div>

@code {
    private ElementReference dialog;
    private IJSObjectReference module;

    protected override async Task OnAfterRenderAsync(bool firstRender)
    {
        if (firstRender)
        {
            module = await JS.InvokeAsync<IJSObjectReference>("import", "./Components/Orders/OrderDialog.razor.js");
        }
    }

    public async Task Show()
    {
        if (module is not null)
        {
            await module.InvokeVoidAsync("showDialog", dialog);
        }
    }
}
```

Not:

```csharp
await JS.InvokeVoidAsync("orderDialog.show", dialog);
```

**Public source.** [JavaScript location in Blazor apps](https://learn.microsoft.com/en-us/aspnet/core/blazor/javascript-interoperability/location-of-javascript),
the part on JavaScript files next to a component. Also
[Call JavaScript functions from .NET methods in Blazor](https://learn.microsoft.com/en-us/aspnet/core/blazor/javascript-interoperability/call-javascript-from-dotnet),
the part on JavaScript isolation in modules.

## The module uses `export function`, no `var`

**What it means.** A component module is an ES module: a file that shares only what it marks with
`export`. Each function that the component calls is written as `export function`. The module uses
`const` or `let`, never `var`, so a name lives only in its block.

Do:

```javascript
export function showDialog(dialog) {
    dialog.show();
}

export function hideDialog(dialog) {
    dialog.hide();
}
```

Not:

```javascript
var orderDialog = {
    show: function (dialog) { dialog.show(); }
};
window.orderDialog = orderDialog;
```

**Public source.** [MDN JavaScript modules](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Guide/Modules),
the part on how a module shares its functions, and the
[ESLint rule no-var](https://eslint.org/docs/latest/rules/no-var).

## A document or window listener is removed when its element leaves the page

**What it means.** A module that adds a listener to `document` or `window` must also remove it.
Otherwise the listener stays after the component is gone, and it can call into a component that no
longer exists. Use the repository's cleanup helper, which `javascript.cleanupHelper` names. Such a
helper watches the page with a `MutationObserver`. When the component's element is no longer on the
page, it runs the cleanup actions it was given. When the key is not set, use the helper that the
modules next to your change use, and add none of your own without asking.

Do:

```javascript
export function startDrag(container) {
    const onMouseMove = (event) => { /* ... */ };
    document.addEventListener('mousemove', onMouseMove);

    whenRemoved(container, [
        () => document.removeEventListener('mousemove', onMouseMove)
    ]);
}
```

Not:

```javascript
export function startDrag(container) {
    document.addEventListener('mousemove', (event) => { /* ... */ });
}
```

**Public source.** [MDN MutationObserver](https://developer.mozilla.org/en-US/docs/Web/API/MutationObserver)
and [MDN removeEventListener](https://developer.mozilla.org/en-US/docs/Web/API/EventTarget/removeEventListener).

## A broken call is fixed, not hidden

**What it means.** When the browser connection is gone, a JS interop call throws, for example a
`JSDisconnectedException`. JS interop is a call from C# to JavaScript or back. Do not catch and ignore
such an exception in a component, and do not wrap module code in a `try` block that ignores the error.
Fix the lifecycle instead: remove the listener through the cleanup helper, so nothing calls into a
component that is gone.

**Public source.** [Handle errors in Blazor apps](https://learn.microsoft.com/en-us/aspnet/core/blazor/fundamentals/handle-errors)
and [JavaScript interop calls without a circuit](https://learn.microsoft.com/en-us/aspnet/core/blazor/javascript-interoperability/#javascript-interop-calls-without-a-circuit).

## No HTML or code from input

**What it means.** A value from input, from the server or from the address bar never goes into
`innerHTML`, `outerHTML` or `insertAdjacentHTML`, and never into `eval`, `new Function` or a string
argument of `setTimeout`. Each of these runs text as markup or code. Set `textContent`, or build the
element with `createElement`.

**Public source.** [OWASP page on DOM based XSS](https://cheatsheetseries.owasp.org/cheatsheets/DOM_based_XSS_Prevention_Cheat_Sheet.html)
and [MDN eval](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/eval#never_use_direct_eval!).

## Related

- [The javascript-conventions skill](../SKILL.md) - the short rules.
- [Code conventions](/.claude/skills/code-conventions/SKILL.md) - the rules for every language.
