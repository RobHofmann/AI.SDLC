# Gate list

Every gate of the core and of each pack, with what it checks and how to fix a finding. A script makes this page from the `gates.json` files of the packages, so do not edit it by hand.

A gate that fails or cannot check prints its checks text before its own output. Run `Invoke-LocalGates.ps1 -List` to see the same texts for the gates of one repository. A package with no gate has no section.

## core

### The change adds no secret outside the gitleaks baseline

- Clause: C03
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Script: `.claude/skills/ai-sdlc-gates/scripts/Test-GitleaksBaseline.ps1`
- Checks: It scans the commits of the change with the pinned gitleaks rules, and in a local run also the staged files. It fails on a finding that `gitleaks-baseline.json` does not hold, and never on one that the baseline holds. Exit 2 means git or gitleaks is missing in a local run (GitHub Actions exits 1 then), and it never exits 3.
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
- Checks: It reads each doc that sets `story:` in its front matter and checks the story key, the phase and the `relates` paths. It also needs a `because` reason on each `adr` and `spec` edge, and an `intent.assumption` on a discovery or elaboration doc. It skips a doc with no `story:`, and it does not check a URL. Exit 2 means none of the artifact roots exists, and exit 3 means no doc declares a story.
- Fix: Correct the front matter field that the output names, such as the story key, the phase or a path.

### Docs have no orphan page, isolated page or broken relative link

- Clause: C05
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Runs locally when the change touches: `**/*.md`, or the skill or tool folder of its script
- Script: `.claude/skills/ai-sdlc-gates/scripts/Check-DocsWiki.ps1`
- Checks: It reads every page of the doc layers and fails on a broken relative link, an orphan page or an isolated page. It does not check external links or whether an index is current. Exit 2 means none of the doc layers exists, and exit 3 means the doc layers hold no markdown page.
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
- Checks: It scans `AGENTS.md` and the doc layers for the em-dash character (U+2014). It also finds the HTML codes that draw it: the named entity mdash, the decimal form 8212 and the hexadecimal form 2014. It does not check source files. Exit 2 means a path passed with `-Path` or the doc layers do not exist, and exit 3 means there is no page to read.
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
- Checks: It reads each local path in `apm.yml` and `apm.lock.yaml`, and fails on a path that is missing or that git does not track. It does not check a path outside the repository. Exit 2 means `apm.yml` is missing or git cannot answer, and exit 3 means apm.yml and apm.lock.yaml name no local package.
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
- Checks: It scans the docs for an empty claim, an empty table row, a template fragment, an empty table and a path from one machine. It does not judge whether a fact is true. Exit 2 means none of the doc roots exists, and exit 3 means the doc roots hold no markdown page.
- Fix: Delete the empty row or line, or write the fact that it should hold.

### A change to source also changes its mirrored tests and its docs

- Clause: AI-SDLC
- Mode: Advisory
- Runs in: pull request action (as a warning), local run
- Script: `.claude/skills/ai-sdlc-gates/scripts/Check-ChangeCompleteness.ps1`
- Checks: It reports a changed source file with no test change in its mirrored test folder, but not a deleted file. It also reports a source area whose docs did not change and that no changed ADR names. A `No-Test` or `No-Docs` commit trailer with a listed reason clears the files of its own commit. Exit 2 means the change could not be listed, and exit 3 means no changed or deleted file carries behaviour.
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
- Checks: It checks that each doc layer holds an index and a page, and that each unit has a technical page. The packs or `docs.units` name the units, and a decision record never counts as a page. A missing layer is a finding, so it never exits 2. Exit 3 means no doc layer is set and no unit is named.
- Fix: Write the page that the output names, or run the adopt-docs skill to draft each missing page.

### No doc page was last checked longer ago than `docs.lastCheckedMaxAgeDays`

- Clause: C05
- Mode: Advisory
- Runs in: pull request action (as a warning), local run
- Script: `.claude/skills/ai-sdlc-gates/scripts/Check-DocLastChecked.ps1`
- Checks: It reads each `Last checked` date in `AGENTS.md` and the doc layers, and lists a date older than `docs.lastCheckedMaxAgeDays`. It does nothing when that setting is off. Exit 3 means the setting is off, and it never exits 2.
- Fix: Check the facts on the page again and update its `Last checked` date, or raise `docs.lastCheckedMaxAgeDays`.

