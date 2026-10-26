---
story: "#1"
phase: governance
step: write-adr
intent:
  assumption: "deterministic gates and reviewer agents that must prove each serious finding are precise enough that a person does not need to watch the loop between the two checkpoints"
  decision-drivers:
    - "a stop for a person at every outward step costs more time than it saves once every quality check blocks on its own"
    - "a person must still approve what is written to the tracker, and review every pull request before it merges"
    - "Claude Code and GitHub Copilot CLI must run the same skill and agent files, so the model cannot depend on one tool"
relates:
  orchestration: core/.apm/skills/ai-sdlc-handbook/references/orchestration.md
  pattern: core/.apm/skills/ai-sdlc-handbook/references/pattern.md
  plan: core/.apm/skills/ai-sdlc-handbook/references/plan.md
  hooks: core/.apm/hooks/ai-sdlc-hooks.json
  hygiene: core/.apm/skills/ai-sdlc-gates/scripts/Check-SkillHygiene.ps1
because:
  orchestration: "the page that holds the two checkpoints, the stop list and the evidence record"
  pattern: "the workflow, knowledge and agent shapes"
  plan: "the measured facts about which folders each agent tool reads"
  hooks: "the PreToolUse entries that refuse a push to the default branch and a merge by the agent"
  hygiene: "the gate that holds the skill name and frontmatter rules"
---

# ADR 0004: The way of working runs between two human checkpoints

**Status:** Accepted
**Date:** 2026-10-24
**Supersedes:** none
**Superseded by:** none

## Context

An agent that asks for a confirmation at every outward step makes a person approve dozens of steps.
The gates already hold the quality of most of them: they block in CI and before every push
([ADR 0005](0005-the-gate-contract.md), [ADR 0006](0006-hooks-enforce-what-must-happen-every-time.md)).
What still needs a person is small: what goes into the tracker, and the review of the change.

Three more facts shape the choice:

- Claude Code and GitHub Copilot CLI both read `.claude/skills/`. Claude Code documents
  `.claude/agents/`; Copilot CLI reads it too, which a probe showed but its docs do not say
  ([plan.md](../../core/.apm/skills/ai-sdlc-handbook/references/plan.md)).
- Copilot CLI does not read the `permissions` block of `.claude/settings.json`. A rule set that only one
  tool follows makes the two tools behave differently.
- On GitHub the agent opens the pull request with the owner's `gh` login, so GitHub sees the owner as
  the author. An author cannot approve their own pull request (GitHub docs).

## Decision

**1. Two checkpoints, and nothing else stops the loop on purpose.**

| Checkpoint | When | The person confirms |
|---|---|---|
| Alpha: document ready | A story, epic, PRD, research synthesis, hypothesis, journey or triage result is finished | Creating or changing the named GitHub issues and comments |
| Bravo: change ready | Every local check is green, and the loop has pushed the branch and opened or updated the pull request | The review of the pull request, then the merge, or sending it back |

Before Bravo the loop commits, pushes the story branch and opens the pull request on its own. It never
pushes to the default branch. A run collects its updates to existing issues and shows them once.

**2. A build starts on its own only from a refined story.** The issue is open and carries the `refined`
label and a `size:<n>` label. A story without both stops the build at once.

**3. A short stop list.** The loop stops and asks when the story is unclear in a way that changes
behaviour. It stops and asks as well when the change departs from a clause or an ADR. It also stops when it does not converge,
when the scope grows, or when it needs a secret, a permission or production. A reviewer finding that
needs a design change stops it too. [orchestration.md](../../core/.apm/skills/ai-sdlc-handbook/references/orchestration.md)
holds the full list.

**4. The pull request carries an evidence record.** It lists each acceptance criterion with its test,
and every check result. It lists every review finding marked fixed or declined with the reason, and what was not
checked.

**5. Bravo on GitHub: the owner reviews and merges, and the agent never merges.** The ruleset on the
default branch asks for a pull request and for the required status checks, with zero required
approvals. The owner's merge is the approval. The agent never approves or merges a pull request, and
never closes an issue (clause C09). A `Deny-AgentMerge` check in the PreToolUse `Bash|PowerShell` hooks
refuses `gh pr merge` and a `gh api` call to a merge endpoint. Like the other hooks it fails open.

