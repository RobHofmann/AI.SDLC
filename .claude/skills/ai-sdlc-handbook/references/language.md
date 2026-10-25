# Language and reading level

This page says how we write, everywhere: documentation, work items, wiki pages, pull requests, and chat
with an agent. It has two rules. The first says how easy the text must be to read. The second says
which language to use. Clause C11 in the [constitution](constitution.md) makes both rules ones that
never bend.

## Rule 1: sentences at B2, words at B1

The levels come from the CEFR (Common European Framework of Reference for Languages), the scale of the
Council of Europe for language skill. It runs from A1 (beginner) to C2 (almost a native speaker). At B1
a reader knows the everyday words and can follow a simple text about work. At B2 a reader can follow a
clear, detailed text and an explanation with several steps. Source: the Council of Europe level
descriptions, <https://www.coe.int/en/web/common-european-framework-reference-languages/level-descriptions>.

We split the two on purpose. The ideas we write about are technical, so a sentence sometimes needs
an extra part. The words can still be simple.

### Sentences: B2

- One main idea per sentence. One extra part joined with "because", "which", or "when" is fine. Two are
  not.
- Aim for under 20 words. Never go over 25.
- Say who does what. "The gate fails the build", not "the build is failed by the gate".
- No brackets inside brackets. Do not join many parts with commas; the reader must see the main point at
  once.
- Join sentences with plain words: so, but, because, then, after that.

### Words: B1

- Use the word you would say to a team member in a meeting.
- Write a short form like ADR or PR out in full the first time it appears on a page. After that, use the
  short form.
- Keep the exact name of a thing. Cosmos DB, Service Bus, landing zone, and `ProblemDetails` are names,
  not hard language. Explain the name once in plain words, then keep using it.
- Easy is not unclear. Keep every number, name, file path, and code name exactly as it is.

Words to replace:

| Instead of | Write |
| --- | --- |
| utilise, leverage | use |
| commence, initiate | start |
| terminate | stop, end |
| ensure | make sure |
| obtain | get |
| require | need |
| sufficient | enough |
| additional | more, extra |
| numerous | many |
| demonstrate | show |
| facilitate | help, make it easier |
| mitigate | reduce, limit |
| load-bearing | key, the one that matters |
| regarding, with respect to | about |
| in order to | to |
| prior to | before |
| subsequently | then, after that |
| approximately | about |
| endeavour, attempt | try |

### How to check your own text

1. Read your longest sentence out loud. If you cannot follow it, split it in two.
2. Count its words. Over 25 means rewrite.
3. Look for words from the left column of the table above.
4. Check that every short form is written out in full once.

## Rule 2: English for what we keep, the user's language for chat

| Where the text lands | Language |
| --- | --- |
| `AGENTS.md`, the docs roots, ADRs, skills in `.claude/skills/` | English, always |
| The work item tracker and the wiki (for example GitHub Issues): titles, descriptions, comments | English, always |
| Commit messages, branch names, pull request title and description | English, always |
| Code, names in code, test names, log messages, script help blocks | English, always |
| Chat with an agent (Claude Code, GitHub Copilot, and the rest) | The language the user writes in |

**What we keep is English** because it stays after the conversation is over. People who did not write
it read it. Search tools must find it. Other teams get a copy. Part of those readers cannot read a page
in another language in an English wiki.

**Chat follows the user** because chat is a conversation, not a record. Nothing that stays is written
there. Answering in the user's own language makes the conversation easier and reduces the chance that the
reader gets the wrong idea.

### What that means in a chat reply

- Answer in the language of the user's message. If they switch, switch with them.
- If a message mixes languages, follow the one most of it is written in. If you cannot tell, use English.
- Never translate what you copy in. It stays exactly as it is, also inside an answer in another language.
  That covers a file path, a command, an error message, a code name, and a line copied from a work item
  or a page.
- A chat in Dutch about an English page still writes the page in English. The reply may explain the
  change in Dutch. The text that goes into the work item, the page, or the pull request is English.
- Both rules work together: a reply in another language is also written with B2 sentences and B1 words.

## Say the main thing first

This is the form the two rules take in every reply, work item and page. `AGENTS.md` carries it in short;
this is the full version.

Say the main thing first: the answer, the decision, or the result. Give the reason after it, and only
when the reason changes what the reader does next. Cut the words that add nothing: openers like "sure,
happy to help", soft words that add no fact, and any repeat of the question. Say the one fact that
matters instead of writing a paragraph around it. Say plainly and briefly what you assume, what can go
wrong, and what you have not checked. The goal is that every word adds something, not that there are as
few words as possible. Write full, short, direct sentences. Do not drop words to save space, and do not
sound rude.

