# Questioning methods

A chosen set of questioning methods the `grilling` skill draws on. They are adapted from the method
registry in bmad-code-org/BMAD-METHOD (`src/core-skills/bmad-advanced-elicitation/methods.csv`), and
narrowed to the ones that earn their place in this SDLC. The skill picks the one or two methods that fit the work and the
gap, it does not run all of them. Pick by what is uncertain, not by habit.

Each method names when it is the right tool and which persona most naturally wields it.

| Method | Use when | Wielded by | Shape |
|---|---|---|---|
| Targeted gap questions | The default. The user gave a partial brief and you need the missing specifics. | the owning persona | find what is unstated, ask only that |
| First principles | A request is framed as a solution and you suspect the real need is different. | Architect, PM | strip assumptions, rebuild from the real need |
| Five whys | A stated reason feels shallow and the real driver is one or two layers down. | PM, Analyst | ask why repeatedly until the root reason surfaces |
| Pre-mortem | The work is large or a risk and you want failure modes before committing. | QA, Architect, Lead | imagine it shipped and failed, ask what went wrong |
| Edge-case hunter | Acceptance criteria cover the happy path only. | QA | enumerate empty, equal, boundary, unaffected, error |
| Red team | A security, data, or auth surface is touched and you want it attacked. | Lead, Architect | try to break, misuse, or go around the proposed design |
| Devil's advocate | A choice looks obvious and nobody has argued the other side. | Architect | argue the opposing approach to test the decision |
| Approach comparison | More than one realistic technical path exists. | Architect | lay out the paths, name the forces that decide between them |
| Stakeholder round table | The work spans roles and the tradeoffs between them are unclear. | PM + Architect + QA | each role states its concern, then reconcile |
| Limit mapping | Scope is fuzzy and in/out of scope is not pinned. | PM | list what is in, what is out, what is explicitly deferred |
| Socratic | A claim is asserted as fact and you want it grounded. | Analyst, Lead | question the claim until it is evidenced or reframed as an assumption |

## How methods combine with depth

The story-point bands in `grilling` decide how many methods run and how many personas speak:

- **2 or 3 points:** targeted gap questions only, from one or two personas.
- **5 points:** targeted gap questions plus one fitting method (often edge-case hunter or approach
  comparison), from two or three personas.
- **8 points or more:** a short round table plus one or two methods chosen for the work. 13 points or a
  migration adds a pre-mortem or red team pass.

## Attribution

The method set is adapted, not vendored, from BMAD's `bmad-advanced-elicitation` methods registry. BMAD is
credited as inspiration; no BMAD code or files are copied into this repo.
