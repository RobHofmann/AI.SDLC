# AI-SDLC substrate node templates

This page gives the shape of each substrate node type the authoring skills produce. With it, a node
carries its *why* in set sections rather than leaving it implicit. A reader (human or `walk-substrate`)
can then walk the graph without reading every artifact end to end. This page is the node-level
companion to [pattern.md](pattern.md), the shape of the *skill* that produces a node. It is also the
content-level companion to [artifact-graph.md](artifact-graph.md), the machine-readable *edges* between
nodes.

This document does not restate each node's full body. The canonical body of each node type lives in one
place already: the ADR template, the story template, the OpenAPI spec, and so on. This document points
to it, so there is a single source per node and no drift. This document owns three things:
- the **shared envelope** every node carries;
- the **why-bearing sections** each type must contain;
- the **lifecycle map** of which node belongs to which phase, owner, and home.

## The shared envelope (every node, every type)

Two things make a node a first-class graph node rather than a document on its own. A node missing either is a
substrate gap the walking skills will flag.

**1. The machine envelope: graph frontmatter.** Repo artifacts carry the YAML frontmatter defined in
[artifact-graph.md](artifact-graph.md) (`story`, `phase`, `step`, `intent`, `relates`, `because`). That is the
authority for the frontmatter; do not redefine it here. The `intent` block is where the why from the questioning lands
structurally (the riskiest `assumption`, the `decision-drivers`, the upstream `hypothesis` edge). Nodes whose
home is a GitHub issue cannot carry repo frontmatter. For those the issue holds the edges (see
artifact-graph.md), and the node still carries the text envelope below.

**2. The text envelope: a lifecycle header and a graph-links footer.** Every node, including the
GitHub issue ones, opens and closes with two blocks a reader depends on:

- A **lifecycle header line** as the first block of the body. It says which phase and step this node is,
  and who owns it. It also says what it derives from upstream, and what consumes it downstream.

  ```
  Phase: <discovery | elaboration | create | mature | governance>. Step: <step>. Owner: <persona>.
  Upstream: <links to the node(s) this derives from, or "none" for a root>.
  Downstream: <the node(s)/stories that consume this>.
  ```

- A **graph-links footer** as the last block, listing upstream and downstream links. Write a downstream
  consumer that is planned but does not exist yet explicitly as **`(not yet created)`**. The absence is
  signal (a leaf to watch), not something to omit.

  ```
  ## Graph links
  Upstream: <links>
  Downstream: <links, or "(not yet created)" where a consumer is planned but absent>
  ```

## The why is not optional

A node-content standard exists for one reason. The graph used to model *which* artifacts relate, without
making the *why* traversable. So intent survived only as text buried in an ADR or a story, or as an issue
link reason no reader could follow. Every node type below names the sections that carry its why. An
author fills them from the `grilling` answers that came before the draft. They are not the author's
invention and not the user's to hand-type. The same why can also be a machine edge, such as the riskiest
assumption or the upstream hypothesis. Then it goes into the `intent` frontmatter as well, so it is both
easy to read and checkable.

## The lifecycle map

The discovery nodes come from the discovery pack, the stories from the github-issues pack, and the API contract
from the dotnet pack. A repository without that pack does not produce that node.

