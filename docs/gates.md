# Repository gates

The gates that only AI.SDLC runs, from `repoGates` in `aisdlc.json`. A script makes this page from that list, so do not edit it by hand.

The gates of the core and of the packs are on the [shared gate list](../core/.apm/skills/ai-sdlc-gates/references/gate-catalog.md). A gate that fails or cannot check prints its checks text before its own output.

## Gates

### Tracked files, commits and pull request text hold no term from the private term list

- Clause: AI-SDLC
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Script: `core/.apm/skills/ai-sdlc-gates/scripts/Check-PrivateTerms.ps1`
- Checks: It checks tracked files, commit messages, the branch name and the pull request text against the private term list, and never prints a term. Here it runs with `-Required`, so a missing list exits 1. Exit 2 means a rule is not valid, and exit 3 means the repository is private.
- Fix: Remove the text at the file and line that the output names, or ask the list owner which rule it breaks.

### No shared file names a skill that a release retired

- Clause: AI-SDLC
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Script: `tools/Check-RetiredSkillNames.ps1`
- Checks: It reads every file except `CHANGELOG.md` and the sync manifest, and fails on an old skill name from `config/retired-skill-names.txt`. It does not check a name that is not on that list. Exit 2 means the list is missing or a line in it is not a pair of names, and it never exits 3.
- Fix: Replace the old skill name with its new name, as the retired list gives it.

### The skill list names every skill and agent of every package

- Clause: AI-SDLC
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Script: `tools/Update-SkillCatalog.ps1`
- Checks: It builds the list of skills and agents from `core/` and `packs/` and compares it with `skill-catalog.json`. It does not check the text of a skill. Exit 2 means there is no core or packs folder, and it never exits 3.
- Fix: Run `tools/Update-SkillCatalog.ps1` and commit the list it writes.

### The sync manifest lists every file the packages deliver, with its current hash

- Clause: AI-SDLC
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Script: `tools/Update-SyncManifest.ps1`
- Checks: It builds the manifest from the files under `.apm/` of each package and compares it with `sync-manifest.json`. It also fails on a test file under `.apm/` and on a file of an unknown kind. Exit 2 means there is no core or packs folder, and it never exits 3.
- Fix: Run `tools/Update-SyncManifest.ps1` and commit the manifest it writes.

### The shared parts of the agents file stay within their line and word budget together

- Clause: AI-SDLC
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Script: `tools/Check-SharedAgentsPartSize.ps1`
- Checks: It counts the lines and words of every `agents-*.md` part, with the marker lines, and fails over the budget. It does not check the text of a part. Exit 2 means there is no part under `core/` or `packs/`, and it never exits 3.
- Fix: Shorten a shared part, or move its detail into a docs page and link it.

### Every `apm.yml` has the version of the newest CHANGELOG release

- Clause: AI-SDLC
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Script: `tools/Check-PackageVersion.ps1`
- Checks: It reads the first release heading of `CHANGELOG.md` and compares it with the version in each `apm.yml` and in `apm.lock.yaml`. It does not check that the tag exists. Exit 2 means `CHANGELOG.md`, its version heading or the `apm.yml` files are missing, and it never exits 3.
- Fix: Set `version` in each `apm.yml` to the newest release of `CHANGELOG.md`, then run `apm install` until the lock file matches.

### Shared files and docs hold no em-dash characters

- Clause: C06
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Script: `core/.apm/skills/ai-sdlc-gates/scripts/Check-DocEmDashes.ps1`
- Checks: It scans the markdown in `core`, `packs`, `tools`, `test-consumers`, the docs, `README.md`, `AGENTS.md` and `CHANGELOG.md` for the em-dash character (U+2014). It does not check files outside that list. Exit 2 means a listed path is missing, and it never exits 3.
- Fix: Replace each em-dash with a comma, a colon or a hyphen with a space on each side.

### Shared docs cite no source line numbers

- Clause: C02
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Runs locally when the change touches: `**/*.md`, or the skill or tool folder of its script
- Script: `core/.apm/skills/ai-sdlc-gates/scripts/Check-DocLineCitations.ps1`
- Checks: It scans the markdown in `core`, `packs`, the docs, `README.md` and `AGENTS.md` for a line number such as `file.ext:42` or the words line 42. It does not check that a cited path exists. Exit 2 means a listed path is missing, and exit 3 means there is no markdown file to scan.
- Fix: Replace each line number with the file path and the name of the symbol.

### Shared files and docs read at B2 sentences and B1 words

- Clause: C11
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Runs locally when the change touches: `**/*.md`, `**/.reading-level-allowlist`, or the skill or tool folder of its script
- Script: `core/.apm/skills/ai-sdlc-gates/scripts/Check-DocReadingLevel.ps1`
- Checks: It reads the markdown in `core`, `packs`, the docs, `README.md` and `AGENTS.md`. It fails on a sentence over 25 words or on a word above level B1. A sentence that wraps over lines counts as one. Exit 2 means a listed path is missing, and exit 3 means there is no markdown file.
- Fix: Split each long sentence into shorter ones, and replace each hard word with a plain word.

### The gate list pages match the gates.json files and repoGates

- Clause: AI-SDLC
- Mode: Blocking
- Runs in: pre-push hook, pull request action, local run
- Script: `tools/Build-GateCatalog.ps1`
- Checks: It builds the shared gate list and `docs/gates.md` in memory from every `gates.json` file and from `repoGates`, and compares them with the committed pages. It does not judge whether a gate text is true. Exit 2 means a folder, a file or a gate text is missing, and exit 3 means there is no gate at all.
- Fix: Run `pwsh tools/Build-GateCatalog.ps1` and commit `gate-catalog.md` and `docs/gates.md`.

## Related

- [Tools](tools.md) - the scripts of this repository, including the tool that writes this page.
- [Shared gate list](../core/.apm/skills/ai-sdlc-gates/references/gate-catalog.md) - the gates of every package.
