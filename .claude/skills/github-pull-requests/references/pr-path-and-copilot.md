# The pull request path and the Copilot review

The detail behind the `github-pull-requests` skill: how to check the pull request path before a build, and how the Copilot review is asked.

## The preflight, before the first code change

Check that a working PR path exists before you build, so the last step cannot dead-end. Try in order,
and record which one works:

1. **The helper `.claude/skills/github-pull-requests/scripts/New-PullRequest.ps1`** (entry function `New-PullRequest`),
   backed by `gh`, the normal path. First run `gh auth status` and `gh repo view`.
2. **The GitHub MCP**, only if it can really write to this repository. It runs with its own token;
   a `403` means that token lacks write access, and `gh auth login` does not fix it. Skip the MCP for repo writes then.
3. **The browser URL**, as the last fallback:
   `https://github.com/<owner>/<repo>/compare/main...<branch>?expand=1`.

## Asking Copilot for a review

`scripts/Request-CopilotReview.ps1 -Id <number>` asks Copilot for a review with
`gh pr edit <number> --add-reviewer @copilot`. It finds the last Copilot review in
`gh api repos/<owner>/<name>/pulls/<number>/reviews` and counts the lines changed since its `commit_id`
with `git diff --numstat`. It asks when 20 or more lines changed (`-MinChangedLines`), when there is no
Copilot review yet, when it cannot count, or with `-Force`. Binary files do not count. A failed request
is a warning, and the script exits 0. Run it only after your own push, so small fixes start no new round.

gh exits 0 even when GitHub drops the request, for example when Copilot code review is off for the
repository. So the script reads `reviewRequests` back, and reports a request that did not land as a warning.

The GitHub docs document the `@copilot` reviewer for `gh pr edit` and `gh pr create`
([Using GitHub Copilot code review](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/request-a-code-review/use-code-review),
[gh pr edit](https://cli.github.com/manual/gh_pr_edit)), read on 2026-11-26. They do not say whether a
request by hand works on a draft. A ruleset can also review every push; then the script and the ruleset
both ask.

A new repository sets its branch ruleset once, after the first workflow run, with `Set-BranchRuleset.ps1
-RequiredCheck <names>`. The ruleset on the default branch asks for a pull request with zero required approvals and
the named status checks. It also blocks a force push and a deletion. The owner's merge is the approval. `-WhatIf` shows the change first.

## Related

- [github-pull-requests](../SKILL.md) - the skill this page belongs to.
