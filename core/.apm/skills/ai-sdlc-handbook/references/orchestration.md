# AI-SDLC orchestration

How the work runs between two human checkpoints. It says which steps run on their own and where a person
decides. It also says when the loop stops to ask, and how the steps hand work to agents. This is the
operational companion to [the lifecycle](README.md#the-lifecycle) and [the skills](README.md#the-skills)
in the handbook README. Read those for *what* the phases and steps are, and this for *how* they are run.

## Two human checkpoints, and the loop between them

A person decides at two points: Checkpoint Alpha and Checkpoint Bravo. Everything between them runs on
its own. A human checkpoint is not a gate. A gate is a script that checks one rule the same way each
time; at a checkpoint, a person judges the content.

| Checkpoint | When | The person reviews | The person confirms |
|---|---|---|---|
| Alpha: document ready | A story, epic, PRD, research synthesis, hypothesis, journey or triage result is finished | The full draft, the persona questions and answers, the open questions, the `draft-reviewer` result | Creating or updating the named GitHub issues and comments. A document for the repository waits for Checkpoint Bravo, in the pull request |
| Bravo: change ready | Every local check is green, and the loop has pushed the story branch and opened or updated the pull request | The pull request: the diff and the evidence record in its description | Approving and merging it, or sending it back with review comments |

Up to Checkpoint Bravo nothing waits for a person. `wrap-up` commits, and the loop pushes the story branch and
opens or updates the pull request on its own. It never pushes to `main` or `master`. The agent never approves,
votes on, completes or merges a pull request, and never closes an issue or changes its `refined` label (clause C09). After the
review, `fix-pr-feedback` fixes the findings, runs every check again and pushes the update, which
comes back to Checkpoint Bravo.

### One confirmation for the GitHub issue writes of a run

A new GitHub issue always waits for the person's go on its content at Checkpoint Alpha. An
update to an existing item needs a go as well, but only one per run:

1. The run collects every update it wants to make: a description made true, the PR link, an ADR
   backlink, an issue link or a comment. It writes none of them yet.
2. At the end of the run it shows them all as one diff, grouped per item. When the run also reaches
   Checkpoint Alpha, the list joins that confirmation. Otherwise it goes with the hand-over at Checkpoint Bravo.
3. One go writes every update in the list. Each write is read back.

An update that comes up after the go waits for the next list; it never gets a prompt of its own. The
go covers only the updates the list showed, never closing an issue (C09).

The title and the description of the pull request belong to the agent. It writes them when it opens
the pull request. It updates them at any time with no prompt, so they always say what the branch
holds. The person reviews both at Checkpoint Bravo. The pull request skill of the installed pack has a script
for this. That script can change only the title and the description, never a status or a vote.

### Toward Checkpoint Alpha

1. The duplicate scan runs first. `grilling` looks up the facts that the code, the docs, the ADRs and
   the linked work items hold, through a sub-agent.
2. `grilling` runs as a panel: the `draft-reviewer` agent of the github-issues pack (Product Manager, QA and
   Analyst), the `architect` agent, and the `security-reviewer` agent of the dotnet pack (Lead). The
   main thread voices UX, and any role whose agent is not installed.
3. A fact the substrate holds is looked up, not asked. Each decision goes to the person in rounds,
   each with a recommended answer that "yes" accepts. A round is not a gate: when the person says
   "draft now", the rest go into an "Open questions" list in the draft, answered at Checkpoint Alpha.
4. After drafting, `draft-reviewer` reviews the draft blind, whatever its type, so the author does
   not grade its own draft. Without the github-issues pack, the author checks the draft against its node
   template and says so at Checkpoint Alpha.

### Toward Checkpoint Bravo

1. The `substrate-walker` agent builds the context.
2. The `architect` agent writes the plan on Opus, and the main session saves it.
3. The branch is created. Then the `builder` agent builds test-first on Sonnet, from the plan and the
   context block. Where it cannot run or cannot write files, the main session builds.
4. The tests and the local gates run until green.
5. The review agents of the installed packs review side by side, for example `code-reviewer` and
   `test-analyzer` of the dotnet pack. `security-reviewer` joins when the diff touches auth, RBAC,
   outbound calls, JS interop or request logging. Without a pack that ships review agents, the skill
   reviews the diff itself. Nothing is committed before `wrap-up`, so the diff comes from the working
   tree: `git add --intent-to-add .`, then `git diff $(git merge-base origin/main HEAD)`.
6. The findings are fixed and checked again.
7. The evidence record is written. Then `wrap-up` runs, the single owner of the steps that finish a
   change. It searches the repository for what the change left behind. It updates both doc layers
   through `write-docs`, which ends with the `docs-reviewer` agent, and runs the ADR check through
   `write-adr`. It brings the story and the pull request contract in line and runs the lessons step.
8. `wrap-up` commits, then runs `run-preflight` on that commit. The loop runs none of the steps of
   `wrap-up` itself, before or after it. A commit is not a sign-off. A green run writes a receipt for the
   tree in the receipt folder (`paths.preflightReceipts` in `aisdlc.json`, `temp/preflight` by
   default); the push hook refuses a commit without one. Then the loop pushes the story branch and opens or
   updates the pull request, with the evidence record as its description. The PR link on the story
   joins the one list of issue updates for the run.
9. The loop works the pull request feedback through `fix-pr-feedback`. It waits for the PR checks and
    for the review bots the repository runs. It fixes each failed check and each open thread,
    and pushes. It repeats until the checks pass and no bot thread is open. The bot review of the
    latest commit must also raise nothing new.
10. Checkpoint Bravo: a person reviews the pull request.

### The start condition

A build starts on its own only from a story a person has refined: the `refined` label and a
`size:<n>` label. A story without both stops the build at once, and the run says what is missing.

## Stop and ask

These are exceptions, not gates. The loop stops, says why, and waits when:

1. the story is unclear in a way that changes behaviour, and the substrate does not settle it;
2. the change would break a constitution clause, or depart from an ADR or a convention;
3. the loop does not converge. The same check fails after 3 fix attempts, or there is no progress across
   2 review rounds. Or it would need a fourth review round;
4. the scope grows beyond the story;
5. it needs a secret, a new permission, anything in production, a deployment or a dangerous command.
   A dangerous command is a force push, skipping the hooks, `gh workflow run` or a `gh ... delete`.
   So is a role assignment, a secret in a secret store, a destructive git command, or a script that
   migrates stored data. See [where the gates are enforced](#where-the-gates-are-enforced);
6. a reviewer finds a HIGH problem that needs a design change;
7. the pull request loop would need a fourth bot review round, or its wait passes 45 minutes.

A new ADR that follows an existing pattern does not stop the loop.

## The evidence record

The evidence record is the pull request description. It is drafted in the git-ignored `temp/` folder
and holds:

- each acceptance criterion with the test that asserts it;
- every check result;
- every review finding, marked fixed or declined with the reason;
- the ADRs written;
- what was not checked, for example "not deployed to dev";
- whether each review ran in an agent or inline;
- a **Merge danger** part: the door and the blast radius, as below.

The Merge danger part tells the person at Checkpoint Bravo how careful the merge must be:

```markdown
## Merge danger

**Door:** one-way or two-way

<optional: why>

**Blast radius:** <one word>

<optional: what the merge could break>
```

A two-way door can be walked back: a revert undoes it. A one-way door cannot, for example a data
migration, a deleted resource, a published contract or a change of a secret. A pull request that is
cheap to roll back is lower risk. The blast radius is how far the change can reach, such as one page,
every consumer of an API, or a shared workflow. Think of every way the merge could hurt, not only the
one the change is about.

Declined findings are recorded so the person at Checkpoint Bravo sees the triage instead of doing it. An AI review
in the pipeline that posted findings with no triage was removed for that reason: the person had to sort
every finding again.

The Merge danger part comes from the `pr` skill in [mattpocock/skills](https://github.com/mattpocock/skills)
(MIT licence, Copyright (c) 2026 Matt Pocock). That skill credits the `show-me` skill of Dex Horthy,
Humanlayer ([humanlayer/skills](https://github.com/humanlayer/skills), MIT licence).

## Where the gates are enforced

The gates live in the skills and in this page, not in permission rules. Copilot CLI does not read the
`permissions` block of `.claude/settings.json`. A probe in a throwaway repository on 2026-09-23 showed
that its own tool approvals decide. Claude Code does apply the rules. One rule set that only one
tool follows gives the two tools different behaviour, so the settings hold no ask or deny rule.

What stays in `.claude/settings.json` is not enforcement:

- **allow:** the commands each installed package lists in its `gates.json`, which
  `Sync-AllowRules.ps1` writes ([layout](layout.md#allow-rules-come-from-the-packages)). A repository
  may add its own rules. An allow rule only saves a person from a prompt per command.
- **the push hook** `.claude/skills/ai-sdlc-hooks/scripts/Deny-IncompletePush.ps1`, which both tools run.
  It refuses a push to `main` or `master`, including a bare push while on `main`. It also refuses a
  push that leaves tests or docs behind, and a push whose commit has no green pre-flight receipt. A push
  that sends nothing new needs no receipt. Each pushed ref is a delete, or its commit is already on
  the remote it goes to. A release tag is an example. A branch policy on
  `main` should refuse a direct push on the server as well.

The commands that must never run unseen are on the stop list above, item 5:

- a force push, and a push or commit that skips the hooks;
- `gh workflow run` and any `gh ... delete`;
- role assignments, secrets and keys in a secret store, deployments and app config;
- the destructive git commands (`reset --hard`, `clean`, `branch -D`, a forced switch);
- any script that migrates stored data.

The agent stops and asks in chat before any of them. Voting on, completing or merging a pull request is never done by an agent (clause C09).

On GitHub the agent opens the pull request with the owner's `gh` login. So GitHub sees the owner as
the author, and the owner cannot approve it. So the ruleset on the default branch asks for a pull
request and the required status checks, with zero required approvals. The owner's merge is the
approval. The hook `Deny-AgentMerge` refuses `gh pr merge` and a `gh api` call to a merge endpoint, so
the agent never merges.

## The pull request feedback loop

When the github pack is installed, two scripts in
`.claude/skills/github-pull-requests/scripts/` run the loop, and a third waits for any other
workflow run. All three use the `gh` login (`gh auth status`):

| Script | What it does |
|---|---|
| `Get-PullRequestFeedback.ps1 -Wait` | Waits for the PR checks and the review bots, then lists the open review threads and comments by source: a bot (a login that ends in `[bot]`, such as `sonarqubecloud[bot]`), gitleaks or a person. With `-ReturnOnReview` it returns `review` as soon as the bot threads of the round are there, so the loop fixes them while the checks run |
| `Reply-PullRequestThread.ps1` | Answers a review thread and resolves a thread tagged `sonarcloud` or `gitleaks`; it never resolves a thread a person started, or a thread of any other bot (C09) |
| `Wait-WorkflowRun.ps1 -Wait` | Waits for any other workflow run, such as a release, and stops when a run waits for a person's approval |

A bot finding is fixed, or declined with the reason in the reply and in the evidence record. A person's
thread gets a reply that names the fix, and that person resolves it at Checkpoint Bravo.

## Hand-offs to agents

A workflow skill hands review and context work to one of the agents in `.claude/agents/`. Claude Code,
Copilot CLI and Copilot in VS Code all read that folder. Neither tool promises to start an agent, so
every hand-off names the fallback in the next sentence:

> Hand the review to the `code-reviewer` agent on Sonnet 5.5 (model `sonnet` in Claude Code,
> `claude-sonnet-5.5` in Copilot). If you cannot run agents, load the `csharp-generation-smells` skill
> and do the review yourself.

In GitHub Copilot CLI the model in the hand-off is not optional. Its `task` tool refuses an agent whose
file says `opus` or `sonnet` when the call passes no model, so the agent does not run at all. With
`claude-opus-5.5` or `claude-sonnet-5.5` passed, it runs on that model.

Some agents come from a pack: `draft-reviewer` from the github-issues pack, and `code-reviewer`,
`test-analyzer` and `security-reviewer` from the dotnet pack. In a repository without that pack the
agent is not there, so the skill takes the fallback in the same way.

Every agent is read-only except `builder`, which writes code and tests and nothing else. A reviewer
that can write is no longer independent. The builder exists so the build step runs on a chosen model,
whatever the model of the session is. The skill that called an agent does every other write, and the
evidence record says whether each step ran in an agent or inline. The shape of an agent is in
[pattern.md](pattern.md#the-agent-shape). Each agent names its model, `opus` or `sonnet`, and each hand-off names
it too. The table and the reason, also for the skills, are in
[pattern.md](pattern.md#the-model-of-each-step). The session model matters less now: Sonnet is enough
for the main session, because the heavy steps run on their own model.

## Parallel vs sequential: the independence rule

Two steps may run side by side only when they are really independent:

- neither consumes the other's output, and
- they do not write the same artifact (file, spec, or work item).

Independent, for example:

- `write-research-summary` and `draw-customer-journey` - different artifacts, no data dependency.
- `code-reviewer` and `test-analyzer` (dotnet pack) on the same diff - both only read.
- implementing two separate end-to-end slices of one story.

Dependent, so they run one after the other, for example:

- `write-api-spec` (dotnet pack) then `implement` - the build consumes the spec.
- the build of `implement` then `wrap-up`, whose pre-flight runs the tests on the new code.
- any two steps that write the same file or the same GitHub issue.

The phase order (discovery, elaboration, create, mature) is itself a sequence. Work runs side by side
*within* a phase or across really independent branches, never by skipping a dependency. On a tool
that cannot run agents side by side, the same steps run one after the other and give the same result.

## Aggregation and failure

When steps run side by side, the orchestrator waits for all of them. Then it reports each result (done,
blocked, or needs a decision) and the one next step. A blocked or failed step is reported with its
reason, never dropped. A failure that hits the stop list stops the loop; any other failure is fixed
inside the loop and recorded in the evidence record.

## Related

- [README.md](README.md#the-lifecycle) - the phases and the skills this runs over.
- [pattern.md](pattern.md) - the workflow, knowledge and agent shapes.
- [personas.md](personas.md) - the roles the agents speak for.
- [artifact-graph.md](artifact-graph.md) - the edges `guide-me` reads to decide what is next.
- [constitution.md](constitution.md) - clause C09, the sign-off that stays with a person.
- [Your first story](first-story.md) - what a person checks at Checkpoint Alpha and Checkpoint Bravo, on a first small story.