**6. Skills are addressed by a bare functional name.** A skill name says what it does, such as
`write-story` or `fix-pr-feedback`. Its lifecycle position sits in frontmatter (`phase:`, `persona:`),
so a phase move changes no name and no reference.

**7. A skill is one of two kinds.** `kind: workflow` is a step people run: its steps, gates, stop list
and hand-offs. `kind: knowledge` is how one thing is done here: short, not invocable, with a `## Sources`
section that links the page holding the full rule. There is no separate command layer, because a skill
already is the command.

**8. Agents live in `.claude/agents/`, and only `builder` edits.** Every agent has an explicit `tools`
list and a persona. Review runs in an agent with a clean context, so the author does not grade its own
work. A skill that hands work to an agent also says how to do the step without one. So the flow works
in a tool without agents.

**9. The rules live in skills and hooks, not in permission rules.** Both tools run the hooks. The
settings keep an allow list for the loop's commands and no ask or deny rule.

## Consequences

**Positive:**

- A person acts twice per piece of work instead of at every step.
- A pull request arrives with its tests, docs, ADRs and review findings in place.
- The same skill and agent files run in Claude Code and in Copilot CLI.
- The owner never has to go around a branch rule, because no approval is required.

**Negative:**

- More runs happen without a person watching. A wrong turn costs more agent time before someone sees
  it; the stop list and the limits on fix attempts bound it.
- Reviewer agents can still be wrong. The guard is proof for a serious finding and a record of declined
  findings, not certainty.
- A merge is not recorded as an approval in GitHub's review history; the merge itself is the record.
- Copilot CLI's support for `.claude/agents/` is not documented, so an update can remove it. Every
  workflow still works without agents.
- The dangerous commands rest on the stop list in the skills. The hooks and the ruleset are the only
  hard stops.

**Neutral:**

- A later option is a GitHub App that opens the pull requests. Then the owner can approve for real.

## Alternatives considered

1. **A confirmation per outward action.** Rejected because a person approved dozens of steps whose
   quality the gates already hold.
2. **A confirmation before the push and the pull request.** Rejected because the person would approve
   the same change twice. The pull request review is where the code is really read.
3. **Let the agent merge a pull request that passed every gate.** Rejected by clause C09: an agent never
   signs off for a person.
4. **A ruleset that asks for one approval.** Rejected because the author cannot approve, so the owner
   would go around the rule on every pull request. That habit later skips a check that matters.
5. **Skill names with a phase prefix, or a folder per phase.** Rejected because a skill can serve more
   than one phase, and a phase move would force a rename of every reference.
6. **Agents in `.github/agents/` with pointers in `.claude/agents/`.** Rejected because one folder is
   enough, and two copies drift.

## Verification

- `Check-SkillHygiene.Tests.ps1` and `Check-AgentHygiene.Tests.ps1` cover the name, kind and frontmatter
  rules and the agent tool lists.
- `Deny-IncompletePush.Tests.ps1` covers the refusal of a push to the default branch.
- The tests of the `Deny-AgentMerge` check cover `gh pr merge` and the `gh api` merge call.
- By hand: run one change from a refined issue to an open pull request, and check that its description
  carries the evidence record.
- Not covered by a test: the ruleset on GitHub. Check it in the repository settings.

## References

- [Orchestration](../../core/.apm/skills/ai-sdlc-handbook/references/orchestration.md) - the checkpoints, the stop list and the evidence record.
- [Skill patterns](../../core/.apm/skills/ai-sdlc-handbook/references/pattern.md) - the workflow, knowledge and agent shapes.
- [Plan](../../core/.apm/skills/ai-sdlc-handbook/references/plan.md) - which folders each agent tool reads.
- `core/.apm/hooks/ai-sdlc-hooks.json` - the hook entries.
- An author cannot approve their own pull request: https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/reviewing-changes-in-pull-requests/approving-a-pull-request-with-required-reviews
- Rulesets: https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets
- Claude Code skills and subagents: https://code.claude.com/docs/en/skills and https://code.claude.com/docs/en/sub-agents
- Copilot custom agents: https://docs.github.com/en/copilot/reference/custom-agents-configuration

## Related

- [ADR 0005](0005-the-gate-contract.md) - the gates that make the loop safe to run on its own.
- [ADR 0006](0006-hooks-enforce-what-must-happen-every-time.md) - the hooks both tools run.
- [ADR index](README.md) - the list of decisions in this repository.
