# C# security rules

The `security-reviewer` agent reads this page when a change touches a C# file. These checks came from
that agent when it moved from the dotnet pack to core. The checks for every language are in the agent.

- **Access control.** A new endpoint or page without `[Authorize]` or a policy, or a new
  `[AllowAnonymous]`, is a finding. So is a policy handler that misses the `HttpContext`, `RouteData`
  or resource branch, and an admin check that goes around `IsAuthorizedFor`.
- **Graph and ARM calls** stay at the scope the story needs, never wider.
- **No query built as a string from input**: an OData or Graph filter, or a Cosmos query. Pass the
  value as a parameter.
- **No type names from input** in a serializer, and no polymorphic setting on data from outside.
- **A ProblemDetails holds no stack trace, internal name or raw exception message.** How errors reach
  the caller is in [api.md](/.claude/skills/api-contract-conventions/references/api.md).

## Related

- [The csharp-conventions skill](../SKILL.md) - the C# rules this page belongs to.
- [C# conventions](csharp.md) - the wider C# style, with validation and errors.
