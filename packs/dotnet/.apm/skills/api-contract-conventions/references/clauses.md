# Constitution (dotnet clauses)

These clauses hold in every repository that installs the dotnet pack. They carry the `DOTNET-` prefix,
which says they live in this pack. The core clauses and the ID scheme are in the
[core constitution](/.claude/skills/ai-sdlc-handbook/references/constitution.md). The short form of each clause
sits in the `## Constitution (dotnet)` part of `AGENTS.md`.

**Version:** 1.1

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

## DOTNET-02: Controllers are thin, one domain each, and status codes keep their standard meaning

- **Statement:** A controller composes IDs, calls services, and returns responses; business logic lives
  in services. One domain per controller. A response uses the standard HTTP status code: 200 for a
  read, 201 with a `Location` header for a create, 204 for a success without a body. A real error goes
  through `ProblemDetails`, such as 400 for invalid input, 404 for an unknown resource in the URL and
  409 for a conflict with the current state. A result that the caller expects, such as "already gone",
  is a success and never a 4xx.
- **Rationale:** Every HTTP client and tool reads the standard codes the same way (RFC 9110). A client
  still handles every error in one place, because every error, and only an error, is a 4xx or 5xx with
  `ProblemDetails`.
- **Enforcement:** code review - active. The detail is in [api.md](api.md) and in the
  [api-contract-conventions skill](../SKILL.md). ADR 0029 of AI.SDLC holds the reasons for the status
  codes.

## DOTNET-03: A project reference is used in code and points to a lower layer

- **Statement:** A project reference that a change adds has use in code: the referencing project uses a
  namespace that the target project declares. Remove a reference that no code uses. A repository can set
  its layer order in `dotnet.layers` in `aisdlc.json`. Then a reference that a change adds points to a
  lower layer, never to its own layer or a higher one.
- **Rationale:** An unused project reference still ties two projects together. It changes the build
  order, makes a change reach more tests, and hides the real dependencies of the code. A reference
  against the layer order mixes parts that the team keeps apart, so one change ships in more hosts than
  it needs.
- **Enforcement:** `.claude/skills/dotnet-gates/scripts/Check-ProjectReferenceUse.ps1` (advisory) -
  active. It judges a `ProjectReference` that the change adds, and with `-All` every reference. It reads
  text, not a compiler, so it cannot see code that finds its types at run time. It leaves out a
  reference with `ReferenceOutputAssembly` set to false or `OutputItemType` set to `Analyzer`.
  `.claude/skills/dotnet-gates/scripts/Check-ProjectLayerOrder.ps1` (advisory) - active. It judges the
  same added references against `dotnet.layers`, and reports not applicable without that setting. With
  `-From` and `-To` it judges one planned reference by path, so the `architect` agent checks a plan
  before the project files exist. ADR 0028 of AI.SDLC records the layer setting.

## DOTNET-04: Code uses the shared parts, not its own copy

- **Statement:** A service takes its settings as an options class, not as `IConfiguration`. It gets an
  `HttpClient` from the factory, not with `new`. It gets an Azure credential from one shared helper
  (`dotnet.credentialHelper`). A custom exception derives from one shared base exception
  (`dotnet.baseException`), not straight from `Exception`.
- **Rationale:** One answer for these four parts keeps the services alike, and gives one place to change
  when the answer changes. A new `HttpClient` for each call can use up the free connections of a host.
  The wiring code of a host is the one place that creates these parts.
- **Enforcement:** `.claude/skills/dotnet-gates/scripts/Check-SharedParts.ps1` (advisory) - active. It
  reads the `.cs` files under `paths.sourceRoot`, and lists a finding on a line the change adds before
  older debt. It skips tests, generated files, `Program.cs`, `Startup.cs` and a service registration
  extension method. It skips the credential or the exception rule when its setting is empty. The
  examples are on the [C# house style](/.claude/skills/csharp-conventions/references/house-style.md) page.

## Related

- [API conventions](api.md) - the full wire and controller rules these clauses rest on.
- [api-contract-conventions](../SKILL.md) - the skill that carries these clauses into a build or a review.
- [Core constitution](/.claude/skills/ai-sdlc-handbook/references/constitution.md) - the core clauses and the
  clause ID scheme.
