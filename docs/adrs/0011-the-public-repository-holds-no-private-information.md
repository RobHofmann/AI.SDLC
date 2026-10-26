---
story: "#1"
phase: governance
step: write-adr
intent:
  assumption: "a gate that reads a private list of patterns from outside the repository, and never prints a match, can keep a public repository free of private facts without publishing what it looks for"
  decision-drivers:
    - "a public repository publishes its files, its history, its branch names and its pull requests"
    - "even a list of patterns says something about what it guards, so the list cannot live in the repository"
    - "public CI logs mean a gate that prints its match publishes the very thing it guards"
relates:
  gate: core/.apm/skills/ai-sdlc-gates/scripts/Check-PrivateTerms.ps1
  config: core/.apm/skills/ai-sdlc-gates/scripts/AiSdlcConfig.psm1
  gates: core/.apm/skills/ai-sdlc-gates/gates.json
  learning: core/.apm/skills/ai-sdlc-handbook/references/autolearn.md
because:
  gate: "the gate that scans for private terms and prints only file, line and rule number"
  config: "the module that reads visibility, privateTermsFile and knowledgeRoot"
  gates: "the core gate list where the private-terms gate is Blocking"
  learning: "the route table that sends a rule here and a fact to the knowledge repository"
---

# ADR 0011: The public repository holds no private information

**Status:** Accepted
**Date:** 2026-10-24
**Supersedes:** none
**Superseded by:** none

## Context

AI.SDLC is public ([ADR 0002](0002-distribution-auth-and-updates-on-github.md)). Everything in it is
public: the files, the history, the commit messages, the branch names, and the pull request titles and
bodies. A shared file that names a server, a domain, a person or a private repository publishes it.

There are three reasons to split rules from facts, and they hold even for a private repository:

- A skill that knows one server is a skill nobody else can use, the owner included on the next server.
- Facts go stale faster than rules. A stale fact in a shared skill misleads every consumer at once.
- The split makes each kind of content easy to find: the process in one place, the facts next to what
  they describe.

A gate needs a list of what to look for. That list itself says something, so it cannot be in the
repository. CI logs of a public repository are public too.

## Decision

**1. Process here, facts elsewhere.**

| Content | Home |
|---|---|
| The process, skills, agents, hooks, gates and handbook | AI.SDLC (public) |
| Facts about one project: its config, docs and ADRs | That project's repository |
| Facts that span projects, shared decisions, knowledge notes | The private knowledge repository ([ADR 0013](0013-docs-that-span-projects-live-in-a-knowledge-repository.md)) |
| The private term list | The knowledge repository, at `ai-sdlc/private-terms.txt`, and one Actions secret |

Examples use made-up names, such as `Contoso`, `PROJ`, `contoso/portal`, `#42` and `server01`.

**2. One gate, `Check-PrivateTerms.ps1`, in the core.** It is Blocking in the core `gates.json`, under
clause `AI-SDLC`. It runs when `visibility` in `aisdlc.json` is `public`, or with `-Force`. Otherwise it
exits 0 and says the repository is private. In GitHub Actions it also reads the event of the run, but
only for the checked-out repository (`GITHUB_WORKSPACE`). When GitHub says that repository is public,
the gate checks it whatever `visibility` says, and a wrong `visibility` fails the build. So a public
consumer cannot skip the gate by a setting nobody changed.

**3. The list lives outside the repository.** The gate takes the first list it finds: `-TermsFile`, the
environment variable `AISDLC_PRIVATE_TERMS`, `paths.privateTermsFile`, then
`<knowledgeRoot>/ai-sdlc/private-terms.txt`. A list holds one regular expression per line, with `#`
comments. In CI the list comes from the `AISDLC_PRIVATE_TERMS` secret.

**4. It checks more than the files.** It scans every tracked file and staged new file, and skips binary
files. It also scans the commit messages since the base, the branch name, and the pull request title and
body, because those are public too.

**5. It never prints what it found.** A finding is printed as `<file>:<line>  rule <n>`, where `n` is the
line number in the list. An invalid entry is `rule <n> is not a valid regular expression`. The matched
text and the rule text never appear, locally or in CI. Then one `FIX:` line.

**6. It fails closed in every public repository in CI.** No list is exit 2, "could not check"
([ADR 0005](0005-the-gate-contract.md)), on a machine and in a private repository. In GitHub Actions, a
repository that GitHub says is public fails with exit 1 instead, because it must never pass unchecked.
The one exception is a pull request from a fork. It gets no secrets, so it warns with exit 2. The owner
then runs the gate by hand before the merge. AI.SDLC runs the gate with `-Required`, so a missing list
is exit 1 there in every case, its pre-push hook and fork pull requests included.

**7. Lessons are routed by kind.** `capture-learning` sends a rule about the way of working to AI.SDLC
as a pull request. It sends a fact about how a system behaves to the knowledge repository. The gate is the
backstop for a lesson that carries a private name.

## Consequences

**Positive:**

- The public repository holds only the check itself. Every private fact lives in one private place.
- A finding never gets out through a public log.
- A public consumer gets the same check in CI, even before anyone sets `visibility: public`.

**Negative:**

- GitHub passes no secrets to a workflow run from a fork. So the gate cannot run in CI on an outside
  contribution. The owner runs it locally before merging such a pull request.
- The gate protects only what the list names. A new private term must go on the list first.
- Someone else who installs AI.SDLC gets no protection until they write their own list.
- A finding names only a rule number, so the reader opens the private list to see which term it was.

**Neutral:**

- gitleaks still runs for secrets in the shared CI step; this gate is about names, not secrets.

## Alternatives considered

1. **A term list in the repository.** Rejected because even a list of patterns tells a reader what it
   guards.
2. **A gate that prints the matched term.** Rejected because a public CI log would then publish it.
3. **Exit 2 when the list is missing, also in AI.SDLC.** Rejected for AI.SDLC itself, because a warning
   lets the public repository pass with nothing checked.
4. **Keep the repository private instead.** Rejected because every consumer would then need a token
   ([ADR 0002](0002-distribution-auth-and-updates-on-github.md)), and the split of rules and facts is
   good design anyway.

## Verification

- `Check-PrivateTerms.Tests.ps1` covers the list order, the skip on a private repository, exit 2 and
  `-Required`. It also covers a run in GitHub Actions with a fake event file. The cases are a wrong
  `visibility`, no list, a fork pull request, and an event for another folder. It covers the commit message, branch and pull request scan, and an invalid entry. It also checks that no output
  line holds the matched text. The tests use made-up terms only.
- By hand: run the gate in AI.SDLC with the real list before a release, and see zero findings.

## References

- `core/.apm/skills/ai-sdlc-gates/scripts/Check-PrivateTerms.ps1` - the gate.
- `core/.apm/skills/ai-sdlc-gates/gates.json` - its mode.
- [Autolearn](../../core/.apm/skills/ai-sdlc-handbook/references/autolearn.md) - the route table for lessons.
- Secrets are not passed to a workflow triggered from a fork: https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets
- Workflow logs of a public repository can be read by anyone who is logged in to GitHub: https://docs.github.com/en/actions/how-tos/monitor-workflows/use-workflow-run-logs

## Related

- [ADR 0002](0002-distribution-auth-and-updates-on-github.md) - why the repository is public.
- [ADR 0013](0013-docs-that-span-projects-live-in-a-knowledge-repository.md) - the knowledge repository that holds the facts and the list.
- [ADR index](README.md) - the list of decisions in this repository.
