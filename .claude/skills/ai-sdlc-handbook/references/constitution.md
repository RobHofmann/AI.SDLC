# Constitution (core clauses)

The engineering rules that never bend, in every repository that installs the shared AI-SDLC. A change
must meet them no matter who wrote it, a person or an agent. This page holds the statement, the reason
and the enforcement of each core clause, and its short form. The `## Constitution (core)` part of
`AGENTS.md` imports this page with an `@` line, so every Claude Code session loads it (C12).

A clause earns its place only if breaking it does real harm and the rule is not already plain from the
code. A detailed convention belongs on a conventions page, and a single decision belongs in an ADR
(Architecture Decision Record). Keep this list small.

**How to read the Enforcement line:** `how it is checked - status`. The check is one of: CI gate, linter,
hook, skill, code review. The status is active, or deferred with the planned target. A deferred check
is tracked debt, not a wish.

**Version:** 1.0

## Clause IDs

A clause ID says where a clause lives:

- A **core clause** keeps its C number and holds in every repository that installs the core. This page
  holds them all.
- A **pack clause** carries the prefix of its pack, such as `DOTNET-01`, and holds where that pack is
  installed. The dotnet pack keeps DOTNET-01 (the JSON wire format is PascalCase) and DOTNET-02 (thin
  controllers, one domain each) in the `references/clauses.md` page of its `api-contract-conventions`
  skill.
- A **repository clause** carries the prefix of the repository, for example `APP-01`, and holds in that
  repository only. It lives in the repository's own constitution page (`paths.constitution` in
  `aisdlc.json`).

The core clauses are numbered in order, C01 to C12. A new core clause takes the next free number. When a
clause leaves the core, its number is never given to another clause. The next new clause then takes the
number after the highest one. Old ADRs, merged pull requests and issues keep the IDs they used.

The history of the clauses stays in the constitution page of each repository. The `update-constitution`
skill adds or changes a clause. A core clause changes on this page only. The core part of `AGENTS.md`
(`ai-sdlc-gates/assets/agents-core.md`) imports this page with an `@` line, so Claude Code loads every
clause in each session.

## C01: A decision the architecture rests on needs an ADR before merge

- **Statement:** A change that makes a decision the architecture rests on must add or update an ADR in
  the same change. The ADRs live in the ADR folder (`paths.adrFolder` in `aisdlc.json`), with the README
  of that folder as the index.
- **Rationale:** It stops the team and the agents from reopening a settled decision, or undoing it
  without noticing. The ADR is the lasting "why".
- **Enforcement:** code review - active; the `write-adr` skill flags a decision that needs a record -
  active. Where the github-issues pack is installed, `Check-PrStoryContract.ps1` blocks in the pull request
  workflow. It fails a change to a data-model file (`tracker.dataModelPatterns`) with no ADR whose `story:`
  is the story key - active. `Check-StoryBackEdges.ps1` reports a story that does not link back to its ADR
  (advisory) - active. Deferred: a CI check for a decision outside the data model.
- **Short form:** A decision the architecture rests on needs an ADR before merge.

## C02: No source line numbers in documentation

- **Statement:** No documentation (markdown, ADRs, READMEs, wikis) may point at source by line number.
  Point at the file path and the symbol name instead.
- **Rationale:** A line number is wrong after the next edit, and nobody notices. A path and a symbol
  survive.
- **Enforcement:** `.claude/skills/ai-sdlc-gates/scripts/Check-DocLineCitations.ps1` (blocking gate in
  `Invoke-LocalGates.ps1` and in the pull request workflow) plus code review - active.
- **Short form:** No source line numbers in any documentation; reference by file path + symbol.

## C03: No hardcoded secrets

- **Statement:** No credentials, tokens, connection strings or keys in source. Read them from a secret
  store, a configuration service or the environment, as the codebase already does.
- **Rationale:** A secret that gets out is a security incident, and it is hard to take back completely.
- **Enforcement:** `Test-GitleaksBaseline.ps1` is the **blocking** C03 gate in `gates.json`, so
  `Invoke-LocalGates.ps1` runs it in the shared composite action, the pre-push hook and a local run. The
  action installs the pinned gitleaks first (`Install-Gitleaks.ps1`, SHA-256 checked). A finding that
  `gitleaks-baseline.json` does not hold fails the build. On a pull request build it scans only the
  commits of the pull request. A repository without a baseline counts every finding;
  `Create-GitleaksBaseline.ps1` makes a baseline for old findings that are not secrets. The scripts
  are in `.claude/skills/ai-sdlc-gates/scripts/`. The pre-flight (`run-preflight`) scans the commits of
  the branch, and a finding outside the baseline is a FAIL row, so it writes no receipt - active.
