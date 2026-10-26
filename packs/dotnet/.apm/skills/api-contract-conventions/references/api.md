# API conventions

This page is the detailed reference for a REST API in a .NET repository. The rules that never bend are
clauses DOTNET-01 (PascalCase) and DOTNET-02 (thin controllers, one domain, status codes), written out
in full in [the dotnet clauses](clauses.md). The short form sits in
[the api-contract-conventions skill](../SKILL.md).

## Base reference

REST APIs follow the defaults of the
[Zalando RESTful API Guidelines](https://opensource.zalando.com/restful-api-guidelines/):

- OpenAPI first, plural resource names and URLs without verbs;
- JSON in UTF-8 and authenticated endpoints;
- semantic versioning, and `problem+json` for errors.

## Deviation: JSON property names

JSON property names are **PascalCase**, not snake_case. This is an intended deviation from the Zalando
MUST rule. The `System.Text.Json` defaults and every API consumer use PascalCase, so a switch would break
the whole surface.

Use `[JsonPropertyName]` only when the wire name must differ from the property name, such as the Cosmos
DB system fields `id` and `ttl` or a partition key path. The dotnet gate `Check-ApiPascalCase.ps1`
blocks anything else. It knows `id`, `ttl`, `_etag` and `_ts` everywhere. It knows any other wire name
only in the one file listed for it, with a reason, in `dotnet.wireNameAllowlist` in aisdlc.json. A
partition key path belongs there, because it cannot change once the container exists. An entry without
a reason is debt that nobody recorded, not an exemption.

The PascalCase rule covers the properties of a JSON request or response **body** only. **Query and path
parameters are never PascalCase.** A new parameter uses snake_case, bound with
`[FromQuery(Name = "...")]`, for example `page_size` or `subscription_id`; this is the Zalando default.
An older endpoint may expose a camelCase parameter through a plain `[FromQuery]`. **Keep the wire name a
parameter already ships with**, because renaming a live query parameter breaks its callers.

## Thin controllers

A controller composes IDs, calls service methods and returns responses. Business logic belongs in the
service layer: validation, authorization checks and data composition.

## One domain per controller

Do not add unrelated actions to an existing controller. Create a new controller for a new domain.

The line is the resource the URL addresses, not the feature that uses it. A **sub-resource or a view of
an existing aggregate** belongs on the controller of that aggregate, even when another feature drives it.
Add a new controller only for a really separate domain, not for the same resource seen through a new
feature. Before you add one, check whether an existing controller already owns the resource.

## Status codes

A business result that is not an error, such as "the record is already gone", returns **200 OK** with the
result in the body. Other status codes are kept for real errors: auth failures, validation errors and
server errors. These go through the `ProblemDetails` pipeline. A service raises an error by throwing a
typed domain exception, never by a null check with `NotFound()` or an anonymous error body. The
repository's own exceptions page says which exceptions exist.

## The contract

An endpoint that changes moves its OpenAPI spec in the same change. The spec lives in the specs folder
(`paths.specsRoot` in aisdlc.json), the [write-api-spec skill](/.claude/skills/write-api-spec/SKILL.md)
writes it, and the dotnet gate `Check-SpecDrift.ps1` compares it with the controllers.

## Related

- [The dotnet clauses](clauses.md) - DOTNET-01 and DOTNET-02 in full.
- [The api-contract-conventions skill](../SKILL.md) - the short rules a build and a review check.
- [C# conventions](/.claude/skills/csharp-generation-smells/references/csharp.md) - JSON settings and typed exceptions.
- [Constitution](/.claude/skills/ai-sdlc-handbook/references/constitution.md) - the core clauses and the ID scheme.
