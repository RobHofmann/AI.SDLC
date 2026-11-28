---
story: "#105"
phase: governance
step: write-adr
intent:
  assumption: "an API that uses the standard status codes is read the same way by every client and tool, and its clients still handle every error in one place"
  decision-drivers:
    - "the old rule, only an error is non-200, clashed with the base standard of the dotnet pack, which uses 201 and 204"
    - "upstream reports that working endpoints answer 201 or 204 while their client treats every 2xx answer as a success"
    - "every HTTP client and guideline reads the standard codes the same way"
    - "a client handles errors in one place only when every error, and only an error, is a 4xx or 5xx"
relates:
  clause: packs/dotnet/.apm/skills/api-contract-conventions/references/clauses.md
  reference: packs/dotnet/.apm/skills/api-contract-conventions/references/api.md
  skill: packs/dotnet/.apm/skills/api-contract-conventions/SKILL.md
  spec: packs/dotnet/.apm/skills/write-api-spec/SKILL.md
  docs: docs/packages/dotnet.md
because:
  clause: "DOTNET-02 now states the standard status codes"
  reference: "holds the table of status codes and the sources"
  skill: "the short form of the status code rule"
  spec: "a spec models each response with its standard code"
  docs: "the technical page of the dotnet package"
---

# ADR 0029: An API uses the standard status codes

**Status:** Accepted
**Date:** 2026-11-28
**Supersedes:** none
**Superseded by:** none

## Context

DOTNET-02 said that a business result that is not an error returns 200 with the result in the body. A
code other than 200 was kept for real errors. The aim was that a client could treat any answer other
than 200 as an error.

That rule clashed with the base standard of the dotnet pack. The Zalando guidelines ask for the most
specific code, such as 201 for a create and 204 for a success without a body. Upstream reports that
working endpoints of a consumer already answered 201 or 204, while their clients treated every 2xx
answer as a success. That fact has one source, the upstream release note, and this repository cannot
check it. It is not needed for the decision: the clash with the base standard is enough.

Upstream changed the rule in its release v2.18.0. This port brings the change over.

## Decision

1. **A response uses the standard HTTP status code (RFC 9110).** 200 for a read, 201 with a `Location`
   header for a create, and 204 for a success without a body.
2. **A real error goes through `ProblemDetails`.** 400 for invalid input, also against a business rule,
   and never 422. 401 or 403 for auth. 404 for an unknown resource in the URL, and 409 for a conflict
   with the current state.
3. **A result that the caller expects is a success, never a 4xx.** A delete of a resource that is
   already gone answers 204. "Nothing to do" answers 200 when the body says what happened, and 204 when
   there is nothing to report.

## Consequences

- Every HTTP client and tool reads the codes the same way, with no house rule to learn.
- A client still handles every error in one place, because only an error is a 4xx or 5xx.
- An endpoint that answers 200 for a create is not wrong at once, but a change to it moves it to 201.
- A spec models each success with its own code, so a client generator sees 201 and 204.
- A consumer whose client reads only 200 as a success must accept every 2xx code.

## Alternatives considered

1. **Every success is 200.** Rejected: it breaks the base standard, and real endpoints already differ.
2. **Keep 200, and allow 201 and 204 as exceptions.** Rejected: two rules for one thing, and the reader
   must guess which applies.

## Sources

- RFC 9110, HTTP Semantics, sections 9.3.3 (POST) and 9.3.5 (DELETE), and section 15 on status codes:
  https://www.rfc-editor.org/rfc/rfc9110
- Microsoft Azure REST API guidelines: a delete answers 204, also when the resource is already gone:
  https://github.com/microsoft/api-guidelines/blob/vNext/azure/Guidelines.md
- Zalando RESTful API guidelines: use the most specific status code, and 400 over 422:
  https://opensource.zalando.com/restful-api-guidelines/#http-status-codes
- Upstream release v2.18.0 and its decision record, read by the port; single source for the
  consumer fact in the context.

## Related

- [ADR 0028](0028-a-repository-sets-its-dotnet-layer-order-and-a-new-reference-points-down.md) - the other dotnet clause that changed in this port.
- [The dotnet package](../packages/dotnet.md) - where DOTNET-02 lives.
