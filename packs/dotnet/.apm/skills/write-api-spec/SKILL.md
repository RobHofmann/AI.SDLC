---
name: write-api-spec
kind: workflow
phase: elaboration
persona: Architect
description: >
  Produce a machine-readable API specification (OpenAPI 3.x in YAML) for the slice being built, so
  the build and tests consume a contract instead of prose. This is the L3 keystone: the contract
  lives in the repo. Use when designing or changing a REST endpoint, or before code generation
  begins on a slice that exposes or changes an HTTP surface: "design the API for this", "write the
  OpenAPI spec", "define the contract for #42", "what should the request/response shape
  be". Do NOT use to author an ADR (write-adr), to write feature docs, to generate the
  implementation (implement) or for non-HTTP work.
---

# Elaboration: API design

Owned by the **Architect** persona (the L3 keystone of the workflow). Called as `/write-api-spec`.

Turn the agreed slice into a **machine-readable contract**: an OpenAPI 3.x document in YAML under
`paths.specsRoot` (default `specs/`). Downstream steps (code generation, QE) consume this spec rather than re-deriving the shape
from text. That is what moves the slice from prompt-driven to contract-gated work. The spec is the
single source of truth for paths, payload shapes, status codes, and auth on this slice.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).

## Before drafting

Load the `api-contract-conventions` skill. It holds the wire rules this spec must encode, and points at
[api.md](/.claude/skills/api-contract-conventions/references/api.md) and clauses DOTNET-01 and DOTNET-02 for the full rule. In short:

- **Base standard:** the Zalando RESTful API Guidelines defaults, with one deviation.
- **JSON body properties are PascalCase (DOTNET-01).** Query and path parameters are snake_case; a shipped
  parameter keeps the wire name it already has, because renaming it breaks callers.
- **A business result that is not an error returns 200 (DOTNET-02).** Real errors are
  `application/problem+json` (`ProblemDetails`).
- **One domain per spec and per controller.**

## The spec file is plain OpenAPI YAML (no front-matter)

`<paths.specsRoot>/<feature>.openapi.yaml` is a **plain OpenAPI document**. Do **not** put a markdown `---`
front-matter block at the top of it. A leading `---` starts a second YAML document in the same file,
and that breaks OpenAPI parsers and generators.

The spec joins the artifact graph indirectly, via an already front-matter'd artifact:
- Add a `relates.spec:` edge on the **story's repo doc or its ADR** pointing at the spec path, per the
  front-matter schema in [artifact-graph.md](/.claude/skills/ai-sdlc-handbook/references/artifact-graph.md) (example: `specs/order-compare.openapi.yaml`).
- The artifact-graph gate (`Check-ArtifactGraph.ps1`, in `Invoke-LocalGates.ps1`) validates that every `relates.spec` path resolves to a real
  file, so the edge must point at the spec you really wrote.
- Link the spec to the story issue from the issue side via `write-story` in update mode.

## Workflow

1. **Confirm scope.** Restate the resource, the operations (which verbs/paths), and the slice
   boundary. Name the story issue this serves. If the resource shares ground with an existing controller's
   domain, say so and confirm a dedicated spec is correct (DOTNET-02, one domain each).
2. **Draft the OpenAPI spec.** Define `paths`, request/response schemas with **PascalCase**
   body properties (but **snake_case** query and path parameters), `problem+json` error responses,
   and the security scheme. Where the slice reuses an existing type or endpoint, **check it against
   the real code (file path + symbol) before asserting it exists**. Do not invent a schema name or
   route. State unverified shapes as open
   questions, not facts. (On Claude Code you can read the source involved directly to confirm.)
3. **Write `<paths.specsRoot>/<feature>.openapi.yaml`** (default `specs/`) as plain OpenAPI YAML with
   no `---` front-matter. Create the folder if it does not exist.
4. **Wire the graph edge.** Add or update `relates.spec:` on the story's repo doc or its ADR to point
   at the new spec. Suggest backlinking the spec onto the story issue via `write-story` in update mode.
5. **Review.** Hand the draft spec to the `architect` agent
   on Opus 5.5 (model `opus` in Claude Code, `claude-opus-5.5` in Copilot) for review. If you cannot run agents, load
   `api-contract-conventions` and review the spec against it yourself. Fix each finding or record why
   you declined it.
