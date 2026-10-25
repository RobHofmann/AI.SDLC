## Communication

Say the main thing first: the answer, the decision, or the result. Give the reason after it, and only when the
reason changes what the reader does next. Lead with the action or the result, number the steps, and end with one
next action. Cut every word that adds nothing. Say what you assume, what can go wrong, and what you have not
checked. When a request can be read in more than one way, ask one question to make it clear before you start.
Inside a run, look up what the substrate holds. Before Checkpoint Alpha, `grilling` asks the rest in rounds, and
what the person leaves open goes to Checkpoint Alpha. In the build loop, an unclear story is a stop; any other open
point goes to Checkpoint Bravo. Write **sentences at CEFR B2 and words at CEFR B1**: one main idea per sentence,
never over 25 words. Use the word you would say in a meeting. Keep every name, number, path and code name exactly
as it is. Everything we keep is English: docs, ADRs, skills, work items, wiki pages, commits, branches, pull
requests, code and log messages. Chat follows the language the user writes in. Nothing we keep names an AI tool as
its author or helper. The full rule: `.claude/skills/ai-sdlc-handbook/references/language.md`.

## Constitution (core)

These rules never bend, in every change. Claude Code loads the full clauses through the import line below;
any other agent reads that file before it starts. A repository's own clauses live in `paths.constitution`.

@.claude/skills/ai-sdlc-handbook/references/constitution.md

## Shared AI-SDLC

The files under `.claude/` that `apm.lock.yaml` lists are installed from AI.SDLC and are read-only
here. Change one in AI.SDLC; `.claude/skills/ai-sdlc-handbook/references/layout.md` says how. A clone
is set up once with `pwsh .claude/skills/ai-sdlc-hooks/scripts/Install-AiSdlc.ps1`. The way of working
starts at `.claude/skills/ai-sdlc-handbook/references/README.md`; `guide-me` finds the next step.
