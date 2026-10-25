# The Graphify code graph

The code graph is a local, generated graph of the code of a repository. It answers questions about
structure, such as "what calls this", "what breaks if I change it" and "what implements this interface".
Every answer comes with a file and a line. The graph is optional, runs fully on your machine, and is
rebuilt on demand. The short rules sit in [the dotnet-code-graph skill](../SKILL.md).

## What it is

Graphify parses the repository with tree-sitter and writes `graphify-out/graph.json`. It holds nodes for
files, types and members, joined by typed edges such as `contains`, `references`, `calls`, `imports`,
`method`, `defines`, `dispatches_to`, `case_of`, `implements`, `inherits` and `indirect_call`.

Every edge carries a confidence tag:

| Tag | Meaning here |
| --- | --- |
| `EXTRACTED` | Read literally from the syntax tree. Confidence score 1.0. |
| `INFERRED` | Worked out by a rule, not read literally. Score 0.8 to 0.9. |
| `AMBIGUOUS` | Evidence that did not resolve, such as dynamic dispatch or reflection. |

**`INFERRED` does not mean a model guessed it.** The upstream documentation says `INFERRED` means "your
model connected the dots". That is true only when a model backend is set up. The scripts here never set
one up: the build is code-only and no API key is set. So the tag marks an edge the C# resolver worked
out by a fixed, careful rule.

That matters, because the rule-based edges are the most useful ones:

| Relation | What it is |
| --- | --- |
| `calls` | A call into an injected interface, for example a controller method to the service method it uses |
| `dispatches_to` | An interface method to its single implementation |
| `indirect_call` | A call reached through a reference in between |

Every `dispatches_to` edge is `INFERRED`, because a match on a single implementer is a rule, not a fact
in the syntax tree. **So dropping the edges that are not `EXTRACTED` deletes the whole
dependency-injection call graph.** Do not filter them out. Use the tag to know how an edge was found,
not to decide whether to believe it.

## Running it

```powershell
pwsh .claude/skills/dotnet-code-graph/scripts/Invoke-GraphifyIndex.ps1            # build or refresh the graph
pwsh .claude/skills/dotnet-code-graph/scripts/Invoke-GraphifyIndex.ps1 -Report    # rebuild, then print coverage and staleness
pwsh .claude/skills/dotnet-code-graph/scripts/Invoke-GraphifyIndex.ps1 -ReportOnly # report on the existing graph, no rebuild
```

The wrapper always passes `--code-only`, which is local parsing with no API key. So no code and no
document text leaves the machine. It refuses any argument that would reach a model backend.

Ask the graph through the query wrapper, which checks first that the graph is current:

```powershell
pwsh .claude/skills/dotnet-code-graph/scripts/Invoke-GraphifyQuery.ps1 affected 'IOrderRepository' --depth 2
pwsh .claude/skills/dotnet-code-graph/scripts/Invoke-GraphifyQuery.ps1 explain 'IStageStrategy'
pwsh .claude/skills/dotnet-code-graph/scripts/Invoke-GraphifyQuery.ps1 path 'OrderService' 'OrderRepository' --undirected
```

`path` follows directed edges by default. It finds no path across an interface boundary, because the
service points at the interface and the implementation points at it too. Pass `--undirected` for
anything that crosses dependency injection.

## What it covers

C#, Razor, PowerShell and project files are in the graph. Bicep has no parser in the tool, and
`--code-only` skips pipeline YAML, so both stay grep work. Run the `-Report` form to see the coverage
per file type in your repository.

Dependency injection resolves through the `dispatches_to` edge, which fires when an interface has exactly
one implementing class. An interface with several implementers gets no `dispatches_to` edge, but
`explain` still lists every implementer.

## What it answers badly

The graph sounds just as sure when it is wrong as when it is right, so the failure modes are named here.

- **Coupling between processes.** Services joined by message topics, events or stored documents have no
  method call between them, so there is no edge. Use the topic or subscription name with grep.
- **Anything in Bicep or pipeline YAML.** It is not in the graph at all. An empty result is not proof
  that something is absent.
- **"Which files mention this name".** Grep gives the same answer, faster. Use the graph for a
  relationship, not for a word.
- **Questions in plain language.** The `query` command walks out from nodes matched on keywords, so a
  question in plain words turns into noise. Name a symbol and use `affected`, `explain` or `path`.
- **Extension methods.** A call to an extension method produces no `calls` edge, because it resolves to
  the framework type it is written on. A dependency list from call edges alone can be short. The
  namespace-level `imports` edge does see that case.

## Proving it still works

