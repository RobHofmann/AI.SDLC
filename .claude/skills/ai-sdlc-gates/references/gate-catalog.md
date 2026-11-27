# Gate list

Every gate of the core and of each pack, with what it checks and how to fix a finding. A script makes this page from the `gates.json` files of the packages, so do not edit it by hand.

A gate that fails or cannot check prints its checks text before its own output. Run `Invoke-LocalGates.ps1 -List` to see the same texts for the gates of one repository. A package with no gate has no section.

## core

### The change adds no secret outside the gitleaks baseline

- Clause: C03
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Script: `.claude/skills/ai-sdlc-gates/scripts/Test-GitleaksBaseline.ps1`
- Checks: It scans the commits of the change with the pinned gitleaks rules and fails on a finding that `gitleaks-baseline.json` does not hold. It does not read the findings that the baseline already holds. Exit 2 means git or gitleaks is missing in a local run, and GitHub Actions exits 1 in that case. It never exits 3.
- Fix: Remove the secret and replace it, or add a finding that is not a secret to `gitleaks-baseline.json` with `Create-GitleaksBaseline.ps1`.

### Docs cite no source line numbers

- Clause: C02
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Runs locally when the change touches: `**/*.md`, or the skill or tool folder of its script
- Script: `.claude/skills/ai-sdlc-gates/scripts/Check-DocLineCitations.ps1`
- Checks: It scans the docs for a line number after a file name or after the word line. It does not check that a cited path or symbol exists. Exit 2 means a path passed with `-Path` is missing, and exit 3 means there is no markdown file to scan.
- Fix: Replace each line number with the file path and the name of the symbol.

### Artifact links in doc front matter point at files that exist

- Clause: AI-SDLC
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Script: `.claude/skills/ai-sdlc-gates/scripts/Check-ArtifactGraph.ps1`
- Checks: It reads each doc that sets `story:` in its front matter and checks the story key, the phase and the `relates` paths. It skips a doc with no `story:`, and it does not check a URL. Exit 2 means none of the artifact roots exists, and it never exits 3.
- Fix: Correct the front matter field that the output names, such as the story key, the phase or a path.

### Docs have no orphan page, isolated page or broken relative link

- Clause: C05
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Runs locally when the change touches: `**/*.md`, or the skill or tool folder of its script
- Script: `.claude/skills/ai-sdlc-gates/scripts/Check-DocsWiki.ps1`
- Checks: It reads every page of the doc layers and fails on a broken relative link, an orphan page or an isolated page. It does not check external links or whether an index is current. Exit 2 means none of the doc layers exists, and it never exits 3.
- Fix: Link the page from a related page, or correct the broken link so that it points at a file that exists.

### Each doc index matches what `Build-DocsIndex.ps1` makes from the current pages

- Clause: C05
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Runs locally when the change touches: `**/*.md`, or the skill or tool folder of its script
- Script: `.claude/skills/ai-sdlc-gates/scripts/Build-DocsIndex.ps1`
- Checks: It builds each doc index again in memory and compares it with the committed file. It does not check the content or the links of a page. Exit 2 means none of the doc layers exists, and it never exits 3.
- Fix: Run `Build-DocsIndex.ps1` without `-Check` and commit the index files it writes.

### Docs hold no em-dash characters

- Clause: C06
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Runs locally when the change touches: `**/*.md`, or the skill or tool folder of its script
- Script: `.claude/skills/ai-sdlc-gates/scripts/Check-DocEmDashes.ps1`
- Checks: It scans `AGENTS.md` and the doc layers for the em-dash character (U+2014). It does not check source files. Exit 2 means a path passed with `-Path` or the doc layers do not exist, and it never exits 3.
- Fix: Replace each em-dash with a comma, a colon or a hyphen with a space on each side.

### The agents file stays within its line and word limit

- Clause: AI-SDLC
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Runs locally when the change touches: `**/*.md`, or the skill or tool folder of its script
- Script: `.claude/skills/ai-sdlc-gates/scripts/Check-AgentsFileSize.ps1`
- Checks: It counts the lines and the words of the file that `paths.agentsFile` names, and fails over either limit. It does not check what the file says. Exit 2 means the file is missing, and it never exits 3.
- Fix: Move detail from the agents file into a docs page and link it, until both counts are under the limit.

