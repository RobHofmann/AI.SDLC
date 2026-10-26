#Requires -Version 7
<#
.SYNOPSIS
    Sets up the shared AI-SDLC in a repository that does not have it yet: picks the packs, writes the
    config files, installs the packages and says what is still left to do by hand.

.DESCRIPTION
    Run it from a clone of AI.SDLC, with the path of the other repository. A skill cannot do this job,
    because a repository has no installed skill before its first install.

    1. It picks the packs. A repository lives on GitHub and tracks its work in GitHub Issues, so github
       and github-issues are always added. The stack packs follow what the repository holds: a solution
       or project file means dotnet, a .razor file means blazor, a .bicep file means bicep. The script
       never picks discovery, knowledge or sonarcloud itself, because only some repositories need them:
       add them with -AddPacks, for example -AddPacks sonarcloud for a repository with a SonarCloud
       project. -Packs overrides the choice, and -AddPacks adds to it.
    2. It writes aisdlc.json with the github settings: github.repository from the git remote (origin)
       and the trunk from config/defaults.json. It writes apm.yml with the core and the packs at one
       release tag of the AI.SDLC source (aiSdlc.repositoryUrl in config/defaults.json); apm.yml is the
       one list of the packs.
       It writes AGENTS.md, .claude/CLAUDE.md and a first docs wiki (setup.md and overview.md) when
       they are missing, and a .gitattributes line that keeps LF endings on the git hooks.
       .claude/CLAUDE.md imports AGENTS.md for Claude Code; it does not sit at the root, because
       GitHub Copilot reads a root CLAUDE.md as well and would then load AGENTS.md twice. It refuses to
       overwrite an existing aisdlc.json or apm.yml unless -Force is passed.
       With -Force it merges into an existing aisdlc.json, so a field added by hand stays.
    3. It writes a starter pull request workflow, .github/workflows/pr.yml, from
       tools/templates/workflows/pr.yml, when the repository has none (see -NoWorkflows). The workflow
       runs the composite action of the core. The output shows the step that makes its check required
       on the trunk apart from the other steps left to do, because without it no gate has to pass.
       It also writes .github/workflows/ai-sdlc-update.yml from tools/templates/workflows/ai-sdlc-update.yml
       when it is missing. Every Monday that workflow opens a pull request for a newer AI.SDLC release,
       signed in as a GitHub App, so AI.SDLC never needs to know this repository.
    4. Unless -SkipInstall is passed, it runs apm install, stages the result, sets the executable bit on
       the git hooks, writes the shared parts of AGENTS.md with Sync-AgentsFile.ps1, brings existing
       docs up to the wiki rules (see -NoDocsUpgrade), and generates the docs index.
    5. It prints what it could not do: switching on Issues, the ruleset on the trunk, the GitHub App of
       the update workflow, the repository part of AGENTS.md, and the commit.

    The github-issues tracker settings name the AI.SDLC source repository (aiSdlc.repository in
    config/defaults.json) in tracker.acceptedRepositories. An update pull request names the release issue of
    AI.SDLC, and the pull request story check accepts an issue of another repository only from that list.

    Nothing is committed or pushed. The person reviews the staged files and commits them. -WhatIf shows
    what the script would write, and writes nothing.

    The GitHub CLI login check, the hint for a failed apm install and the executable bit of the git hooks
    come from AiSdlcSetup.ps1 in the core (ai-sdlc-hooks/scripts), which Install-AiSdlc.ps1 and
    Update-AiSdlc.ps1 use too. The login check only warns: a public AI.SDLC source needs no login.

.PARAMETER TargetRepo
    The root of the repository to set up. It must be a git repository.

.PARAMETER Ref
    The AI.SDLC release tag to pin. Defaults to the newest tag without a suffix, or the newest tag at all
    when there is no release yet.

.PARAMETER Packs
    The packs to install, instead of the ones the script picks.

.PARAMETER AddPacks
    Packs to add to the ones the script picks, for example sonarcloud.

.PARAMETER ScriptFolder
    The folder of the repository's own scripts and gates, relative to its root. It becomes
    paths.toolsFolder. Defaults to tools.

.PARAMETER SkipInstall
    Write the files only. Do not run apm install, git or Sync-AgentsFile.ps1.

.PARAMETER Force
    Rewrite an existing aisdlc.json and apm.yml. apm.yml is overwritten. aisdlc.json is merged: the
    script sets the fields it computes, and every other field stays, for example repoGates or
    readingLevelRoots. A "packs" field goes, because apm.yml is the one list of the packs.