The question set (`dotnet.graphifyBenchmarkCases` in aisdlc.json) holds questions with known answers
from the repository's own code.
`pwsh .claude/skills/dotnet-code-graph/scripts/Invoke-GraphifyBenchmark.ps1` runs them and scores the
answers.

This measures **being right**, which is what matters. The tool's own `graphify benchmark` measures how many
tokens it saves, which says the graph is cheap to ask and nothing about whether it is right. A tool that is cheap
and wrong is worse than grep. Run the benchmark after every version bump. It is advisory by default and
takes `-FailOnRegression` for the day it becomes a gate.

A good question set has one case turned around on purpose, such as "Bicep is absent from the graph". If
that case ever fails, the tool gained coverage and the list above has become wrong.

## What the graph is really for

A graph that is right and never used is not worth its upkeep. It earns its place on three questions
that a text search answers badly:

- **Who consumes a project, including callers that never name it.** A host can use a library through an
  injected interface and a transitive reference. Its project file does not name the library and its code
  does not name the implementation, so no grep finds it.
- **A project reference is not a dependency.** A project can reference another project and use nothing
  from it.
- **What implements what.** When an interface has two implementations, the interface does not say which
  one a reader needs.

`.claude/skills/dotnet-code-graph/scripts/CodeGraph.psm1` is the query layer: `Get-ProjectConsumer`,
`Get-ProjectDependency`, `Get-ProjectImplementation`, `Get-TypeCaller` and `Test-ProjectsConnected`.
Three things use it:

1. `Check-DocGraphClaims.ps1` compares what a page claims about relationships with the graph. It finds a
   sentence that connects two projects that never touch, which every text check passes because every
   name on the page is real. A line with the words `no direct code path` is exempt.
2. `Update-DocFromGraph.ps1` writes the relationships into the facts file next to the names, so the
   page gets a Consumers section. Each implementation fact names the project the contract is declared in.
3. The skills ask it directly: `write-docs` before it writes a Related section,
   `walk-substrate` for the reach of a change, and `wrap-up` after a dependency moves.

**What to trust.** `implements` and `inherits` are read literally. Consumer edges mix those with `calls`,
`dispatches_to` and `references`, so treat a consumer list as a lead to check. The negative direction is
the strong one: no edge at all between two projects means a sentence that connects them is almost
certainly wrong. The graph pays off on breadth and indirection, such as a library with many consumers.
For a small library with one consumer, grep is as quick.

## Linking the docs to the code

A page names its sources: the source file beside the thing it describes.
`pwsh .claude/skills/dotnet-code-graph/scripts/Invoke-DocGraphLink.ps1` turns those names into
`documents` edges by resolving each name against the files git tracks. A name that matches two files in
different projects is skipped, not guessed. The rule is precision over recall, the same as the C#
resolver.

A source is read whole and only at a name boundary. A fenced code block is not read at all. Nor is a
placeholder stem such as Foo, Bar, Baz, Qux, or a name that starts with My or Your and a capital.
That list is short on purpose. A filter that removes real sources is worse than the noise it removes,
because nothing later can tell that a page lost a link.

The refresh hooks run the linker straight after every rebuild, because a fresh graph has no `documents`
edges.

Asking a model to link documents to code does not work. The code is parsed locally, the documents go to
the model in separate pieces, and the model never sees the code. To link a page to a class it has to
guess a node id. Resolving names beats guessing and costs nothing.

## Finding documentation that has fallen behind

The dotnet gate `pwsh .claude/skills/dotnet-gates/scripts/Check-DocDrift.ps1` compares what a page says
with what the files it names really declare. It needs no code graph, only git and the files, so the
pre-push hook runs it for everyone. The [dotnet-gates skill](/.claude/skills/dotnet-gates/SKILL.md)
lists the gate, and its help block lists the signals: missing, stale, phantom, route, thin and
service. The rules it shares with the graph tools, such as which files a page names, live in one module, `.claude/skills/dotnet-gates/scripts/DocSurface.psm1`.
The copies drifted when each tool had its own.

## Proposing an update from the graph

`pwsh .claude/skills/dotnet-code-graph/scripts/Update-DocFromGraph.ps1 -DocPath <page>` takes a page that
has drifted. It gathers the public types and named members of the files the page names, and of the whole
project for a project page. It writes those facts, the drafting rules and a check list to a facts
file, `doc-candidates/<page>.facts.md`. It calls no model and needs no secret. The agent in the session
hands the facts file to a subagent that drafts the candidate through `write-docs`. When subagents are not
available, the agent drafts it inline. The structure comes from the graph; the drafter only writes text.