### Installed skills, agents and hooks in `.claude/` match the sync manifest, with nothing left over

- Clause: AI-SDLC
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Script: `.claude/skills/ai-sdlc-gates/scripts/Check-SyncManifest.ps1`
- Checks: It compares each file and hook of the installed packages with `sync-manifest.json`, and fails on a missing, changed or stale file. A skill or agent that belongs to the repository itself is left alone. Exit 2 means `apm.yml` or the manifest is missing or git cannot hash a file, and it never exits 3.
- Fix: Run `apm install` and commit the result, and change a shared file at its source, never in the `.claude/` copy.

### Every local package in `apm.yml` and `apm.lock.yaml` is a folder that git tracks

- Clause: AI-SDLC
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Script: `.claude/skills/ai-sdlc-gates/scripts/Check-LocalPackages.ps1`
- Checks: It reads each local path in `apm.yml` and `apm.lock.yaml`, and fails on a path that is missing or that git does not track. It does not check a path outside the repository. Exit 2 means `apm.yml` is missing or git cannot answer, and it never exits 3.
- Fix: Add the package folder to git, or remove its line from `apm.yml` and its entry from `apm.lock.yaml`.

### The shared parts of the agents file match the installed packages

- Clause: AI-SDLC
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Runs locally when the change touches: `**/*.md`, `.claude/**`, `.gitignore`, or the skill or tool folder of its script
- Script: `.claude/skills/ai-sdlc-gates/scripts/Sync-AgentsFile.ps1`
- Checks: It builds the shared parts of the agents file from the installed packages and compares them with the marked parts in the file. It does not check the text outside the markers. Exit 2 means the file, a package part or a marker is missing, and it never exits 3.
- Fix: Run `Sync-AgentsFile.ps1` without `-Check` and commit the agents file.

### Docs read at B2 sentences and B1 words

- Clause: C11
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Runs locally when the change touches: `**/*.md`, `**/.reading-level-allowlist`, or the skill or tool folder of its script
- Script: `.claude/skills/ai-sdlc-gates/scripts/Check-DocReadingLevel.ps1`
- Checks: It reads every markdown file and fails on a sentence over 25 words or on a word above level B1. It does not read code, links or the words on the allow list. Exit 2 means a path passed with `-Path` is missing, and exit 3 means there is no markdown file.
- Fix: Split each long sentence into shorter ones, and replace each hard word with a plain word.

### Each skill has valid front matter, the standing rules and the failure-mode sections

- Clause: AI-SDLC
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Runs locally when the change touches: `.claude/**`, or the skill or tool folder of its script
- Script: `.claude/skills/ai-sdlc-gates/scripts/Check-SkillHygiene.ps1`
- Checks: It reads each skill under `.claude/skills` and checks its name, description, links, standing rules and failure-mode sections. It does not judge whether the text is useful. Exit 3 means there is no skills folder, and it never exits 2.
- Fix: Add the missing front matter field or section to the skill, as the finding names it.

### Each agent lists explicit read-only tools, a known persona and the standing rules

- Clause: AI-SDLC
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Runs locally when the change touches: `.claude/**`, or the skill or tool folder of its script
- Script: `.claude/skills/ai-sdlc-gates/scripts/Check-AgentHygiene.ps1`
- Checks: It reads each file under `.claude/agents` and checks its name, tools, persona and standing rules. Only the listed writer agent may edit files. Exit 2 means the persona list is missing, and exit 3 means there is no agents folder.
- Fix: Give the agent an explicit tool list without edit tools, a `Persona:` line from `personas.md` and a standing rules section.

### Docs name no contributor from the git history

- Clause: C08
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Script: `.claude/skills/ai-sdlc-gates/scripts/Check-DocPersonNames.ps1`
- Checks: It takes the full names of the commit authors from `git log` and looks for them in `AGENTS.md` and the doc layers. It does not catch a surname alone or a person who never committed. Exit 2 means none of the doc layers exists, and exit 3 means there is no name to check.
- Fix: Replace the name with the number of the pull request, or add a lawful exception to the person-name allow list.

