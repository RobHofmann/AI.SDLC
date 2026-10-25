---
story: "#1"
phase: governance
step: write-adr
intent:
  assumption: "a GitHub issue number, written as #42 in text and as a 42- prefix in a branch name, can be matched without also matching a year, a version or a markdown heading"
  decision-drivers:
    - "every artifact is anchored on a story key, so the key must be the tracker's own id"
    - "a bare number matches too much: a year, a version, a count"
    - "in YAML a bare # starts a comment, so an unquoted key reads as empty"
    - "an update pull request in a consumer belongs to the release issue of AI.SDLC, not to an issue of the consumer"
    - "work can follow a story after the story closed, such as an update to a release whose issue closed at the release"
relates:
  config: core/.apm/skills/ai-sdlc-gates/scripts/AiSdlcConfig.psm1
  graph: core/.apm/skills/ai-sdlc-gates/scripts/Check-ArtifactGraph.ps1
  hygiene: core/.apm/skills/ai-sdlc-gates/scripts/Check-PrHygiene.ps1
  conventions: packs/github-issues/.apm/skills/github-issue-conventions/SKILL.md
  contract: packs/github-issues/.apm/skills/check-pr-contract/scripts/Check-PrStoryContract.ps1
  setup: tools/Add-AiSdlcConsumer.ps1
  update: core/.apm/skills/ai-sdlc-hooks/scripts/New-AiSdlcUpdatePullRequest.ps1
because:
  config: "the module that returns the story pattern and reads a key from a branch or a text"
  graph: "the gate that checks the story key in front matter"
  hygiene: "the gate that asks whether a pull request names a story"
  conventions: "the knowledge skill that holds the issue rules"
  contract: "the gate that accepts a key of another repository only from tracker.acceptedRepositories"
  setup: "the onboarding script that lists the AI.SDLC repository in tracker.acceptedRepositories"
  update: "the script that names the release issue with Refs owner/AI.SDLC#n in each update pull request"
---

# ADR 0010: The story key is a GitHub issue number

**Status:** Accepted
**Date:** 2026-10-24
**Supersedes:** none
**Superseded by:** none

## Context

Every artifact in the way of working is anchored on a story key: front matter, the branch, the pull
request, a test marker. The tracker is GitHub Issues, so the key is an issue number. A number is harder
to find in text than a key with a project prefix:

- A bare number matches a year, a version and a count.
- `#` is also the start of a markdown heading and of an HTML entity such as `&#123;`.
- In YAML a bare `#` starts a comment, so `story: #42` reads as an empty value (YAML spec).

GitHub links `#42` to the issue in the same repository and `owner/repo#42` across repositories. A
branch made from an issue gets the name `42-short-name`. A pull request body with `Fixes #42` closes
the issue on merge (GitHub docs).

## Decision

**1. The key forms.**

| Where | Form |
|---|---|
| Text | `#42`, or `owner/repo#42` across repositories |
| Branch | `42-short-name`, also under a folder such as `feature/42-x`; a bug branch may be the bare `42` |
| Front matter | `story: "#42"`, always quoted |
| Pull request body | `Fixes #42`; an update pull request says `Refs owner/AI.SDLC#42` |
| Test marker | `#42`, for example `[Trait("Story", "#42")]` |

**2. One pattern, read through one function.** `Get-AiSdlcStoryPattern` in `AiSdlcConfig.psm1` returns
the text pattern, unless `tracker.keyPattern` in `aisdlc.json` overrides it. The default does not match
a bare number, an `&#123;` entity or a heading `# Title`. Every gate reads the pattern through this
function and never writes its own.

**3. A key from a branch is read by position.** `Get-AiSdlcBranchStoryKey` returns `#<n>` when the last
segment of the branch starts with `<digits>-`. It never matches a bare number elsewhere in the name.

**4. Gates are kind to the YAML trap.** A gate accepts an unquoted number, `story: 42`, as `#42`. It
reports `story:` with an empty value as an error with a `FIX:` line that says to quote the key.

**5. A closed issue is done, and a person closes it.** `Fixes #42` closes the issue when the owner
merges, which is the owner's act at Checkpoint Bravo. The agent never closes an issue itself (clause C09).

**6. A key of another repository counts only for an accepted repository.** `tracker.acceptedRepositories`
in `aisdlc.json` lists the repositories whose issues may anchor a pull request here. The PR-story
contract gate accepts a key `owner/repo#42` only when that list names `owner/repo`, without regard to
case. It then reads the issue in that repository and holds it to the same rule as a local issue: labelled
`refined`, open or closed. Any other key of another repository fails the gate, and the gate reads no
issue for it. The list is empty by default.

