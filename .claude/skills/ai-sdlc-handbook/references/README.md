# The AI-SDLC

The start-here guide to the AI-assisted software development lifecycle. It says what the lifecycle is,
which skills run it, and how to drive a piece of work through it. The other pages in this handbook are focused
references; this page orients you and links to them. Where each shared part comes from, and which parts
a repository keeps itself, is on the [layout page](layout.md).

## TL;DR

Work runs through **skills**: one markdown file per job, installed under `.claude/skills/`, read by
Claude Code and GitHub Copilot alike. A workflow skill is a command you type, or an internal step that
other skills call; knowledge skills are loaded by them. **Agents** in `.claude/agents/` write the plan, build and review; only the `builder`
writes files. Which skills
and agents a repository has depends on the packs it installs. You do not need to know the list.

**A person decides twice.** At Checkpoint Alpha you approve a story, epic or other draft before anything is written to
a GitHub issue. A document for the repository reaches you at Checkpoint Bravo. There you review the pull request the loop pushed and opened for a tested
change, and you merge it or send it back. Everything else runs on its own
([orchestration](orchestration.md)).

**Start every piece of work the same way:**

```
/guide-me #42
```

`#42` stands for a GitHub issue number (`owner/repo#42` for an issue in another repository). The skill reads the work
item and the repository, says which phase the work is in, what is missing, and which skill to run next.
It writes nothing, it points. If you remember one command, remember that one.

**The three you will use most:**

| You want to | Run | What it does |
|---|---|---|
| Build a story end to end | `/implement #42` | Assembles the context, plans, writes tests first, brings coverage to the bar and has agents review it. Then it runs `wrap-up`, which updates both documentation layers, records decisions, commits and runs the pre-flight on the commit. Then it pushes and opens or updates the pull request with an evidence record. It works the PR checks and the bot review threads until no bot finding is open, then waits for your review. Starts only from a refined story. |
| Finish a change you already made | `/wrap-up` | Searches the repository for anything that still refers to what you renamed or removed, then brings the tests, both documentation layers, the user story and the gates up to what the change really did. Then it commits and runs the pre-flight, so you only push and open or update the pull request. Run it on the story branch; it stops on `main` or on a branch with no story key. |
| Fix a bug that is already a GitHub issue | `/fix-bug #42` | Reads where the bug stands. It triages an item nobody triaged, says what a person must add before the fix, or frames the fix of a refined bug and hands it to `/implement`. |

**Two rules that never bend:**

- **A human signs off, never the agent** ([C09](constitution.md)).
- **Quality lives in deterministic gates, not in how careful the model felt.**
  `pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1` runs the same gates CI runs, in seconds.

**What it promises, and what it does not.** The skills make good work likely, and they can still be
wrong. The gates are deterministic, but a gate is only as strong as its mode and the build policy that
needs it. An advisory gate only reports, and a gate the policy does not need can be skipped. So a
green pull request is a request for review, not proof that the change is right. A person stays in
control at both human checkpoints.

**Your first story?** Pick a small one and follow [Your first story](first-story.md).

**Not using an AI tool?** Nothing here blocks you. The gates and the git hooks run for everyone, and the
pre-push hook reports documentation drift whatever wrote the code.

The rest of this page explains the phases, the full skill set, and how they fit together.

## What it is

The AI-SDLC turns ad-hoc "prompt the model" work into a **navigable, gated, cross-tool lifecycle**. Three
ideas hold it together:

1. **Every ability is a skill.** A skill is a `SKILL.md` process under `.claude/skills/`, read by Claude
   Code and GitHub Copilot (and Codex / Gemini) alike. One committed file, every tool. The skills are the
   contract.
2. **Every work product joins an artifact graph.** GitHub issues, specs, ADRs, docs, and the code are linked
   on a stable issue key. The *why* (the riskiest assumption, the decision drivers) travels as structured
   intent, not just text. A reader or `/guide-me` can walk "what exists and what is next."
3. **Quality lives in gates, not vibes.** A small constitution of non-negotiables and deterministic gates
   in CI and on your machine enforce what matters. So the rule holds, whoever or whatever wrote the change.

The target is the AI-SDLC maturity model, from L1 prompt-driven up to L5 self-running. The L3 hinge is
**gating**: the contract must live in the repo as vendor-neutral markdown. The workflow runs at L4: the
steps run on their own between two human checkpoints, and a person decides what leaves the machine
([orchestration](orchestration.md)).

## The lifecycle

Four phases run in order, with a cross-cutting track available throughout:

```
discovery  ->  elaboration  ->  create  ->  mature
   (Analyst)     (PM/QA/Arch)   (Dev/QA/SM/TW)  (PM/Dev)
                          \  cross-cutting track  /
            (grilling, walk-substrate, ADRs, gates, graph, personas - any phase)
```

- **discovery** - turn a fuzzy idea into a stated problem, a journey, and a testable hypothesis.
- **elaboration** - frame the work: the story and its acceptance criteria, the PRD, the API contract.
- **create** - build it: plan, test-first code, docs, decisions, review, PR.
- **mature** - improve the product: learn from what shipped, fix what breaks and make it better.
- **cross-cutting** - questioning, context-gathering, decisions, work item upkeep, and the gates, used in any phase.

**Not every piece of work touches every phase.** A bug fix lives in mature -> create; a one-line change needs
no hypothesis or journey. The rule (in [artifact-graph.md](artifact-graph.md)) is *an artifact is mandatory
only where a downstream step needs it as input*. The size of the work sets how much questioning it gets,
not which artifacts it needs.

## The skills

The workflow skills are named by what they do (the phase and owner live in each skill's `phase:` /
`persona:` frontmatter, not the name). Each declares `kind: workflow`; the knowledge skills and the agents
are listed after them. `/guide-me` reads that frontmatter to tell you the next step. The tables below are
the **index**: a skill's full process, inputs, failure modes, and guardrails live in its own
`.claude/skills/<name>/SKILL.md`. Read that file for the ins and outs of any single skill. Call a skill by
typing `/<name>`, or just say what you want in the words of the "Use it" column - the description triggers it.

A workflow skill is one of two things. A **command** is one you type; it shows with a slash in the
tables below. An **internal step** sets `user-invocable: false`: another skill calls it, and Claude Code
keeps it out of the slash-command list. It shows without a slash, with the command that runs it. Not sure
which command fits? Ask `/guide-me` with no work item, and it names the one for your situation.

The Package column says where a skill comes from. A skill from a pack is there only when the repository
installs that pack; the [layout page](layout.md) lists the packs.

### Discovery (Analyst)

| Skill | Package | Purpose | How it works | Use it (example) |
|---|---|---|---|---|
| `/write-research-summary` | discovery | Turn raw research into navigable findings | Reads the study, writes a synthesis as a markdown page under the discovery folder (`paths.discoveryRoot`), and anchors it on an issue with the `spike` label with the links + summary. The entry to discovery. `wrap-up` commits the page on a spike branch for the pull request. | "write up the interview findings and anchor them on the spike" |
| `/draw-customer-journey` | discovery | Map the customer journey and opportunity landscape | Lays out stages, pains, and opportunities, renders a diagram, and writes it as a markdown page under the discovery folder that carries the intent. `wrap-up` commits the repo files on a spike branch for the pull request. | "map the journey for the onboarding flow" |
| `/write-hypothesis` | discovery | Capture a product hypothesis as a lean canvas | Grills the belief, states the hypothesis and assumptions, marks the single riskiest one, defines how to falsify it. `wrap-up` commits the page on a spike branch for the pull request. | "what is our riskiest assumption about self-service?" |

### Elaboration (PM / QA / Architect)

| Skill | Package | Purpose | How it works | Use it (example) |
|---|---|---|---|---|
| `/write-story` | github-issues | Create or refine a story issue and its testable acceptance criteria, or bring a story in line with what shipped | Scans for duplicates, runs `grilling`, fills the house template, sizes against comparators, has the `draft-reviewer` agent check readiness, then writes at Checkpoint Alpha. Splits an epic into vertical slices as sub-issues of a parent issue, with "blocked by" links. Its update mode is the single writer for an existing item: other skills call it for a description, a title, links and backlinks. | "create a story for the build-version footer"; "update #42 to say what we shipped" |
| `/write-prd` | core | Write a PRD for an initiative or epic | Frames problem, goals, scope, requirements, and success metrics as the anchor that stories derive from. `wrap-up` commits it on an epic branch for the pull request. | "draft the PRD for the mass-update initiative" |
| `/write-api-spec` | dotnet | Produce the OpenAPI contract for a slice | Designs the wire shape (PascalCase bodies, problem+json errors); the L3 keystone the build and tests consume. After a standalone run, `wrap-up` commits it for the pull request. | "write the OpenAPI spec for the compare endpoint" |

### Create (Developer / Tech Writer)