These rules apply everywhere: chat replies, work items, ADRs, wiki pages, docs. The form differs, the
style does not. In chat, give a direct answer in a few sentences or a short list. Use tables, many
sections, or a step-by-step summary only when the reader asks for them or the content needs them. Report
the result; do not describe each action you took. In a document, keep the required template and fill in
every part: a story keeps its sections, an ADR its format. But keep each part short, with nothing
extra. Everywhere: give the one warning that matters, not every possible one. Aim for the length of a
good pull request comment.

When a request can be read in more than one way, ask one question to make it clear before you start.
Show the readings you see, so the person picks one instead of guessing what you meant. Inside a run,
look up what the substrate holds. Before Checkpoint Alpha, `grilling` asks the rest in rounds, and what the person
leaves open goes to Checkpoint Alpha. In the build loop, an unclear story is a stop; any other open point goes to
Checkpoint Bravo ([orchestration](orchestration.md)).

### Lead with the action

The CEFR rules above govern the words and the sentences. These rules govern the order and the
structure of a reply, so the reader can act on it at once:

- The first line of a chat reply is the result, or something the reader can do.
- A task with several steps is a numbered list, with one bounded action per step.
- End with one concrete next action, small enough to do now.
- One topic per reply. Offer a side issue separately, in one line, instead of mixing it in.
- On long work, say where you are, for example "step 3 of 5 done".
- State an error as its cause and its fix, in a matter-of-fact tone.

Three parts of the source are left out on purpose. They are a hard limit on the number of list items,
time estimates, and a switch to turn the rules on or off. A list is as long as the content needs, an
estimate from a model is a guess, and these rules always apply.

Source: adapted from the `i-have-adhd` skill, <https://github.com/ayghri/i-have-adhd>, MIT licence,
Copyright (c) 2026 Ayoub Ghriss.

Nothing that is kept names an AI tool as its author or helper. A commit, a pull request, a work item or
a page carries no "generated by" and no `Co-Authored-By` line.

## What the rules do not change

- Exact copied text, error text, and command output are copied as they are, whatever their level or language.
- Field names in an API and names in code are never simplified. Both sides of the system depend on them
  as they are.
- A technical term with no plain word for it stays. Explain it in one plain sentence the first time a page
  uses it. When several pages need the same explanation, put it in the glossary page of the repository.

## How the rule is kept

Five things hold the rule in place:

- `.claude/skills/ai-sdlc-gates/scripts/Check-DocReadingLevel.ps1` checks the markdown files under the
  reading-level roots (`paths.readingLevelRoots` in `aisdlc.json`). It reports a sentence over 25 words,
  and a word that the CEFR word lists place at B2, C1 or C2. The lists and their licence are described in
  `.claude/skills/ai-sdlc-gates/scripts/data/README.md`. It also reports every word in the table above.
  A word the lists do not know, such as a product name, is never reported. The team can accept a word
  that is the exact name of a thing in the reading-level allow list (`paths.readingLevelAllowlist` in
  `aisdlc.json`). The check runs as a blocking gate in `Invoke-LocalGates.ps1` and in the pull request
  workflow. It skips code, link targets, `[Source: ...]` source tags, index rows, and text in double
  quotes. So a quote, or an example of a word not to use, does not fail the build. It does not check
  sentence length in headings or table rows. Run
  `pwsh .claude/skills/ai-sdlc-gates/scripts/Check-DocReadingLevel.ps1 -Path docs -Detail` to see each
  finding for one folder.
- The `## Communication` part of `AGENTS.md` states both rules. Every agent loads that file in every
  session.
- Every skill in `.claude/skills/` states the rule in short in its `## Standing rules` block and links
  here for the whole of it. `.claude/skills/ai-sdlc-gates/scripts/Check-SkillHygiene.ps1` blocks a skill
  that has no such block, or whose block does not link this page. The wording lives here, so a skill
  only points.
- Clause C11 in the [constitution](constitution.md) makes the rule one that never bends.
- A person checks both rules in code review.

The check does not read meaning. It cannot see a sentence with two stacked extra parts if the sentence
is short. It does not know a short form was used before it was written out. Those two stay with the
reader and the reviewer.

## Related

- [Code comments](comments.md) - the other writing rule every change must follow, and where the
  explanation goes instead of into the code.
- [Constitution](constitution.md) - the rules that always apply, including C06 (no em-dash) and C08 (no
  names of team members). Those two are house style with an automatic check behind them.
- [Documentation wiki](docs-wiki.md) - how the documentation layers are kept linked and checked, and
  which house-style checks run.
- [Skill patterns](pattern.md) - the shape every skill follows, including the rules for what it returns.
- [Autolearn](autolearn.md) - the other standing rule every skill carries, and the level a captured
  lesson is written at.
