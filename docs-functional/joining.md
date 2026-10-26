# Adding the AI-SDLC to a repository

A new or existing repository joins the AI-SDLC with one script, run from a clone of AI.SDLC. After
that, every clone of the repository sets itself up with one command.

## What you get

- The packs the repository needs: the core, `github` and `github-issues` always, and a pack for each
  technology the repository holds.
- An `aisdlc.json` with the GitHub settings: the repository from the git remote, and the main branch.
- An `apm.yml` that pins every package to one release tag of AI.SDLC.
- A technical and a functional docs layer, and a pull request workflow when the repository has none.
- The update workflow `.github/workflows/ai-sdlc-update.yml`, which opens a pull request for each new
  release of AI.SDLC. AI.SDLC itself does not know your repository.
- The issues of AI.SDLC accepted as a story key, through `tracker.acceptedRepositories`, so each
  update pull request passes the story check.
- A list of what is left for you, such as switching on Issues and the ruleset on the main branch. It
  also names the GitHub App of the update workflow, and the commits.

## When you need it

When a repository starts to use the AI-SDLC, run from a clone of AI.SDLC:

```powershell
pwsh tools/Add-AiSdlcConsumer.ps1 -TargetRepo ../portal
```

Then open an issue for the setup. Commit what the script staged on a branch named with its number,
such as `12-ai-sdlc-setup`, and open a pull request with `Fixes #12`. The pull request workflow fails
a pull request with no issue key. After the first push, make the workflow required, as the next
section says.

## The starter workflow

A repository with no `.github/workflows/pr.yml` gets one, filled in from the defaults: the main branch
`main` and the runner `ubuntu-24.04`.

- It runs on every pull request to the main branch, with read rights only.
- It checks out the full history, then runs the shared AI-SDLC step of the core. That step checks the
  installed files, scans for secrets with gitleaks and runs every gate.
- For a .NET solution it first builds and tests with coverage, and hands the coverage to the shared
  step for the coverage ratchet.
- Put the other build and test jobs of the repository next to it.

Then make GitHub ask for it on every pull request. After the first push and the first run, from the repository:

```powershell
pwsh .claude/skills/github-pull-requests/scripts/Set-BranchRuleset.ps1 -RequiredCheck "AI-SDLC gates" -WhatIf
pwsh .claude/skills/github-pull-requests/scripts/Set-BranchRuleset.ps1 -RequiredCheck "AI-SDLC gates"
```

The first line shows what it would do. The second sets a ruleset on the main branch: every change comes
through a pull request, and the checks of the workflow must pass. `AI-SDLC gates` is the name of the job in the starter
workflow; name your own jobs when your workflow has others. It asks for no approval, because you
cannot approve your own pull request; your merge is the approval. A repository that already has a pull
request workflow keeps it, and the setup script prints the step to add to it. `-NoWorkflows` skips
the starter file on purpose.

Do not skip this step. Without a required check, no gate has to pass on a pull request, and a broken
install reaches the main branch. The setup script prints the step apart from the others for that reason.

## What to know

- The script commits and pushes nothing in the new repository. You review what it staged.
- Switch on Issues for the repository, and add the labels `refined`, `to-refine` and `spike`. The
  setup script reminds you.
- The update workflow signs in as a GitHub App, because a pull request that the default workflow token
  opens starts no checks. Create an App with Contents and Pull requests set to read and write, install it
  on the repository, and set the variable `AISDLC_UPDATE_APP_CLIENT_ID` and the secret
  `AISDLC_UPDATE_APP_PRIVATE_KEY`. One App can serve all your repositories.
- Existing docs get the machine fixes. When a doc gate or the coverage gate still fails, run
  `/adopt-docs` in the repository, in its own pull request ([complete documentation](documentation.md)).
- Each clone runs `pwsh .claude/skills/ai-sdlc-hooks/scripts/Install-AiSdlc.ps1` once. It checks that the
  GitHub CLI (`gh`) is signed in, and only advises when it is not.
- A repository that keeps large files in Git LFS needs Git LFS on each machine. A normal `git push`
  then uploads the large files, and LFS file locking keeps working. Nobody needs to run `git lfs push` by hand.
- The skills read and write issues with the GitHub CLI. Sign in once with `gh auth login`.
- Start Claude Code or GitHub Copilot in the root folder of the repository. Copilot runs no agent hook in a
  session that starts in a subfolder.
- A public repository sets `"visibility": "public"` in `aisdlc.json`. The private term gate then checks
  every file, commit message and pull request text against your private list. The workflow passes
  that list from the secret `AISDLC_PRIVATE_TERMS`. Without that secret, the workflow of a public
  repository fails, also when `visibility` still says `private`. A pull request from a fork gets no
  secrets, so check it by hand before you merge it.
- A team keeps skills, agents and hooks of its own in the root `.apm/` folder, next to `apm.yml`. A
  local package in `apm.yml` must be a folder in git, or the push stops
  ([own parts](../core/.apm/skills/ai-sdlc-handbook/references/consumer-own.md)).

## Related

- [What the AI-SDLC gives a team](overview.md) - why a repository joins.
- [Taking a new version](new-version.md) - what happens after the first install.
- [tools](../docs/tools.md) - the setup script and its tests.
- [Index](index.md) - every page of this layer.
