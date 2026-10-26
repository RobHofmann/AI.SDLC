# AI-SDLC artifact graph

Work products live across systems (GitHub Issues, the repository, a design tool, a research tool). To make
them navigable as one graph, we anchor everything on a stable work-item key and declare links in
machine-readable front-matter. A linter validates the links; `guide-me` walks them.

This is incremental: an artifact joins the graph by **opting in** (adding the front-matter below).
The linter only validates artifacts that have opted in, so existing docs are untouched until they do.

## Anchor: the GitHub issue key

Every artifact references a GitHub issue key, for example `#42`, or `owner/repo#42` for an issue in
another repository (`tracker.repository` in aisdlc.json names the issue repository). The issue is the
spine and the hub that the PO/PM and developers share. Anchor at the right level of the hierarchy:

- **Epic** (a parent issue with sub-issues) for an initiative, **Story** for a slice, an issue with
  the `spike` label for a research step.
- Research can start in a tool without a work item. When it becomes actionable, create
  a spike issue and link the study from it. The issue holds the link and a short
  synthesis summary. The graph stores the **edge and summary, not the content**, so a developer
  walks from the issue without needing access to the upstream tool. Where the upstream tool cannot
  store the issue key, the issue is the source of truth for that edge.
- Do not create a work item per micro-step. Use the hierarchy; too many work items is extra work, not traceability.

## Story-to-story links (in GitHub Issues)

Work items relate to each other, and that is a first-class edge of the graph. For example, the
development Stories that came out of a research spike link back to that spike issue. A
Story that depends on another links it too. These edges are kept **in GitHub Issues**, each with a one-line reason. An edge is a sub-issue
under its parent, a "blocked by" link for a dependency, or a `Relates to #42` line in the issue body. When the github-issues pack is installed, the `write-story` skill writes
them in its update mode (`gh issue edit` or `gh api`, with the why in the issue body).

- The canonical store for story-to-story edges is **GitHub Issues**, not repo front-matter. So the
  PO/PM see them on the board, and developers see them on the story.
- A repo artifact may mirror the ones that matter most in front-matter as
  `relates.stories: ["#40", "#41"]`, but GitHub Issues is the source of truth for these edges.
- `guide-me` follows the issue links when walking. A walk from a dev story reaches its source spike
  (and its synthesis and upstream-tool link) without leaving the graph.
- The integrity of these edges needs the GitHub API, so it is part of the **deferred issue-side check**.
  Until then the update mode of `write-story` holds them.

## Front-matter convention (repo artifacts)

Add YAML front-matter to a repo artifact (PRD, spec, MADR, doc) to put it in the graph:

```yaml
---
story: "#42"
phase: elaboration
step: write-api-spec
intent:
  hypothesis: docs/discovery/order-compare/hypothesis.md
  assumption: "approvers need arbitrary-pair comparison, not just latest-vs-new"
  decision-drivers:
    - "reuses the proven, version-agnostic diff engine, the lowest-risk path"
relates:
  spec: specs/order-compare.openapi.yaml
  adr: docs/adrs/0007-order-compare.md
  design: <repo path or a design-tool link>
  research: <a research-tool or repo link>
  docs: docs/api/orders.md
because:
  adr: "records why arbitrary-pair compare reuses the diff engine"
  spec: "the wire contract the build and tests consume"
---
```

- `story` is required: the anchor work-item key, always in quotes (`"#42"`), because a bare `#` starts a
  YAML comment. `phase` is required: `discovery`, `elaboration`,
  `create`, `mature` or `governance`. `step` is optional: the process step. An old `step` that names a
  renamed skill stays as it is; `guide-me` maps it to the new name through `retired` in `sync-manifest.json`.
- `intent` is optional: the why, made traversable (see "Intent: the why as a structured edge"). Its
  `hypothesis` is the upstream-why edge, a repo path or a URL.
- `relates` is optional: edges to other artifacts. `because` is optional: a one-line reason per
  `relates` edge.
- Keep each value alone on its line. The artifact-graph gate reads a trailing `# ...` comment as part
  of the value.
- `relates` values are either **repo-relative paths** (checked to exist) or **URLs**. The gate does not
  check a
  URL, and does not notice a missing one; CI cannot read an external tool.
- The issue side of the edges is kept by the update mode of the `write-story` skill (outbound links and the why).
  Repo artifacts carry the inbound `story:` and `relates:`. Walk works both directions.

## Intent: the why as a structured edge

The graph models which artifacts relate. The `intent` and `because` blocks make the **why** traversable
rather than prose-only. A reader (or `guide-me`) can then follow intent without reading every artifact end
to end. They are produced by the `grilling` questioning that comes before drafting.

- **`intent.hypothesis`** is the upstream-why edge: the discovery hypothesis this artifact traces up to.
  A repo path is resolve-checked; a URL is not checked. This is what lets the chain
  hypothesis -> PRD -> story -> ADR -> code be walked. Without it, the upstream why never enters the graph.
- **`intent.assumption`** is the single riskiest belief the work rests on, stated so it can be shown false.
  Free text. Under `-Strict` the gate asks for it on a `discovery` or `elaboration` artifact.
- **`intent.decision-drivers`** are the forces that drove the chosen approach. Free text list; the gate does
  not check it.
- **`because.<edge>`** is a one-line reason a given `relates` edge exists, keyed by the same edge name. It
  tells a reader a `relates.adr` (a decision link) from a `relates.docs` (a reference).