| Phase | Node type | Owner | Home | Canonical body template | Why-bearing sections |
| --- | --- | --- | --- | --- | --- |
| discovery | Research synthesis | Analyst | repo page under the discovery folder (`paths.discoveryRoot`) + spike issue anchor | `write-research-summary` | Situation and problems stated before any proposal; the gaps itemised, not referred to; findings named to source; conclusions marked checked vs worked out; advice carries its cost and the objections; open questions |
| discovery | Hypothesis canvas | Analyst / PM | repo page `<discoveryRoot>/<theme>/hypothesis.md` | `write-hypothesis` | Riskiest assumption; what would falsify it; `intent.assumption` |
| discovery | Journey map | Analyst (with UX) | repo page under the discovery folder + diagram | `draw-customer-journey` | Design intent; evidence-backed pains vs marked assumptions |
| elaboration | PRD | Product Manager | repo | `write-prd` | Problem and goal; non-goals; the decision drivers |
| elaboration | User story + acceptance criteria | PM / QA | GitHub issue | `write-story/references/story-template.md` | `So that` (goal); Expected Value; scope boundary in Risks; testable criteria |
| elaboration | API contract | Architect | repo (the specs folder, `paths.specsRoot`) | `write-api-spec` (dotnet pack) | Where the contract differs from an upstream node, annotated; `because.spec` |
| governance | ADR | Architect / Lead | repo (the ADR folder, `paths.adrFolder`) | the template in the ADR folder, see `adr-conventions` | Context (the forces); Alternatives (rejected because); `intent.decision-drivers` |
| create | Code | Developer | repo (the source root) | the conventions of the installed stack packs | Tied to its story by the story trait on its tests |
| create | Tests | QA / Developer | repo (the test root) | `implement` step 5, measured by `run-preflight` | Each numbered AC mapped to a covering test |
| create / mature | Documentation | Tech Writer | repo, both documentation layers (`paths.technicalDocs` and `paths.functionalDocs`) | `write-docs` | The why behind a behaviour, not just the what |

## Mandatory only where a downstream step needs it

Not every node is required for every piece of work, and size does not decide it. The single test: **a node is
mandatory only where a downstream step needs it as input.** A bug fix's downstream is the code change and its
test. They consume no journey and no hypothesis, so none are needed. A multi-story initiative's stories
consume a journey and its framing, so those become mandatory for it. This is the nature of the work, not its
story points (the `size:<n>` label; an 8 or 13-point refactor can need no upstream node). The operational rule lives in
[artifact-graph.md](artifact-graph.md) ("Required artifacts: mandatory only where a downstream step needs
it"). It says which parts resolve deterministically, and names the one discovery question the framework
**asks rather than guesses**. So the authoring skills and `guide-me` read one rule. An author never
invents a node a downstream step does not need. An author also never silently skips one a downstream step
does need. Where the need is unclear, the author surfaces the question rather than deciding.

## Conventions every node honours

- **Name what it does NOT cover.** Every discovery and elaboration node states its explicit non-goals, held
  to scope. It is the cheapest defence against silent scope creep.
- **State conflicts, do not resolve them.** If a node goes against an upstream node (a scope decision, an
  ADR), the author flags it for the owner and does not reconcile it. Surface, don't decide.
- **Graph links are key.** A node with no upstream link is an orphan; a node whose downstream links
  are all `(not yet created)` is a leaf to watch. Both are surfaced, never hidden.
- **Draft, then write only through Checkpoint Alpha.** Authoring skills return drafts. A person confirms the named
  writes at Checkpoint Alpha. Only then does the skill create or edit the GitHub issue
  ([orchestration.md](orchestration.md), [constitution](constitution.md) C09).
- **Close the back-edge (required, every producer).** Producing a node is not done until its anchoring work
  item shows it. An artifact can be a PR, an ADR, a constitution clause, an API spec, a doc or a research
  synthesis. Whichever skill produces it hands the back-edge to `write-story` in update mode, the single writer. That
  is an edit of the issue body, under the same headings. The PR and spec and doc go under `📎 Artifacts & references`, and the
  ADR and clause under `🧭 Decisions & ADRs`. A node whose story does not reference it is a half-created
  node. The repo-to-issue direction is the deferred issue-side check (advisory `Check-StoryBackEdges.ps1`).
  So nothing else catches the omission yet, and the producing skill owns it as a closing step rather
  than an offer.
- **House style:** [C02 and C06](constitution.md) hold in node bodies as everywhere.

## Related

- [pattern.md](pattern.md) - the shape of the skill that produces each node.
- [artifact-graph.md](artifact-graph.md) - the frontmatter envelope, the intent edges, and the required-tier rule.
- [personas.md](personas.md) - the owners named in the lifecycle map.
- [plan.md](plan.md) - the workflow and its phases.
