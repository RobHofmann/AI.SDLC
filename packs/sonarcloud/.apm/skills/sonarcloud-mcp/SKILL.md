---
name: sonarcloud-mcp
kind: knowledge
user-invocable: false
description: >
  How to read SonarQube Cloud through the sonarqube MCP server that the sonarcloud pack installs: the
  quality gate, the issues and the rules of the project of this repository. Each person sets their own
  token in AISDLC_SONAR_MCP_TOKEN and the organization in AISDLC_SONAR_ORG, and only the placeholders go
  in a committed file. Use when a SonarQube Cloud quality gate fails,
  when a pull request has SonarQube Cloud comments, when a rule such as S3776 needs checking, or when the
  MCP server does not answer or the gate Check-McpToken.ps1 fails.
---

# SonarQube Cloud through the MCP server

The sonarcloud pack installs one MCP server, `sonarqube`, in `.mcp.json`. It talks to the SonarQube Cloud
MCP endpoint `https://api.sonarcloud.io/mcp`. An agent loads this skill when it needs the analysis of
this repository. That is why the quality gate failed, which issues a branch has, or what a rule asks.
The project key and the organization of the repository are `sonarcloud.projectKey` and
`sonarcloud.organization` in aisdlc.json.

SonarQube Cloud analyses the GitHub repository and writes its result on the pull request. On the Free
plan it analyses the main branch and the pull requests that target it, not other branches. So ask for
the analysis of a pull request or of main, never of a feature branch.

## Set up your token once

- Make a token in SonarQube Cloud: My Account, Security. It has the rights of your own account.
- Set it as the user environment variable `AISDLC_SONAR_MCP_TOKEN` on your machine.
- Set the user environment variable `AISDLC_SONAR_ORG` to the organization key, the same value as
  `sonarcloud.organization`. The server sends it in the `SONARQUBE_ORG` header. The dotnet
  pre-flight (`-IncludeSonar`) reads `SONAR_TOKEN`, so set that one too when you run the scan.
- Start Claude Code again in the repository, and approve the `sonarqube` server when it asks.
- The name is the same for everyone. A rename in `.mcp.json` makes every person change their variable,
  so the gate `Check-McpToken.ps1` fails on any other name.
- The server does not use `SONAR_TOKEN`. Claude Code treats that name as a secret, and fills it in as an
  empty value in an MCP config. The server then answers HTTP 401 "SonarQube token required".

## Only the placeholders go in a committed file

- `.mcp.json` holds `Authorization: Bearer ${AISDLC_SONAR_MCP_TOKEN}` and `SONARQUBE_ORG: ${AISDLC_SONAR_ORG}`.
  The tool fills in the values when it starts the server, so the file is the same on every machine.
- apm install fills it in too. When `AISDLC_SONAR_MCP_TOKEN` is set in the shell that runs `apm install` or
  `Update-AiSdlc.ps1`, APM writes the real token into `.mcp.json`. It does the same with
  `AISDLC_SONAR_ORG`. It does this when it first adds the server, and again when the pack changes the server.
- The gate `Check-McpToken.ps1` fails the build when the `sonarqube` server sends anything but the
  placeholder, or a written-out organization in `SONARQUBE_ORG`, and never shows the value. It also fails when the value of `AISDLC_SONAR_MCP_TOKEN` or
  `SONAR_TOKEN` stands anywhere in `.mcp.json`, `.github/mcp.json` or `.vscode/mcp.json`. That second
  check needs the variable to be set in the shell that runs the gate. A file that git ignores is skipped.
- `pwsh .claude/skills/sonarcloud-mcp/scripts/Check-McpToken.ps1 -Fix` writes the placeholders back.
  Run it before you commit an update.

## Read the analysis

- Ask the server for the quality gate of the branch or the pull request first. It names the conditions
  that failed, such as new issues or coverage on new code.
- Then ask for the issues of that branch, filtered by rule or by file. Fix the issue in the code, or
  in AI.SDLC when the file is a shared one under `.claude/`.
- A shared file under `.claude/` is left out of the analysis of a consumer (`sonar.exclusions`).
  AI.SDLC runs no SonarQube Cloud analysis of its own; its tests and gates check the shared files.

## The mistakes that really happen

- **A token committed with an update.** `Update-AiSdlc.ps1` ran with `AISDLC_SONAR_MCP_TOKEN` set, and the diff
  of the update held `.mcp.json` with the value. Run the gate with `-Fix`. When the token was pushed,
  revoke it in SonarQube Cloud and make a new one; a commit in history keeps it.
- **The server does not answer.** Claude Code was started before `AISDLC_SONAR_MCP_TOKEN` was set, or the server
  was not approved. Set the variable, start Claude Code again and approve the server.
- **HTTP 401 "SonarQube token required", with a valid token.** The header still names `SONAR_TOKEN`,
  which Claude Code fills in as an empty value. The gate fails on it; run it with `-Fix`.
- **"Not authorized or project not found".** The token belongs to an account without rights on the
  project, or the key is wrong. Check the key in aisdlc.json against the project in SonarQube Cloud.
  Check that `AISDLC_SONAR_ORG` holds the organization key too.
- **No analysis for a feature branch.** The Free plan analyses only main and the pull requests that
  target it. Open the pull request, or read the analysis of main.
- **A repository with its own `sonarqube` server.** APM does not change a server of the same name that
  is already in `.mcp.json`. Change its header to `Bearer ${AISDLC_SONAR_MCP_TOKEN}` by hand, or run the gate with `-Fix`.

## Sources

- [Layout of the shared AI-SDLC](/.claude/skills/ai-sdlc-handbook/references/layout.md) - the
  `sonarcloud` fields of aisdlc.json, and why the installed files stay out of a consumer's analysis.

## Standing rules

Two rules hold in every run of every skill, and each is defined in one place:

- **Language.** Everything we keep is English, at CEFR B2 sentences and B1 words; chat follows the
  language the user writes in. See [language conventions](/.claude/skills/ai-sdlc-handbook/references/language.md).
- **Autolearn.** A lesson from this session that would change a future run goes to its durable home,
  proposed and never written in silence. See [autolearn](/.claude/skills/ai-sdlc-handbook/references/autolearn.md).
