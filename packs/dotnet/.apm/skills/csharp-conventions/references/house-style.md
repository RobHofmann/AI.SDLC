# C# house style

These are the C# house rules. Write new and changed C# this way. Each rule shows an example and names
its public sources (clause C07). The examples use made-up names. Some points are a matter of taste. There
a change follows the file it edits, and [not-decided.md](not-decided.md) gives the default for a new
file.

The test rules are in the test style of [csharp.md](csharp.md).

## A primary constructor, with its parameters used directly

Put the constructor parameters right after the class name, and use them directly in the methods. Do
not copy a parameter into a private `_field` in a classic constructor.

```csharp
public class OrderService(IOrderRepository orderRepository) : IOrderService
{
    public async Task<Order> GetAsync(string orderId) => await orderRepository.GetAsync(orderId);
}
```

Source: [Primary constructors](https://learn.microsoft.com/en-us/dotnet/csharp/whats-new/tutorials/primary-constructors)
and the analyzer rule [IDE0290](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/style-rules/ide0290).

## One top-level type per file

Each file holds one class, interface, record or enum, and the file has the same name: `Order.cs`
holds `public class Order`. A nested type
inside that class is fine. A family of small wire models that together describe one message of an
outside API may share a file.

Source: the analyzer rule [SA1402](https://github.com/DotNetAnalyzers/StyleCopAnalyzers/blob/master/documentation/SA1402.md)
and [SA1649](https://github.com/DotNetAnalyzers/StyleCopAnalyzers/blob/master/documentation/SA1649.md)
of StyleCop.Analyzers.

## The folder of a new type is a setting

A new interface of a client, repository or service goes in the contracts folder of its project. A new
exception and a new options class go in their folders too. The names are team facts, so a repository
sets them in `aisdlc.json`: `dotnet.folders.contracts`, `dotnet.folders.exceptions` and
`dotnet.folders.options`. When a key is not set, put the new type where the types of the same kind
next to your change already sit. A file that exists stays where it is; do not move it in a change that
does not need it.

Source: the [layout page](/.claude/skills/ai-sdlc-handbook/references/layout.md), which lists the
settings. No vendor page sets a folder name.

## Options classes end in Options and come in through IOptions

An options class holds settings read from configuration. Its name ends in `Options`. A class that
needs it takes `IOptions<T>` in its constructor and reads `.Value`. It does not take
`IConfiguration`.

```csharp
public class OrderOptions
{
    public Uri Endpoint { get; init; }
}

public class OrderClient(IOptions<OrderOptions> orderOptions) : IOrderClient
```

Source: [Options pattern in .NET](https://learn.microsoft.com/en-us/dotnet/core/extensions/options)
and [Options pattern in ASP.NET Core](https://learn.microsoft.com/en-us/aspnet/core/fundamentals/configuration/options).

## A method that returns a task ends in Async

A method that returns a `Task` or a `ValueTask` has a name that ends in `Async`, such as
`GetOrderAsync`. This holds for clients, services and repositories alike. A controller action is the
one exception: it has no suffix, see the section on controller actions.

```csharp
public async Task<Order> GetOrderAsync(string orderId) => await orderRepository.GetAsync(orderId);
```

Not `public async Task<Order> GetOrder(string orderId)` in a service.

Source: [the Task-based asynchronous pattern](https://learn.microsoft.com/en-us/dotnet/standard/asynchronous-programming-patterns/task-based-asynchronous-pattern-tap),
the part on naming, and the
[.NET naming guidelines](https://learn.microsoft.com/en-us/dotnet/standard/design-guidelines/naming-guidelines).

## A null check uses is null

Write a null check as `is null` or `is not null`, not `== null` or `!= null`. Write no null check for a
value that cannot be null, such as a value the framework always sets or a value checked just before.

```csharp
if (order is null)
{
    throw new OrderNotFoundException(orderId);
}
```

Source: [the is operator](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/operators/is)
and the analyzer rules [IDE0041](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/style-rules/ide0041)
and [IDE0150](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/style-rules/ide0150).
No rule reports `== null`, so the reviewer checks that form.

## nameof when a string must equal a C# name

Use `nameof` when a string must be the same as a name in the C# code. Then a rename changes the string
too. Examples are a parameter name in an argument exception and a property name in a JSON path.

```csharp
throw new ArgumentNullException(nameof(orderId));
```

Use a literal string when the name is a contract that must not change with a rename. Examples are the
name in `[JsonPropertyName]`, a name in a system we do not own, a placeholder in a log template and a
configuration key.

Source: [the nameof expression](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/operators/nameof)
and the analyzer rules [CA1507](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/quality-rules/ca1507)
and [CA2208](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/quality-rules/ca2208).

## Controller actions have one fixed shape

A controller action has no `Async` suffix, even when it returns a task. It has a
`[ProducesResponseType]` attribute and a route `Name`. The route is in kebab-case: lower case words
joined by hyphens.

```csharp
[HttpGet("orders/{orderId}", Name = "get-order-by-id")]
[ProducesResponseType(typeof(Order), StatusCodes.Status200OK, MediaTypeNames.Application.Json)]
public async Task<ActionResult<Order>> GetById([FromRoute] string orderId)
```

Not `[HttpGet("Orders/{orderId}")]` with `GetByIdAsync`.

Source: [Controller action return types](https://learn.microsoft.com/en-us/aspnet/core/web-api/action-return-types)
and [Routing to controller actions](https://learn.microsoft.com/en-us/aspnet/core/mvc/controllers/routing).

## No region blocks

Do not write `#region` and `#endregion`. A file that needs folding is too long, so split it.

Source: [C# preprocessor directives](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/preprocessor-directives),
the part on regions, and the analyzer rule
[SA1124](https://github.com/DotNetAnalyzers/StyleCopAnalyzers/blob/master/documentation/SA1124.md).

## The short forms of C#

- **Target-typed `new()`** when the type is already known, and a **collection expression** `[]` to build
  a list or array: `new() { Id = orderId, Tags = [] }`, not `new Order { Id = orderId, Tags = new List<string>() }`.
- **A switch expression** to pick a value, also from two cases, not a `switch` statement that returns
  or sets a value. It always has a default arm, `_ =>`:
  `value switch { true => "yes", _ => "no" }`.
- **`var`** for a local variable: `var order = await orderRepository.GetAsync(orderId);`.
- **An expression body** with `=>` for a member that only returns one expression.
- **A file-scoped namespace**: one line `namespace Shop.Orders;` at the top. The name is the root namespace
  of the project plus the folder path, so `Shop/Orders/Order.cs` in the project `Shop` uses `Shop.Orders`.
- **The `is` pattern**: `if (exception is OrderException orderException)`, not `as` and a null check.

Source: [the new operator](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/operators/new-operator),
[collection expressions](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/operators/collection-expressions),
[the switch expression](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/operators/switch-expression),
[implicitly typed locals](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/statements/declarations),
[expression-bodied members](https://learn.microsoft.com/en-us/dotnet/csharp/programming-guide/statements-expressions-operators/expression-bodied-members),
[the namespace keyword](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/keywords/namespace)
and [the is operator](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/operators/is).
The second source of each form is its analyzer rule: IDE0090, IDE0028, IDE0300, IDE0066, IDE0007,
IDE0022, IDE0025, IDE0161, IDE0130 and IDE0019. The
[code style rules page](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/style-rules/)
lists each one.

## Related

- [The csharp-conventions skill](../SKILL.md) - the short rules a build and a review check.
- [C# conventions](csharp.md) - errors, logging, DI, closed sets and the test style.
- [Not decided](not-decided.md) - the C# points of taste, with the default for a new file.
- [Code conventions](/.claude/skills/code-conventions/SKILL.md) - the rules for every language, and what to do on a point not decided.