- **Short form:** No hardcoded secrets; use a secret store, configuration or the environment.

## C04: Test changed code, mirroring the test layout

- **Statement:** New and changed behaviour ships with mirrored tests: a test project or folder that
  mirrors the source layout (`paths.sourceRoot` and `paths.testRoot` in `aisdlc.json`). Coverage is
  measured two ways, and both must hold. Where the repository sets a coverage baseline file
  (`paths.coverageBaseline`), total line coverage must not drop below the baseline in it. Coverage on
  new code (the lines a pull request changes) targets >= 80%. Both figures count only the code the team
  owns and can test. The run settings file (`paths.runSettings`) scopes the measurement on the
  collecting side. The exclusions of the code-quality service scope it on the other side, for example
  `sonar.coverage.exclusions` in SonarCloud. Both use one shared list of left-out files, such as UI components, browser scripts,
  program start-up and dependency wiring. Business logic, controllers, services, validators and
  repositories are never left out.
- **Rationale:** Coverage protects against regressions and is the basis for acceptance-criteria
  coverage. A bar that no gate measures is read by nobody. A report that also counts third-party
  packages and test projects gives a figure that means nothing. So the fix is the denominator and the
  shape of the check, never the threshold.
- **Enforcement:** where the dotnet pack is installed, `.claude/skills/dotnet-gates/scripts/Check-Coverage.ps1`
  runs as a ratchet against the recorded baseline. It is **blocking** in the pre-flight
  (`run-preflight`), which the agent push hook asks for. `Invoke-LocalGates.ps1` runs it only with `-CoverageFile`. The
  shared composite action runs it, blocking, when the workflow passes the `coverage-file` input: an
  earlier test step writes the merged coverage file. The starter workflow of a new .NET
  repository does that. When the pre-flight has no coverage file, or no `dotnet-coverage` tool, its row is
  a FAIL that names the fix, so it writes no receipt. Always pass the run settings when you collect coverage. The code-quality service reports the
  >= 80% on new code; whether that blocks a merge is a setting of the repository and a team decision.
  Where the dotnet pack is installed, `Check-StoryTraits.ps1 -Strict` (blocking) fails a test class with
  no Story trait or with a malformed story key - active. Code review - active for "tests exist".
- **Short form:** Changed code ships with mirrored tests; total line coverage must not drop below the
  baseline file that `paths.coverageBaseline` names, where the repository sets one.

## C05: Documentation is one checked wiki

- **Statement:** The docs roots (`paths.docsRoots` in `aisdlc.json`, for example a technical and a
  functional layer) are one linked wiki graph. Every page is reachable from its layer index AND linked
  page to page with its related pages; the index does not count as a link. Links are relative markdown
  links, not `[[wikilinks]]`. There is no page without a link in, no page without a link to another
  content page, and no broken relative link.
- **Rationale:** Documentation that drifts or ends in a dead page misleads without anyone noticing. The
  docs are a checked knowledge base that a model helps maintain (the llmwiki pattern in
  [docs-wiki.md](docs-wiki.md)). An index-only structure is a star, not a graph. The value is in the
  links between related pages, so a reader walks the web instead of going back to the index at every
  hop.
- **Enforcement:** `Check-DocsWiki.ps1 -Strict` and `Build-DocsIndex.ps1 -Check` in
  `.claude/skills/ai-sdlc-gates/scripts/`, run by the `write-docs` skill, by
  `Invoke-LocalGates.ps1`, by the pre-push hook and in the pull request workflow. It blocks a page
  that nothing links to, an isolated page (no links in and none out), a broken link, and index drift.
  A page with links in but none out is reported as advice. The local run and the
  CI run the same checks, because a local run that differs hides a failure until merge.
  `Check-DocSectionRefs.ps1` blocks as well: a pointer at a section of another page, and a link anchor,
  must name a heading that is there. A decision record that a script names must exist.
  `Check-DocCoverage.ps1` blocks a missing technical or functional layer, and a unit with no page - active.
  Where the dotnet pack is installed, `Check-DocDrift.ps1 -FailOnDrift` (blocking) fails a page that has
  fallen behind the code it cites. `Check-SpecDrift.ps1` (advisory) reports an endpoint that moved
  while its spec stood still. `Check-DocGraphClaims.ps1` (advisory, needs the code graph) reports a
  page that states a relationship the code graph does not have - active.
- **Short form:** Docs are one checked wiki: indexed AND linked page to page, relative links, no
  orphans, no broken links.

## C06: Documentation contains no em-dash characters

- **Statement:** Documentation (markdown in `AGENTS.md` and in the docs roots) must not contain the
  em-dash character (U+2014). Use a spaced hyphen ' - ', commas, colons or parentheses.