.PARAMETER NoWorkflows
    Do not write the starter workflows. Without it, a repository with no .github/workflows/pr.yml gets
    one from tools/templates/workflows/pr.yml, and one with no ai-sdlc-update.yml gets that one too. For a .NET solution the workflow also runs the tests
    with coverage first (tools/templates/workflows/dotnet-test-steps.yml), and passes the merged
    coverage to the composite action for the C04 coverage ratchet.

.PARAMETER NoDocsUpgrade
    Do not bring existing docs up to the wiki rules after the install. Without it, the script runs
    Repair-DocsWiki.ps1 from the installed adopt-docs skill on a repository that already has docs.

.PARAMETER LocalSource
    Test seam for CI: install the packages from this local AI.SDLC folder instead of the tagged remote,
    so no network or login is needed. apm.yml then names local paths, which never reach a real commit.

.PARAMETER DefaultsFile
    Test seam: the defaults. Defaults to config/defaults.json, which holds the AI.SDLC source URL, the
    trunk branch and the runner of the starter workflow.

.EXAMPLE
    pwsh tools/Add-AiSdlcConsumer.ps1 -TargetRepo ../portal

.EXAMPLE
    pwsh tools/Add-AiSdlcConsumer.ps1 -TargetRepo ../portal -AddPacks discovery -SkipInstall
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$TargetRepo,
    [string]$Ref,
    [string[]]$Packs,
    [string[]]$AddPacks = @(),
    [string]$ScriptFolder = 'tools',
    [switch]$SkipInstall,
    [switch]$Force,
    [switch]$NoWorkflows,
    [switch]$NoDocsUpgrade,
    [string]$DefaultsFile,
    [string]$LocalSource
)

$ErrorActionPreference = 'Stop'
$aiSdlcRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $aiSdlcRoot 'core' '.apm' 'skills' 'ai-sdlc-hooks' 'scripts' 'AiSdlcSetup.ps1')
$packOrder = @('dotnet', 'blazor', 'bicep', 'github', 'github-issues', 'discovery', 'knowledge', 'sonarcloud')
$alwaysPacks = @('github', 'github-issues')
if (-not $DefaultsFile) { $DefaultsFile = Join-Path $aiSdlcRoot 'config' 'defaults.json' }
$defaults = Get-Content -LiteralPath $DefaultsFile -Raw | ConvertFrom-Json
$sourceUrl = $defaults.aiSdlc.repositoryUrl
$aiSdlcRepository = [string]$defaults.aiSdlc.repository
$trunk = $defaults.github.trunk
$skip = '[\\/](\.claude|\.git|apm_modules|node_modules|bin|obj)[\\/]'
$todo = [System.Collections.Generic.List[string]]::new()

function Write-Utf8File {
    param([string]$Path, [string]$Content)
    $folder = Split-Path -Parent $Path
    if ($folder -and -not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    [IO.File]::WriteAllText($Path, ($Content -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))
}

function Merge-Config {
    param([System.Collections.IDictionary]$Existing, [System.Collections.IDictionary]$New)
    $merged = [ordered]@{}
    foreach ($key in $Existing.Keys) { $merged[$key] = $Existing[$key] }
    foreach ($key in $New.Keys) {
        if ($merged.Contains($key) -and $merged[$key] -is [System.Collections.IDictionary] -and $New[$key] -is [System.Collections.IDictionary]) {
            $merged[$key] = Merge-Config -Existing $merged[$key] -New $New[$key]
        }
        else { $merged[$key] = $New[$key] }
    }
    return $merged
}

function Get-RepoFiles {
    param([string]$Filter)
    @(Get-ChildItem -LiteralPath $TargetRepo -Recurse -File -Filter $Filter -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $skip })
}

function Get-WorkflowCheckName {
    param([string]$Path)
    $jobs = [System.Collections.Generic.List[object]]::new()
    $inJobs = $false
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ($line -match '^jobs:\s*$') { $inJobs = $true; continue }
        if (-not $inJobs) { continue }
        if ($line -match '^\S') { break }
        if ($line -match '^  ([\w-]+):\s*$') { $jobs.Add([pscustomobject]@{ Id = $Matches[1]; Name = ''; Gates = $false }); continue }
        if ($jobs.Count -eq 0) { continue }
        if ($line -match '^    name:\s*(.+?)\s*$') { $jobs[-1].Name = $Matches[1].Trim('"', "'") }
        if ($line -match 'assets/actions/ai-sdlc-pr') { $jobs[-1].Gates = $true }
    }
    $job = @($jobs | Where-Object Gates) + @($jobs) | Select-Object -First 1
    if (-not $job) { return '' }
    if ($job.Name) { return $job.Name }
    return $job.Id
}

