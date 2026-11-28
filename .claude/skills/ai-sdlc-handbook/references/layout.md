# The layout of the shared AI-SDLC

The AI-SDLC is shared from one repository, AI.SDLC. Each repository installs the parts it needs with
APM (Agent Package Manager) and keeps a few files of its own. This page says which part lives where,
how a repository pins a version, and how to change a shared file. The way of working itself starts at
the [handbook start page](README.md).

## Three kinds of part

| Kind | Where it comes from | Who changes it |
|---|---|---|
| Core | The `core` package of AI.SDLC: the workflow skills, the core agents, the hooks, the core gates and this handbook | A pull request on AI.SDLC |
| Pack | One package per technology, tool or purpose: `dotnet`, `blazor`, `bicep`, `github`, `github-issues`, `discovery`, `knowledge`, `sonarcloud` | A pull request on AI.SDLC |
| Repo-only | The repository itself: `aisdlc.json`, `apm.yml`, its own skills, agents and hooks in the root `.apm/` folder, its own gates, its docs, its own part of `AGENTS.md` and `.claude/settings.json` | A pull request on that repository |

A repository installs `core` and the packs that fit its stack and its tools. A repository with no .NET
code does not install `dotnet`, so it never gets a .NET skill or gate.

A repository can also add skills, agents and hooks of its own. The [own parts page](consumer-own.md)
says where they live and how to name them. It also says when a local package in `apm.yml` is allowed.

## Where the installed files land

- Skills go to `.claude/skills/<name>/`, and agents go to `.claude/agents/`. Every agent tool the
  team uses reads them there.
- A script always sits in the `scripts/` folder of a skill. The core gates and the gate runner are in
  `.claude/skills/ai-sdlc-gates/scripts/`, and the hook scripts are in `.claude/skills/ai-sdlc-hooks/scripts/`.
  The Pester tests of these shared scripts stay in AI.SDLC, so `.claude/` holds no `*.Tests.ps1` of them.
  A script of the repository's own keeps its test next to it.
- APM merges the hook entries of each package into `.claude/settings.json`, next to the entries the
  repository adds itself.
- `Sync-AgentsFile.ps1` writes the core part of `AGENTS.md`, and the part of each pack, between
  `ai-sdlc:<package>` markers. The text outside the markers belongs to the repository.
  The core part imports [constitution.md](constitution.md) with an `@` line. The dotnet part imports its
  clause page the same way, so no clause is copied (C12).

The repository commits all of it, together with `apm.lock.yaml`, so a fresh clone works without
running APM. That is also why a clone sets itself up with an installed script:
`pwsh .claude/skills/ai-sdlc-hooks/scripts/Install-AiSdlc.ps1`. A repository keeps no setup script
of its own.

## The installed files are read-only

A file that `apm.lock.yaml` lists is a shared file. Change it in AI.SDLC, never in place:

- The hook `Deny-SharedFileEdit.ps1` stops an agent that edits one, and names the source path.
- `apm audit --ci` in the pull request workflow fails on a hand edit.
- `Sync-AgentsFile.ps1 -Check` fails on a hand edit between the markers in `AGENTS.md`.
- `Check-SyncManifest.ps1` fails on a file of an installed package that is missing, changed or left
  behind from an older version. It also fails on a shared hook that is missing from `.claude/settings.json`.
  And it fails on a skill folder or an agent file that an older version left behind. That is one whose
  name a release retired, or one of a package that `apm.yml` no longer installs. The manifest lists the
  retired names. A skill or an agent of the repository itself passes, with no list to keep.
  It checks against `sync-manifest.json`, which AI.SDLC builds from its own source. So it also catches a
  file that APM skipped, which `apm audit` cannot see, because APM writes the lockfile itself.
  AI.SDLC installs its own packages with `- ./core` in `apm.yml`. There the gate reads the manifest in
  `core/`, not the installed one, so a change to a source file without a new `apm install` fails.
  It only checks the packages from the source of the core: the same `git:` URL, or the same prefix in
  the short or local form. A repository may install packs from a source of its own next to AI.SDLC.
  The gate leaves such a pack alone, and counts its skills as the repository's own. Give such a pack a
  name that no AI.SDLC pack has, because the gate runner counts a pack as installed by its name.

