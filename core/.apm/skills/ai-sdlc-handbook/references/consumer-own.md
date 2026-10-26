# Own skills, agents and hooks of a repository

Every repository gets the same shared skills, agents, hooks and gates from AI.SDLC. A repository can
add parts of its own next to them. This page says where those parts live, how to name them, and how
a lesson in one of them reaches the other teams. The [layout page](layout.md) says where the shared
parts live.

## Where the own parts live

A repository keeps its own skills, agents and hooks in the root `.apm/` folder, next to `apm.yml`.
The folder has the same shape as a package of AI.SDLC:

| Part | Where in the repository | Where APM installs it |
|---|---|---|
| Skill | `.apm/skills/<name>/SKILL.md`, with its `scripts/` and `references/` | `.claude/skills/<name>/` |
| Agent | `.apm/agents/<name>.agent.md` | `.claude/agents/<name>.md` |
| Hooks | `.apm/hooks/<name>-hooks.json` | Merged into `.claude/settings.json` |

`apm install` installs the own parts with the shared ones. It lists them under `local_deployed_files`
in `apm.lock.yaml`. `apm.yml` needs no line for them. Commit the source in `.apm/` and the installed
copy under `.claude/` together, as for the shared parts.

Change an own part in `.apm/`, then run `apm install` again. A change made only in the copy under
`.claude/` is lost at the next install. A hook command uses a path from the repository root, such as
`pwsh -NoProfile -File tools/my-hook.ps1`. APM rewrites a path inside the hooks folder, and the hook
then breaks on Windows.

## A local package only when its folder is in git

`apm.yml` can also name a local package: a line such as `- ./packs/<name>`, with its own `apm.yml`
and `.apm/` folder. That is allowed only when git tracks the folder. A folder outside git is missing
in a fresh clone, in the pull request workflow and in the update to a new AI.SDLC version. Then
`apm audit --ci` fails on an orphaned package, and the update opens no pull request.

The same failure comes back when the parts move from a local package to the root `.apm/` folder. The
entry in `apm.yml` goes, but the dependency in `apm.lock.yaml` can stay behind.

The blocking core gate `Check-LocalPackages.ps1` catches both. It reads each local path in `apm.yml`
and each `local_path` in `apm.lock.yaml`. It fails when a path is missing or git does not track it,
and it names the package. The fix is one of two:

- Add the folder to git and commit it.
- Remove the entry from `apm.yml`, and the dependency from `apm.lock.yaml` when it is still there.
  Then run `apm install` and `apm audit --ci`, and commit the result.

The gate runs in the pre-push hook and in the shared composite action, so the push stops before the
release does. It does not check a path outside the repository, such as `- ../AI.SDLC/core`. That form
is only for [trying a shared change from a local clone](layout.md#developing-against-a-local-clone),
and it never reaches a pull request.

## Naming an own skill or agent

An own name must not be a shared name or a retired one:

- **No shared name.** `skill-catalog.json` in the `ai-sdlc-gates` skill lists every shared skill of
  every package, also of a pack the repository does not install. A pack can be added later.
- **No retired name.** `config/retired-skill-names.txt` in AI.SDLC lists each name that a release
  retired. The installed `sync-manifest.json` carries the same list under `retired`.
- **A prefix per repository is advised.** For example `ab-` for every own skill and agent of one
  repository. A new shared name then never meets an own name.

`Check-SyncManifest.ps1` already blocks a clash. An own skill with the name of an installed shared
skill makes that folder differ from the release. The gate also fails on an own skill with a retired
name, or with the name of a pack that is not installed. It takes that folder for one an older version
left behind, and says to delete it. Rename the own skill in `.apm/` instead.

## The other own parts

- **Own gates** go in `repoGates` of `aisdlc.json`, each with a name, a script and a mode. The script
  path is relative to the repository root, usually in its tools folder (`paths.toolsFolder`).
  `Invoke-LocalGates.ps1` runs them with the shared gates. The [add-gate](/.claude/skills/add-gate/SKILL.md) skill says how to write one.
- **Own rules** go in `AGENTS.md`, outside the `ai-sdlc:<package>` markers. `Sync-AgentsFile.ps1`
  rewrites only the text between the markers.
- **Own settings** go in `.claude/settings.json`, next to the hook entries that APM merges there.

## A lesson for every team

An own part often starts as a fix for one repository. When the lesson would help every repository,
it goes to AI.SDLC as a pull request, and the own part goes away after the release. The
[autolearn page](autolearn.md) says how to tell a shared lesson from one that stays in the repository.

## Related

- [Layout](layout.md) - the shared parts, `aisdlc.json` with `repoGates`, and the version pin.
- [Autolearn](autolearn.md) - where a lesson goes, shared or repo-only.
- [The handbook start page](README.md) - the phases, the skills and the agents of the way of working.