### The change adds no commented-out code, open TODO or AI tool name in a C# or Razor comment

- Clause: C10
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Runs locally when the change touches: `**/*.cs`, `**/*.razor`, or the skill or tool folder of its script
- Script: `.claude/skills/ai-sdlc-gates/scripts/Check-CommentHygiene.ps1`
- Checks: It reads only the lines that the change adds to `.cs` and `.razor` files. It fails on commented-out code, on a TODO, FIXME or HACK with no issue key, and on a comment that names an AI tool. Exit 2 means the change could not be worked out, and it never exits 3.
- Fix: Delete the commented-out code, add an issue key such as `#42` to the TODO, or remove the AI tool name from the comment.

### The change adds no commented-out code, open TODO or AI tool name in a YAML or PowerShell comment

- Clause: C10
- Mode: Advisory
- Runs in: pull request action (as a warning), local run
- Runs locally when the change touches: `**/*.ps1`, `**/*.psm1`, `**/*.psd1`, `**/*.yml`, `**/*.yaml`, or the skill or tool folder of its script
- Script: `.claude/skills/ai-sdlc-gates/scripts/Check-CommentHygiene.ps1`
- Checks: It reads the comments on the lines that the change adds to PowerShell and YAML files, outside quoted strings, and skips installed files. It reports commented-out code, a TODO, FIXME or HACK with no issue key, and an AI tool name. The help block, `#Requires`, `#region`, a shebang and the marker lines pass. Exit 2 means the change could not be read or a script does not parse, and exit 3 means nothing to check.
- Fix: Delete the commented-out code, add an issue key such as `#42` to the TODO, or remove the AI tool name from the comment.

### A native call that the change adds in PowerShell checks its exit code

- Clause: C13
- Mode: Advisory
- Runs in: pull request action (as a warning), local run
- Runs locally when the change touches: `**/*.ps1`, `**/*.psm1`, or the skill or tool folder of its script
- Script: `.claude/skills/ai-sdlc-gates/scripts/Check-NativeExitCode.ps1`
- Checks: It parses the added PowerShell lines, and reports a `git`, `az`, `dotnet` or `bicep` call with no exit code check after it. A `||` or `&&` chain and `$PSNativeCommandUseErrorActionPreference = $true` pass, and it skips installed files. Exit 2 means the change could not be read or a script does not parse, and exit 3 means nothing to check.
- Fix: Check `$LASTEXITCODE` right after the call and throw when it is not 0, or set `$PSNativeCommandUseErrorActionPreference = $true` in the script.

### PSScriptAnalyzer finds nothing on the PowerShell lines that the change adds

- Clause: C13
- Mode: Advisory
- Runs in: pull request action (as a warning), local run
- Runs locally when the change touches: `**/*.ps1`, `**/*.psm1`, or the skill or tool folder of its script
- Script: `.claude/skills/ai-sdlc-gates/scripts/Check-ScriptAnalyzer.ps1`
- Checks: It runs PSScriptAnalyzer with its own settings, without the `PSAvoidUsingWriteHost` rule, and reports the findings on the lines that the change adds. It never reads a settings file from the repository, and it skips installed files. Exit 2 means the module is missing or older than 1.21.0, or a script could not be read, and exit 3 means nothing to check.
- Fix: Change the line as the PSScriptAnalyzer rule asks, or keep a form that `powershell-conventions` asks for and say so in the pull request.

### The pull request stays within the size limit of the repository

- Clause: C14
- Mode: Advisory
- Runs in: pull request action (as a warning), local run
- Script: `.claude/skills/ai-sdlc-gates/scripts/Check-PrSize.ps1`
- Checks: It counts the lines that the change adds and removes since the merge base, and warns above `pullRequest.sizeLimit`. It reads both size settings at the merge base, and skips installed files and the files that `pullRequest.sizeExclude` names. Exit 2 means the change, a setting or a binary file could not be read, and exit 3 means no limit is set.
- Fix: Split the work into smaller stories with a pull request each, or say in the pull request why it cannot be split.

