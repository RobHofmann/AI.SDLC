# Taking a new version

AI.SDLC releases one version for all its packages at once. AI.SDLC does not know who installs it, so each
repository pulls the release itself. It opens a pull request that moves it to the new version, and a
person reviews and merges it.

## What you get

- A pull request in your repository for each release, on the branch `ai-sdlc-<tag>`. The workflow
  `.github/workflows/ai-sdlc-update.yml` opens it every Monday when a newer release exists, signed in as
  your GitHub App. A newer update pull request closes an older one that is still open.
- The new version of every installed package, all pinned to the same tag. Only the `ref:` lines of the AI.SDLC packages move; another dependency keeps its own ref.
- A root `CLAUDE.md` that only imports `AGENTS.md` moves to `.claude/CLAUDE.md`. Nothing else changes.
- The issue of AI.SDLC that the release tag names, so the change is traced to its issue. The title
  names it as `RobHofmann/AI.SDLC#42`, and the description as `Refs RobHofmann/AI.SDLC#42`. It says
  `Refs`, never `Fixes`, so your merge does not close the issue of AI.SDLC.
- A description that says what to fix in the same pull request. It lists each line of your own files that
  still uses a retired skill name, with the new name. A file whose name marks it as history, such as a
  change list, is listed apart, with the `paths.historyPaths` entry to add instead of a rename. It also
  holds the steps that each release since your old version asks of you. A "Before you merge" list at the
  top names each step, so the whole update fits in this one pull request. When the list is too long, the
  full list is in a comment on the pull request.

## When you need it

- An update pull request is open: do the steps of its "Before you merge" list on that branch, then merge it.
- You want a release now, not next Monday: run the `update-ai-sdlc` skill, or
  `pwsh .claude/skills/ai-sdlc-hooks/scripts/New-AiSdlcUpdatePullRequest.ps1`. It opens the same pull request.
- You want a pre-release to test: run `pwsh .claude/skills/ai-sdlc-hooks/scripts/Update-AiSdlc.ps1 -Ref <tag>`
  on a branch of your own. It moves the refs, installs and stages, and pushes nothing.

## What to know

- A tag with a suffix, such as `v1.1.0-rc.1`, is a pre-release. A consumer can pin it to test a
  change, and the update workflow skips it.
- A tag whose message names no issue gives an update pull request without an issue key. The script says so, and the story check then fails it.
- The story check accepts the issue of AI.SDLC only when `tracker.acceptedRepositories` in your
  `aisdlc.json` lists the AI.SDLC repository. The setup script writes it; an older setup adds it by hand.
  The issue must carry the `refined` label, like any story. It is closed by then, and a closed issue counts.
- The update workflow needs a GitHub App, because a pull request that the default workflow token opens
  starts no checks. Set the variable `AISDLC_UPDATE_APP_CLIENT_ID` and the secret
  `AISDLC_UPDATE_APP_PRIVATE_KEY`; until then the workflow fails and says what to set.
- A hand edit to an installed file fails `apm audit --ci` in the workflow. Fix the file in AI.SDLC instead.
- Every pull request run checks that each file and hook of the installed packages is there, with
  the same content as the release. A file that did not arrive, or one left behind from an older version, fails the run.
  So does the folder of a skill that a release renamed, when an older version left it behind. Delete it.
  A skill or an agent of your own passes.
- A release can rename a skill. Your own files, such as your part of `AGENTS.md`, `CLAUDE.md` or an
  onboarding page, may still use the old name. Run
  `pwsh .claude/skills/ai-sdlc-hooks/scripts/Find-RetiredSkillNames.ps1` to list each of those lines
  with the new name, and change them in the update pull request. When the new name is an internal step,
  the line says so, because a person cannot type it. When there is one, it names the command to type instead, such as `/grill-me`. `Update-AiSdlc.ps1` prints the same list.
  The list leaves out your decision records (`paths.adrFolder`, `docs/adrs` by default). An ADR records a
  decision as it was made, so you do not change the names in it.
- Some of your files record history on purpose, such as a change list that shows the old text next to the
  new text. List them in `paths.historyPaths` of `aisdlc.json`, as paths or glob patterns, and the list
  leaves them out. It then says in one line how many places it left out. Do not list a page that people
  read as current, because an old name there still misleads a reader.

## Related

- [Adding the AI-SDLC to a repository](joining.md) - the first install that this updates.
- [How AI.SDLC is built](../docs/overview.md) - the workflow and the release behind this.
- [Glossary](glossary.md) - what an update pull request and a pre-release are.
- [Index](index.md) - every page of this layer.