Enforcement of the why follows the advisory-then-blocking pattern: by default it is **not required**, so
existing artifacts stay green while the graph fills up. Run the linter with **`-Strict`** to enforce
two things, and that is the mode the gate switches to once the graph is full:

- every intent-bearing edge (`adr`, `spec`) carries a non-empty `because.<edge>` reason; and
- every artifact in a why-bearing phase (`discovery`, `elaboration`) carries a non-empty `intent.assumption`.

The second is the soft enforcement of the questioning. Those phases are where the `grilling` questioning
runs, so an artifact written there without that questioning has no captured assumption, and `-Strict` flags
it. The author fills `intent.assumption` from the user's grilling answers; the user does not type it.

The code-to-story tie at the far end of the chain is a story trait on each test, not front-matter.
Source files do not carry front-matter. Each stack pack defines its own trait: the dotnet pack
uses an xUnit `Story` trait and checks it with its story-trait gate. A test class that predates the
convention carries the placeholder story key `LEGACY-0`. The story-trait gate accepts it, but it is on purpose not
a real issue key. So a walk from such a test ends where you can see it, not on a likely wrong story. When
an old class is next changed for a real story, the placeholder becomes that story's key. The number of
`LEGACY-0` occurrences shows how much of the suite still predates the convention. No gate ratchets it,
because that would punish touching old tests.

## Required artifacts: mandatory only where a downstream step needs it

Not every artifact is required for every change, and **size does not decide this.** The governing test is the
nature of the work: **an artifact is mandatory only where a downstream step needs it as input.** Story points
(the `size:<n>` label) size how deeply `grilling` questions the work; they do not decide which
artifacts must exist. An 8 or 13-point change can need no upstream artifact at all (a large refactor, a
well-understood migration). A small change can sit inside an initiative that already has a journey. Keep
the two things apart: **points size the questioning depth; the nature of the work decides the required
artifacts.**

Most of the test resolves from what the work touches:

- Any tracked change needs its **story and acceptance criteria**, and, when it changes code, its **tests**.
- Work that changes or exposes an **HTTP surface** needs an **API contract** (`relates.spec`).
- Work that makes a **key or data-model decision** needs an **ADR** (`relates.adr`).
- **Net-new behaviour whose value, desirability, or users are not yet known** needs **discovery
  framing**. That is a hypothesis, then a journey, then a PRD as it firms up.

The one judgement that does not resolve by rule is whether a net-new behaviour is understood well
enough to skip discovery. **The framework does not guess this; it asks.** The entry point can plainly be a
bug, a refactor, an ops task, or a told-to-build change. Then no discovery framing is needed and none is
asked for. The work can also look discovery-driven with the framing absent. Then the authoring skill says
so and **asks the user whether upstream framing is needed**. It does not assume a gap or skip one in silence.
An authoring skill never invents an artifact a downstream step does not need, and never skips one a
downstream step does need. Surface, don't decide.

`guide-me` applies the same test when it reports what is missing. A required artifact that
is absent is named as a gap. The discovery question is raised as a question, not stated as a gap. The full
shape of each artifact type is in [node-templates.md](node-templates.md).

## Phases

`discovery` | `elaboration` | `create` | `mature` | `governance` (cross-cutting). See
[the skills](README.md#the-skills) in the handbook README for the skills of each phase. A `step`
value is the name of the skill that wrote the artifact.

## What the linter enforces (v1)

`.claude/skills/ai-sdlc-gates/scripts/Check-ArtifactGraph.ps1` scans the doc roots (`paths.docsRoots` in
aisdlc.json) and the specs folder (`paths.specsRoot`). It checks every artifact there that declares
`story:`, so functional docs are first-class graph nodes, not just technical ones:

1. `story` is a valid work-item key: `#42` or `owner/repo#42` (`tracker.keyPattern` can set another
   pattern). An unquoted number such as `42` counts as `#42`. An empty `story:` is an error, because
   an unquoted `#42` turned the value into a comment.
2. `phase` is present and one of the known phases.
3. Each `relates.*` repo path resolves to a file in the repo. A URL is not checked.
4. `intent.hypothesis`, when present as a repo path, resolves to a file. A URL is not checked.
5. Under `-Strict` only: every intent-bearing `relates` edge (`adr`, `spec`) carries a non-empty
   `because.<edge>` reason, and every `discovery` or `elaboration` artifact carries a non-empty
   `intent.assumption`. Without `-Strict` this is advisory, so the build stays green while the graph
   fills up.

It exits non-zero (fails the build) on any violation, and does nothing on artifacts that have not opted in.

## Intended required edges (target, tightened as use grows)

These are the edges the graph should need per phase in the end (not all enforced in v1):

- A Story entering `create` links a machine-readable spec (`relates.spec`).
- An architectural decision is recorded as an ADR and backlinked from its story.
- A design-phase artifact links the design source (`relates.design`).
- Every spec and ADR references its `story`.
- A development Story is linked in GitHub Issues to the spike issue it came from (story-to-story edge).

## Enforcement is shared

The same script runs two ways (one rule, one source of truth):

- **Locally:** `.claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1` and the pre-push hook. Claude
  Code and Copilot CLI both run the same script.
- **In CI:** a gating step in the repository's pull request workflow.

## Related

- [Node templates](node-templates.md) - the content shape of each artifact whose edges this graph validates.
- [Skill patterns](pattern.md) - the shapes of the skills that produce and consume these graph nodes.
- [Documentation wiki](docs-wiki.md) - the knowledge layer that partners this traceability layer.
- [AI-SDLC design](plan.md) - why there are four phases and a cross-cutting track.
