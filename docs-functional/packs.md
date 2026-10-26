# What a pack adds to a repository

The AI-SDLC comes in packages. The core is the way of working itself, and every repository installs
it. A pack is an add-on for one technology or one tool. A repository installs only the packs that fit
what it holds. So a Bicep repository never sees a .NET rule, and a .NET repository never sees a Bicep gate.

## What you get

Each pack can bring any of these, and the core picks them up by itself:

- **Skills**: commands a person types or internal steps another skill calls, such as `write-api-spec` from the `dotnet` pack,
  and rulebooks an agent reads, such as `bicep-conventions`.
- **Review agents**: readers that report findings and never edit, such as `code-reviewer` and
  `security-reviewer` from the `dotnet` pack.
- **Gates**: checks that run on your machine before a push and again in the pull request workflow.
  The coverage gate of the `dotnet` pack runs in the pre-flight, and in the pull request workflow when a
  test step hands it the coverage. The starter workflow of a new .NET repository does that.
  A blocking gate stops the push; an advisory one warns.
- **A setup step**, run once per clone, such as the .NET restore.
- **A pre-flight step**, run before an agent pushes, such as the .NET build with tests or the Bicep build.
- **A post-edit step**, run after an edit, such as the build of the project an edited C# file belongs to.
- **The list of units that need a page**, such as every .NET project or every Bicep building block.
  With it comes the tool that reads the facts of a unit for a first draft of its page.
- **Its part of `AGENTS.md`**, the short rules every agent reads first.
- **Hooks**, the stops an agent tool runs before a command, such as the refusal of a stale code graph query.

| Pack | Install it when | What it adds, in short |
|---|---|---|
| `dotnet` | the repository has a .NET solution | C# rules, test-first, three review agents, seven gates, the code graph, a page per project |
| `blazor` | the repository has a Blazor app | the component and authorization conventions, and two gates on the components |
| `bicep` | the repository has Bicep templates | the Bicep conventions, the Bicep pre-flight, a page per building block |
| `github` | the repository lives on GitHub | the pull request helpers, the feedback loop on a pull request, the workflow conventions, and the ruleset on the main branch |
| `github-issues` | the repository tracks its work in GitHub Issues | the story and bug skills, the story contract gate, the backlink check and the issue pre-flight |
| `discovery` | the team does discovery work | the journey map, research synthesis and hypothesis canvas skills, which write pages in the repository |
| `knowledge` | the repository keeps notes on how its platform behaves | the platform knowledge notes, written to a private knowledge repository |
| `sonarcloud` | the repository has a SonarCloud project | the SonarQube MCP server, so an agent can read the quality gate and the issues, and a gate that keeps your token out of the repository |

The technical page of each pack lists its skills, agents and gates by name: [dotnet](../docs/packages/dotnet.md),
[blazor](../docs/packages/blazor.md), [bicep](../docs/packages/bicep.md), [github](../docs/packages/github.md),
[github-issues](../docs/packages/github-issues.md), [discovery](../docs/packages/discovery.md),
[knowledge](../docs/packages/knowledge.md) and [sonarcloud](../docs/packages/sonarcloud.md).

## When you need it

- A repository joins the AI-SDLC: the setup script picks the packs from what the repository holds, and
  always adds `github` and `github-issues` ([joining](joining.md)). It adds `discovery`, `knowledge`
  and `sonarcloud` only when you ask for them, for example with `-AddPacks sonarcloud`. With `sonarcloud`, each person sets their own SonarCloud token in the
  variable `AISDLC_SONAR_MCP_TOKEN`; it never goes in a file.
- A repository gains a technology, for example its first Bicep template: add the pack to `apm.yml`,
  and take it with the next install. `apm.yml` is the one list of the packs a repository uses.
- The team needs a rule for a technology nobody covers yet: a new pack in AI.SDLC, through a pull request there.

## What to know

- A pack holds nothing you edit in your repository. The values a repository sets, such as its solution
  path or its test folder, live in its own `aisdlc.json`.
- A pack moves with the version you pin. Every pack and the core share one release tag, so a repository
  takes them together ([taking a new version](new-version.md)).
- The exact folder shape of a pack, and which file carries what, is on the
  [technical overview](../docs/overview.md).

## Related

- [What the AI-SDLC gives a team](overview.md) - the core that every pack adds to.
- [Adding the AI-SDLC to a repository](joining.md) - how the packs are chosen at setup.
- [Taking a new version](new-version.md) - how a pack reaches a repository after a release.
- [How AI.SDLC is built](../docs/overview.md) - the folder shape of a pack.
- [Index](index.md) - every page of this layer.