APM writes the hook entries into `.claude/settings.json` and `.claude/apm-hooks.json`, but
`deployed_files` in `apm.lock.yaml` lists neither. So `Deny-SharedFileEdit.ps1` and `apm audit` do not
see a hand edit of the hooks. `Check-SyncManifest.ps1` fails when a shared hook is gone or changed, but
not on a hook added by hand. Treat a shared hook like any shared file: change it in AI.SDLC.

A code-quality service such as SonarCloud should leave the installed files out too, for example with
`.claude/**` in `sonar.exclusions`. The repository cannot change them, and the pull request workflow of
AI.SDLC runs SonarCloud over them at the source. A finding in a shared file goes to AI.SDLC as a pull
request, like any other lesson about a shared file.

## When each gate runs

Each package declares its gates in its `gates.json`. The runner, `Invoke-LocalGates.ps1`, reads the
`gates.json` of the core and of each pack that `apm.yml` lists, so a pack brings its gates with it.

| Where | Which gates |
|---|---|
| The pre-push hook | The Blocking gates, unless a passing pre-flight receipt covers the tree of the tip commit of each pushed ref (`Test-PushReceipt.ps1`). None for a push that only deletes refs or sends commits the remote already has |
| The pull request workflow, through the shared composite action `ai-sdlc-gates/assets/actions/ai-sdlc-pr` | Every gate; an Advisory gate is a warning, and a Blocking gate that could not check fails the job |
| A local run of `Invoke-LocalGates.ps1` | Every gate; an Advisory gate never fails the run |

A gate with `requires: CoverageFile`, such as C04, runs only when the runner gets `-CoverageFile`. The
dotnet pre-flight runs `Check-Coverage.ps1` itself after its test run. The shared composite action
passes `-CoverageFile` when the workflow gives it the `coverage-file` input. The pre-push hook does not run C04.

The composite action runs the same gates as a local run, so a repository lists no gate steps by hand.
The pull request workflow calls it as `uses: ./.claude/skills/ai-sdlc-gates/assets/actions/ai-sdlc-pr`,
after `actions/checkout` with `fetch-depth: 0`. Before the gates it installs the pinned APM, runs
`apm audit --ci` and `apm install --frozen`. Then it installs the pinned gitleaks. The C03 gate
`Test-GitleaksBaseline.ps1` runs as part of the gates, so the secret scan runs once and blocks on a new
finding (constitution C03). The action takes three optional inputs. `coverage-file` names the merged
coverage file that an earlier test step wrote; the action then runs the blocking C04 ratchet, and a
missing file fails it. `pre-gate-command` holds a `pwsh` command that runs after the install and before
the gates, for example a restore that a gate needs. It never holds a gate: a gate goes in `gates.json`
or in `repoGates`. `private-terms` takes the private term list from a repository secret, as
`${{ secrets.AISDLC_PRIVATE_TERMS }}`. The default runner is `ubuntu-24.04`. The action reads issues
and pull requests with `gh`, through `github.token`.

`pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1 -List` shows the list: the package,
the mode and the clause of each gate, and where it runs.

## aisdlc.json

Each repository says in `aisdlc.json` where it keeps its things. The shared skills, hooks and gates
read it through `AiSdlcConfig.psm1` and never name a repository's folders. A field that is left out
gets the default.

The packs are not in `aisdlc.json`. `apm.yml` lists them, because that file decides what APM
installs. `AiSdlcConfig.psm1` takes each dependency whose path ends in `packs/<name>` as a pack. A
`packs` field in an older `aisdlc.json` is ignored, so remove it. A pack that always needs another
pack lists it under `dependencies` in its own `apm.yml`, as a path next to it (`- ../css`), so APM
installs both. The `blazor` pack brings `css` and `javascript` that way. Such a pack counts as installed for
the sync check, but not for the gate runner. So it ships no gate (ADR 0025).