- It refuses ADRs and story files outright.
- It writes into `doc-candidates/` at the repository root, which is git-ignored. It never overwrites the
  page and never commits, because an agent does not sign off its own documentation (clause C09). Not
  under `docs/`, where the wiki gate reads every file, and not under `graphify-out/`, which each build
  empties.
- `-DryRun` prints the facts and writes nothing.
- **The output is a proposal.** The drafter gets names and the old page, never the code. Names can be
  checked, behaviour cannot. `-Check` lists under `UNVERIFIED:` every identifier in the candidate that
  matched neither the facts nor the page, and above twelve it refuses the candidate. It also refuses a
  candidate that keeps less than 98 percent of the words or drops a heading.
- **Absence in the facts is not a deleted file.** The facts are a partial view, so the drafting rules
  forbid removing or renaming any file reference.

The person who runs the step checks each added claim against the source and merges claim by claim, as
the `write-docs` skill says. A file copy mixes checked lines with unchecked ones.

## Staleness

The graph records the commit it was built at. A graph built before a rename describes code that no
longer exists, with the same confidence as a fresh one. So every tool checks before it answers.

The check lives in `Get-GraphIndex`, the one place any tool loads the graph. It reports one of three
states:

- **Current**: no file the graph covers has changed since the build.
- **Stale**: at least one has. The tool prints the count and the first few paths.
- **Unknown**: the graph records no build commit, the commit is gone after a rebase or squash, or the
  graph is not in a git repository. Unknown is silent, because it is not evidence of drift.

The changed set is `git diff` from the recorded commit to `HEAD`, plus `git status`, so an edit you have
not committed counts. That set is filtered to the file types the graph holds nodes for, read from the
graph itself.

A query warns and answers anyway. `Check-DocGraphClaims.ps1` warns and checks anyway too, and the warning never
changes its exit code. An edit you have not committed still counts after a rebuild, because the graph
records the commit, not the edits. `Update-DocFromGraph.ps1` refuses, because a false claim written onto
a page reads as checked ever after; `-AllowStaleGraph` overrides it.

There is one door, and a test holds it. `CodeGraphWiring.Tests.ps1` in this skill fails when a script
names `graph.json` without going through `Get-GraphIndex`, unless the test lists it with a reason. The
same test holds the wrapper, the hook, the pinned version and the prefix rules described below.

The raw `graphify` CLI does not know the check, so `Invoke-GraphifyQuery.ps1` is the door for a
question. It accepts only `affected`, `explain` and `path` and their documented flags, so it cannot reach
`extract`, which can reach a model backend. Three things make the wrapper the one that gets used:

- The instructions point at `Invoke-GraphifyQuery.ps1`. No skill may name a raw `graphify affected`,
  `explain` or `path` unless the same line names the wrapper.
- A `PreToolUse` hook, `.claude/skills/dotnet-code-graph/scripts/Deny-StaleGraphQuery.ps1`, denies a raw
  query from an agent **while the graph is stale** and points at the wrapper. It stays silent while the
  graph is current, because a hook that fires on every query gets switched off.
- A person at a shell is not covered, and cannot be.

The git hooks in `.claude/skills/ai-sdlc-hooks/githooks/` rebuild the graph in the background after a
commit, a pull, a branch switch, and a rebase or amend. Git fires neither `post-commit` nor `post-merge`
for a rebase, so `post-rewrite` is needed too. The hooks do nothing when graphify is not installed, and
they never fail a git operation. They need `core.hooksPath` set to that folder, which the one-time setup
does. They also need the executable bit recorded in git, or they fail on Linux and macOS while Windows
shows nothing wrong.

### Why every build is a clean full build

The incremental `graphify update` command is not used. It does not accept `--code-only`, so it pulls
documentation into the graph. That creates second nodes with the same name as a type. It also opens
the path that reaches a model backend when a key is set. The cache and the merge then keep those nodes
alive. So the wrapper deletes `graphify-out/` before every build. A clean build is also faster than a
cached one.

## Tuning what is indexed

`.graphifyignore` at the repository root is committed and shared. It uses `.gitignore` syntax, merges
with `.gitignore`, and only ever leaves out more. Leave out `packages.lock.json` files, vendored browser
libraries and build output: they add many nodes and no code anyone walks. Dependency versions are
answered by `Directory.Packages.props` (`paths.packagesProps` in aisdlc.json), not by a code graph.

## Related

- [The dotnet-code-graph skill](../SKILL.md) - when to ask the graph and the pinned version.
- [The dotnet-gates skill](/.claude/skills/dotnet-gates/SKILL.md) - the doc drift check and the other .NET gates.
- [Documentation wiki](/.claude/skills/ai-sdlc-handbook/references/docs-wiki.md) - how pages name their sources.
