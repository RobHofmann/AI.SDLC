---
name: check-pr-contract
kind: workflow
phase: cross-cutting
persona: Lead
user-invocable: false
description: >
  Check a pull request against the substrate contract before it is opened or merged. The PR
  references a dev-active GitHub issue, and a data-model or load-bearing change carries an ADR that names the story. It reads
  the PR and the substrate and reports a verdict; it never edits the PR, the story or the code.
  It never passes blind: if the substrate cannot be reached it reports blocked in a session, and the CI form exits 2 (a warning). Use when
  the intent is to verify the PR-to-substrate wiring: "check this PR references a story", "is my
  PR wired to a dev-active story", "does this data-model change have an ADR", "verify the PR
  contract before I open it", "pre-PR substrate check", or as the pre-open step of wrap-up, inside run-preflight.
  Do NOT use to run the code-analysis gates locally (Invoke-LocalGates.ps1 or run-preflight). Do NOT
  use to create or update the story (write-story) or to author an ADR
  (write-adr).
---

# Check PR contract

Owned by the **Lead** persona (contract integrity). It is an internal step: `wrap-up` and
`run-preflight` call it, and a person does not type it. It is a
reader / checker skill: see the reader shape in [pattern.md](/.claude/skills/ai-sdlc-handbook/references/pattern.md). It is the
**local, interactive** form of the substrate gates the pull request workflow runs with `GH_TOKEN` (see "The
CI form (now wired)" below). Run it in-session before opening or merging a PR. Then a missing story
reference or a missing ADR is caught at the keyboard, not later in the workflow.

**A gate that can't check the contract is not a gate.** This check never passes blind: if GitHub
cannot be read or a referenced issue cannot be resolved, it reports BLOCKED in a session. The CI form exits 2,
which the workflow shows as a warning, never as a pass.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).

## What it checks

1. **PR references a dev-active story.** The branch name, the PR title, the PR body or the issues the PR
   closes hold an issue key (`#NNNN`, or `owner/repo#NNNN` for another repository). The issue exists.
   It is dev-active: the issue carries the label in `tracker.refinedLabel` of aisdlc.json (default
   `refined`). A closed issue counts too, because work can follow a story after it closed. A key of another repository counts only when `tracker.acceptedRepositories`
   lists that repository. Its issue is read from there and must be dev-active too. An update pull
   request that takes an AI.SDLC release names the release issue of AI.SDLC this way. Any other repository is BLOCKED.
