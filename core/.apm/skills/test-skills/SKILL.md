---
name: test-skills
kind: workflow
phase: cross-cutting
persona: Lead
description: >
  Validate the AI-SDLC skills under .claude/skills/ with the layered eval harness before relying
  on a new or changed one. Use when a skill has just been added or edited and needs checking, or
  when the user says "eval the skills", "validate this skill", "run the skill harness", "test the
  skills", "did my skill change break routing" or "check skill discriminability". This is the
  durable form of the draft-only eval harness. Do NOT use to validate the
  artifact graph or docs wiki (Invoke-LocalGates.ps1), or to author or edit a skill's content.
---

# Test the skills

Usable by **any** persona, typically Lead or Architect. Called as `/test-skills`.

A skill change is not done until it is validated. This is the sibling of the docs and graph gates in
`Invoke-LocalGates.ps1`, which validate artifacts and docs. This one validates the **skills themselves**:
their structure, how they route, and whether they add value over a good baseline. It is
description-level and behavioural validation, not whether people use them.

Run it for any skill you add or change. When you touch a description, re-run the routing layer for
the whole set. Routing is a shared space: one skill's triggers can clash with another's.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).

## The layers

| Layer | Question | Nature | How |
|---|---|---|---|
| 0 - static | Is every skill and agent structurally sound and house-style clean? | deterministic | `.claude/skills/ai-sdlc-gates/scripts/Check-SkillHygiene.ps1` and `.claude/skills/ai-sdlc-gates/scripts/Check-AgentHygiene.ps1` |
| 1 - routing | Does each skill win the prompts meant for it and avoid over-triggering? | subagent panel | independent routing judges over a prompt set |
| 2 - value | Does the skill beat a no-skill baseline on a real task? | subagent + the `blind-judge` agent | with-skill vs baseline, scored blind |
| 4 - cross-tool | Does the same SKILL.md trigger in Copilot CLI? | headless Copilot runs | `.claude/skills/test-skills/scripts/Invoke-CopilotRouting.ps1` over the Layer 1 prompt set |

There is no Layer 3 here; the layer numbers are kept as they are.

## Layer 0 - static (run first)

```powershell
.claude/skills/ai-sdlc-gates/scripts/Check-SkillHygiene.ps1 -Strict
.claude/skills/ai-sdlc-gates/scripts/Check-AgentHygiene.ps1
```

The first exits non-zero and names the skill at fault and the rule on any violation. It checks the
rules of each kind. A workflow skill needs its phase, persona, persona line and Next-steps section. A
knowledge skill needs `user-invocable: false`, a Sources section whose links resolve, and at most 120
lines. Both kinds need a name in the Agent Skills form and a trigger-rich description of at most 1024
characters. GitHub Copilot does not load a skill with a longer one. They also need the Standing
rules, no em-dash, no line-citations,
cross-refs that resolve and no plugin-style reference. The second checks every agent in
`.claude/agents/`. Each needs an explicit tool list, read-only except for the writer agent `builder`, and a known persona. A model line, when
there is one, is `opus`, `sonnet` or `inherit`, and an `opus` agent names its model in its output. Its Read first list links each preloaded knowledge skill. Fix and re-run until green before spending subagent
budget on Layers 1-2.

The pull request workflow runs this gate together with every other CA gate: docs, code, story-traits. AI.SDLC runs
the gate self-tests in its own pull request workflow. To run them all locally, use the local aggregator:
`.claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1`. Add `-IncludeToolTests` to also run the
Pester tests. It prints one pass/fail summary and exits
non-zero if any blocking gate fails, so it works as a pre-push check.

## Layer 1 - routing discriminability

Confirms each skill is the best pick for its own prompts and is NOT chosen for adjacent ones.
Only workflow skills are routing targets. A knowledge skill sets `user-invocable: false`, so nobody
types it. Leave it out of the routing set, or add it only to check that no workflow prompt lands on it.
An internal workflow skill also sets `user-invocable: false`, but it stays a routing target. The model
loads it on its description when another skill or a request needs it. A skill with
`disable-model-invocation: true` is not a routing target, because the model never starts it; leave it out.

1. **Build the routing set of pages** (what a routing agent really sees - names + descriptions):
   ```powershell
   Get-ChildItem .claude/skills -Directory | Sort-Object Name | ForEach-Object {
     $d = Get-Content (Join-Path $_.FullName 'SKILL.md') -Raw
     if ($d -match '(?m)^kind:\s*knowledge') { return }
     if ($d -match '(?m)^disable-model-invocation:\s*true') { return }
     if ($d -match '(?ms)^description:\s*>?\s*(.+?)\r?\n---') { "### $($_.Name)`n$($matches[1].Trim())`n" }
   }
   ```
2. **Write a prompt set** spanning three styles:
   - direct: the skill's own trigger phrasing;
   - paraphrased: same intent, different words;
   - adversarial keyword-bait: a prompt that contains the skill's keywords but whose true intent is a
     sibling skill. For example, "triage #42 and write it up" baits write-story but must route
     to fix-bug.

    Cover the changed
   skill's own prompts AND its boundaries with each neighbour.