- **Rationale:** An em-dash slips in from pasted or model-written text and is hard to spot by eye. A
  mechanical gate keeps the house style the same, whichever agent or person writes the page. The scope
  is documentation only; source files are not searched, so the clause stays one a gate can keep.
- **Enforcement:** `.claude/skills/ai-sdlc-gates/scripts/Check-DocEmDashes.ps1` (blocking gate in
  `Invoke-LocalGates.ps1`, in the pre-push hook and in the pull request workflow) - active.
- **Short form:** Documentation contains no em-dash characters (U+2014).

## C07: A claim names its source, inside the artifact

- **Statement:** A factual claim the framework makes must name a source you can trust. That covers a
  finding, a piece of advice, a triage conclusion, or a statement written into an artifact. A claim a
  decision rests on is one that drives advice or a stakeholder decision. It must have at least two
  independent trusted sources, or be flagged as single-sourced or weakly sourced. When the claim is
  saved into a work item, an ADR or a doc, its source is saved with it, not left only in chat.
- **Rationale:** A claim without a source cannot be defended, least of all to a security officer or an
  auditor. It turns into folklore, and someone has to check it again at a cost. A source saved with the
  claim lets a reader check the basis without rerunning the analysis. Prefer first-hand and official
  sources (vendor or product docs, standards, the system of record, the raw study) over second-hand
  ones. Two pages that copy the same upstream are one source, not two. A routine mechanical action,
  such as a rename or a formatting fix, needs no source.
- **Enforcement:** skill - active: the skills that write artifacts build the source rule into their
  steps. Code review - active. Deferred: a source check in the doc gates.
- **Short form:** A claim names its source; a claim a decision rests on has two; the source is saved in
  the artifact.

## C08: Documentation does not name team members

- **Statement:** Documentation (`AGENTS.md` and the docs roots) must not name a member of the team (a
  repository contributor). Reference the pull request by number instead. An outside author named as a
  source, for example a book or standard author, is allowed.
- **Rationale:** A named person in a lasting record is a data-protection concern (keep personal data to
  a minimum), and nothing rests on it. Who reviewed a change or caught a bug belongs in the pull request
  history, by number, not in permanent text.
- **Enforcement:** `.claude/skills/ai-sdlc-gates/scripts/Check-DocPersonNames.ps1` (blocking gate in
  `Invoke-LocalGates.ps1` and in the pull request workflow) plus code review - active. The gate matches
  the full names in the repository's own commit-author list against the docs. The allow list
  (`paths.personNameAllowlist` in `aisdlc.json`) holds lawful exceptions. It catches only contributors
  present in `git log`, and it does not catch a surname-only mention.
- **Short form:** Documentation does not name team members; reference the PR by number instead.

## C09: An agent never signs off for a human

- **Statement:** On its own judgement, an agent never marks an acceptance criterion done. It also never
  moves a work item to a done or checked state, or resolves a flagged conflict. It shows the evidence (a
  test name, a response, a gate result) for a human to confirm. It does not approve or merge a pull request
  either. Opening a pull request is a request for review, not a sign-off, and needs no confirmation.
- **Rationale:** An agent can be wrong or make things up, so a green check it set itself is not
  evidence. Keeping the sign-off with a human keeps the acceptance record trustworthy. The two human
  checkpoints in [orchestration.md](orchestration.md) apply the same boundary to the whole flow.
- **Enforcement:** skill - active (the verification and build skills report evidence and never mark a
  criterion done); code review - active.
- **Short form:** An agent never signs off for a human; it shows the evidence, and a PR is a request for
  review.

## C10: Code is documented, and a comment says why

- **Statement:** Public and shared types, functions and members carry a doc comment in the form of
  their language. That is an XML doc comment (`/// <summary>`) in C#, a docstring in Python, and JSDoc
  or TSDoc in TypeScript. In Razor it is a summary on a component that has parameters. In PowerShell it
  is the comment-based help block that every script ALWAYS carries (`.SYNOPSIS`, a short
  `.DESCRIPTION`, a `.PARAMETER` per parameter, an `.EXAMPLE`).
  Inside a body, a comment says why: a hard limit, a workaround with its issue or link, or
  a decision that is not obvious. It never says what the next line does; a better name comes
  first. A comment never holds:
  - commented-out code;
  - the ADR, the pull request or the issue retold at length; it links them instead;
  - a `TODO`, `FIXME` or `HACK` without an issue key such as `#42`;
  - the name of an AI tool or of a person.

  These are not comments and stay: language directives such as `#Requires`, `#pragma`, `#region`,
  `#nullable` and shebangs; the machine marker lines `ai-sdlc:<package>:start` and
  `ai-sdlc:<package>:end` that `Sync-AgentsFile.ps1` writes in `AGENTS.md`; and the `// Arrange`,
  `// Act`, `// Assert` test markers. Comments that already exist are not removed: the clause governs
  what a change adds.