| Skill | Package | Purpose | How it works | Use it (example) |
|---|---|---|---|---|
| `/wrap-up` | core | Finish a working change: tests, docs, substrate, gates, lessons, commit, pre-flight | The end of every build loop (`implement`, `refactor`, `fix-pr-feedback`), of `adopt-docs`, and of `write-platform-note` (knowledge pack). `write-prd`, `write-pipeline` and the discovery skills call it for the repository files they write. `write-adr`, `update-constitution`, `write-docs`, `add-gate`, `capture-learning` and `write-api-spec` call it only after a standalone run. It is the single owner of those steps. It stops on `main`, `master` or a branch with no story key. An orchestrator: it reads the diff, searches for anything elsewhere that still refers to what changed, then calls the skills that own tests, docs, decisions, the user story and the gates. Then it commits (a save point, not a sign-off) and runs the pre-flight on that commit. Fired by the pre-push completeness check. | "the feature works, finish it off" |
| `/implement` | core | Drive a change from story to PR | The build loop: walk -> plan -> branch -> TDD -> review by agents -> evidence record -> `wrap-up` (docs, ADR, lessons, commit and pre-flight) -> push and PR -> Checkpoint Bravo, your review; delegates each step to its owning skill or agent. | "take #42 through the full dev cycle" |
| `/refactor` | core | Improve internal structure without changing behaviour | Tests green before and after, public contract the same, constitution intact. Starts only from a refined work item, as `/implement` does. | "refactor the email service, no behaviour change" |
| `/write-docs` | core | Maintain both doc layers as one wiki | Index-first; routes each change to the technical or the functional layer, cross-links related pages. Runs the truth checks before it drafts, generates only for pages provably wrong, and checks every added claim against the source before merging it. After a standalone run, `wrap-up` commits the pages for the pull request. | "update the docs for the new compare endpoint" |
| `/write-pipeline` | github | Write the GitHub Actions workflows of a repository | Asks for the workflow type, the environments and the steps, then writes the workflows in the team layout, with the shared AI-SDLC composite action in the pull request workflow. Runs only when called by name. `wrap-up` commits the files on a story branch for the pull request. | "set up the workflows for this function app" |
| `/fix-pr-feedback` | github | Resolve all PR feedback (bots, people, gitleaks, SonarCloud) | Gathers every source (people, review bots, SonarCloud, gitleaks), fixes the findings, then runs `wrap-up`, which captures the lessons from the open review before any thread is resolved. After a push it loops on the PR checks and the bot review threads until no bot finding is open. | "work through the review on PR 17" |

### Mature (PM / Developer)

| Skill | Package | Purpose | How it works | Use it (example) |
|---|---|---|---|---|
| `/fix-bug` | github-issues | Take an existing bug, request or incident from report to a framed fix | Reads the state first. Not triaged: builds a tight feedback loop that goes red on the bug, commits the red test on the bug branch, classifies, prioritises, checks for duplicates, and stops at Checkpoint Alpha with a triage comment. Triaged, not refined: says what a person must add. Refined: frames the fix and hands off to `/implement`. A new bug item is `/write-story`. | "triage #42"; "is this a duplicate?"; "fix #42" |

### Cross-cutting (any phase; mostly Lead / any)