6. **Where the draft goes next.** Inside the build loop of `implement`, write the files without a
   separate confirmation. The spec is a repository file, and the person sees it in the diff at Checkpoint Bravo.
   Run standalone, show the draft spec and the edge change first, then write.
7. **Hand the work to a pull request (standalone run only).** A standalone run is one a person
   starts directly, not from `wrap-up`, a build loop or another skill. The work goes on a branch named
   with an issue number. When you are not on a branch named with an issue number, create it from the
   current state (`git switch -c <n>-<topic>`); the work moves with it. When you are on one, stay on it. Then
   `/wrap-up` commits it and runs the pre-flight. Push the branch and open or update the pull request through the pull request skill of the
   installed pack, as `implement` does. In `github-pull-requests`, `New-PullRequest.ps1` opens a new one and `Update-PullRequest.ps1` updates an open one. Called
   from `wrap-up`, a build loop or another skill, skip this step: write the files only, and `wrap-up`
   commits them.

## Guardrails

- **Check before asserting.** Check reused types, endpoints, and auth policies against the code
  first. If you cannot confirm one, mark it as a decision or open question, not a fact.
- **PascalCase JSON bodies (DOTNET-01); never PascalCase parameters.** Body properties are PascalCase; new query/path parameters are snake_case (e.g. `page_size`), but match the existing wire name of a shipped parameter (some are camelCase like `runType`) rather than renaming it. See [api.md](/.claude/skills/api-contract-conventions/references/api.md).
- **Errors are `problem+json`; success is 200 (DOTNET-02).** Do not model business results as 4xx.
- **No front-matter inside the OpenAPI file.** The graph edge lives on the story doc or ADR, not the spec.
- **Match to the node shape.** Per [node-templates.md](/.claude/skills/ai-sdlc-handbook/references/node-templates.md), the
  contract's why is the annotated difference from an upstream node. Note in the spec where and why the wire
  shape departs from the ADR or design. Carry the `because.spec` reason on the story or ADR, not as a
  text envelope inside the YAML.
- **No pasted artifacts.** Link to the spec; do not inline it into other docs.
- **Keep one domain per spec.** A standalone run shows the draft before it writes; inside the build loop
  the diff reaches the person at Checkpoint Bravo ([orchestration.md](/.claude/skills/ai-sdlc-handbook/references/orchestration.md)).

## Failure modes

- **A type is reused from memory rather than read** -> the spec then describes a shape the code does not have. The build silently differs from the contract. Check the model, or mark it an open question.
- **A business result is modelled as a 4xx** -> "no results", "already applied", "not allowed" are 200 responses with a body (DOTNET-02). Only errors use `problem+json`.
- **A body property is written camelCase to match a parameter style** -> bodies are PascalCase (DOTNET-01). The two conventions differ on purpose and mixing them is the slip the PascalCase gate catches.
- **A shipped parameter gets renamed to fit the convention** -> renaming a live query parameter is a breaking change. Match the wire name it already has, even when it is camelCase like `runType`, and use snake_case for new ones.
- **Graph front-matter is added to the OpenAPI file** -> it is plain OpenAPI. The edge belongs on the story doc or the ADR; front-matter inside the YAML breaks it as a spec.
- **The spec covers several domains** -> one domain per spec, or nothing can be owned or versioned independently.
- **The wire shape departs from the ADR and the spec does not say why** -> annotate the difference. An unexplained difference reads as a mistake to whoever implements it.

## Observable signal

**Positive:** the implementation and its tests are written against the spec instead of against text. The request and response shapes are settled before the first controller line, and the review is not about field names.

**Audit trail:** the spec file in the repository is the receipt for what was agreed. Its notes record where the contract differs on purpose from the design it came from.

**Drift signal:** if PRs keep changing wire shapes the spec does not describe, the spec is being written after the code rather than before it. If the PascalCase gate keeps firing on new endpoints, the convention split between bodies and parameters is not landing.

## Next steps

- `/wrap-up` (Developer) - after a standalone run, commits the spec and runs the pre-flight; then push
  and open or update the pull request (step 7). Inside a build loop, skip it.
- `/implement` (Developer) - consume this spec to drive the TDD build of the slice.
- `write-story` in update mode (any) - link the spec onto its story issue and add a dated decision-log line. That issue write joins the run's list of issue updates.
- `/write-adr` (Architect) - only if a key API decision was made (e.g. a new
  boundary or a deviation worth recording).
- Run `pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1` to confirm the `relates.spec` edge resolves once it is wired.