| Field | What it holds | Default |
|---|---|---|
| `repository` | The name of the repository | empty |
| `paths.toolsFolder` | The folder of the repository's own scripts and gates | `tools` |
| `paths.docsRoots` | The folders that make up the docs wiki | `docs` |
| `paths.technicalDocs` / `paths.functionalDocs` | The technical and the functional docs layer | `docs` / none |
| `paths.adrFolder` | The folder of the decision records | `docs/adrs` |
| `paths.historyPaths` | The files that record what was true at their time, such as a change list that gives the old text on purpose. The retired skill name scan leaves them out. Each entry is a path or a glob from the repository root: a folder, a file, or a pattern such as `docs/course_changes_*.md`, where `*` stays in one folder and `**` crosses folders. Do not list a page that people read as current: an old name in it misleads a reader. | none |
| `paths.constitution` | The repository's constitution page | `docs/constitution.md` |
| `paths.agentsFile` | The instructions file every agent reads | `AGENTS.md` |
| `paths.languagePage` | The page whose word table the reading-level gate reads | the handbook page `language.md` |
| `paths.readingLevelRoots` / `paths.readingLevelAllowlist` | The folders the reading-level gate reads, and its list of allowed words | `docs` / `docs/.reading-level-allowlist` |
| `paths.personNameAllowlist` | The names the person-name gate lets through | `docs/.person-name-allowlist` |
| `paths.sectionRefRoots` | The folders the section-reference gate reads | `docs` |
| `paths.specsRoot` | The folder of the OpenAPI files | `specs` |
| `paths.codeAreasPage` | The page that describes the code areas, which the architect agent reads; its `## Review checks` section lists the questions the architect answers for every plan | none |
| `paths.codeAnalysisPipeline` / `paths.pipelinesFolder` | The pull request workflow and the folder of the workflows | none |
| `paths.preflightReceipts` | Where the pre-flight writes its receipts. The setup makes git ignore a folder outside `temp/` too, with a rule from the root such as `/out/`. | `temp/preflight` |
| `paths.sourceExtensions` / `paths.sourceDocMap` | The source files the change check watches, and the docs each source folder maps to | none |
| `secretScan.allowPaths` | Regular expressions on file paths that the secret scan skips: files that hold secrets on purpose, because the application needs them there. The pre-flight, the C03 gate and a new baseline all skip them. A skipped path is never scanned, so use the narrowest pattern that works, such as `^\.runtime/`. The repository decides what it skips. The scan only refuses a pattern with a quote or a control character, or one that is not a valid regular expression. | none |
| `git.allowTrunkPush` | `true` lets this repository update `main` or `master` with a plain push, without a pull request. It fits a repository whose changes are tested on the running system before they are committed. Both push hooks still refuse a delete and a force push of `main`, and the blocking gates still run. Only the JSON value `true` counts, and only in `aisdlc.json` of the commit that is the tip of the remote `main` branch, so the change that turns it on goes through a pull request first. On `main`, the pre-flight then skips the issue-contract row, because such a change has no story. | `false` |
| `paths.bicepRoot` | The folder whose subfolders are the Bicep building blocks, for the `bicep` pack | `building-blocks` |
| `paths.platformKnowledge` | The folder of the platform knowledge notes, for the `knowledge` pack | `docs/platform-knowledge` |
| `paths.knowledgeRoot` | The clone of the knowledge repository, next to this repository. `walk-substrate` and `guide-me` read it when it is there; CI never reads it. In a linked git worktree, a relative path that is not there is resolved against the main checkout, so `../Knowledge` is found from `.claude/worktrees/<name>` too | `../Knowledge` |
| `paths.privateTermsFile` | The private term list of the private-terms gate. Empty means `<knowledgeRoot>/ai-sdlc/private-terms.txt` | empty |
| `paths.discoveryRoot` | The folder of the discovery pages, for the `discovery` pack | `docs-functional/discovery` |
| `visibility` | `private` or `public`. The private-terms gate runs only on a `public` repository | `private` |
| `docs.lastCheckedMaxAgeDays` | A positive whole number switches on a warning for every `Last checked: <date>` in `AGENTS.md` and the doc layers that is older than this many days. The local gate run and the pre-push hook show it, and it never fails a push. Any other value counts as off. | `0` (off) |
| `docs.units` / `docs.unitExclude` | The units that need a page, when the list of the packs does not fit, and the unit paths left out on purpose | the packs' list / none |
| `paths.solution`, `paths.sourceRoot`, `paths.testRoot`, `paths.runSettings`, `paths.coverageBaseline`, `paths.packagesProps` | The .NET solution, its code, its tests and its coverage setup, for the `dotnet` pack. `Get-AiSdlcConfig` refuses a `paths.sourceRoot` or `paths.sourceRoots` folder outside the repository or behind a link | none |
| `paths.sourceRoots` | More source folders, as a list, for the change completeness gate. It reads them next to `paths.sourceRoot`. A package folder such as `core` or `packs` maps a script under `.apm/` to its test under `tests/` | none |
| `commands.build` / `commands.test` / `commands.testChanged` | How to build and test the repository. The pre-flight runs `commands.test` from the repository root, unless a pack pre-flight runs the tests itself, as the dotnet pack does. A scoped pre-flight runs `commands.testChanged` in its place when it is set; a test command that exits 3 ran no test and shows `N/A` | none |
| `tracker` | The issue repository (`tracker.repository`, `owner/name`; empty means the `origin` remote), an own key pattern (`tracker.keyPattern`), the `refined` and `to-refine` labels, the size label prefix (`size:`), the labels and the data model patterns, for the `github-issues` pack. `tracker.acceptedRepositories` lists other repositories, as `owner/name`, whose issues may anchor a pull request here, such as the AI.SDLC source for an update pull request | `refined`, `to-refine`, `size:`; no accepted repositories |
| `github` | The repository (`github.repository`, `owner/name`; empty means the `origin` remote) and the main branch (`github.trunk`). It is the one setting for the main branch: the gates, the pre-flight and the test runner compare a change with `origin/<trunk>` through `Get-AiSdlcMainBranch` | `main` |
| `sonarcloud` | The SonarCloud organization and project key, for the `sonarcloud` pack | none |
| `css` | The token prefix (`css.tokenPrefix`, such as `--brand-`) and the colour scheme files (`css.colourSchemeFiles`, a list of paths), read by `css-conventions`, for the `css` pack. A key that is not set means: use what the style sheets next to the change use | none |
| `javascript` | The name of the cleanup helper that removes a listener when its element leaves the page (`javascript.cleanupHelper`), read by `javascript-conventions`, for the `javascript` pack. A key that is not set means: use the helper that the modules next to the change use | none |
| `knowledge` | The knowledge repository (`knowledge.repository`, `owner/name`). The setup offers `gh repo clone` into `paths.knowledgeRoot` when the folder is missing | none |
| `dotnet` | The code graph benchmark, the external contract paths, the wire name allow list, the app component (`appComponent`) and the API page folders, for the `dotnet` pack. `dotnet.folders.contracts`, `.exceptions` and `.options` name the folders for a new interface, exception and options class, which `csharp-conventions` reads; a key that is not set means: follow the types next to the change. `dotnet.layers` is the layer order of the solution, bottom layer first: a list of objects with a `name` and `projects`, a list of path globs to project files (ADR 0028). Without it the layer gate reports not applicable. `dotnet.credentialHelper` and `dotnet.baseException` name the shared credential helper type and the shared base exception type that `Check-SharedParts.ps1` reads; an empty key skips its rule | none |
| `pullRequest.sizeLimit` / `pullRequest.sizeExclude` | The most changed lines (added plus removed) a pull request has before `Check-PrSize.ps1` warns, a whole number above 0, and the path globs of the files that do not count. The gate reads both at the merge base, so a change cannot raise its own limit. Without a limit the gate reports not applicable | none |
| `bicep` | For the `bicep` pack: `bicep.roleLookupFiles`, the paths of the files that hold the role definition IDs, which the role ID gate reads (without it the rule reports not applicable). `bicep.registryAlias`, the module registry alias, and `bicep.deploymentNameHelper`, the helper function for deployment names, are read by `bicep-conventions` only. A key that is not set means: follow the files next to the change | none |
| `repoGates` | The repository's own gates, each with a name that says what passes, a script, a mode (Blocking, Advisory or Off), a clause (a core clause, a pack clause or `AI-SDLC`), a `checks` text and a `fix` text | none |
| `gateModes` | An object of shared gate names and modes (Blocking, Advisory or Off), which sets the mode of a shared gate in this repository. A name that no shared gate that runs has fails the run. The secret scan, the private-terms gate and the sync manifest check always run Blocking. A weaker mode shows as a warning in every run | none |