2. **A data-model or key change carries an ADR.** The domain model is the paths that match
   `tracker.dataModelPatterns` in aisdlc.json, such as domain entities or the storage model. If the change
   touches it, or makes a key architectural decision, it needs an ADR. An ADR in the ADR folder
   (`paths.adrFolder`) has `story: "<key>"` in its front matter, in quotes, because a bare `#` starts a
   YAML comment. A link from the story to an ADR alone is not enough, because the CI gate reads only the ADR files. Whether a change is key is not always mechanical: where it is unclear, this
   skill asks rather than guessing (surface, don't decide).

## Process

1. **Resolve the PR and the story.** Read the PR body. For an existing PR, read it by number with
   `gh pr view <number> --json title,body,headRefName,closingIssuesReferences`. Before the PR exists,
   read the intended body plus the branch name, since story branches start with the issue number. Pull
   out the issue key from the branch, the title, the body or the issues the PR closes, in that order.
   The gate does the same. If none of them holds one, that is the first finding.
2. **Walk the substrate (fail closed).** Resolve the story with `gh issue view <n> --json state,labels,parent,url`
   (the same in Claude Code and Copilot), and read its state, labels and links. If GitHub cannot be
   read or the key does not resolve, stop and report BLOCKED with the reason; do not pass.
3. **Look at the diff for data-model / key changes.** From the branch diff, see whether changed
   files fall in the domain-model area or otherwise mean an architectural decision. If so, look in the ADR
   folder for an ADR with `story: "<key>"` in its front matter.
4. **Assemble and return the verdict**, attention first, under ~3KB. Never edit the PR, the story, or the
   code; recommend the fix and point at the skill that writes it.

```
# PR contract check for <PR or branch>

## Attention
- BLOCKING: <no story key | story not dev-active | data-model change with no ADR | substrate unreachable>
- The specific fix and which skill applies it

## Verdict
- PASS  /  BLOCKED  - one sentence why

## Checks
| Check                          | Result        | Detail                              |
| ------------------------------ | ------------- | ----------------------------------- |
| References a story key         | PASS/BLOCKED  | <key, or "none found">              |
| Story is dev-active            | PASS/BLOCKED  | <open or closed, and the labels>    |
| Data-model change has an ADR   | PASS/BLOCKED/NA | <ADR file, or "no ADR for key">   |
```

## The CI form (now wired)

This skill is the interactive form, using the session's gh. The headless CI form is
`.claude/skills/check-pr-contract/scripts/Check-PrStoryContract.ps1`, run by the shared `ai-sdlc-pr`
action in the pull request workflow. The action sets `GH_TOKEN` to the workflow token, which can read the
issues of the repository. It takes the story key from the first of five places that holds one. In order,
that is a key passed in, the PR source branch, the PR title, the PR body, then the issues the PR closes. A key of
a repository outside `tracker.acceptedRepositories` exits 1; an accepted one is read with `gh issue view <n> -R owner/repo`. It checks
that the issue is labelled `refined`, open or closed, through `gh issue view`, and applies the domain-model -> ADR check in
the repository. An issue that does not exist exits 1. When GitHub cannot be read (no gh, no token, or no
access to the repository) it exits 2. The workflow shows that as a warning, never as a pass. Its mode is Blocking,
set in `gates.json`. The local runner (`Invoke-LocalGates.ps1`) lists
it too, where it is a no-op (no PR context). So this skill and the CI gate apply the same rule, interactively and headlessly.

## Failure modes

- **No issue key in the branch, the title or the body** -> BLOCKED. Recommend adding the `#NNNN` reference, for example
  `Fixes #1234` in the body. The CI gate `Check-PrStoryContract.ps1` fails the pull request without it.
- **Branch with no key** -> `wrap-up` step 0 stops before the pre-flight. Rename the branch
  (`git branch -m <number>-<topic>`).
- **Story not dev-active** -> BLOCKED. The issue is closed or not labelled `refined`, so it is not ready
  to be worked. Or the PR references the wrong one. A person refines or reopens it, or the reference is fixed.
- **Key of another repository that `tracker.acceptedRepositories` does not list** -> BLOCKED. Name an
  issue of this repository, or ask the owner to add that repository to the list.
- **Data-model change, no ADR** -> BLOCKED; recommend an ADR with `story: "<key>"` in its front matter
  (`write-adr`), or adding that line to the ADR that governs the change. Do not wave it through.
- **GitHub cannot be read** -> BLOCKED (fail closed), with the reason; never report PASS on an unverifiable
  contract.
- **Key unclear** -> ask the user whether the change warrants an ADR rather than guessing either
  way.

## Guardrails

- **Check, never edit.** Reports a verdict and recommended fixes; it does not edit the PR, the story, the
  ADR links, or the code.
- **Fail closed.** An unverifiable contract is BLOCKED, not PASS.
- **Surface, don't decide.** Where "is this key" is a judgement, raise it as a question.

## Observable signal

**Positive:** PRs reach the workflow already wired to a dev-active story and with an ADR that names the story.
So the CI gate (and human reviewers) find nothing to bounce.

**Audit trail:** the verdict block is the receipt for why a PR was considered contract-clean before it opened.

**Drift signal:** if PRs keep opening with no story reference, check that `wrap-up` still
calls it before the pull request opens. If data-model PRs keep missing ADRs, the data-model area heuristic needs opening up.

## Next steps

- Rename the branch to carry the issue number (`git branch -m <number>-<topic>`) before `wrap-up`; its step 0
  refuses a branch with no key. For an open pull request, put the key in its title or body with
  `Update-PullRequest.ps1` in `github-pull-requests`.
- `write-story` in update mode (any) - add the links or the ADR backlink on the story.
- `/write-adr` (Architect) - author the ADR a data-model change needs.
- Run `pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1` for the gates alone. The full pre-flight runs once, at the end of `/wrap-up`.
