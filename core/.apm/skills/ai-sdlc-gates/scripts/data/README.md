# Word lists for the reading-level check

`Check-DocReadingLevel.ps1` reads the CSV files in this folder to decide which words sit above CEFR B1.
CEFR is the Common European Framework of Reference for Languages. The rule the check serves is in
[the language page in the handbook](/.claude/skills/ai-sdlc-handbook/references/language.md).

## Files

| File | Levels | Rows | Source |
| --- | --- | --- | --- |
| `cefrj-vocabulary-profile-1.5.csv` | A1, A2, B1, B2 | 7,799 | The CEFR-J Wordlist Version 1.5, compiled by Yukio Tono, Tokyo University of Foreign Studies |
| `octanove-vocabulary-profile-c1c2-1.0.csv` | C1, C2 | 2,136 | Octanove Vocabulary Profile C1/C2, version 1.0, by Octanove Labs |
| `reading-level-allowlist.txt` | above B1 | 163 | The exact terms the shared AI-SDLC uses, merged with the repository allow list |

Both files come from the Open Language Profiles repository,
<https://github.com/openlanguageprofiles/olp-en-cefrj>, downloaded on 2026-09-17 and stored as they are.
The columns used are `headword` and `CEFR`; the other columns are kept as they were.

## Licence

- CEFR-J Vocabulary Profile: "can be used for research and commercial purposes with no charge, provided
  that you cite the dataset properly. The copyright belongs to Tono Laboratory at TUFS (Tokyo University
  of Foreign Studies)." This file and the check's help text carry that source line.
- Octanove Vocabulary Profile: Creative Commons Attribution-ShareAlike 4.0 International
  (<https://creativecommons.org/licenses/by-sa/4.0/>). The file is used as published, without changes.

Copied from the repository README on the download date. If a list is updated or replaced, update the
row above and the download date.
