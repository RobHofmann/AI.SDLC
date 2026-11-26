---
story: "#84"
phase: governance
step: write-adr
intent:
  assumption: "a token that an agent never sees and no install writes out cannot reach a commit or a log"
  decision-drivers:
    - "apm install writes the value of a variable that an MCP server entry names into .mcp.json"
    - "an agent shell, its output and its command lines end up in transcripts and logs"
    - "the pack must work on Windows, macOS and Linux"
relates:
  set: packs/sonarcloud/.apm/skills/sonarcloud-mcp/scripts/Set-SonarMcpToken.ps1
  module: packs/sonarcloud/.apm/skills/sonarcloud-mcp/scripts/SonarMcpToken.psm1
  setup: core/.apm/skills/ai-sdlc-hooks/scripts/AiSdlcSetup.ps1
because:
  set: "the one way to store the token, with a hidden prompt and a check against SonarCloud"
  module: "where the token is stored on each system, and the state the setup row and the hook report"
  setup: "runs apm install without the token variables, so .mcp.json keeps its placeholders"
---

# ADR 0018: The SonarCloud MCP token lives in a user store

**Status:** Accepted
**Date:** 2026-11-26
**Supersedes:** none
**Superseded by:** none

## Context

The `sonarqube` MCP server of the sonarcloud pack sends the header
`Bearer ${AISDLC_SONAR_MCP_TOKEN}`. The tool that starts the server fills in the variable. Each person
set the variable by hand, in a way of their own.

Two things went wrong with that. First, an install can write the token into `.mcp.json`. APM 0.31.0 does
that when it adds or changes the server, and the shell that runs it holds the variable. The
sonarcloud package page records this, checked with APM 0.31.0. An update commit can then hold the token.
Second, a person who asks an agent to set the token types it into the session. It then stands in a
transcript, in a command line or in a log.

A hidden prompt and a check against SonarCloud are only useful when the result lands in a store that
every tool reads. On Windows that is the user scope of the environment. macOS and Linux have no such
scope: a tool reads what its parent shell set.

## Decision

**A person stores the token once, with `Set-SonarMcpToken.ps1`, in their own terminal.** The script
takes no parameters, so the token never stands on a command line or in a shell history. It stops before
any prompt when its input is redirected, as in an agent shell. It reads the token with hidden input,
checks it against `GET https://sonarcloud.io/api/users/current`, and stores it only when SonarCloud
accepts it. An agent never asks for the token, never runs the script and never prints the environment.

**The store is per system:**

- On Windows, the user variable `AISDLC_SONAR_MCP_TOKEN`.
- On macOS and Linux, the file `ai-sdlc/sonar-mcp-token` in the user config folder
  (`XDG_CONFIG_HOME`, else `~/.config`). The script creates it with mode 600 in a folder with mode 700,
  outside every repository. A line in the shell profile reads the file into the variable; the script
  prints that line, which holds no token.

**Every `apm install` of the shared scripts runs without the token variables.** `Invoke-WithoutSonarToken`
in `AiSdlcSetup.ps1` takes `AISDLC_SONAR_MCP_TOKEN`, `AISDLC_SONAR_ORG` and `SONAR_TOKEN` out of the
process for the install, and puts them back after it. `Install-AiSdlc.ps1`, `Update-AiSdlc.ps1`,
`tools/Add-AiSdlcConsumer.ps1` and `tools/Test-Consumers.ps1` use it.

**The setup and each session say when the token is missing.** The setup row "SonarCloud MCP token" is
OK or WARN, never FAIL. A `SessionStart` hook gives the agent one line when the token is not set, or
when the session did not read it. It says nothing when the token is set.

## Consequences

**Positive:**

- The token never passes through an agent, and the update pull request keeps the placeholders.
- A wrong token fails at once, with the HTTP code, instead of at the first MCP call.
- One way to set the token on every system.

**Negative:**

- A person who updates with an older `Update-AiSdlc.ps1` and the token set still gets it written into
  `.mcp.json`. The guard only works from the release that ships it. The gate `Check-McpToken.ps1`
  still fails such a commit.
- A plain `apm install` typed by hand still writes the token. The gate catches it before the push.
- On macOS, an app that is not started from a terminal does not read the shell profile. The person starts Claude
  Code or VS Code from a terminal.
- Any process of the person can read the variable. That is the same for every tool that reads an
  environment variable. It includes the shell of an agent session, so a command that prints the
  environment would show the token. Only the rule in the `sonarcloud-mcp` skill guards that today.
  A hook that refuses such a command, or a header that a helper reads when it is needed, would close it.

**Neutral:**

- `AISDLC_SONAR_ORG` is not a secret, and the script does not ask for it. It is still kept out of the
  install, because `Check-McpToken.ps1` fails on a written-out organization.

## Alternatives considered

1. **The operating system keychain (Credential Manager, Keychain, libsecret).** Rejected because the
   tool that starts the MCP server reads an environment variable, not a keychain. A keychain still
   needs a shell step that sets the variable from it, and three different APIs to keep working.
2. **`launchctl setenv` on macOS, so an app started outside a terminal sees the variable.** Rejected because it puts the token
   into the environment of every app the person starts, until the next login. Starting the tool from a
   terminal keeps it with the shell.
3. **Only Windows, as before.** Rejected because the pack is also used on macOS and Linux.
4. **Strip the variables only in the update workflow.** Rejected because a person also installs on a
   workstation, where the variable is set by design.

## Related

- [ADR 0011](0011-the-public-repository-holds-no-private-information.md) - the public repository holds
  no private information, and a token is the strictest case of it.
- [sonarcloud](../packages/sonarcloud.md) - the pack, its server and the facts about APM this decision
  rests on.
