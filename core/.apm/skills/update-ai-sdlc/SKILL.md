---
name: update-ai-sdlc
kind: workflow
phase: cross-cutting
persona: Developer
description: >
  Take a new release of the shared AI-SDLC in this repository: one script moves the AI.SDLC refs in
  apm.yml to the new tag, installs it on its own branch, commits, pushes and opens one pull request that
  lists what the release asks of this repository. Then do those steps on the same branch. Use when the
  user says "update the AI-SDLC", "take the new AI.SDLC release", "pull the latest AI-SDLC", "is there a
  new AI-SDLC version", or when the scheduled update pull request needs its steps done. Do NOT use to
  change a shared skill (that is a pull request on AI.SDLC), or to set up the AI-SDLC in a new repository
  (tools/Add-AiSdlcConsumer.ps1 in AI.SDLC).
---

# Update the AI-SDLC

Owned by the **Developer**. AI.SDLC does not know who installs it, so each repository pulls a release
itself. The scheduled workflow `.github/workflows/ai-sdlc-update.yml` does it every week. This skill
does the same on demand, and then finishes what the release asks of this repository.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).

## Workflow

1. **Look first.** Run `pwsh .claude/skills/ai-sdlc-hooks/scripts/New-AiSdlcUpdatePullRequest.ps1 -WhatIf`.
   It names the newest release and the branch, or says the repository is already on it. Pass
   `-Ref vX.Y.Z` for a given release.
2. **Open the pull request.** Run the same command without `-WhatIf`. It needs a clean working tree and
   `gh auth login`. It stops, and changes nothing, when the branch `ai-sdlc-<tag>` is already on origin.
   Then the scheduled workflow opened that pull request, so go on with step 3 on it.
3. **Do the steps on the same branch.** The description opens with a "Before you merge" list: old skill
   names to rename, history files for `paths.historyPaths`, and the steps of each release from the AI.SDLC
   changelog. Check out `ai-sdlc-<tag>`, make each change, run the tests and
   `Invoke-LocalGates.ps1`, commit and push. A step left for after the merge needs a second pull request.
4. **Hand over.** Report the pull request link and what is done. The owner merges it (Checkpoint Bravo).

The script runs `Update-AiSdlc.ps1 -NoGates`, because the pull request workflow runs the gates. The
pull request names the release issue as `Refs owner/AI.SDLC#42`. The PR-story check accepts it, because
`tracker.acceptedRepositories` lists AI.SDLC and a closed issue counts.

## Failure modes

- **The release steps are skipped because the update itself is green** -> the gates check what they
  can. A step such as "type the new names" has no gate. Read the "Before you merge" list.
- **A second update branch is made by hand next to the scheduled one** -> two pull requests then take
  the same release. Work on the branch that is there.
- **Files under `.claude/` are edited to make a gate pass** -> the sync gate fails, and the next update
  overwrites them. Change this repository's own files, or open a pull request on AI.SDLC.
- **The agent merges the pull request** -> never; the owner merges it (C09).

## Observable signal

**Positive:** each release reaches this repository as one pull request with its steps done, and no
consumer is more than one release behind for long.

**Audit trail:** the pull request, its `Refs` line to the release issue, and the commits on its branch.

**Drift signal:** update pull requests that stay open for weeks, or an `apm.yml` many releases behind,
mean nobody does the steps. Raise it at the next planning.

## Next steps

- `/run-preflight` (Developer) - before you push the steps of step 3.
- `/fix-pr-feedback` (Developer) - when the checks or a review fail on the update pull request.
- `/capture-learning` (Lead) - when a release step was unclear, so AI.SDLC can write it better.