3. **Dispatch independent routing judges** (3 is a good default) as subagents. Each gets the set of pages
   and the prompts and picks the single best skill (or "none") per prompt from descriptions only.
4. **Score:** the skill should win every one of its own prompts and be rejected on every bait
   prompt. A tie/loss on a bait prompt is an over-trigger to fix. Tighten the description or add an
   explicit "Do NOT use" exclusion, then re-run.

## Layer 2 - value vs baseline

Confirms the skill earns its place against a capable agent that does not have it.

1. **Run two agents on the same representative task.** Use a DRY RUN: report the plan, no live
   writes. One is **with-skill** (reads the SKILL.md). One is **baseline**: no skill, but given the
   repo conventions a real agent would have.
2. **Judge blind:** hand both plans to the `blind-judge` agent
   on Opus 5.5 (model `opus` in Claude Code, `claude-opus-5.5` in Copilot), without saying which is which. If you
   cannot run agents, ask a fresh session or a team member to judge; do not judge your own run. It scores
   both plans against a rubric. The default rubric is the five items of the `blind-judge` agent, 0 to
   2 each, out of 10.

   Adapt the rubric to the skill under test.
3. **Read the result honestly:** skills win when they enforce a rule the baseline drops; they
   tie when that rule has moved into a gate. A tie is a signal the lasting value now lives in
   the gate, not the prompt.

## Caveats (state them with results)

n is small (1 to 3 tasks, often 1 judge) - signal, not proof. Eval subagents may not inherit the
always-on `AGENTS.md` context a real session has, so baselines are slightly understated on always-on
rules. Layer 4 asks Copilot in a fresh session per prompt, so it measures the description alone, not
the skill body. Copilot also lists the knowledge skills, which Claude hides from the user.

## Layer 4 - cross-tool (Copilot CLI)

The skills are shared, so a description that routes well for Claude can still miss in Copilot. Run
the Layer 1 prompt set through GitHub Copilot CLI, one headless session per prompt:

```
pwsh .claude/skills/test-skills/scripts/Invoke-CopilotRouting.ps1 -Prompts <prompts.md> -Expected <expected.md>
```

The prompt file holds `P01: <prompt>` lines; the expected file holds `P01: <skill>` lines, with
` or ` between names when more than one is right. Run it from the repository root; it passes
`--trust-folder`, so the skills load without a saved trust entry. A miss goes in the recorded
result with its caveats, the same as a Layer 1 miss. A knowledge skill that wins a prompt is a
finding for that skill's description: add the `Do NOT use` route to the workflow skill.

Copilot refuses a skill whose description is over 1024 characters, yet the model can still name it.
So the script first reads `copilot skill list`, and prints each skill that did not load. An answer
that names such a skill is `MISS (not loaded)`. The script exits 1 when any skill did not load, even
when every answer is `OK`. Layer 0 checks the same limit,
so this only fires when Copilot adds a new reason to refuse a skill.

## Guardrails

- **Dry-run only.** Eval scenarios never perform live writes (no GitHub issue, no PR, no file mutation in the
  product). The agents report what they would do; a live write needs its own confirmation gate.
- **Record the result** in the pull request that changes the skill, dated, with the per-layer result
  and the caveats. The pull request is the lasting record; chat threads are not.
- Pairs with the docs and graph gates (artifact/doc integrity) and `update-constitution`
  (the non-negotiables a skill must respect).

## Failure modes

- **A scenario performs a live write** -> eval runs are dry-run only. A harness that creates GitHub issues or opens PRs while measuring routing turns a test run into an outward action nobody approved.
- **Two skills both match a scenario** -> that is the finding, not a tie to break. It means their descriptions cover the same ground, and a real user request could go either way. Sharpen the "Do NOT use" lines rather than picking a winner.
- **A skill routes correctly in every scenario** -> check the scenarios before celebrating. A scenario set written from the skill's own description proves the description matches itself.
- **Layer 0 fails on a skill nobody touched** -> the pattern moved, not the skill. Reconcile `pattern.md` and `Check-SkillHygiene.ps1` together; they are meant to stay in lockstep and drift silently when they do not.
- **The result stays in the chat thread** -> record it in the pull request that changes the skill, dated, with the per-layer result. An unrecorded eval cannot be compared with the next one.
- **A layer is skipped and the run is reported as passing** -> name which layers ran. A Layer 0 pass says the shape is right and nothing about whether the skill routes or helps.
- **The baseline for Layer 2 is not captured** -> without it there is nothing to compare against, and "the skill helped" becomes an impression.

## Observable signal

**Positive:** a new or edited skill is known to route on the phrasings users really type, and known not to steal requests from its neighbours. That is settled before anyone depends on it in a real session.

**Audit trail:** the dated entry in the pull request that changes the skill is the receipt, carrying the per-layer result and the caveats. It is what makes the next run a comparison rather than a fresh impression.

**Drift signal:** if skills keep landing without a harness run, the eval is optional in practice. If routing findings keep coming back between the same pair of skills, their descriptions cover the same ground by design. One of them probably should not exist.

## Next steps

- Run `pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1` to validate artifact and doc-link integrity next to skill and agent hygiene.
- If a routing or value finding needs changing a skill, edit it, then re-run this harness before relying on it.