### Doc lines and table rows carry a fact, not an empty row or a template leftover

- Clause: C05
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Runs locally when the change touches: `**/*.md`, or the skill or tool folder of its script
- Script: `.claude/skills/ai-sdlc-gates/scripts/Check-DocRowContent.ps1`
- Checks: It scans the docs for an empty claim, an empty table row, a template fragment, an empty table and a path from one machine. It does not judge whether a fact is true. Exit 2 means none of the doc roots exists, and it never exits 3.
- Fix: Delete the empty row or line, or write the fact that it should hold.

### A change to source also changes its mirrored tests and its docs

- Clause: AI-SDLC
- Mode: Advisory
- Runs in: pull request action (as a warning), local run
- Script: `.claude/skills/ai-sdlc-gates/scripts/Check-ChangeCompleteness.ps1`
- Checks: It reads the changed files and reports a source change with no changed test file. It also reports a source area whose docs and ADRs did not change. A commit trailer `No-Test` or `No-Docs` with a listed reason clears the files of its own commit, and the output names each waiver. Exit 3 means no behaviour file changed, and it never exits 2.
- Fix: Add the test and the doc page of the area, or run wrap-up, which writes a `No-Test` or `No-Docs` trailer after the reviewer agrees.

### The pull request names a story, and its description is not empty or cut off

- Clause: AI-SDLC
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Script: `.claude/skills/ai-sdlc-gates/scripts/Check-PrHygiene.ps1`
- Checks: It looks for a story key such as `#42` in the branch, the title or the description. It also rejects a description that is empty, repeats the title or is too short. It does not check that the story exists. Exit 2 means the pull request text could not be read, and exit 3 means there is no pull request context.
- Fix: Add the story key to the branch name, the title or the description, and write a description that says what changed and why.

### A public repository holds no term from the private term list

- Clause: AI-SDLC
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Script: `.claude/skills/ai-sdlc-gates/scripts/Check-PrivateTerms.ps1`
- Checks: It checks tracked files, commit messages, the branch name and the pull request text against the private term list. It never prints a term, and it does not check a private repository. Exit 2 means no list was found or a rule is not valid, and exit 3 means the repository is private.
- Fix: Remove the text at the file and line that the output names, or ask the list owner which rule it breaks.

### A pointer to a section of another page names a heading that exists

- Clause: C05
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Script: `.claude/skills/ai-sdlc-gates/scripts/Check-DocSectionRefs.ps1`
- Checks: It reads pointers to a named section, a quoted section and a link anchor, and checks that the target page has that heading. It skips a file name that matches more than one file. Exit 3 means there is nothing to scan, and it never exits 2.
- Fix: Correct the section name or the anchor so that it matches a heading of the target page, or rename the heading.

### Both doc layers exist, and every unit has a technical page

- Clause: C05
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Script: `.claude/skills/ai-sdlc-gates/scripts/Check-DocCoverage.ps1`
- Checks: It checks that each doc layer holds an index and a page, and that each unit has a technical page. The packs or `docs.units` name the units, and a decision record never counts as a page. A missing layer is a finding, so it never exits 2 and it never exits 3.
- Fix: Write the page that the output names, or run the adopt-docs skill to draft each missing page.

### No doc page was last checked longer ago than `docs.lastCheckedMaxAgeDays`

- Clause: C05
- Mode: Advisory
- Runs in: pull request action (as a warning), local run
- Script: `.claude/skills/ai-sdlc-gates/scripts/Check-DocLastChecked.ps1`
- Checks: It reads each `Last checked` date in `AGENTS.md` and the doc layers, and lists a date older than `docs.lastCheckedMaxAgeDays`. It does nothing when that setting is off. Exit 3 means the setting is off, and it never exits 2.
- Fix: Check the facts on the page again and update its `Last checked` date, or raise `docs.lastCheckedMaxAgeDays`.

### Allow rules of the installed packages are in `.claude/settings.json`