### Allow rules of the installed packages are in `.claude/settings.json`

- Clause: AI-SDLC
- Mode: Advisory
- Runs in: pull request action (as a warning), local run
- Script: `.claude/skills/ai-sdlc-gates/scripts/Sync-AllowRules.ps1`
- Checks: It builds the allow rules from the `allow` lists of the installed packages and fails when one is missing from `.claude/settings.json`. It does not remove a rule, and it does not check the local knowledge folder. Exit 2 means a package list or the settings file cannot be read, and exit 3 means there is no installed package to read.
- Fix: Run `Sync-AllowRules.ps1` without `-Check` and commit `.claude/settings.json`.

## bicep

### Registry module calls are pinned to a tag other than latest

- Clause: BICEP-01
- Mode: Advisory
- Runs in: pull request action (as a warning), local run
- Runs locally when the change touches: `**/*.bicep`, `**/*.bicepparam`, or the skill or tool folder of its script
- Script: `.claude/skills/bicep-conventions/scripts/Check-BicepConventions.ps1`
- Checks: It reads the `.bicep` and `.bicepparam` files, where a comment or a plain string never counts. It reports a module, test, import, extension or using reference to the registry that ends in the tag `latest`. Exit 3 means no Bicep file, and it never exits 2.
- Fix: Pin each registry module to a dated tag, such as `2026.01.01.1-main`, and never to `latest`.

### Role IDs come from the lookup files that aisdlc.json names

- Clause: BICEP-02
- Mode: Advisory
- Runs in: pull request action (as a warning), local run
- Script: `.claude/skills/bicep-conventions/scripts/Check-BicepConventions.ps1`
- Checks: It reads the `.bicep` and `.bicepparam` files and reports each line outside the lookup files that holds a GUID from them. A comment is not read. Exit 2 means a lookup file is missing or holds no GUID. Exit 3 means `bicep.roleLookupFiles` is not set or there is no Bicep file.
- Fix: Read each role ID from the lookup file that `bicep.roleLookupFiles` names, and never type the GUID again.

## blazor

### Components have no inline style block, I*State interface or DOCTYPE outside the app component, and attributes sit above members

- Clause: AI-SDLC
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Script: `.claude/skills/razor-conventions/scripts/Check-RazorConventions.ps1`
- Checks: It reads the `.razor` and `.cs` files under `paths.sourceRoot`. It fails on an `I*State` interface, an inline `<style>` block and a `<!DOCTYPE` outside the app component. It also fails on an attribute on the same line as its member. Exit 2 means `paths.sourceRoot` is not set or the old key `dotnet.portalAppComponent` is still set, and exit 3 means there is no file to read.
- Fix: Use the state class, move each style to the `.razor.css` file, keep the DOCTYPE in the app component, and put each attribute above its member.

## dotnet

### Docs match the relationships the code graph has

- Clause: C05
- Mode: Advisory
- Runs in: pull request action (as a warning), local run
- Script: `.claude/skills/dotnet-code-graph/scripts/Check-DocGraphClaims.ps1`
- Checks: It compares what a reference page says about who uses a project, or what implements its contract, with the code graph. It warns when the graph is older than the working tree. Exit 3 means there is no code graph, and it never exits 2.
- Fix: Correct the page so that it names the relationships the graph shows, or rebuild the graph when it is old.

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
- Checks: It reads only the lines that the change adds, in the test files under `paths.testRoot`. It fails on a test class or method that the change adds with no Story trait, and on a malformed key on an added line. It finds a test class at the top level and in a block or file-scoped namespace, and LEGACY-0 never covers code that the change adds. Exit 2 means `paths.testRoot` is not set or there is no merge base, and it never exits 3.
- Fix: Add a Story trait with the story key, such as `#42`, to the test class, or correct the malformed key.

### Test methods that the change adds or edits keep the Arrange, Act and Assert markers in order