| Skill | Package | Purpose | How it works | Use it (example) |
|---|---|---|---|---|
| `grilling` | core | Question the work from the roles that matter before drafting | Maps the decisions as a tree and asks in rounds, each question with a recommended answer that "yes" accepts. Looks facts up instead of asking them, asks from the personas the work touches, and hands back the answers and the why. Authoring skills call it pre-draft. | runs inside an authoring skill; type `/grill-me` to run it on your own plan |
| `/grill-me` | core | Stress-test your own plan or design | Runs `grilling` on the plan you name, until every branch is settled and you confirm. Only a person starts it. | "/grill-me on the plan for the migration" |
| `walk-substrate` | core | Walk a work item's upstream and code-side substrate before building | resolve -> walk -> assemble -> return a sub-3KB attention-first context block. Action skills call it pre-build, once per work item per thread. An internal step. | runs inside `/implement`, `/fix-bug` and `/refactor` |
| `/convene-personas` | core | Talk to one role or convene a panel | Voices the persona registry in character for view, not to author an artifact. | "what would the Architect say about reusing the diff engine?" |
| `/update-constitution` | core | Create, amend, or check the constitution | Maintains the non-negotiables; check mode flags a change against the clauses. After a standalone create or amend, `wrap-up` commits it for the pull request. | "check this change against the constitution" |
| `/write-adr` | core | Author MADR-style ADRs | Records a key decision with context, alternatives, and intent; emits the graph frontmatter. After a standalone run, `wrap-up` commits it for the pull request. | "record the decision to reuse the diff engine as an ADR" |
| `check-pr-contract` | github-issues | Check a PR references a dev-active story and that a data-model change has an ADR | Reads the issue with `gh`, fail-closed; the headless CI form is `Check-PrStoryContract.ps1`. An internal step. | runs inside `/wrap-up` and the pre-flight |
| `run-preflight` | core | Run the whole PR pipeline locally before pushing | Loops the deterministic checks (gates, analyzer rules, coverage, gitleaks) to green and surfaces the rows that need a human decision. A green run on a committed tree writes the receipt the push hook asks for. Never suppresses a finding or pushes. An internal step. | runs inside `/wrap-up` |
| `/add-gate` | core | Scaffold a new deterministic gate end to end | Generates the validator, its Pester test and its entry in `gates.json` or `repoGates`, which the shared composite action runs; advisory-first. After a standalone run and a go-ahead on the diff, `wrap-up` commits a repository gate for the pull request. A shared gate goes to AI.SDLC through its own pull request. | "add a gate that blocks a PR with no story key" |
| `/capture-learning` | core | Turn a correction in this session, or the feedback on a pull request, into a lasting rule | From this session: a short checklist, the autolearn filter, the one home, and the write handed to the skill that owns it. From a pull request: mines the diff, the threads and the findings, classifies each correction and measures which gates catch it. The autolearn hook asks for it after a correction. After a standalone run that changed the repository, `wrap-up` commits the change for the pull request. | "remember this: never log that way again"; "what can we learn from the review on PR 17?" |
| `/test-skills` | core | Eval the skills before relying on them | Layer 0 hygiene (scripted), Layer 1 routing discriminability, Layer 2 value vs a baseline, Layer 4 routing in Copilot CLI. | "eval the skills after my change" |
| `/update-ai-sdlc` | core | Take a new AI.SDLC release | Opens one update pull request on the branch `ai-sdlc-<tag>`, with the steps the release asks of this repository, then does those steps on the same branch. The scheduled workflow opens the same pull request every Monday. | "update the AI-SDLC to the newest release" |
| `/handoff` | core | Write a handoff document before a compact or a fresh session | Checks the session is at a boundary, writes the costly parts to their own home, then writes a handoff document to the OS temporary folder for the next session. The person types `/compact`, never the agent. Only a person starts it. | "/handoff the next session builds #42" |
| `/wait-what` | core | Re-pitch the last answer that did not land | Says it again with a little context, at our reading level and in the words of the functional glossary. Writes no file. Only a person starts it. | "/wait-what" |
| `/summary` | core | A one-page HTML summary of a conversation, branch or work tree | Builds a visual page in `temp/`: charts and diagrams over long text, with accessible, artistic and animated variants. | "give me a handover page for this branch" |
| `/guide-me` | core | Walk: report where a work item sits and what is next, or which command fits a situation | Resolves the anchor, walks the graph, reports the current phase, the gate the work waits at, and the next skill and its persona; can dispatch on request. Without a work item, it reads the skill descriptions and names the command for the situation. Read-only itself. | "what is the next step for #43?"; "which command do I use for a failed review?" |
| `/adopt-docs` | core | Bring existing docs up to the wiki rules once, after the install | Runs `Repair-DocsWiki.ps1` for the machine fixes (em-dashes, titles, Related sections, the index), links the code graph for a .NET repository, then fixes the reading level and links page by page until the gates pass. | "our old docs fail the doc gates after the install" |

### Operations (Operations engineer)

These skills come from the `knowledge` pack, for operations work on servers, monitoring and incidents.
They read the facts of the platform from the platform notes, never from the skill.

| Skill | Package | Purpose | How it works | Use it (example) |
|---|---|---|---|---|
| `write-platform-note` | knowledge | Write or update a note on how the platform behaves | Adds or updates a note in `paths.platformKnowledge` when a merged change or an incident shows a behaviour worth keeping. The look-up rules are in `platform-knowledge-conventions`. `wrap-up` commits the note on a story branch for the pull request. An internal step: `/capture-learning` calls it. | "write down how the backup job on server01 works" |

### Knowledge skills (loaded, never typed)

A knowledge skill says how we do one thing and links the page that holds the full rule. It sets
`user-invocable: false`, so it is not in the slash-command list: a workflow skill or an agent loads it.