- **Rationale:** A doc comment is part of the contract of a public type or member. The IDE shows it at
  every call, so a reader does not have to open the body. Text inside a body rots without anyone
  noticing, so it earns its place only when it says why. A comment that says what repeats the code,
  and dead code or an open `TODO` is noise that nobody owns. The ADR stays the home of a decision. The
  full rule is in [comments.md](comments.md).
- **Enforcement:** where the dotnet pack is installed, two gates read the added C# and Razor lines.
  `.claude/skills/dotnet-gates/scripts/Check-CommentHygiene.ps1` blocks commented-out code, a `TODO`
  without an issue key and a comment that names an AI tool - active.
  `.claude/skills/dotnet-gates/scripts/Check-XmlDocs.ps1` (advisory) reports an added public or
  protected declaration without a `///` doc comment - active. Both run in `Invoke-LocalGates.ps1` and in the
  pull request workflow. Skill - active: the build and review skills state the rule, and the
  `code-reviewer` agent flags missing doc comments and comments that say what. Code review - active
  for the other languages, which no gate reads.
- **Short form:** Code is documented: public types and members carry doc comments. A comment says why,
  not what, and is never dead code or names an AI tool.

## C11: Everything we keep is English, at B2 sentences and B1 words

- **Statement:** Every text a repository keeps is English. So is every record an agent writes into a
  work item tracker, a wiki, a pull request or git. All of it is written at the reading level in
  [language.md](language.md). Sentences are at CEFR B2: one main idea, at most one extra part, never
  over 25 words. Words are at CEFR B1. The exact name of a thing is a fact and stays as it is; the team records
  such names in the reading-level allow list (`paths.readingLevelAllowlist` in `aisdlc.json`). Quoted
  text is copied as it is. Chat with an agent follows the language the user writes in, at the same
  level.
- **Rationale:** Teams, clients and agents often work in English as a second language. Text that only
  an expert native speaker gets on the first read is read too fast, misread or ignored. A rule that
  lives only in a style note drifts within months. One level for everything, stated once and checked by
  a tool, keeps every page, work item and reply easy to read.
- **Enforcement:** `.claude/skills/ai-sdlc-gates/scripts/Check-DocReadingLevel.ps1` (blocking gate in
  `Invoke-LocalGates.ps1` and in the pull request workflow) - active. Skill - active: the
  `## Communication` part of `AGENTS.md` and the `## Standing rules` block of every skill state the rule.
  Code review - active for work items, wiki pages and chat, which no gate reaches.
- **Short form:** Everything we keep is English, at CEFR B2 sentences and B1 words.

## C12: One source of truth

- **Statement:** Every rule and every fact has one source. Anywhere else, a text loads the source or
  links to it, with the clause ID and the page. A rule is never copied. Where a tool cannot load or
  link the source, a script generates the copy and a gate checks it for drift. A rule restated in free
  text is not allowed. The `## Standing rules` block of a skill is a pointer with a one-line summary and
  a link, so it stays.
- **Rationale:** A copy drifts. After a while two texts say different things, and a reader cannot tell
  which one is the rule. Every agent needs the clauses in every session, so the core part of `AGENTS.md`
  imports this page with an `@` line instead of holding a list.
- **Enforcement:** the import line in `ai-sdlc-gates/assets/agents-core.md` loads this page in every
  Claude Code session - active. The generated copies, where no import is possible, have their own gates
  - active:
  - the sync manifest: `Check-SyncManifest.ps1` and `tools/Update-SyncManifest.ps1 -Check`;
  - the list of skills and agents: `tools/Update-SkillCatalog.ps1 -Check`;
  - the allow rules in `.claude/settings.json`: `Sync-AllowRules.ps1 -Check` (advisory);
  - the shared parts of `AGENTS.md`: `Sync-AgentsFile.ps1 -Check`.

  Code review and the `docs-reviewer` agent - active for free text, because no gate can find a
  restated rule reliably.
- **Short form:** Every rule and fact has one source; elsewhere, load it or link to it. Only where that
  is not possible, a script generates the copy and a gate checks it.

## Related

- [Language and reading level](language.md) - the full form of C11, and the level every clause is
  written at.
- [Code comments](comments.md) - the full form of C10 and where the longer reasoning goes.
- [Documentation wiki](docs-wiki.md) - the knowledge-layer contract that C05 enforces.
- [Artifact graph](artifact-graph.md) - the traceability contract that C01, C07 and C09 point at.
- [Orchestration](orchestration.md) - the two human checkpoints behind C09.
- [Layout](layout.md) - where core, pack and repository clauses live, and the `aisdlc.json` fields
  the clauses read.
