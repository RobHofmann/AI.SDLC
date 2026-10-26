# Third-party notices

Some shared files of AI.SDLC adapt text or carry data from open-source repositories. This page lists each one, with
its source and its licence. No code was copied.

## mattpocock/skills

Source: [github.com/mattpocock/skills](https://github.com/mattpocock/skills). MIT licence, Copyright (c)
2026 Matt Pocock.

Skills whose text we keep close to upstream. Each folder holds the licence text in
`LICENSE-upstream.md`, and a Sources section in `SKILL.md`:

| Our skill | Upstream file |
|---|---|
| `core/.apm/skills/grilling` | `skills/productivity/grilling/SKILL.md` |
| `core/.apm/skills/grill-me` | `skills/productivity/grill-me/SKILL.md` |
| `core/.apm/skills/wait-what` | `skills/productivity/wait-what/SKILL.md` |
| `core/.apm/skills/handoff` | `skills/productivity/handoff/SKILL.md` |

Files that take a method from upstream, each with a Sources line:

| Our file | What it takes | Upstream file |
|---|---|---|
| `packs/github-issues/.apm/skills/fix-bug/SKILL.md` | the feedback loop of the reproduce step | `skills/engineering/diagnosing-bugs/SKILL.md`, phase 1 |
| `packs/github-issues/.apm/skills/write-story/SKILL.md` | the vertical slices and blocking edges of an epic split | `skills/engineering/to-tickets/SKILL.md` |
| `core/.apm/skills/capture-learning/SKILL.md` | the improvement categories of the session checklist | `skills/engineering/retro/SKILL.md` |
| `core/.apm/skills/guide-me/SKILL.md` | the routing by situation | `skills/engineering/ask-matt/SKILL.md` |
| `core/.apm/skills/ai-sdlc-handbook/references/orchestration.md` | the Merge danger part of the evidence record | `skills/engineering/pr/SKILL.md` |
| `core/.apm/skills/ai-sdlc-handbook/references/pattern.md` | the description rules and the two loads | `skills/productivity/writing-for-agents/SKILL.md` and `SKILL-MECHANICS.md` |
| `packs/dotnet/.apm/skills/test-first-dotnet/SKILL.md` and `core/.apm/agents/builder.agent.md` | the seams rule and the test anti-patterns | `skills/engineering/tdd/SKILL.md` |

## humanlayer/skills

Source: [github.com/humanlayer/skills](https://github.com/humanlayer/skills), by Dex Horthy, Humanlayer.
MIT licence. The upstream `pr` skill credits its `show-me` skill, so the Merge danger part of the
evidence record credits it too.

## affaan-m/ECC

Source: [github.com/affaan-m/ECC](https://github.com/affaan-m/ECC). MIT licence, Copyright (c) 2026
Affaan Mustafa.

Files that adapt parts of ECC. Each carries this notice at its end or in its help block:

| Our file | What it takes | Upstream |
|---|---|---|
| `core/.apm/agents/architect.agent.md` | the plan and design review | the architect, code-architect and planner agents |
| `core/.apm/agents/blind-judge.agent.md` | the blind scoring of a result | the agent-evaluator agent |
| `core/.apm/agents/substrate-walker.agent.md` | the context walk | the code-explorer and spec-miner agents |
| `packs/dotnet/.apm/agents/code-reviewer.agent.md` | the code review | the code-reviewer, csharp-reviewer and silent-failure-hunter agents |
| `packs/dotnet/.apm/agents/security-reviewer.agent.md` | the security review | the security-reviewer agent |
| `packs/dotnet/.apm/agents/test-analyzer.agent.md` | the test review | the pr-test-analyzer and tdd-guide agents |
| `core/.apm/skills/ai-sdlc-hooks/scripts/Invoke-CompactSuggestionHook.ps1` | the two signals of the compact suggestion | the strategic-compact skill |

## ayghri/i-have-adhd

Source: [github.com/ayghri/i-have-adhd](https://github.com/ayghri/i-have-adhd). MIT licence, Copyright (c)
2026 Ayoub Ghriss.

The file that adapts it carries this notice under the part it adapts:

| Our file | What it takes | Upstream |
|---|---|---|
| `core/.apm/skills/ai-sdlc-handbook/references/language.md` | the "Lead with the action" rules | the `i-have-adhd` skill |

## Open Language Profiles

Source: [github.com/openlanguageprofiles/olp-en-cefrj](https://github.com/openlanguageprofiles/olp-en-cefrj).

The reading-level gate reads two word lists, stored as they were published, in
`core/.apm/skills/ai-sdlc-gates/scripts/data/`:

| File | Source | Licence |
|---|---|---|
| `cefrj-vocabulary-profile-1.5.csv` | The CEFR-J Wordlist Version 1.5, compiled by Yukio Tono, Tokyo University of Foreign Studies | Free for research and commercial use, provided that the dataset is cited. The copyright belongs to Tono Laboratory at TUFS. |
| `octanove-vocabulary-profile-c1c2-1.0.csv` | Octanove Vocabulary Profile C1/C2, version 1.0, by Octanove Labs | [Creative Commons Attribution-ShareAlike 4.0 International](https://creativecommons.org/licenses/by-sa/4.0/) |

`data/README.md` in that folder holds the source line to cite, the licence lines and the download date.

## Other sources

The handbook page `core/.apm/skills/ai-sdlc-handbook/references/plan.md` names the other sources that
shaped the design: BMAD-METHOD and ECC. The files that adapt ECC text are listed above.

## The MIT licence of mattpocock/skills

```text
MIT License

Copyright (c) 2026 Matt Pocock

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
