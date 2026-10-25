# Constitution (dotnet clauses)

These clauses hold in every repository that installs the dotnet pack. They carry the `DOTNET-` prefix,
which says they live in this pack. The core clauses and the ID scheme are in the
[core constitution](/.claude/skills/ai-sdlc-handbook/references/constitution.md). The short form of each clause
sits in the `## Constitution (dotnet)` part of `AGENTS.md`.

**Version:** 1.0

## DOTNET-01: JSON wire format is PascalCase

- **Statement:** Serialized JSON uses PascalCase. Do not add `[JsonPropertyName]` unless the serialized
  name really must differ, for example the Cosmos DB `id`, `ttl` or a partition key path.
- **Rationale:** Every consumer of the API is locked to the wire format, so a change to it is a breaking
  change across the whole surface. This departs from the Zalando snake_case MUST on purpose, as
  [api.md](api.md) explains.
- **Enforcement:** code review plus `.claude/skills/dotnet-gates/scripts/Check-ApiPascalCase.ps1`
  (blocking gate) - active. The gate flags a `[JsonPropertyName]` wire name that is not PascalCase. It
  leaves out the models for outside systems (`dotnet.externalContractPaths` in `aisdlc.json`). A name
  that cannot change, such as a partition key path, is allowed only in the file that declares it. It
  goes through `dotnet.wireNameAllowlist` in `aisdlc.json`, and every entry carries the reason. Drift
  between the code and the OpenAPI spec is not covered by this gate.

## DOTNET-02: Controllers are thin, one domain each, and only an error is non-200

- **Statement:** A controller composes IDs, calls services, and returns responses; business logic lives
  in services. One domain per controller. A business result that is not an error returns 200 with the
  result in the body; a non-200 code is kept for real errors, through `ProblemDetails`.
- **Rationale:** It keeps the API surface the same everywhere. It also keeps the error handling of
  every client reliable, because a client can treat any non-200 answer as an error.
- **Enforcement:** code review - active. The detail is in [api.md](api.md) and in the
  [api-contract-conventions skill](../SKILL.md).

## Related

- [API conventions](api.md) - the full wire and controller rules these clauses rest on.
- [api-contract-conventions](../SKILL.md) - the skill that carries these clauses into a build or a review.
- [Core constitution](/.claude/skills/ai-sdlc-handbook/references/constitution.md) - the core clauses and the
  clause ID scheme.
