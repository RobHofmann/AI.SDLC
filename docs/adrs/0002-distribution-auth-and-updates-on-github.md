---
story: "#1"
phase: governance
step: write-adr
intent:
  assumption: "APM installs a package from a public GitHub repository with no token, and reads GITHUB_APM_PAT when a source is private"
  decision-drivers:
    - "a token in every consumer, on every machine and in every CI run, is a cost paid many times and a secret that can leak"
    - "a new version must reach each consumer as a pull request a person reviews, not as a silent change"
    - "a public source cannot know, and must not list, who installs it"
    - "a pull request opened with the workflow token starts no workflow, so its checks would never run"
relates:
  update: core/.apm/skills/ai-sdlc-hooks/scripts/Update-AiSdlc.ps1
  pull: core/.apm/skills/ai-sdlc-hooks/scripts/New-AiSdlcUpdatePullRequest.ps1
  workflow: tools/templates/workflows/ai-sdlc-update.yml
  setup: tools/Add-AiSdlcConsumer.ps1
because:
  update: "the step that moves the refs to a new tag, installs and stages"
  pull: "the script in each consumer that opens the update pull request"
  workflow: "the scheduled workflow that runs that script in each consumer, signed in as a GitHub App"
  setup: "the onboarding script that writes the workflow into a new consumer"
---

# ADR 0002: Distribution, auth and updates on GitHub

**Status:** Accepted
**Date:** 2026-10-25
**Supersedes:** none
**Superseded by:** none

## Context

[ADR 0001](0001-ai-sdlc-is-shared-as-apm-packages.md) shares AI.SDLC as APM packages that each consumer
pins to a tag. Two questions stay open: how a consumer gets read access to the source, and how a new
version reaches each consumer.

Facts that shape the answer:

- APM needs no token for a public package on github.com. For a private source it reads
  `GITHUB_APM_PAT`, and it falls back to `gh auth token` (APM authentication docs).
- A pull request opened with `GITHUB_TOKEN` starts no new workflow run. That token can also only write
  to the repository that runs the workflow (GitHub docs on `GITHUB_TOKEN`).
- A GitHub App token can write where the App is installed. A workflow gets one per run with
  `actions/create-github-app-token`, and the token ends with the job.
- The source repository holds no private information ([ADR 0011](0011-the-public-repository-holds-no-private-information.md)).
  So nothing in it needs the repository to be private, and anyone can install it.

## Decision

**1. The AI.SDLC repository is public.** A consumer then needs no token to install it, on a machine or
in CI. The default source URL is `https://github.com/RobHofmann/AI.SDLC`.

**2. A private source uses `GITHUB_APM_PAT`.** Someone who runs AI.SDLC from a private fork sets that
variable, locally and as a secret in each consumer. Nothing in the shared files sets it. The setup
check for GitHub (`gh auth status`) is advisory and never skips `apm install`.

**3. Each consumer pulls a new version itself.** AI.SDLC keeps no list of consumers and writes to no
consumer. `New-AiSdlcUpdatePullRequest.ps1` in the core runs in the consumer. It finds the newest release
tag, takes it on the branch `ai-sdlc-<tag>` with `Update-AiSdlc.ps1`, and opens one pull request. Its
description lists what the release asks of that repository. A person does those steps and merges it, so
Checkpoint Bravo still holds ([ADR 0004](0004-two-human-checkpoints-and-one-skill-model.md)).

**4. A scheduled workflow in each consumer runs it, signed in as a GitHub App.**
`tools/Add-AiSdlcConsumer.ps1` writes `.github/workflows/ai-sdlc-update.yml`, which runs every Monday and
on demand. It gets an App token for that run, with contents and pull request rights on that one
repository. The App's client ID is the variable `AISDLC_UPDATE_APP_CLIENT_ID`, and its private key is the
secret `AISDLC_UPDATE_APP_PRIVATE_KEY`. A person who wants a release sooner runs the `update-ai-sdlc`
skill, which runs the same script.