| Skill | Package | Covers |
|---|---|---|
| `ai-sdlc-handbook` | core | This handbook: the full rules of the way of working |
| `ai-sdlc-gates` | core | The deterministic gates, the gate runner and `aisdlc.json` |
| `ai-sdlc-hooks` | core | The hooks and the git hooks, and why one refused a step |
| `docs-wiki-conventions` | core | The two doc layers as one checked wiki |
| `adr-conventions` | core | When a decision needs an ADR and how it is written |
| `csharp-generation-smells` | dotnet | The ways generated C# and Razor drift from the conventions where no analyzer looks |
| `test-first-dotnet` | dotnet | Test-first, the story trait, AAA markers, the coverage ratchet |
| `api-contract-conventions` | dotnet | The wire rules and the spec that moves with its endpoint |
| `dotnet-gates` | dotnet | The gates the dotnet pack adds |
| `dotnet-code-graph` | dotnet | The local code graph and what it answers |
| `nuget-vulnerability-remediation` | dotnet | Finding and fixing a vulnerable NuGet package |
| `blazor-conventions` | blazor | The Blazor component conventions and their gates |
| `blazor-authorization` | blazor | The checks before a portal authorization change |
| `bicep-conventions` | bicep | How a Bicep template is laid out and changed |
| `platform-knowledge-conventions` | knowledge | Looking up and trusting the platform notes, and the shape of a note |
| `github-pull-requests` | github | Opening and reading back a pull request |
| `github-actions-conventions` | github | The team layout and rules of a GitHub Actions workflow |
| `github-issue-conventions` | github-issues | The issue template, labels, sizing and readiness check |
| `sonarcloud-mcp` | sonarcloud | Reading the SonarCloud analysis through the MCP server, with the token kept out of the repository |

### Agents (helpers with their own context)

An agent runs in its own context with a fixed tool list. Every agent is read-only except `builder`,
which writes code and tests and nothing else. A reviewer that can write is no longer independent, so
the review agents stay read-only. The builder exists so the build step runs on a chosen model, whatever
the model of the session is. Claude Code, Copilot CLI and Copilot in VS Code all read
`.claude/agents/`. Every skill that hands work to an agent also says how to do the step without one ([orchestration](orchestration.md)).

| Agent | Package | Persona | Model | Used by |
|---|---|---|---|---|
| `substrate-walker` | core | any | `sonnet` | `implement`, `fix-bug`, `refactor` before the build |
| `architect` | core | Architect | `opus` | `grilling` and `/convene-personas` panels; the plan of `implement`; plan review; `write-adr`; `write-api-spec` |
| `docs-reviewer` | core | Tech Writer | `sonnet` | after the docs step, before the push |
| `blind-judge` | core | Lead | `opus` | `test-skills` Layer 2 |
| `builder` | core | Developer | `sonnet` | the test-first build step of `implement` |
| `draft-reviewer` | github-issues | Product Manager, QA, Analyst | `opus` | `grilling` and `/convene-personas` panels; blind review of every Checkpoint Alpha draft |
| `code-reviewer` | dotnet | Lead, Developer | `sonnet` | the review step; `refactor`; `update-constitution` check mode |
| `test-analyzer` | dotnet | QA | `sonnet` | the review step of `implement` and `refactor` (a bug fix from `fix-bug` reaches it inside `implement`) |
| `security-reviewer` | dotnet | Lead | `opus` | the review step when auth, RBAC, outbound calls, JS interop or request logging move; `grilling` and `/convene-personas` panels |