**7. An update pull request names the release issue of AI.SDLC.** `Add-AiSdlcConsumer.ps1` lists the
AI.SDLC repository in the consumer's `tracker.acceptedRepositories`. `New-AiSdlcUpdatePullRequest.ps1`
names the release issue as `owner/AI.SDLC#42` in the title and the commit, and the body starts with
`Refs owner/AI.SDLC#42`. It never says `Fixes`. The release issue closes at the release
([ADR 0002](0002-distribution-auth-and-updates-on-github.md)).

**8. A closed issue anchors a pull request too.** The PR-story check asks for the `refined` label, not
for an open issue. Work can follow a story after it closed: a late fix, or an update to a release whose
issue closed at the release. A build still starts only from an open issue
([ADR 0004](0004-two-human-checkpoints-and-one-skill-model.md)).

## Consequences

**Positive:**

- The key is the tracker's own id, so no mapping table is needed.
- One function holds the pattern, so a fix to it reaches every gate.
- A branch made with GitHub's "create a branch" button already carries the key.

**Negative:**

- A key without its `#` in text is not found. That is on purpose: the cost of a bare number matching a
  year is higher.
- The quote in front matter is easy to forget. The gate reports it, so the mistake costs one edit.

- A consumer that lists a repository in `tracker.acceptedRepositories` lets every refined issue there
  anchor a pull request here. So the list stays short: by default only the AI.SDLC repository.
- A pull request can name a story that closed long ago. Review sees the key and its issue; no gate
  checks that the work still belongs to it.

**Neutral:**

- A consumer that uses another tracker sets `tracker.keyPattern` and keeps every gate.

## Alternatives considered

1. **Match a bare number.** Rejected because it matches years, versions and counts.
2. **A project prefix such as `PROJ-42` in labels or titles.** Rejected because GitHub does not link it,
   and it would be a second id next to the issue number.
3. **Accept any key of another repository.** Rejected because any open issue anywhere could then
   anchor a pull request, and the story rule would check nothing.
4. **An issue in each consumer for each update.** Rejected because a person or a bot would open one
   issue per consumer per release, and the release issue already says why the change exists. A bot
   that labels its own issue `refined` would also skip Checkpoint Alpha.
5. **Keep the release issue open until every consumer updated.** Rejected because AI.SDLC does not know
   its consumers, so nobody can tell when that is.
6. **An unquoted `story: 42` as the only form.** Rejected as the written rule, because it reads as a
   number and not as a key. The gates still accept it, so an old file does not break.

## Verification

- `AiSdlcConfig.Tests.ps1` covers the pattern: `#42`, `owner/repo#42`, no match on a bare number, an
  entity or a heading, and the branch forms.
- `Check-ArtifactGraph.Tests.ps1` covers the quoted key, the unquoted number and the empty value.
- `Check-PrHygiene.Tests.ps1` covers a key in the branch, the title and the body.
- `Check-PrStoryContract.Tests.ps1` covers `tracker.acceptedRepositories`. It refuses a key of a
  repository that the list does not name. It reads a key of an accepted repository there, matches the
  name without regard to case, and holds that issue to the `refined` rule. It passes a closed issue with that label.
- `Add-AiSdlcConsumer.Tests.ps1` covers the AI.SDLC repository in `tracker.acceptedRepositories`, and
  `New-AiSdlcUpdatePullRequest.Tests.ps1` covers the `Refs` line of an update pull request.

## References

- `core/.apm/skills/ai-sdlc-gates/scripts/AiSdlcConfig.psm1` - `Get-AiSdlcStoryPattern`, `Get-AiSdlcBranchStoryKey`, `Get-AiSdlcStoryKey`.
- `packs/github-issues/.apm/skills/check-pr-contract/scripts/Check-PrStoryContract.ps1` - the check of `tracker.acceptedRepositories`.
- `tools/Add-AiSdlcConsumer.ps1` and `core/.apm/skills/ai-sdlc-hooks/scripts/New-AiSdlcUpdatePullRequest.ps1` - the setup and the update pull request.
- Autolinked references to issues: https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/autolinked-references-and-urls
- Creating a branch for an issue: https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/creating-a-branch-for-an-issue
- Linking a pull request to an issue with a keyword: https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/linking-a-pull-request-to-an-issue
- YAML comments start with `#`: https://yaml.org/spec/1.2.2/#comments

## Related

- [ADR 0004](0004-two-human-checkpoints-and-one-skill-model.md) - the checkpoint where the owner merges and the issue closes.
- [ADR 0005](0005-the-gate-contract.md) - the contract the key checks follow.
- [ADR 0002](0002-distribution-auth-and-updates-on-github.md) - the update pull request that names the release issue.
- [ADR index](README.md) - the list of decisions in this repository.
