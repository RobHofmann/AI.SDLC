---
units:
  - packs/sonarcloud
---

# sonarcloud

The `packs/sonarcloud` unit gives an agent session in a repository read access to its SonarCloud
analysis. It installs the `sonarqube` MCP (Model Context Protocol) server, and a gate that keeps the
token of each person out of the repository.

## What it contains

| Part | Kind | What it does | Used by |
|---|---|---|---|
| `sonarqube` server | MCP server in `apm.yml` | The SonarCloud MCP endpoint `https://api.sonarcloud.io/mcp`, with the header `Authorization: Bearer ${AISDLC_SONAR_MCP_TOKEN}` | Claude Code, through `.mcp.json` |
| `sonarcloud-mcp` | knowledge skill | How to set up the token and read the quality gate, the issues and the rules | the model, when a quality gate fails or a pull request has SonarCloud comments |
| `Set-SonarMcpToken.ps1` | script a person runs | Asks for the token with hidden input, checks it with SonarCloud, and stores it: the Windows user variable, or a file with mode 600 in `~/.config/ai-sdlc/` on macOS and Linux | a person, once, in their own terminal; never an agent |
| `SonarMcpToken.psm1` | module | Says whether the token is in this process, only in the user store, or missing, and never returns the value | the set script, the setup row and the hook |
| `Initialize-SonarCloud.ps1` | setup step | The "SonarCloud MCP token" row of `Initialize-AiSdlc.ps1`: OK or WARN, never FAIL | `Initialize-AiSdlc.ps1`, through `setup` in `gates.json` |
| `Invoke-SonarTokenHook.ps1` | `SessionStart` hook | Gives the agent one line when the token is missing or the session did not read it | Claude Code and GitHub Copilot CLI, through `.claude/settings.json` |
| `Check-McpToken.ps1` | Blocking gate | Fails when the `sonarqube` server does not send exactly `Bearer ${AISDLC_SONAR_MCP_TOKEN}`, or when the value of `AISDLC_SONAR_MCP_TOKEN` or `SONAR_TOKEN` stands in an MCP file. `-Fix` writes the placeholder back | the local gates and the pull request workflow |

The skill lives at `packs/sonarcloud/.apm/skills/sonarcloud-mcp/SKILL.md`, with the gate in its
`scripts/` folder. `apm.yml` lives at `packs/sonarcloud/apm.yml`.

## How the server gets into a repository

APM reads the server from `dependencies.mcp` in the `apm.yml` of the pack. A consumer lists the pack
as a direct dependency, so APM trusts the server without `--trust-transitive-mcp`. It writes the server
into `.mcp.json` for the `claude` target, and records it under `mcp_configs` in `apm.lock.yaml`.

These facts were checked with APM 0.31.0:

- APM writes the server on the first install, when `.mcp.json` lacks it, and when the pack changes it.
  At any other install it reports "already configured" and leaves the file alone.
- APM leaves a server of the same name that the repository had before alone, so an old `sonarqube`
  entry stays until a person changes it. The gate names it.
- APM does not list `.mcp.json` in `deployed_files`, so `Check-SyncManifest.ps1` does not check it.
  The gate of this pack does.
- When `AISDLC_SONAR_MCP_TOKEN` is set in the shell that runs the install, APM writes its value into
  `.mcp.json` in place of `${AISDLC_SONAR_MCP_TOKEN}`. The lock keeps the placeholder. So the shared
  install scripts run APM without the token variables (`Invoke-WithoutSonarToken` in `AiSdlcSetup.ps1`).

## The tool groups

The server entry sends `SONARQUBE_TOOLSETS` with seven groups: projects, issues, quality-gates, rules,
measures, coverage and duplications. The SonarQube Cloud endpoint reads this header and offers only
those groups (SonarQube MCP server docs, "SonarQube Cloud hosted" and "Environment variables" pages).
By the tool list in those docs that is 15 tools; the count was not checked against a live server.
`Check-McpToken.ps1 -Fix` keeps the header when it writes the placeholders back.

APM 0.31.0 rewrites the `sonarqube` entry in `.mcp.json` when the pack changes it, and writes the token
value when the shell holds it. This was checked on 2026-11-26 with a scratch consumer.

## Where the token lives

A person stores the token once with `Set-SonarMcpToken.ps1`, as
[ADR 0018](../adrs/0018-the-sonarcloud-mcp-token-lives-in-a-user-store.md) decides. On Windows it is
the user variable `AISDLC_SONAR_MCP_TOKEN`. On macOS and Linux it is the file
`ai-sdlc/sonar-mcp-token` in the user config folder, with mode 600. A line in the shell profile reads
it into the variable. The script takes no parameters and stops when its input is redirected, so
an agent cannot run it.

## Why the token name is fixed

Each person sets the token in the variable `AISDLC_SONAR_MCP_TOKEN` on their own machine. The name is
shared by everyone in a repository, because `.mcp.json` is committed. One rename makes every person
change their variable, so the gate fails on any other name. A person who wants another name sets
`AISDLC_SONAR_MCP_TOKEN` from it in their shell profile.

The server does not use `SONAR_TOKEN`, the name the SonarCloud scanner and the dotnet pre-flight
(`-IncludeSonar`) read. Claude Code keeps a list of secret variable names, and `SONAR_TOKEN` is on it.
It fills in such a name as an empty value in an MCP config, so the server answers HTTP 401 "SonarQube
token required". This was found with Claude Code 2.1.308 on 2026-10-22. The gate names this reason
when the header still holds `SONAR_TOKEN`. Because a person often holds the same token in both
variables, the gate also fails on the value of `SONAR_TOKEN` in an MCP file.

## Settings

| Field | What it holds | Read by |
|---|---|---|
| `sonarcloud.projectKey` | The key of the SonarCloud project of the repository | `sonarcloud-mcp`, the dotnet pre-flight |
| `sonarcloud.organization` | The SonarCloud organization of the project | `sonarcloud-mcp`, the dotnet pre-flight |

The setup script adds the pack only with `-AddPacks sonarcloud`, and then lists both fields as a step
to do by hand.

## Related

- [How AI.SDLC is built](../overview.md) - where this pack sits among the packages.
- [dotnet](dotnet.md) - the pre-flight that runs the SonarCloud scan with the same token, read from `SONAR_TOKEN` or `AISDLC_SONAR_MCP_TOKEN`.
- [ADR 0018](../adrs/0018-the-sonarcloud-mcp-token-lives-in-a-user-store.md) - where the token lives, and why an agent never sees it.
- [Index](../index.md) - every page of this layer.