## Pinning a version

`apm.yml` names each package with the AI.SDLC repository, the package folder and a release tag. One
tag covers every package, so all entries use the same `ref`:

```yaml
dependencies:
  apm:
    - git: https://github.com/RobHofmann/AI.SDLC
      path: core
      ref: v1.0.0
    - git: https://github.com/RobHofmann/AI.SDLC
      path: packs/bicep
      ref: v1.0.0
targets: [claude]
```

AI.SDLC does not know its consumers, so each repository pulls a release itself. The workflow
`.github/workflows/ai-sdlc-update.yml` (written by `tools/Add-AiSdlcConsumer.ps1`) and the `update-ai-sdlc`
skill run `New-AiSdlcUpdatePullRequest.ps1`. It takes the release on the branch `ai-sdlc-<tag>`, pushes it and
opens this pull request. Then the usual step is to do what its description lists, and merge it. To take a new version by hand, run
`pwsh .claude/skills/ai-sdlc-hooks/scripts/Update-AiSdlc.ps1`, which takes
the newest release, or pass `-Ref v1.2.0`. When the AI.SDLC source is a private repository, APM reads
it with the token in `GITHUB_APM_PAT`; a public source needs nothing. The script does these steps:

1. It moves the `ref` of every AI.SDLC entry in `apm.yml` to the new tag. An AI.SDLC entry is one whose
   `git:` URL is the same as that of the entry with `path: core`. It never touches the `ref` of another dependency.