Why each agent uses its model, and which model to pick for a skill, is in
[pattern.md](pattern.md#the-model-of-each-step). Sonnet is enough for the main session, because the
heavy steps run on their own model.

## Personas

A persona is a role, a lens, and the questions it typically asks. `grilling` voices them to question work
before it is drafted, and `/convene-personas` voices them to talk to a role or a panel. They are also the
role-framing on every skill. The full registry, with each persona's questions and voice, is in
[personas.md](personas.md). You rarely call a persona by name. `grilling` pulls in the ones a piece of work
touches on its own; use `/convene-personas` when you want a role's view on purpose.

| Persona | Lens | Owns (skills) | Agent | How to use it (example) |
|---|---|---|---|---|
| Analyst | Evidence over opinion: what we know vs believe | write-research-summary, draw-customer-journey, write-hypothesis | `draft-reviewer` | "convene the Analyst: what is the evidence this problem is real?" |
| Designer / UX | The human using it: clarity, friction, the empty and error states | discovery prototype and MVP design framing (folded into the steps); speaks when a UI is touched | none; the main thread voices it | "ask UX: what do the empty and error states look like here?" |
| Product Manager | Value and scope: the right thing, sliced right | write-story, write-prd, the triage of fix-bug | `draft-reviewer` | "ask the PM: what is in scope here and what is gold-plating?" |
| Architect | Approach and key decisions, with alternatives | write-api-spec, write-adr, elaboration architecture | `architect` | "ask the Architect: what should we reuse, and is this ADR-worthy?" |
| Scrum Master | Sequencing: dependency, readiness, flow | sprint planning, done by hand in GitHub Issues | none | "ask the Scrum Master: is this refined and unblocked enough to pull in?" |
| Developer | Implementability, test-first | implement, refactor, wrap-up, run-preflight, update-ai-sdlc, the fix of fix-bug, fix-pr-feedback, write-pipeline | `builder`; `code-reviewer` (with Lead) | "ask the Developer: is this specific enough to build without guessing?" |
| QA | Testability and the edges; the unhappy path | acceptance criteria (with PM), the readiness check in github-issue-conventions | `draft-reviewer`, `test-analyzer` | "ask QA: how do we observe this is done, and what are the edge cases?" |
| Tech Writer | Will the next reader understand this | write-docs, adopt-docs | `docs-reviewer` | "ask the Tech Writer: what changed that the next reader needs, and on which layer?" |
| Operations engineer | Servers, monitoring and incidents: prove the cause read-only, change only through code, a person sends it | write-platform-note, platform-knowledge-conventions | none | "ask the Operations engineer: what does this error prove, and what does it not show?" |
| Lead | The non-negotiables, the contract, graph integrity | update-constitution, check-pr-contract, add-gate, capture-learning, test-skills | `code-reviewer`, `security-reviewer`, `blind-judge` | "ask the Lead: does this touch auth, data, or secrets, and is the decision recorded?" |

A persona whose lens the work does not touch stays silent. For example, UX is silent on a pure backend
change, and Lead is silent when no auth, data, secrets or input handling are involved. `grilling` selects only the personas a piece of work touches,
sized to how much depth it needs.

## The machinery behind the skills

- **Artifact graph and intent** - [artifact-graph.md](artifact-graph.md). Frontmatter (`story`, `phase`,
  `relates`, `intent`, `because`) links every artifact on its issue key and makes the why traversable. Defines
  the required-artifacts-by-nature rule.
- **Node templates** - [node-templates.md](node-templates.md). The content shape of each artifact type, with
  a shared envelope so the why is captured in mandated sections, not left implicit.
- **Skill patterns** - [pattern.md](pattern.md). The two skill kinds and the four workflow shapes (reader,
  author, discovery, action/executor). Also the knowledge shape, the agent shape, the hand-off sentence,
  and the section policy the hygiene gates enforce.
- **Autolearn** - [autolearn.md](autolearn.md). How a correction in a session becomes a lasting rule.
  It covers the moments it fires, the filter that keeps noise out, and the table that sends each lesson
  to one home. Two of the moments fire by themselves through the hook in `.claude/settings.json`; the
  runnable step is `/capture-learning`.
- **Context management** - [context-management.md](context-management.md). Where a compaction is safe,
  and what it keeps and drops. Also the rule to write the costly part of the session to a file first.
  The nudge fires by itself through the hook in `.claude/settings.json`; the runnable step is
  `/handoff`.
- **Delivery metrics** - when the github pack is installed, the `github-pull-requests` skill
  carries the page on whether the workflow delivers. It counts merged pull requests, lead time, review
  wait and rework per week, for the team and never per person.
- **Skill usage** - [skill-usage.md](skill-usage.md). Which skills the team really runs, counted from the
  session transcripts, including one skill delegating to another. It also names the skills nothing calls.
- **Personas** - [personas.md](personas.md). The single registry of roles, lenses, and the questions each
  asks; read by `grilling`, `/convene-personas`, and every skill's role-framing.
- **Orchestration** - [orchestration.md](orchestration.md). The two human checkpoints, what runs on its own
  between them, and the stop list. Also the evidence record, where the gates are enforced, and how skills
  hand work to agents.
- **Gates and the constitution** - the core non-negotiables are listed in full in
  [constitution.md](constitution.md), next to the ID scheme for pack and repository clauses. They are
  enforced by the `Check-*.ps1` scripts that
  `pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1` and the pre-push hook run locally, and
  by the pull request workflow of the repository. That workflow runs the shared AI-SDLC composite action. New
  gates are scaffolded by `/add-gate`. Which gates block and which only advise is in the enforcement
  key of the constitution. `run-preflight` runs the whole PR pipeline locally before you push: the
  gates, the analyzer rules, the tests and coverage, and gitleaks. So you catch failures without the
  push-and-wait round-trip. One core gate, `Check-PrivateTerms.ps1`, blocks the terms of a private list
  in a public repository. The list itself lives outside the repository.
- **Coding conventions** - [comments.md](comments.md) and [language.md](language.md) hold the conventions
  every repository shares. Each stack pack carries its own conventions in the `references/` folder of its
  knowledge skills, for example `csharp-generation-smells` for C# or `bicep-conventions` for Bicep. The
  create-phase skills follow them and several gates enforce them.
- **Docs wiki, and whether it is true** - [docs-wiki.md](docs-wiki.md). Two different questions, both
  checked by script. *Reachable*: `Check-DocsWiki.ps1` lints orphans, broken relative links and
  page-to-page connectivity, and `Build-DocsIndex.ps1 -Check` checks index drift. *Correct*: two checks exist only in a repository with the dotnet pack.
  `Check-DocDrift.ps1` reads every page against the code it names. It reports a constant the code
  declares and the page omits, and a file or identifier that no longer exists. It also reports a
  documented route that no route-carrying file names, and a service the project page never names. It
  needs only git, so the pre-push hook runs it for everyone, and it blocks. `Check-DocGraphClaims.ps1`
  uses the local code graph to catch a page that claims a relationship the code does not have. No text
  check can see that. It stays advisory, because not every machine has the graph. A third check, in the
  core, is `Check-DocSectionRefs.ps1`. It reads what comes after the file name: a pointer at a section,
  and a link anchor, must name a heading that is there. A decision record a script names must exist. The `dotnet-code-graph` skill of the dotnet pack
  says what the graph can and cannot answer.
- **Design** - [plan.md](plan.md): the decisions that still hold and why, including how the same skills
  run under Claude Code and Copilot.
- **Sharing with other repositories** - [layout.md](layout.md). The core package, the stack and tool
  packs, and the files a repository keeps itself. Also how a repository pins a version and changes a
  shared file. [consumer-own.md](consumer-own.md) says where a repository keeps skills, agents and
  hooks of its own.

## How to use it

### Set up a clone once

Run `pwsh .claude/skills/ai-sdlc-hooks/scripts/Install-AiSdlc.ps1` once per clone, from a terminal in
the repository. It switches Windows long paths on when they are off (approve the one administrator
prompt), and it checks your `gh auth status`. It installs APM when it is missing, installs exactly the versions in
`apm.lock.yaml`, and wires the git hooks. When no ignore rule covers `temp/`, it adds `temp/` to
`.git/info/exclude` of the clone, so nobody edits `.gitignore` by hand. The pull request workflow checks the installed files against
the lock (`apm audit --ci`). Then start Claude Code or GitHub Copilot in the root folder of the
repository. The agent hooks come from the committed `.claude/settings.json`. In Copilot they run only
once you trust the repository folder. They also run only in a session that starts in the root folder:
a session started in a subfolder runs no hook. The skills read GitHub issues and pull requests with the `gh` command.
Run `gh auth login` once per machine. You may also add the GitHub MCP server for its read tools, but no skill needs it.
The `substrate-walker` agent uses `gh` and `git` read-only. Copilot does not read the allow rules in
`.claude/settings.json`, so it asks before each command. To allow a command for a session, start
Copilot with `--allow-tool`, for example `copilot --allow-tool 'shell(dotnet test:*)'`. A repository that has no AI-SDLC yet gets it from
`tools/Add-AiSdlcConsumer.ps1` in AI.SDLC ([layout](layout.md)). A new version is taken with
`pwsh .claude/skills/ai-sdlc-hooks/scripts/Update-AiSdlc.ps1`, which stages the whole update for one
commit.

### Your first story

New to the flow? Take one small story through it with [Your first story](first-story.md). It says how to
pick the story, which steps to run, and what to check at each human checkpoint.

### The entry point

For any work item, start with **`/guide-me <key>`**. It tells you which phase the work is in, what
exists and what is missing. It also names the next skill to run, with the persona who owns it. It writes nothing; it
points. From there you run the skill it names, or ask it to dispatch.

### Two habits the framework runs on

- **Authoring grills first.** Before a story, hypothesis, journey, PRD or ADR is drafted, the authoring
  skill calls `grilling`. It questions the scope and the why from the right roles, sized to the work, in
  rounds with a recommended answer each. You answer a few questions, often with "yes"; the answers
  become the artifact's intent.
- **Building walks first.** Before code is written, `/implement` (and `/fix-bug`, `/refactor`)
  call `walk-substrate`. It collects the upstream why and the code-side context: the governing ADRs,
  contract drift, recent PRs and coverage gaps. It also reads the knowledge repository when it is cloned next to the repository. So the build runs against reality, not the story text alone.

### Worked example A: a new feature, end to end

1. `/guide-me` on the idea (or start in discovery). `/write-hypothesis` to state the riskiest
   assumption; `/write-research-summary` and `/draw-customer-journey` if there is research and a flow to map.
2. `/write-prd` for the epic, then `/write-story` to split it into vertical slices and write each one
   (each runs `grilling`).
3. The readiness review inside `/write-story` scores each point pass, fail or unknown. A failed or unknown point sends the story another round to sharpen.
4. `/write-api-spec` if it touches an endpoint; `/write-adr` if it makes a key decision.
5. Sequence the ready stories into the sprint by hand in GitHub Issues.
6. `/implement` per refined story. It walks the substrate, plans, writes tests first and brings
   coverage to the bar. It has the agents review. Then it writes the evidence record and runs
   `/wrap-up`. That updates both doc layers and runs the ADR check and the lessons step. Then it commits
   and runs `run-preflight` on that commit. Then it pushes the branch and opens or updates the PR on its own; you review it
   at Checkpoint Bravo.
7. Inside `/wrap-up`, `run-preflight` runs the tests and the coverage ratchet; the story-tagged tests show each criterion is covered.
   A green run on a committed tree writes the receipt the push hook asks for. So an agent never pushes a commit on which a check failed. A SKIP or NOT-AVAIL row did not run, so read the rows before the push.

### Worked example B: a bug fix (no upstream artifacts needed)

1. `/fix-bug <key>` on the inbound report. It builds a loop that goes red on the bug, and commits the
   red test on the bug branch. Then it classifies and routes the report, and stops at Checkpoint Alpha.
2. A person refines the bug issue: the `refined` label and a `size:<n>` label.
3. `/fix-bug <key>` again. It sees a refined bug and frames the fix against the red test. Then it hands
   off to `/implement` for the scoped cycle (walk -> fix -> test -> review -> `/wrap-up` -> PR).

No hypothesis, journey, or PRD is required: the downstream steps (the fix and its test) do not consume them.

### Worked example C: a thin story handed to you

1. `/guide-me <key>` reports the story as thin and names the gaps
   (untestable criteria, no spec, an open decision).
2. `/write-story` (which runs `grilling`) sharpens it; its update mode records any decisions or links.
3. Re-check readiness with `/write-story`. A person then adds the `refined` label and a `size:<n>` label
   to the issue, and you build. A thin user story sent straight to `/implement` produces guesswork, which
   is exactly what the readiness check prevents.

### Before every PR

Run `/wrap-up` after a change made by hand; `/implement`, `/refactor`, `/fix-pr-feedback` and `/adopt-docs`
run it for you. So do `/write-prd`, `/write-pipeline` and
the discovery skills, for the repository files they write. `/write-adr`, `/update-constitution`,
`/write-docs` and `/write-api-spec` do the same when you start them yourself. So do `/add-gate` for a
repository gate and `/capture-learning` for a change to this repository. A shared gate or lesson goes
to AI.SDLC through its own pull request. Make the change on a branch named with the
story key, never on `main`; `wrap-up` stops on a branch with no story key. It commits everything on
that branch, then runs `run-preflight` on that commit. So when you want a separate pull request for a
side change, make a separate branch for it first. A commit is a save point, not a
sign-off. The pre-flight runs the whole
PR pipeline locally. It loops the deterministic checks to green: the gates, the tests of `commands.test`, the
analyzer rules, coverage and gitleaks. It shows the rows that need a human decision. So you skip the slow
push-and-wait round-trip. A green run writes a receipt for the tree in the receipt folder
(`paths.preflightReceipts` in `aisdlc.json`, `temp/preflight` by default). The agent push hook
(`Deny-IncompletePush.ps1`) refuses a commit without it. The git pre-push hook does not need it. It skips the blocking gates when a passing receipt covers the tip commit of each pushed ref. For a lighter check, `pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1`
runs just the deterministic gates. When the github-issues pack is installed, `check-pr-contract` checks that the
PR is tied to a dev-active story, with an ADR for any data-model change.
A human confirms acceptance criteria and "done" from the evidence the skills report ([C09](constitution.md)).

## Related

- [Your first story](first-story.md) - one small story through the flow, for a first run.
- [Design and decisions](plan.md) - why the workflow is built this way.
- [Layout](layout.md) - core, packs, repo-only files and `aisdlc.json`.
- [Own skills, agents and hooks](consumer-own.md) - where a repository keeps parts of its own.
- [Artifact graph](artifact-graph.md), [node templates](node-templates.md), [skill patterns](pattern.md),
  [personas](personas.md), [orchestration](orchestration.md), [docs wiki](docs-wiki.md).
- [Constitution](constitution.md) - the core non-negotiables the gates enforce.
- [Language and reading level](language.md) - the reading level and the language for everything this workflow writes.
