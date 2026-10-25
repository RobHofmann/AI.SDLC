# Does the workflow deliver?

The skill usage report says which parts of the workflow a team runs. This page answers the other
question: does the work reach the main branch faster and with less waiting than before. The script
`.claude/skills/github-pull-requests/scripts/Get-PrMetrics.ps1` answers it from the pull requests
GitHub already holds. It reads the repository from `github.repository` in aisdlc.json, or from the git remote.

```bash
pwsh .claude/skills/github-pull-requests/scripts/Get-PrMetrics.ps1              # the weekly table, last 90 days
pwsh .claude/skills/github-pull-requests/scripts/Get-PrMetrics.ps1 -Days 30     # a shorter window
pwsh .claude/skills/github-pull-requests/scripts/Get-PrMetrics.ps1 -Detail      # plus review wait and rework (one API call per PR)
```

It needs `gh auth login` and nothing else. It writes nothing anywhere.

## Why this report exists

The DORA reports of 2025 and 2026 find the same pattern in team after team. The output of one person
rises with agent help, while the delivery of the team stays flat. The reason is that the wait moves:
code is written faster, so more of it waits for review. A team that counts only what it produces cannot
see that happen.

So this report counts the things that move when delivery really gets better. It counts them per week
for the team, never per person.

## What each column means

| Column | Meaning |
| --- | --- |
| `Merged` | pull requests merged into the main branch that week |
| `LeadHours` | median hours from opening the pull request to merging it |
| `LeadHoursP75` | the same at the 75th percentile, which shows the slow cases the median hides |
| `ReviewedHours` | median hours from opening to the first review or comment by a person other than the author; bots do not count |
| `Rework` | median number of iterations after the first; a new iteration is a commit dated after opening |
| `Abandoned` | pull requests closed without a merge that week |

`ReviewedHours` and `Rework` are empty without `-Detail`, because they cost an API call per pull
request. The report says so, so that a blank column is not read as zero.

## What it does not measure, on purpose

- **A person.** There is no author column and there will not be one. The unit is the week of the team.
  A count of merged pull requests per person measures typing, not delivery, and it pushes people in the
  wrong direction.
- **The full lead time.** The clock starts when the pull request opens, not at the first commit, so
  `LeadHours` is a floor. Reading the first commit of every branch costs an API call per pull request,
  for a number that moves the same way.
- **Whether an agent wrote it.** Nothing labels a pull request that way, so the report cannot split work
  with an agent from work without one. Do not read a drop as proof of either.
- **Quality.** The gates, the coverage ratchet and SonarCloud answer that. A week with a low lead time
  and a rising `Rework` is a week where review does its job.

## How to read it

One reading is noise. A single big change, a holiday week, or one pull request left open over a weekend
moves every number. Read it monthly, look at three months together, and look at the shape rather than
at any one week. Keep the first reading as the baseline that later readings are compared against.

Two patterns are worth acting on:

- **`Merged` rises while `LeadHours` rises with it.** The team starts more work than it can review. That
  is the DORA finding in the team's own numbers, and the answer is review capacity, not more output.
- **`Rework` rises while `ReviewedHours` stays flat.** Reviews come quickly but send work back. That
  points at what happens before the pull request: the plan, the tests, or the story.

## Before and after the two human checkpoints

The way of working lets the work run on its own between two human checkpoints, with reviewer agents in the
loop (see [orchestration](/.claude/skills/ai-sdlc-handbook/references/orchestration.md)). Its riskiest assumption
is that those agents are precise enough to trust without a person watching each step. `Rework` tests it:
if the agents let defects through, reviewers send more work back after the pull request opens.

Take a "before" reading with `-Detail` over the 60 days up to the change:
`pwsh .claude/skills/github-pull-requests/scripts/Get-PrMetrics.ps1 -Days 60 -Detail`. Take the
"after" reading the same way once two months of pull requests have run under the two human checkpoints. Compare the
shape, not one week. A rising `Rework` with a flat `ReviewedHours` points at the reviewer agents or at
the stop list.

## Related

- [Which skills we use](/.claude/skills/ai-sdlc-handbook/references/skill-usage.md) - the other half: which parts of the workflow run at all.
- [The github-pull-requests skill](../SKILL.md) - the `gh` rules this script follows.
- [Orchestration](/.claude/skills/ai-sdlc-handbook/references/orchestration.md) - the two human checkpoints this report tests.