2. It runs `apm install`, then `apm audit --ci`. It stops when the two disagree, before it stages
   anything.
3. It stages the install and marks the git hooks executable, which APM does not keep.
4. It runs `Sync-AgentsFile.ps1`. When the root `CLAUDE.md` only imports `AGENTS.md`, that script also
   moves the import to `.claude/CLAUDE.md` and stages the move. Then `Find-RetiredSkillNames.ps1` lists each line in the repository's
   own files that still uses a skill name a release retired, with the new name. Fix those lines by hand.
   The list leaves out the ADR folder (`paths.adrFolder`), because an ADR is history. It also leaves out
   the files in `paths.historyPaths`, and says in one line how many places it left out. A pattern there
   that matches no file gives a warning.
5. It runs the blocking gates.

Commit the result in one pull request. The gates run on the staged install, because some gates ask git
which files exist. They treat an untracked installed file as missing. The pull request workflow of the repository then runs the new gates.

## Allow rules come from the packages

Each package lists the commands its skills run in the `allow` array of a `gates.json`. The core lists
the gates and git, `github` the pull request scripts and the `gh` calls, and `dotnet` lists
`dotnet test`. `Sync-AllowRules.ps1` in `ai-sdlc-gates` writes them into `permissions.allow` of
`.claude/settings.json`, as a `Bash(...)` and a `PowerShell(...)` rule. `Initialize-AiSdlc.ps1` and
`Update-AiSdlc.ps1` run it, so a new clone and every new version get the rules of the installed
packages; the repository commits the file. A repository gets no rule for a package it does not
install. Each gate also gets its own rule: its script with the exact arguments of its entry, and no
star. So every gate runs without a prompt, but a form that writes files, such as `Sync-AllowRules.ps1`
without `-Check`, still asks. A rule must name its script. A star glued to a file name in a scripts folder, such as
`scripts/Check-*`, would let a new script run without a prompt. The script never writes
such a rule, and it removes one that an older release wrote. Any other rule the repository wrote itself
stays. The advisory core gate runs it with `-Check` and names a missing rule or a wildcard rule. To
change a shared rule, change the `gates.json` of the skill in AI.SDLC.

Three more lists in a `gates.json` narrow what runs without a prompt:

- `ask` lists commands that always ask a person, also when an allow rule matches them. Claude Code reads
  an ask rule before an allow rule, and a star matches any text, spaces and colons too. So the core
  allows `git push origin <digit>*`, a story branch, and asks for any extra argument, refspec or shell
  character after it. A push to `main` always asks, also when a hook is broken. The agent push hook
  `Deny-IncompletePush.ps1` and the git pre-push hook refuse a push to `main` as a second guard. A rule
  cannot match a literal `*`, so a glob after the branch is left to those hooks.
- `retiredAllow` lists rules that a release took back, such as `git push origin *` and the runners with
  a star. The script never writes them, removes them from `.claude/settings.json`, and `-Check` fails
  on one.
- A rule that names the folder of a skill a release retired, `.claude/skills/<old>/`, is removed too,
  when the installed `sync-manifest.json` lists `<old>` and no such folder exists. `-Check` lists it
  without failing.

The runners `Invoke-LocalGates.ps1` and `Invoke-Preflight.ps1` run without a prompt only with the
argument sets the skills use, such as `-SkipTests`. Any other call asks, and so does
`Invoke-PesterGate.ps1`, which would run any test file. The runners still run the scripts that
`repoGates` in `aisdlc.json` names, and an agent can edit those. So the edit permission is the real
limit: a repository that lets the agent edit without a prompt also lets it run that code.

## Developing against a local clone

To change a shared file and try it in a repository before a release:

1. Clone AI.SDLC next to the repository and make the change on a branch there.
2. In the repository, point each entry of `apm.yml` at the clone, for example `- ../AI.SDLC/core`,
   and run `apm install`. APM copies the files from the clone.
3. Try the change. Run the gates with `pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1`.
4. Put `apm.yml` back to the release tag before you commit. A local path in `apm.yml` never reaches
   a pull request.
5. Open the pull request on AI.SDLC. After the release, take the new tag as described above.

## Lessons about shared files

A lesson that changes a shared file goes to AI.SDLC as a pull request; a lesson about one
repository stays in that repository. A fact about how a system behaves goes to the knowledge
repository, through a branch and a pull request there. The [autolearn page](autolearn.md) says how to decide.

## The knowledge repository and the private terms

The knowledge repository holds the facts about the systems you work on, and the private term list.
Clone it next to the repository, at `paths.knowledgeRoot` (`../Knowledge` by default).
`Sync-AllowRules.ps1` then adds its full path to `permissions.additionalDirectories` in
`.claude/settings.local.json`, which stays on your machine. It only adds a folder below the parent
folder of the repository that it reaches without a link. In a linked worktree, the parent folder of
the main checkout counts too. The parent folder itself and any other folder are skipped with a FIX
line, so a repository cannot open a folder elsewhere to the agent. CI never reads the knowledge folder.

The core gate `Check-PrivateTerms.ps1` blocks a term of the private list in a public repository
(`visibility` is `public`). It reads the list from `AISDLC_PRIVATE_TERMS`, `paths.privateTermsFile`
or the knowledge folder. A finding names the file, the line and the rule number, never the matched text.

In GitHub Actions the gate also reads the event of the run, so it fails closed in a public repository:

- When GitHub says the repository is public, the gate checks it even if `visibility` says `private`,
  and that wrong setting fails the build. Set `"visibility": "public"`, so a local run checks it too.
- In a public repository, a run with no list fails. So pass the secret `AISDLC_PRIVATE_TERMS` to the
  shared step as `private-terms`. `tools/Add-AiSdlcConsumer.ps1` reads the visibility and lists this step.
- A pull request from a fork gets no secrets, so there the gate could not check (exit 2) and the build
  fails. Before you merge such a pull request, check out its branch and run
  `Check-PrivateTerms.ps1 -Required` with the list.

## Related

- [The handbook start page](README.md) - the phases, the skills and the agents of the way of working.
- [Autolearn](autolearn.md) - where a lesson goes, shared or repo-only.
- [Own skills, agents and hooks](consumer-own.md) - the root `.apm/` folder, own names and local packages.
- [Documentation wiki](docs-wiki.md) - how a repository's pages link to the handbook pages.