if (-not (Test-Path -LiteralPath $TargetRepo -PathType Container)) { throw "The target folder does not exist: $TargetRepo" }
$TargetRepo = (Resolve-Path -LiteralPath $TargetRepo).Path
$top = git -C $TargetRepo rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0 -or -not $top) { throw "The target is not a git repository: $TargetRepo" }
$TargetRepo = (Resolve-Path -LiteralPath $top.Trim()).Path
if ($TargetRepo -eq (Resolve-Path -LiteralPath $aiSdlcRoot).Path) { throw 'The target is AI.SDLC itself. Pass the path of the repository to set up.' }

$remote = (git -C $TargetRepo remote get-url origin 2>$null) -join ''
$githubRepository = ''
if ($remote -match 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/?#]+?)(\.git)?/?$') {
    $githubRepository = "$($Matches.owner)/$($Matches.repo)"
}
$repository = if ($githubRepository) { ($githubRepository -split '/')[1] } else { Split-Path -Leaf $TargetRepo }

$Packs = @($Packs | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$AddPacks = @($AddPacks | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (-not $Packs) {
    $picked = [System.Collections.Generic.List[string]]::new()
    if ((Get-RepoFiles '*.sln').Count -or (Get-RepoFiles '*.slnx').Count -or (Get-RepoFiles '*.csproj').Count) { $picked.Add('dotnet') }
    if ((Get-RepoFiles '*.razor').Count) { $picked.Add('blazor') }
    if ((Get-RepoFiles '*.bicep').Count) { $picked.Add('bicep') }
    $picked.AddRange([string[]]$alwaysPacks)
    $Packs = $picked
}
$unknown = @(@($Packs) + @($AddPacks) | Where-Object { $_ -notin $packOrder })
if ($unknown) { throw "Unknown pack(s): $($unknown -join ', '). Known packs: $($packOrder -join ', ')." }
$Packs = @($packOrder | Where-Object { $_ -in @(@($Packs) + @($AddPacks)) })

if (-not $Ref -and $LocalSource) { $Ref = 'v0.0.0-local' }
if (-not $Ref) {
    $tags = @(git -C $aiSdlcRoot tag --list 'v*' --sort=-v:refname)
    $Ref = ($tags | Where-Object { $_ -notmatch '-' } | Select-Object -First 1)
    if (-not $Ref) { $Ref = $tags | Select-Object -First 1 }
    if (-not $Ref) { throw 'This clone of AI.SDLC has no release tag. Run git fetch --tags, or pass -Ref.' }
}

$configPath = Join-Path $TargetRepo 'aisdlc.json'
$apmPath = Join-Path $TargetRepo 'apm.yml'
$initRelative = '.claude/skills/ai-sdlc-hooks/scripts/Install-AiSdlc.ps1'
if (-not $SkipInstall -and -not (Get-Command apm -ErrorAction SilentlyContinue)) {
    throw 'APM is not on the PATH. Install the pinned version with pwsh core/.apm/skills/ai-sdlc-gates/scripts/Install-Apm.ps1 -AddToPath, open a new terminal and run this again, or pass -SkipInstall.'
}
if (-not $SkipInstall -and -not $LocalSource -and (Get-Command Test-GitHubLogin -ErrorAction SilentlyContinue)) {
    $loginProblem = Test-GitHubLogin
    if ($loginProblem) { Write-Warning $loginProblem }
}
if (-not $Force) {
    $existing = @($configPath, $apmPath | Where-Object { Test-Path -LiteralPath $_ })
    if ($existing) { throw "Already present, pass -Force to overwrite: $(($existing | ForEach-Object { [IO.Path]::GetRelativePath($TargetRepo, $_) }) -join ', ')" }
}

$config = [ordered]@{
    repository = $repository
    visibility = 'private'
    paths      = [ordered]@{
        toolsFolder    = $ScriptFolder.TrimEnd('/', '\').Replace('\', '/')
        docsRoots      = @('docs', 'docs-functional')
        technicalDocs  = 'docs'
        functionalDocs = 'docs-functional'
    }
    github     = [ordered]@{ repository = $githubRepository; trunk = $trunk }
}
if (-not (Test-Path -LiteralPath (Join-Path $TargetRepo 'docs' 'constitution.md'))) {
    $config.paths.constitution = '.claude/skills/ai-sdlc-handbook/references/constitution.md'
}
if (-not $githubRepository) {
    $todo.Add('Set github.repository in aisdlc.json to owner/name once the repository exists on GitHub. Until then the scripts read it from the git remote origin, and this one has none on github.com.')
}
if ('github-issues' -in $Packs) {
    $config.tracker = [ordered]@{ repository = $githubRepository; refinedLabel = 'refined'; toRefineLabel = 'to-refine'; sizeLabelPrefix = 'size:'; labels = @(); acceptedRepositories = @(@($aiSdlcRepository) | Where-Object { $_ }) }
}
if ('knowledge' -in $Packs) {
    $config.knowledge = [ordered]@{ repository = '' }
    $todo.Add('Set knowledge.repository in aisdlc.json to the owner/name of your knowledge repository, and clone it next to this one (paths.knowledgeRoot, ../Knowledge by default).')
}
if ('sonarcloud' -in $Packs) {
    $config.sonarcloud = [ordered]@{ organization = ''; projectKey = '' }
    $todo.Add('Set sonarcloud.organization and sonarcloud.projectKey in aisdlc.json to the SonarCloud project. Each person sets their own SonarCloud token in the variable AISDLC_SONAR_MCP_TOKEN, never in .mcp.json; the gate Check-McpToken.ps1 fails on a token in the file.')
}
if ('dotnet' -in $Packs) {
    $sln = Get-RepoFiles '*.sln' | Select-Object -First 1
    $relative = { param($full) [IO.Path]::GetRelativePath($TargetRepo, $full).Replace('\', '/') }
    if ($sln) { $config.paths.solution = & $relative $sln.FullName }
    $bases = @(@($sln.DirectoryName, $TargetRepo) | Where-Object { $_ } | Select-Object -Unique)
    foreach ($pair in @(@{ Field = 'sourceRoot'; Names = @('src', 'source') }, @{ Field = 'testRoot'; Names = @('tests', 'test') })) {
        $found = foreach ($b in $bases) { foreach ($n in $pair.Names) { $p = Join-Path $b $n; if (Test-Path -LiteralPath $p -PathType Container) { $p } } }
        $found = @($found) | Select-Object -First 1
        if ($found) { $config.paths[$pair.Field] = & $relative $found }
    }
    $runSettings = Get-RepoFiles '*.runsettings' | Select-Object -First 1
    if ($runSettings) { $config.paths.runSettings = & $relative $runSettings.FullName }
    $baseline = Get-RepoFiles 'coverage-baseline.json' | Select-Object -First 1
    if ($baseline) { $config.paths.coverageBaseline = & $relative $baseline.FullName }
    $missingPaths = @('sourceRoot', 'testRoot', 'runSettings', 'coverageBaseline' | Where-Object { -not $config.paths.Contains($_) })
    if ($missingPaths) { $todo.Add("Set the .NET paths the dotnet gates read and the script could not find: paths.$($missingPaths -join ', paths.') in aisdlc.json (layout.md in the ai-sdlc-handbook skill lists them). A coverage baseline comes from a first coverage run; until it exists, the C04 ratchet of the pull request workflow fails.") }
}
$prWorkflow = '.github/workflows/pr.yml'
$prWorkflowPath = Join-Path $TargetRepo '.github' 'workflows' 'pr.yml'
$hasWorkflow = Test-Path -LiteralPath $prWorkflowPath
$writeWorkflow = -not $NoWorkflows -and -not $hasWorkflow
$updateWorkflow = '.github/workflows/ai-sdlc-update.yml'
$updateWorkflowPath = Join-Path $TargetRepo '.github' 'workflows' 'ai-sdlc-update.yml'
$writeUpdateWorkflow = -not $NoWorkflows -and -not (Test-Path -LiteralPath $updateWorkflowPath)
if ($writeWorkflow) {
    $config.paths.pipelinesFolder = '.github/workflows'
    $config.paths.codeAnalysisPipeline = $prWorkflow
}
$actionIncluded = $hasWorkflow -and ((Get-Content -LiteralPath $prWorkflowPath -Raw) -match 'assets/actions/ai-sdlc-pr')
if ($hasWorkflow -and -not $NoWorkflows -and -not $actionIncluded) {
    $todo.Add("Add the shared AI-SDLC step to $($prWorkflow): after actions/checkout with fetch-depth: 0, add '- uses: ./.claude/skills/ai-sdlc-gates/assets/actions/ai-sdlc-pr' with private-terms: `${{ secrets.AISDLC_PRIVATE_TERMS }}. Set paths.pipelinesFolder and paths.codeAnalysisPipeline in aisdlc.json.")
}
if ($Force -and (Test-Path -LiteralPath $configPath)) {
    try { $existingConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable }
    catch { Write-Warning "aisdlc.json is not valid JSON, so -Force overwrites it: $($_.Exception.Message)"; $existingConfig = $null }
    if ($existingConfig -is [System.Collections.IDictionary]) {
        $keptAccepted = @(if ($existingConfig.tracker -is [System.Collections.IDictionary]) { $existingConfig.tracker.acceptedRepositories })
        $config = Merge-Config -Existing $existingConfig -New $config
        if ($config.tracker -is [System.Collections.IDictionary] -and $config.tracker.Contains('acceptedRepositories')) {
            $accepted = [System.Collections.Generic.List[string]]::new()
            foreach ($value in @($config.tracker.acceptedRepositories) + $keptAccepted) {
                if ($value -and -not ($accepted | Where-Object { $_ -ieq [string]$value })) { $accepted.Add([string]$value) }
            }
            $config.tracker.acceptedRepositories = $accepted.ToArray()
        }
    }
    $config.Remove('packs')
}
if (-not $config.Contains('repoGates')) { $config.repoGates = @() }

$plan = @('aisdlc.json', 'apm.yml', '.gitattributes') + @(if ($writeWorkflow) { $prWorkflow }) + @(if ($writeUpdateWorkflow) { $updateWorkflow }) + @(if (-not (Test-Path -LiteralPath (Join-Path $TargetRepo 'docs'))) { 'docs/setup.md and docs/overview.md' }) + @(if (-not (Test-Path -LiteralPath (Join-Path $TargetRepo 'docs-functional'))) { 'docs-functional/overview.md and docs-functional/glossary.md' })
$planText = "write $($plan -join ', '), AGENTS.md and .claude/CLAUDE.md when missing$(if (-not $SkipInstall) { '; run apm install and stage the result' })"
if (-not $PSCmdlet.ShouldProcess($TargetRepo, $planText)) {
    exit 0
}

Write-Utf8File -Path $configPath -Content (($config | ConvertTo-Json -Depth 10) + "`n")

if ($writeWorkflow -or $writeUpdateWorkflow) {
    $templates = Join-Path $PSScriptRoot 'templates' 'workflows'
    $solution = Get-RepoFiles '*.sln' | Select-Object -First 1
    $solutionPath = if ($solution) { [IO.Path]::GetRelativePath($TargetRepo, $solution.FullName).Replace('\', '/') } else { '' }
    $dotnetTests = 'dotnet' -in $Packs -and $solutionPath
    $tokens = [ordered]@{
        '{{Repository}}'          = $repository
        '{{Trunk}}'               = $trunk
        '{{Runner}}'              = $defaults.workflows.runner
        '{{Solution}}'            = $solutionPath
        '{{RunSettingsArgument}}' = if ($config.paths.Contains('runSettings') -and $config.paths.runSettings) { " --settings $($config.paths.runSettings)" } else { '' }
        '{{ActionInputs}}'        = if ($dotnetTests) { "`n          coverage-file: `${{ runner.temp }}/coverage/coverage.xml" } else { '' }
    }
    function Expand-Template {
        param([string]$Name)
        $text = Get-Content -LiteralPath (Join-Path $templates $Name) -Raw
        foreach ($pair in $tokens.GetEnumerator()) { $text = $text.Replace($pair.Key, [string]$pair.Value) }
        return $text
    }
    if ($writeWorkflow) {
        $testSteps = if ($dotnetTests) { Expand-Template 'dotnet-test-steps.yml' } else { '' }
        $workflow = (Expand-Template 'pr.yml').Replace('{{TestSteps}}', $testSteps)
        Write-Utf8File -Path $prWorkflowPath -Content $workflow
    }
    if ($writeUpdateWorkflow) { Write-Utf8File -Path $updateWorkflowPath -Content (Expand-Template 'ai-sdlc-update.yml') }
}
if ($writeUpdateWorkflow) {
    $todo.Add("Let $updateWorkflow open its update pull requests: create a GitHub App (or reuse one) with Contents and Pull requests set to read and write, install it on this repository, and set the repository variable AISDLC_UPDATE_APP_CLIENT_ID and the secret AISDLC_UPDATE_APP_PRIVATE_KEY. A pull request that the default GITHUB_TOKEN opens starts no workflow, so its required checks would never run.")
}

# The one step without which no gate has to pass on a pull request, so the output shows it apart from the list.
$starterWorkflow = Join-Path $PSScriptRoot 'templates' 'workflows' 'pr.yml'
$checkName = if ($actionIncluded) { Get-WorkflowCheckName -Path $prWorkflowPath } else { '' }
if (-not $checkName) { $checkName = Get-WorkflowCheckName -Path $starterWorkflow }
$rulesetCommand = "pwsh .claude/skills/github-pull-requests/scripts/Set-BranchRuleset.ps1 -RequiredCheck `"$checkName`" (try it with -WhatIf first)"
$gateStep = if ($writeWorkflow) { "After the first push, run the pull request workflow once and make its check required on $($trunk): $rulesetCommand." }
elseif ($hasWorkflow -and -not $NoWorkflows) { "Once $prWorkflow holds the shared AI-SDLC step and is pushed, make its check required on $($trunk): $rulesetCommand." }
else { "This run wrote no workflow. Add a pull request workflow with the shared AI-SDLC step (start from tools/templates/workflows/pr.yml in AI.SDLC), set paths.pipelinesFolder and paths.codeAnalysisPipeline in aisdlc.json, push it, and make its check required on $($trunk): $rulesetCommand." }

$apm = [System.Text.StringBuilder]::new()
$slug = ($repository.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
[void]$apm.AppendLine("name: $slug").AppendLine('version: "0.0.0"').AppendLine('targets:').AppendLine('  - claude').AppendLine('dependencies:').AppendLine('  apm:')
foreach ($path in @('core') + @($Packs | ForEach-Object { "packs/$_" })) {
    if ($LocalSource) { [void]$apm.AppendLine("    - $($LocalSource.Replace('\', '/').TrimEnd('/'))/$path"); continue }
    [void]$apm.AppendLine("    - git: $sourceUrl").AppendLine("      path: $path").AppendLine("      ref: $Ref")
}
Write-Utf8File -Path $apmPath -Content $apm.ToString()

$agentsPath = Join-Path $TargetRepo 'AGENTS.md'
if (-not (Test-Path -LiteralPath $agentsPath)) {
    Write-Utf8File -Path $agentsPath -Content "# AGENTS.md - $repository`n`nThe engineering instructions of this repository. The marked parts come from AI.SDLC through Sync-AgentsFile.ps1; the rest belongs to this repository.`n`n## Project overview`n`nWhat this repository is, how to build and test it, and where the detail lives.`n"
    $todo.Add('Write the repository part of AGENTS.md: the project overview, the build and test commands, and the repository''s own rules. Keep it under 150 lines.')
}
$docsPath = Join-Path $TargetRepo 'docs'
$newDocs = -not (Test-Path -LiteralPath $docsPath)
if ($newDocs) {
    Write-Utf8File -Path (Join-Path $docsPath 'setup.md') -Content @"
# Setup

How to set up a clone of $repository. Run ``pwsh $initRelative`` once per clone. It installs APM and
the shared AI-SDLC from AI.SDLC, and it wires the git hooks. On Windows it switches long paths on
when they are off; approve the administrator prompt it shows.

The packs this repository uses are in ``apm.yml``, which also pins their version. The
[overview](overview.md) says what the repository is.

## Related

- [Overview](overview.md) - what this repository is.
- [Index](index.md) - every page of this wiki.
- [Handbook](../.claude/skills/ai-sdlc-handbook/references/README.md) - the way of working.
- [Layout](../.claude/skills/ai-sdlc-handbook/references/layout.md) - where the shared files live and how to take a new version.
"@
    Write-Utf8File -Path (Join-Path $docsPath 'overview.md') -Content @"
# Overview

What $repository is and what it holds. Replace this line with a short description. The
[setup page](setup.md) says how to set up a clone.

## Related

- [Setup](setup.md) - how to set up a clone and install the shared AI-SDLC.
- [Handbook](../.claude/skills/ai-sdlc-handbook/references/README.md) - the way of working.
"@
    $todo.Add('Write docs/overview.md: what the repository is and what it holds.')
}
$functionalPath = Join-Path $TargetRepo 'docs-functional'
$newFunctional = -not (Test-Path -LiteralPath $functionalPath)
if ($newFunctional) {
    Write-Utf8File -Path (Join-Path $functionalPath 'overview.md') -Content @"
# What $repository gives its users

What the people who use $repository get from it, in plain words. Replace this line with a short
description. The technical layer says how it is built; this layer says what it is for. The
[glossary](glossary.md) explains the words this repository uses.

## Related

- [Glossary](glossary.md) - the words this repository uses, in plain language.
- [Index](index.md) - every page of this layer.
"@
    Write-Utf8File -Path (Join-Path $functionalPath 'glossary.md') -Content @"
# Glossary

The words this repository uses, each with one plain sentence. Add a word when a page uses it and a
new reader would not know it. The [overview](overview.md) says what the repository gives its users.

## Related

- [Overview](overview.md) - what this repository gives its users.
- [Index](index.md) - every page of this layer.
"@
    $todo.Add('Write docs-functional/overview.md: what the repository gives the people who use it. Then run /adopt-docs to draft the other functional pages.')
}
$allowlistPath = Join-Path $docsPath '.reading-level-allowlist'
$nameWords = @($repository -split '[^A-Za-z]+' | Where-Object { $_.Length -gt 2 } | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)
$allowlist = if (Test-Path -LiteralPath $allowlistPath) { Get-Content -LiteralPath $allowlistPath -Raw } else { "# Words the team accepts above CEFR B1, one per line: the exact name of a thing, so a plain word would be less precise.`n# Check-DocReadingLevel.ps1 reads this file.`n" }
$known = @($allowlist -split '\r?\n' | ForEach-Object { $_.Trim().ToLowerInvariant() })
$missingWords = @($nameWords | Where-Object { $_ -notin $known })
if ($missingWords) {
    $prefix = if ($allowlist.EndsWith("`n")) { '' } else { "`n" }
    Write-Utf8File -Path $allowlistPath -Content ($allowlist + $prefix + "`n# The name of this repository`n" + ($missingWords -join "`n") + "`n")
}

$attributesPath = Join-Path $TargetRepo '.gitattributes'
$hookRule = '.claude/skills/ai-sdlc-hooks/githooks/** text eol=lf'
$attributes = if (Test-Path -LiteralPath $attributesPath) { Get-Content -LiteralPath $attributesPath -Raw } else { '' }
if ($attributes -notmatch [regex]::Escape($hookRule)) {
    $prefix = if ($attributes -and -not $attributes.EndsWith("`n")) { "`n" } else { '' }
    Write-Utf8File -Path $attributesPath -Content ($attributes + $prefix + "# The git hooks are shell scripts; with CRLF endings the shebang breaks.`n$hookRule`n")
}
$ignorePath = Join-Path $TargetRepo '.gitignore'
$ignore = if (Test-Path -LiteralPath $ignorePath) { Get-Content -LiteralPath $ignorePath -Raw } else { '' }
if ($ignore -notmatch '(?m)^doc-candidates/?\s*$') {
    $prefix = if ($ignore -and -not $ignore.EndsWith("`n")) { "`n" } else { '' }
    Write-Utf8File -Path $ignorePath -Content ($ignore + $prefix + "# Drafts of the doc tools, checked by a person and never committed.`ndoc-candidates/`n")
}
$ignore = if (Test-Path -LiteralPath $ignorePath) { Get-Content -LiteralPath $ignorePath -Raw } else { '' }
if ($ignore -notmatch '(?m)^/?temp/?\s*$') {
    $prefix = if ($ignore -and -not $ignore.EndsWith("`n")) { "`n" } else { '' }
    Write-Utf8File -Path $ignorePath -Content ($ignore + $prefix + "# Working files of the agents and the pre-flight receipts (paths.preflightReceipts), never committed.`ntemp/`n")
}
# A receipt folder outside temp/ (paths.preflightReceipts) needs its own rule, or a receipt gets committed.
# A leading ./ or / is dropped: git matches no rule that starts with ./, and the receipts land under the repository either way.
# The rule starts with /, so git matches it at the root only: a plain out/ would ignore every folder named out.
$receiptDir = (([string]$config.paths.preflightReceipts -replace '\\', '/').Trim() -replace '^(\.?/)+', '').TrimEnd('/')
if ($receiptDir -and -not [System.IO.Path]::IsPathRooted($receiptDir) -and $receiptDir -ne 'temp' -and -not $receiptDir.StartsWith('temp/')) {
    $ignore = Get-Content -LiteralPath $ignorePath -Raw
    if ($ignore -notmatch ('(?m)^/?' + [regex]::Escape($receiptDir) + '/?\s*$')) {
        $prefix = if ($ignore.EndsWith("`n")) { '' } else { "`n" }
        Write-Utf8File -Path $ignorePath -Content ($ignore + $prefix + "# The pre-flight receipts (paths.preflightReceipts), never committed.`n/$receiptDir/`n")
    }
}
$claudePath = Join-Path $TargetRepo 'CLAUDE.md'
$dotClaudePath = Join-Path $TargetRepo '.claude' 'CLAUDE.md'
# The import sits in .claude/CLAUDE.md, which Claude Code reads and GitHub Copilot does not. Copilot reads
# AGENTS.md and a root CLAUDE.md, and follows its import, so a root import gave Copilot AGENTS.md twice.
if (-not (Test-Path -LiteralPath $claudePath) -and -not (Test-Path -LiteralPath $dotClaudePath)) {
    New-Item -ItemType Directory -Path (Split-Path $dotClaudePath -Parent) -Force | Out-Null
    Write-Utf8File -Path $dotClaudePath -Content "@../AGENTS.md`n"
}

if ('github-issues' -in $Packs) {
    $todo.Add("Switch on Issues for the repository on GitHub (Settings, General, Features), and add the labels refined, to-refine and spike: gh label create refined$(if ($githubRepository) { " --repo $githubRepository" }), and the same for the others.")
}

if (-not $SkipInstall) {
    Push-Location $TargetRepo
    try {
        apm install
        if ($LASTEXITCODE -ne 0) { throw "$(Get-ApmInstallFailureHint -ExitCode $LASTEXITCODE) Then run this again with -Force." }
        if ($newDocs -or $newFunctional) {
            pwsh -NoProfile -File (Join-Path $TargetRepo '.claude' 'skills' 'ai-sdlc-gates' 'scripts' 'Build-DocsIndex.ps1') -RepoRoot $TargetRepo
            if ($LASTEXITCODE -ne 0) { throw "Build-DocsIndex.ps1 failed with exit code $LASTEXITCODE." }
        }
        # Sync-AgentsFile.ps1 runs before the staging, because it refuses to move a staged root CLAUDE.md.
        pwsh -NoProfile -File (Join-Path $TargetRepo '.claude' 'skills' 'ai-sdlc-gates' 'scripts' 'Sync-AgentsFile.ps1') -RepoRoot $TargetRepo
        if ($LASTEXITCODE -ne 0) { throw "Sync-AgentsFile.ps1 failed with exit code $LASTEXITCODE." }
        $stage = @('aisdlc.json', 'apm.yml', 'apm.lock.yaml', 'AGENTS.md', 'CLAUDE.md', '.gitattributes', '.claude') |
            Where-Object { Test-Path -LiteralPath (Join-Path $TargetRepo $_) }
        git add -- @stage
        if (Test-Path -LiteralPath (Join-Path $TargetRepo "docs")) { git add -- docs }
        if (Test-Path -LiteralPath $functionalPath) { git add -- docs-functional }
        if ($writeWorkflow -or $writeUpdateWorkflow) { git add -- .github/workflows }
        if (Test-Path -LiteralPath (Join-Path $TargetRepo '.gitignore')) { git add -- .gitignore }
        Set-GitHookExecutable -RepoRoot $TargetRepo | Out-Null
        $repair = Join-Path $TargetRepo '.claude' 'skills' 'adopt-docs' 'scripts' 'Repair-DocsWiki.ps1'
        if (-not $newDocs -and -not $NoDocsUpgrade -and (Test-Path -LiteralPath $repair)) {
            pwsh -NoProfile -File $repair -RepoRoot $TargetRepo -NoGates
            if ($LASTEXITCODE -ne 0) { throw "Repair-DocsWiki.ps1 failed with exit code $LASTEXITCODE." }
            git add -- docs
            $todo.Add('The existing docs got the machine fixes. If a doc gate still fails (reading level, broken links, line numbers), start an agent in the repository and run /adopt-docs, in its own pull request.')
        }
    }
    finally { Pop-Location }
}
else {
    $todo.Add("Run apm install in the target. Then run Sync-AgentsFile.ps1 and Build-DocsIndex.ps1, and set the executable bit on .claude/skills/ai-sdlc-hooks/githooks/*.")
}

$todo.Add('Run pwsh .claude/skills/ai-sdlc-gates/scripts/Invoke-LocalGates.ps1 in the target and review the staged files. Then open an issue for the setup, commit the files on a branch named for it (<number>-ai-sdlc-setup), and open a pull request with Fixes #<number>; the pull request workflow fails one without a key.')

Write-Host "AI-SDLC set up in $TargetRepo"
Write-Host "  repository: $(if ($githubRepository) { $githubRepository } else { $repository })"
Write-Host "  packs:      core, $($Packs -join ', ')"
Write-Host "  ref:        $Ref"
Write-Host "  written:    aisdlc.json, apm.yml$(if ($writeWorkflow) { ", $prWorkflow" })$(if ($writeUpdateWorkflow) { ", $updateWorkflow" })$(if (-not $SkipInstall) { ', the installed files (staged)' })"
Write-Host 'Without this step no gate has to pass on a pull request, and a broken install reaches the trunk:' -ForegroundColor Yellow
Write-Host "  >> $gateStep" -ForegroundColor Yellow
Write-Host 'Still to do by hand:'
$n = 1
foreach ($item in $todo) { Write-Host "  $n. $item"; $n++ }