- Clause: AI-SDLC
- Mode: Advisory
- Runs in: pull request action (as a warning), local run
- Script: `.claude/skills/ai-sdlc-gates/scripts/Sync-AllowRules.ps1`
- Checks: It builds the allow rules from the `allow` lists of the installed packages and fails when one is missing from `.claude/settings.json`. It does not remove a rule, and it does not check the local knowledge folder. Exit 2 means a package list or the settings file cannot be read, and exit 3 means there is no installed package to read.
- Fix: Run `Sync-AllowRules.ps1` without `-Check` and commit `.claude/settings.json`.

## blazor

### Razor components have no interface over a state class, no inline style block and no document type

- Clause: AI-SDLC
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Script: `.claude/skills/blazor-conventions/scripts/Check-RazorConventions.ps1`
- Checks: It scans the source root for an `I*State` interface, an inline `<style>` block in a `.razor` file and a `<!DOCTYPE` outside the app component. It does not check attribute placement, which has its own gate. Exit 2 means `paths.sourceRoot` is not set, and it never exits 3.
- Fix: Use the state class itself, move the styles into a `.razor.css` file, and keep the document type only in the app component.

### Component attributes sit on their own line above the member they mark

- Clause: AI-SDLC
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Script: `.claude/skills/blazor-conventions/scripts/Check-RazorAttributePlacement.ps1`
- Checks: It scans the source root for a component attribute that shares a line with the member below it. It does not check the other rules of `Check-RazorConventions.ps1`. Exit 2 means `paths.sourceRoot` is not set, and it never exits 3.
- Fix: Move the attribute onto its own line above its member.

## dotnet

### Docs match the relationships the code graph has

- Clause: C05
- Mode: Advisory
- Runs in: pull request action (as a warning), local run
- Script: `.claude/skills/dotnet-code-graph/scripts/Check-DocGraphClaims.ps1`
- Checks: It compares what a reference page says about who uses a project, or what implements its contract, with the code graph. It warns when the graph is older than the working tree. Exit 3 means there is no code graph, and it never exits 2.
- Fix: Correct the page so that it names the relationships the graph shows, or rebuild the graph when it is old.

### The change adds no commented-out code, open TODO or AI tool name in a C# or Razor comment

- Clause: C10
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Script: `.claude/skills/dotnet-gates/scripts/Check-CommentHygiene.ps1`
- Checks: It reads only the lines that the change adds to `.cs` and `.razor` files. It fails on commented-out code, on a TODO, FIXME or HACK with no issue key, and on a comment that names an AI tool. Exit 2 means the change could not be worked out, and it never exits 3.
- Fix: Delete the commented-out code, add an issue key such as `#42` to the TODO, or remove the AI tool name from the comment.

### Added public C# types and members carry a doc comment

- Clause: C10
- Mode: Advisory
- Runs in: pull request action (as a warning), local run
- Script: `.claude/skills/dotnet-gates/scripts/Check-XmlDocs.ps1`
- Checks: It reads the lines that the change adds to `.cs` files and names each public or protected declaration with no `///` line above it. It skips tests, generated files and overrides. Exit 2 means the change could not be worked out, and it never exits 3.
- Fix: Add a `/// <summary>` doc comment above the declaration that the finding names.

### Test classes and methods that the change adds carry a Story trait with a real key

- Clause: C04
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Script: `.claude/skills/dotnet-gates/scripts/Check-StoryTraits.ps1`
- Checks: It reads only the lines that the change adds, in the test files under `paths.testRoot`. It fails on a test class or method that the change adds with no Story trait, and on a malformed key on an added line. LEGACY-0 stays allowed on older code, but never covers code that the change adds. Exit 2 means `paths.testRoot` is not set or there is no merge base, and it never exits 3.
- Fix: Add a Story trait with the story key, such as `#42`, to the test class, or correct the malformed key.

### JSON wire names in C# and in specs are PascalCase