**5. The release issue closes at the release.** Nobody knows when every consumer has updated, so the
issue cannot wait for them. An update pull request still names it, as `Refs RobHofmann/AI.SDLC#42`. The
PR-story check accepts it, because the consumer lists AI.SDLC in `tracker.acceptedRepositories` and a
closed issue with the `refined` label counts ([ADR 0010](0010-the-story-key-is-a-github-issue-number.md)).

## Consequences

**Positive:**

- No consumer keeps a token for AI.SDLC, and AI.SDLC keeps no token for any consumer.
- No list names a private repository, and someone who forks or installs AI.SDLC gets updates the same way.
- A release reaches every consumer without a hand version bump, and it still waits for a review.
- A third-party dependency in a consumer's `apm.yml` never moves with an AI.SDLC update.

**Negative:**

- Everything in the repository, its history and its pull requests is public. The private-terms gate
  is the guard ([ADR 0011](0011-the-public-repository-holds-no-private-information.md)).
- Each consumer sets up a GitHub App once: the App, its install, one variable and one secret. Until then
  its update workflow fails with a message that says what to set.
- AI.SDLC cannot see which consumer is behind. Each consumer sees its own open update pull request.

**Neutral:**

- A consumer that wants to stay on an old version does not merge the update pull request.

## Alternatives considered

1. **A private AI.SDLC repository.** Rejected because every consumer would need a token as a secret,
   on every machine and in every CI run. That gives no gain once the content is clean.
2. **AI.SDLC pushes a re-pin pull request into each consumer, from a private consumer list.** Rejected
   because one token then needs write rights on every consumer. A release also needs the list on the
   machine that runs it, and a repository not on the list never gets an update.
3. **The update workflow with `GITHUB_TOKEN`.** Rejected because a pull request it opens starts no
   workflow, so its required checks never run and it can never be merged.
4. **A personal access token in each consumer.** Rejected because it acts as a person with that
   person's full rights, and it runs out without warning. An App token is scoped and short-lived.
5. **Dependabot or Renovate.** Rejected because neither knows APM. Renovate could move the `ref:` in
   `apm.yml`, but it would not run `apm install`, so `.claude/` and `apm.lock.yaml` would not match.

## Verification

- `Update-AiSdlc.Tests.ps1` covers the tag choice and proves that only the `ref:` lines of the AI.SDLC
  source move.
- `New-AiSdlcUpdatePullRequest.Tests.ps1` covers the branch, the commit with `Refs`, the description,
  a rerun that opens nothing twice, and the close of an older update pull request.
- `tools/Add-AiSdlcConsumer.Tests.ps1` covers the update workflow it writes.
- By hand: run `apm install --frozen` in a consumer with no token set, and see it pass.
- Not covered: a run of the update workflow with a real App. That is checked on the first consumer.

## References

- `core/.apm/skills/ai-sdlc-hooks/scripts/Update-AiSdlc.ps1` - moves the refs, installs and stages.
- `core/.apm/skills/ai-sdlc-hooks/scripts/New-AiSdlcUpdatePullRequest.ps1` - the update pull request.
- `tools/templates/workflows/ai-sdlc-update.yml` - the scheduled workflow.
- APM authentication, a public package needs no token: https://microsoft.github.io/apm/consumer/authentication
- APM in CI: https://github.com/microsoft/apm/blob/main/docs/src/content/docs/integrations/ci-cd.md
- `GITHUB_TOKEN` starts no new workflow run and is limited to its repository: https://docs.github.com/en/actions/concepts/security/github_token
- A GitHub App token per run: https://github.com/actions/create-github-app-token
- Authenticating as a GitHub App installation: https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation

## Related

- [ADR 0001](0001-ai-sdlc-is-shared-as-apm-packages.md) - the packages this decision distributes.
- [ADR 0010](0010-the-story-key-is-a-github-issue-number.md) - the release issue that an update pull request names.
- [ADR 0011](0011-the-public-repository-holds-no-private-information.md) - why the repository can be public.
- [ADR index](README.md) - the list of decisions in this repository.
