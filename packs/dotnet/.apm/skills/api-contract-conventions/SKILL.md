---
name: api-contract-conventions
kind: knowledge
user-invocable: false
description: >
  The wire rules for the REST API. JSON bodies are PascalCase (DOTNET-01), with snake_case query and
  path parameters. Controllers are thin, with one domain each (DOTNET-02). A business result that is not an
  error gets 200, and ProblemDetails is for real errors. An OpenAPI spec in specs/ moves with its
  endpoint. Use when a change touches a controller action, a route, or the shape of a request or
  response. Also use when a spec or a plan for an HTTP surface is reviewed. Do NOT use to write the
  spec itself (write-api-spec) or for a change with no HTTP surface.
---

# API contract conventions

The rules every HTTP surface here follows. `write-api-spec` loads this when an endpoint moves,
and the `architect` agent loads it when it reviews a plan.
The full rules are in the pages under Sources.

## Wire format (DOTNET-01)

- JSON body properties are **PascalCase**. This departs from the Zalando snake_case rule on purpose,
  because every API and portal consumer is locked to PascalCase.
- Add `[JsonPropertyName]` only when the wire name must differ, such as the Cosmos fields `id` and
  `ttl` or a partition key path. `Check-ApiPascalCase.ps1` blocks anything else.
- Query and path parameters are **never** PascalCase. New ones are snake_case, bound with
  `[FromQuery(Name = "...")]`. An existing parameter keeps the wire name it ships with, because a
  rename breaks callers.

## Controllers (DOTNET-02)

- A controller composes IDs, calls a service and returns the result. Validation, authorization checks
  and data composition live in the service.
- One domain per controller. The line is the resource the URL names, not the feature that calls it: a
  sub-resource of an aggregate lives on that aggregate's controller. Check which controller already
  owns a resource before you add one.
- No `try/catch` in an action, no null check followed by `NotFound()`, no anonymous error body.

## Status codes

- A business result that is not an error, such as "already gone", returns **200 OK** with the result
  in the body.
- A non-200 code is kept for real errors: auth, validation, server. A service throws a typed domain
  exception and the middleware turns it into `ProblemDetails` (`application/problem+json`).

## The spec

- When a change touches an HTTP surface, write or update `<specs>/<feature>.openapi.yaml` (the folder is
  `paths.specsRoot` in aisdlc.json) **before** the implementation, through `write-api-spec`. The build and the tests then read one contract.
- The spec is plain OpenAPI YAML with no markdown frontmatter. It joins the graph through a
  `relates.spec:` edge on the story's doc or its ADR.
- When an endpoint's shape moves, the spec moves in the same change. `Check-SpecDrift.ps1` reports an
  endpoint that moved while its spec stood still.
- Schema property names in the spec follow the same PascalCase rule, and parameters the same
  snake_case rule.

## Sources

- [API conventions](references/api.md) - the full REST reference, with the status codes and why a business result returns 200.
- [Dotnet clauses](references/clauses.md) - clauses DOTNET-01 and DOTNET-02 in full.
- [Constitution](/.claude/skills/ai-sdlc-handbook/references/constitution.md) - the core clauses and how pack clause IDs work.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).
