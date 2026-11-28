---
name: code-conventions
kind: knowledge
user-invocable: false
description: >
  The code rules for every language, written once: reuse before you build, build only what the story
  needs, two scope cases, a split for a big story, comments that say why (C10), no new warning, the convention skill of each
  file type and one severity scale for every reviewer. Use when writing, planning or reviewing code in
  any language. Do NOT use for the rules of one language (its
  convention skill) or to run the gates (run-preflight).
---

# Code conventions

This is the one home of the code rules that hold in every language; the agents and build skills point
here. A convention skill of one language, such as `csharp-conventions` in the dotnet pack, adds
the rules of that language only. When a language skill and this page disagree on a shared rule, this
page wins.

## Before you write

- **Reuse before you build.** Take the first that fits: reuse what exists, extend it, and write new
  code in the style of the nearest example only when neither fits. A second copy of a helper, a
  service or a test double next to one that does the job is a finding. The detail is in
  [clean-code.md](references/clean-code.md).
- **Build only what the story needs.** Every option, parameter, setting and endpoint traces to an
  acceptance criterion. Leave out what is there "in case we need it".
- **A closed set is listed in full.** When a change branches on a fixed set of values, handle each one.
- **A decision the architecture rests on carries its ADR in the same change** (clause C01), as
  `adr-conventions` says.

## Scope: two cases

1. **The story itself needs more than the plan names.** Stop and ask; do not grow the change yourself.
2. **A finding has nothing to do with the story.** Draft a new story for it and leave the code alone.
   An agent that cannot write work items puts the draft in its report, and the calling skill hands it
   to `write-story`.

## Small pull requests

One story makes one pull request. Before the build starts, the builder checks the size of the story.
A story with more than 5 acceptance criteria is too big (ADR 0023 of AI.SDLC). So is a plan whose parts
can each ship and be reviewed on their own. In an older story that keeps the old form, the limit is 8.
Then the builder proposes a split and builds nothing until a person decides. `Check-PrSize.ps1` warns
above `pullRequest.sizeLimit` in `aisdlc.json`; no line count stops a build.

## While you write

- **Documented code, and a comment says why** (clause C10). Public and shared types and members carry
  the doc comment of their language. Inside a body, a comment says why, never what; a better name
  comes first. The full rule: [comments.md](/.claude/skills/ai-sdlc-handbook/references/comments.md).
- **A twin follows its sibling.** A new method next to a similar one mirrors its names, guards and
  control flow.
- **Branch on the exit code, not the output,** after each call to an outside tool. A tool that did not
  run must read as failed.
- **Fix the class, not only the named line.** A review finding is a sample: search the file and its
  siblings for the same pattern.

## Language skills and warnings

- **Load the skills of the files you touch,** from [skills-by-file-type.md](references/skills-by-file-type.md).
- **Leave no new warning.** Build before and after the change, and compare the warnings. Fix each
  warning in a line the change added or changed. A warning in a line you did not touch stays as it is.
  A new warning you cannot fix goes under "Not done" in the report. Never silence a warning in code or
  config, unless the language skill names that exception.

## One severity scale for every reviewer

The scale has two levels. There is no LOW: a point too small for MEDIUM is not reported.

- **HIGH:** code that no acceptance criterion asks for, unless a governing ADR in the context block
  requires it and the report quotes that line. An ADR found later does not count. The finding names
  the hunk and the criterion nearest to it. A defect is HIGH too, when the finding names the input or
  state that breaks the code, and the bad result.
- **MEDIUM:** a judgement call, such as an abstraction, a parameter or a hook that may be needed later.
  A defect without that proof is MEDIUM as well.
- A break of an ADR, a convention or a clause is `[HIGH]` for every reviewer and in the plan. The build
  loop fixes it.
- A finding that needs a design change is marked `DESIGN`. Only `[HIGH][DESIGN]` makes the calling
  skill stop and ask. A `[MEDIUM][DESIGN]` finding goes in the report, and the work goes on.

A reviewer may add its own markers, such as `ROT` or `SURPLUS`, and its own proof rules. It never
rates unasked code below HIGH, and never rates a judgement call above MEDIUM.

## A point that is not decided

A language skill may list points that the team has not decided. For such a point, a change follows
the form of the file or class it edits, and a new file follows its neighbours. A default that the
language skill names wins.

## Team facts are settings

A shared file under `core/` or `packs/` holds the meaning of a rule, an example and a public source. It
never holds a fact of one team or repository, such as an environment name, a folder name, a class
prefix or a helper name. Read each one from a setting in `aisdlc.json`, or from the repository's own
pages, such as its constitution page (`paths.constitution`). When neither holds it, ask.
`Check-PrivateTerms.ps1` blocks a shared file that names a private term.

## Sources

- [Clean code](references/clean-code.md) - the shared clean code rules in full.
- [Skills by file type](references/skills-by-file-type.md) - the convention skill and warning source of each file type.
- [Code comments](/.claude/skills/ai-sdlc-handbook/references/comments.md) - clause C10 in full.
- [Constitution](/.claude/skills/ai-sdlc-handbook/references/constitution.md) - C01, C04, C09 and C10.
- [Orchestration](/.claude/skills/ai-sdlc-handbook/references/orchestration.md) - the stop list of the build loop.
- [Layout](/.claude/skills/ai-sdlc-handbook/references/layout.md) - the `aisdlc.json` settings.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).