- Clause: C04
- Mode: Advisory
- Runs in: pull request action (as a warning), local run
- Runs locally when the change touches: `**/*.cs`, or the skill or tool folder of its script
- Script: `.claude/skills/dotnet-gates/scripts/Check-TestShape.ps1`
- Checks: It reads the xUnit `[Fact]` and `[Theory]` methods that the change touches, and needs each marker once, in the order Arrange, Act, Assert. A merged marker such as `// Act & Assert` counts as both, and an edited older method fails only on what the added lines break. Exit 2 means the change could not be read, and exit 3 means no test method changed.
- Fix: Add the missing marker, put the markers in the order Arrange, Act, Assert, or split a test that acts and asserts twice.

### JSON wire names in C# and in specs are PascalCase

- Clause: DOTNET-01
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Script: `.claude/skills/dotnet-gates/scripts/Check-ApiPascalCase.ps1`
- Checks: It scans the `JsonPropertyName` attributes under the source root and the property names in the specs, and fails on a snake_case or camelCase name. It skips external contract paths and system fields. Exit 2 means `paths.sourceRoot` is not set or the specs could not be parsed, and it never exits 3.
- Fix: Rename the wire name to PascalCase, or remove the attribute when it only repeats the property name.

### A project reference that the change adds is used in the code of the project

- Clause: DOTNET-03
- Mode: Advisory
- Runs in: pull request action (as a warning), local run
- Runs locally when the change touches: `**/*.csproj`, `**/*.cs`, or the skill or tool folder of its script
- Script: `.claude/skills/dotnet-gates/scripts/Check-ProjectReferenceUse.ps1`
- Checks: It reads each `ProjectReference` that the change adds, and looks for a namespace of the target in the code of the referencing project. It reads text, so it misses a type that code finds at run time, and it skips analyzer references. Exit 2 means the change or a project file could not be read, and exit 3 means there is no added reference.
- Fix: Remove the project reference, or keep it when code finds its types at run time and say so in the pull request.

### A project reference that the change adds points to a lower layer of `dotnet.layers`

- Clause: DOTNET-03
- Mode: Advisory
- Runs in: pull request action (as a warning), local run
- Runs locally when the change touches: `**/*.csproj`, `aisdlc.json`, or the skill or tool folder of its script
- Script: `.claude/skills/dotnet-gates/scripts/Check-ProjectLayerOrder.ps1`
- Checks: It reads each `ProjectReference` that the change adds, and names a reference that does not point to a lower layer of `dotnet.layers`. A project in no layer, or in two, is named and not judged. Exit 2 means the setting has the wrong shape or the change could not be read, and exit 3 means nothing to check.
- Fix: Point the reference at a project in a lower layer or remove it, or change `dotnet.layers` in `aisdlc.json` when the order itself is wrong.

### C# code uses the shared options, HTTP client, credential and base exception, not its own copy

- Clause: DOTNET-04
- Mode: Advisory
- Runs in: pull request action (as a warning), local run
- Runs locally when the change touches: `**/*.cs`, `aisdlc.json`, or the skill or tool folder of its script
- Script: `.claude/skills/dotnet-gates/scripts/Check-SharedParts.ps1`
- Checks: It reads the `.cs` files under `paths.sourceRoot`. It warns about `IConfiguration` in a constructor, `new HttpClient()`, an own Azure credential, or an exception without the base exception. It skips tests, generated files, `Program.cs`, `Startup.cs` and service registration methods, and lists new breaks first. Exit 2 means a setting is missing or wrong, or the change could not be read, and exit 3 means there is no C# file.
- Fix: Use the shared part that the finding names: an options class, the HTTP client factory, the credential helper or the base exception.

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
- Checks: It judges only the lines that the change adds, changes or removes, and lists older drift as not blocking. It fails on a constant or service that the change adds and the page lacks, or on a cited name that the change removed. It also fails on a bad name on a page line that the change adds. Exit 2 means `paths.sourceRoot` is not set or there is no merge base, and exit 3 means no documentation page matched.
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
- Checks: It finds the story key in the branch, title, body or closing issues, and checks with `gh` that the issue has the refined label. A data-model change needs an ADR for the story that the pull request adds or changes. An older ADR of the same story does not count, but a `No-ADR` commit trailer with a why does. Exit 2 means `gh` or its token is missing, and exit 3 means there is no pull request context.
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