- Clause: DOTNET-01
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Script: `.claude/skills/dotnet-gates/scripts/Check-ApiPascalCase.ps1`
- Checks: It scans the `JsonPropertyName` attributes under the source root and the property names in the specs, and fails on a snake_case or camelCase name. It skips external contract paths and system fields. Exit 2 means `paths.sourceRoot` is not set or the specs could not be parsed, and it never exits 3.
- Fix: Rename the wire name to PascalCase, or remove the attribute when it only repeats the property name.

### A change to an endpoint that has a spec also changes that spec

- Clause: C05
- Mode: Advisory
- Runs in: pull request action (as a warning), local run
- Script: `.claude/skills/dotnet-gates/scripts/Check-SpecDrift.ps1`
- Checks: It reads only the routes and DTO types on the lines that the change adds or removes. It checks that the spec for the same resource changed too, and does nothing for an endpoint with no spec. Exit 2 means CHANGED_FILES is set but there is no merge base. Exit 3 means there is no spec or no changed file.
- Fix: Update the spec under `specs/` for the changed endpoint, or confirm that the wire shape did not change.

### Docs match the code they cite

- Clause: C05
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Script: `.claude/skills/dotnet-gates/scripts/Check-DocDrift.ps1`
- Checks: It judges only the lines that the change adds, changes or removes, and lists older drift as not blocking. It fails on a constant or service that the change adds and the page lacks, or on a cited name that the change removed. It also fails on a bad name on a page line that the change adds. Exit 2 means `paths.sourceRoot` is not set or there is no merge base, and it never exits 3.
- Fix: Update the page to name the code as it is now, or remove the reference to a file or a name that is gone.

### Line coverage stays at the baseline, and a gain of a point is written to the baseline file

- Clause: C04
- Mode: Blocking
- Runs in: only when the run gets a coverage file
- Script: `.claude/skills/dotnet-gates/scripts/Check-Coverage.ps1`
- Checks: It reads the coverage file of the test run. It fails when line coverage drops below the baseline, or rises a point or more and the baseline file did not move. It does not check the 80% target on new code. Exit 2 means the coverage file is missing or the change could not be read, and it never exits 3.
- Fix: Add tests to bring coverage back up, or set `lineCoveragePercent` in the baseline file to the figure that the gate prints.

## github-issues

### The pull request is tied to a refined issue, and a data-model change has an ADR for that story

- Clause: C01
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Script: `.claude/skills/check-pr-contract/scripts/Check-PrStoryContract.ps1`
- Checks: It finds the story key in the branch, title, body or closing issues, and reads the issue with `gh`. It checks that the issue has the refined label. A data-model change needs an ADR for the story, or a commit with a `No-ADR` trailer that gives a why. Exit 2 means `gh` or its token is missing, and exit 3 means there is no pull request context.
- Fix: Name a refined issue in the branch, the title or the body, and add an ADR for a data-model change, or a `No-ADR` trailer.

### Each issue that an ADR names points back at that ADR

- Clause: C01
- Mode: Advisory
- Runs in: pull request action (as a warning), local run
- Script: `.claude/skills/check-pr-contract/scripts/Check-StoryBackEdges.ps1`
- Checks: It reads an ADR only when the change adds or changes its `story:` line. It reads the issue body with `gh`, and warns when the body does not mention the ADR. Exit 2 means no issue body could be read or there is no merge base. Exit 3 means no ADR story line changed or the run is not GitHub Actions.
- Fix: Add the ADR to the Decisions and ADRs section of the issue body, and quote the story key in the ADR front matter.

## sonarcloud

### MCP files hold the SonarQube token and organization as placeholders, never as values

- Clause: C03
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Script: `.claude/skills/sonarcloud-mcp/scripts/Check-McpToken.ps1`
- Checks: It reads `.mcp.json`, `.github/mcp.json` and `.vscode/mcp.json`, and fails when the `sonarqube` server sends a token value, an organization value or another variable name. It skips files that git ignores. Exit 2 means a file cannot be read or parsed, and exit 3 means there is no MCP file.
- Fix: Replace the value with `${AISDLC_SONAR_MCP_TOKEN}` or `${AISDLC_SONAR_ORG}`, and replace a token that was committed.

## Related

- [AI-SDLC gates](../SKILL.md) - the gates, the exit codes and the runner.
