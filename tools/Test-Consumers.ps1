#Requires -Version 7
<#
.SYNOPSIS
    Installs the packages of this repository into each test consumer under test-consumers/, and checks what
    each consumer gets.

.DESCRIPTION
    A shared file can pass its own tests and still break in a consumer: a link that only resolves in
    the source layout, a gate that assumes a folder the consumer does not have, a pack file that lands
    in a repository that did not ask for it. So the pipeline installs the packages the way a consumer
    does, and runs the consumer's gates there.

    Each folder under test-consumers/ is one consumer. It holds an apm.yml that names the packages by a local
    path (../../core, ../../packs/bicep), an aisdlc.json, the repository files the consumer needs, and
    an expect.json:

        { "present": [ ".claude/skills/bicep-conventions/references/bicep.md" ],
          "absent":  [ ".claude/skills/test-first-dotnet" ] }

    The script copies the consumer to a temporary folder outside this repository (APM refuses a local
    package when the consumer sits inside the packages own repository), points each local path at the
    package by its full path, runs apm install
    there, checks every "present" path exists and every "absent" path does not, writes the shared parts
    of AGENTS.md and the docs index, and runs the blocking gates and the Pester tests of every installed script with
    Invoke-LocalGates.ps1 from the installed core. It marks the git hooks executable, as every consumer
    must after an install. Last, it runs apm audit --ci on the committed install.

    After the folders under test-consumers/, the setup-script consumer runs tools/Add-AiSdlcConsumer.ps1 against
    a new repository that already has a Bicep file and docs that break the wiki rules, from the local
    packages (-LocalSource). It checks the defaults, the starter workflow and the docs repair.
    It also walks the documentation route: the functional layer exists, Check-DocCoverage.ps1 reports
    a building block with no page, New-DocCandidate.ps1 collects its facts through the bicep pack (it
    calls no model), and a page for it clears the coverage gate. Then it runs the blocking
    gates and apm audit --ci there. It runs when -Name is not given or names
    setup-script.

    With -Upgrade the script runs the upgrade pass instead. A real consumer never installs from
    scratch: it takes a new version with the Update-AiSdlc.ps1 of the version it has. So for each
    selected folder under test-consumers/ that exists at the previous release tag, the script:

    1. copies the test consumer as it was at that tag, from a worktree of this clone;
    2. points its apm.yml at the AI.SDLC remote at that tag, installs it and commits the install;
    3. runs the Update-AiSdlc.ps1 that the old version installed, with -Ref the branch under test;
    4. fails when a skill folder of a retired name is left behind, prints what Find-RetiredSkillNames.ps1
       of the new version finds, then runs the blocking gates and apm audit --ci.

    Both passes run the tests of the installed scripts (-IncludeToolTests), on purpose. Some of those
    tests read files of the consumer outside their own fixtures: Check-AgentsFileSize.Tests.ps1 reads
    its AGENTS.md, Check-DocSectionRefs.Tests.ps1 scans the whole repository, and
    PullRequestFeedback.Tests.ps1 reads .claude/settings.json. In the upgrade pass those files come from
    the old release, so the two passes do not test the same input. Before you drop a test run because
    its input looks the same, list every file its tests read outside their fixtures.

    APM installs only from a remote: it does not take a file:// source. So the branch under test must
    be pushed. A public AI.SDLC needs no token; for a private one, APM signs in with GITHUB_APM_PAT.

    When the clone has no release tag at all, as before the first release, there is no older version
    to upgrade from: the pass says so and passes.

.PARAMETER Upgrade
    Run the upgrade pass, and not the fresh install or the setup-script consumer.

.PARAMETER UpgradeFrom
    The tag to upgrade from. Defaults to the newest release tag in this clone below the newest version
    in CHANGELOG.md. The clone needs its tags.

.PARAMETER UpgradeTo
    The ref to upgrade to: a pushed branch or tag. Defaults to the head branch of the pull request in
    a workflow, else the branch of this clone.

.PARAMETER SourceUrl
    The git URL of AI.SDLC. Defaults to aiSdlc.repositoryUrl in config/defaults.json
    (https://github.com/RobHofmann/AI.SDLC).

.PARAMETER RepoRoot
    The AI.SDLC repository root. Defaults to the folder above this script.

.PARAMETER Name
    Test only these consumers. Defaults to every folder under test-consumers/.

.PARAMETER Ci
    Report each failure as a GitHub Actions error annotation.

.PARAMETER Keep
    Keep the temporary folders, to look at an install by hand.

.PARAMETER WorkRoot
    The temporary folder the consumers are copied to. The script empties it first and removes it at the
    end unless -Keep is passed, and then names it. Defaults to a new aisdlc-consumers-<8 characters>
    folder in the temp folder for each run, so two runs at the same time do not share a folder.

.EXAMPLE
    pwsh tools/Test-Consumers.ps1

.EXAMPLE
    pwsh tools/Test-Consumers.ps1 -Name bicep-only -Keep

.EXAMPLE
    pwsh tools/Test-Consumers.ps1 -Upgrade -Name full -UpgradeFrom v1.0.0
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string[]]$Name,
    [switch]$Ci,
    [switch]$Keep,
    [string]$WorkRoot = (Join-Path ([IO.Path]::GetTempPath()) ('aisdlc-consumers-' + [guid]::NewGuid().ToString('n').Substring(0, 8))),
    [switch]$Upgrade,
    [string]$UpgradeFrom,
    [string]$UpgradeTo,
    [string]$SourceUrl
)

$ErrorActionPreference = 'Stop'

# The gates and tests inside a test consumer see no workflow, so their warnings and fixture errors do
# not become annotations of this run. This script reports the result itself (-Ci).
Remove-Item Env:GITHUB_ACTIONS -ErrorAction SilentlyContinue
# apm install writes the value of AISDLC_SONAR_MCP_TOKEN into the .mcp.json of the sonarcloud pack, and
# its gate then fails. A test consumer gets the placeholder, as in the pipeline. SONAR_TOKEN goes too:
# an upgrade test can install an older release, which named it, and the gate fails on its value.
Remove-Item Env:AISDLC_SONAR_MCP_TOKEN -ErrorAction SilentlyContinue
Remove-Item Env:SONAR_TOKEN -ErrorAction SilentlyContinue

$testRoot = Join-Path $RepoRoot 'test-consumers'
$consumers = @(Get-ChildItem -LiteralPath $testRoot -Directory | Where-Object { -not $Name -or $_.Name -in $Name } | Sort-Object Name)
if ($consumers.Count -eq 0 -and $Name -notcontains 'setup-script') {
    Write-Host "No test consumer found under $testRoot." -ForegroundColor Yellow
    exit 2
}

if (-not (Get-Command apm -ErrorAction SilentlyContinue)) {
    Write-Host 'Could not check: apm is not on the PATH. Install the pinned version first: pwsh core/.apm/skills/ai-sdlc-gates/scripts/Install-Apm.ps1 -AddToPath.' -ForegroundColor Yellow
    exit 2
}

$failures = [System.Collections.Generic.List[string]]::new()
function Add-Failure {
    param([string]$Consumer, [string]$Text)
    $line = "$($Consumer): $Text"
    $failures.Add($line)
    if ($Ci) { Write-Host "::error title=Test consumer::Test consumer $line" } else { Write-Host "  FAIL $line" -ForegroundColor Red }
}

$work = $WorkRoot
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Path $work | Out-Null

function Assert-FixtureRepo {
    param([string]$Path)
    $top = [string](git -C $Path rev-parse --show-toplevel 2>$null)
    if (-not $top.Trim() -or [IO.Path]::GetFullPath($top.Trim()).TrimEnd('\', '/') -ne [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')) {
        throw "The work folder $Path is not a git repository of its own, so no git command runs there. Another run may have removed it."
    }
}

function Initialize-FixtureRepo {
    param([string]$Path, [string]$Branch)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "The work folder $Path is not a git repository of its own, because it does not exist. Another run may have removed it." }
    $branchArgs = if ($Branch) { @('-b', $Branch) } else { @() }
    git -C $Path init --quiet @branchArgs 2>$null
    Assert-FixtureRepo -Path $Path
    git -C $Path config --local user.email ci@example.invalid
    git -C $Path config --local user.name ci
}

function Save-FixtureCommit {
    param([string]$Path, [string]$Message)
    Assert-FixtureRepo -Path $Path
    git -C $Path add -A *> $null
    git -C $Path commit -m $Message --quiet *> $null
}

# The newest release tag below the newest version in CHANGELOG.md: the version a consumer has before it takes this one.
function Get-PreviousRelease {
    $newest = [regex]::Match((Get-Content -LiteralPath (Join-Path $RepoRoot 'CHANGELOG.md') -Raw), '(?m)^## v(\d+\.\d+\.\d+) ').Groups[1].Value
    if (-not $newest) { return $null }
    $older = @(git -C $RepoRoot tag -l 'v*' | Where-Object { $_ -match '^v\d+\.\d+\.\d+$' -and [version]$_.Substring(1) -lt [version]$newest })
    return ($older | Sort-Object { [version]$_.Substring(1) } | Select-Object -Last 1)
}

# Rewrites each local package path of a test consumer (- ../../core) as a git source at a ref.
function ConvertTo-GitSource {
    param([string]$Manifest, [string]$Url, [string]$Ref)
    $text = [IO.File]::ReadAllText($Manifest)
    $text = [regex]::Replace($text, '(?m)^(?<indent>\s*)- \.\./\.\./(?<path>\S+)\s*$', {
            param($m)
            $i = $m.Groups['indent'].Value
            "$i- git: $Url`n$i  path: $($m.Groups['path'].Value)`n$i  ref: $Ref"
        })
    [IO.File]::WriteAllText($Manifest, $text)
}

function Invoke-UpgradePass {
    $from = if ($UpgradeFrom) { $UpgradeFrom } else { Get-PreviousRelease }
    $to = if ($UpgradeTo) { $UpgradeTo }
          elseif ($env:GITHUB_HEAD_REF) { $env:GITHUB_HEAD_REF }
          elseif ($env:GITHUB_REF_NAME) { $env:GITHUB_REF_NAME }
          else { (git -C $RepoRoot rev-parse --abbrev-ref HEAD).Trim() }
    $url = $SourceUrl
    if (-not $url) {
        $defaults = Get-Content -LiteralPath (Join-Path $RepoRoot 'config' 'defaults.json') -Raw | ConvertFrom-Json
        $url = $defaults.aiSdlc.repositoryUrl
    }
    if (-not $from -and -not $UpgradeFrom -and @(git -C $RepoRoot tag -l 'v*').Count -eq 0) {
        Write-Host 'Upgrade pass: this clone has no release tag yet, so there is no older version to upgrade from. Nothing to check.' -ForegroundColor Yellow
        return
    }
    if (-not $from) { Add-Failure 'upgrade' 'no release tag below the newest version of CHANGELOG.md in this clone; fetch the tags, or pass -UpgradeFrom'; return }
    Write-Host "Upgrade pass: from $from to $to, from $url" -ForegroundColor Cyan

    $old = Join-Path $work '_old'
    git -C $RepoRoot worktree add --quiet --detach $old $from 2>&1 | Write-Host
    if ($LASTEXITCODE -ne 0) { Add-Failure 'upgrade' "git worktree add at $from failed"; return }
    try {
        foreach ($consumer in $consumers) {
            Invoke-UpgradeConsumer -Name $consumer.Name -OldSource (Join-Path $old 'test-consumers' $consumer.Name) -From $from -To $to -Url $url
        }
    }
    finally { git -C $RepoRoot worktree remove --force $old *> $null }
}

function Invoke-UpgradeConsumer {
    param([string]$Name, [string]$OldSource, [string]$From, [string]$To, [string]$Url)
    Write-Host ""
    Write-Host "===== Upgrade of test consumer: $Name ($From to $To) =====" -ForegroundColor Cyan
    if (-not (Test-Path -LiteralPath $OldSource)) { Write-Host "  $Name did not exist at $From; nothing to upgrade."; return }
    $target = Join-Path $work "upgrade-$Name"
    Copy-Item -LiteralPath $OldSource -Destination $target -Recurse
    ConvertTo-GitSource -Manifest (Join-Path $target 'apm.yml') -Url $Url -Ref $From

    Push-Location $target
    try {
        Initialize-FixtureRepo -Path $target
        & apm install 2>&1 | Write-Host
        if ($LASTEXITCODE -ne 0) { Add-Failure $Name "apm install of $From exited $LASTEXITCODE"; return }
        Remove-Item -LiteralPath (Join-Path $target 'apm_modules') -Recurse -Force -ErrorAction SilentlyContinue
        # The rest of an install, as the fresh pass and a real consumer have it: the shared parts of
        # AGENTS.md and the docs index, both written by the scripts of the old version.
        foreach ($step in 'Sync-AgentsFile.ps1', 'Build-DocsIndex.ps1') {
            $oldScript = Join-Path $target '.claude' 'skills' 'ai-sdlc-gates' 'scripts' $step
            if (Test-Path -LiteralPath $oldScript) { & pwsh -NoProfile -File $oldScript -RepoRoot $target 2>&1 | Write-Host }
        }
        Save-FixtureCommit -Path $target -Message "install $From"

        # The update as a consumer runs it: the script of the old version, which installs the new one.
        $update = Join-Path $target '.claude' 'skills' 'ai-sdlc-hooks' 'scripts' 'Update-AiSdlc.ps1'
        if (-not (Test-Path -LiteralPath $update)) { Add-Failure $Name "$From installed no Update-AiSdlc.ps1"; return }
        & pwsh -NoProfile -File $update -RepoRoot $target -Ref $To -NoGates -SkipLongPaths 2>&1 | Write-Host
        if ($LASTEXITCODE -ne 0) { Add-Failure $Name "the Update-AiSdlc.ps1 of $From exited $LASTEXITCODE on the update to $To"; return }
        Remove-Item -LiteralPath (Join-Path $target 'apm_modules') -Recurse -Force -ErrorAction SilentlyContinue
        Save-FixtureCommit -Path $target -Message "update to $To"

        $scripts = Join-Path $target '.claude' 'skills' 'ai-sdlc-gates' 'scripts'
        $manifest = Join-Path $target '.claude' 'skills' 'ai-sdlc-gates' 'sync-manifest.json'
        $retired = if (Test-Path -LiteralPath $manifest) { (Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json -AsHashtable).retired } else { $null }
        foreach ($oldName in @(if ($retired) { $retired.Keys })) {
            foreach ($kind in 'skills', 'agents') {
                $left = Join-Path $target '.claude' $kind $oldName
                if ((Test-Path -LiteralPath $left) -or (Test-Path -LiteralPath "$left.md")) { Add-Failure $Name "the update left .claude/$kind/$oldName behind, a name that a release retired" }
            }
        }
        $find = Join-Path $target '.claude' 'skills' 'ai-sdlc-hooks' 'scripts' 'Find-RetiredSkillNames.ps1'
        if (Test-Path -LiteralPath $find) { & pwsh -NoProfile -File $find -RepoRoot $target 2>&1 | Write-Host }

        & pwsh -NoProfile -File (Join-Path $scripts 'Invoke-LocalGates.ps1') -RepoRoot $target -BlockingOnly -IncludeToolTests 2>&1 | Write-Host
        if ($LASTEXITCODE -ne 0) { Add-Failure $Name "a blocking gate failed after the update from $From (see the log above)" }
        & apm audit --ci 2>&1 | Write-Host
        if ($LASTEXITCODE -ne 0) { Add-Failure $Name "apm audit --ci exited $LASTEXITCODE after the update from $From" }
    }
    finally { Pop-Location }
}

if ($Upgrade) {
    Invoke-UpgradePass
    if (-not $Keep) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    else { Write-Host "Kept the work folder: $work." }
    Write-Host ""
    if ($failures.Count -gt 0) {
        Write-Host ("{0} check(s) failed in the upgrade of {1} test consumer(s)." -f $failures.Count, $consumers.Count) -ForegroundColor Red
        exit 1
    }
    Write-Host ("All {0} test consumer(s) upgrade and pass their gates." -f $consumers.Count) -ForegroundColor Green
    exit 0
}

foreach ($consumer in $consumers) {
    Write-Host ""
    Write-Host "===== Test consumer: $($consumer.Name) =====" -ForegroundColor Cyan
    $target = Join-Path $work $consumer.Name
    Copy-Item -LiteralPath $consumer.FullName -Destination $target -Recurse
    $manifest = Join-Path $target 'apm.yml'
    $root = $RepoRoot.Replace('\', '/').TrimEnd('/')
    [IO.File]::WriteAllText($manifest, ([IO.File]::ReadAllText($manifest) -replace '- \.\./\.\./', "- $root/"))

    Push-Location $target
    try {
        Initialize-FixtureRepo -Path $target
        & apm install 2>&1 | Write-Host
        if ($LASTEXITCODE -ne 0) { Add-Failure $consumer.Name "apm install exited $LASTEXITCODE"; continue }

        $expect = Get-Content -LiteralPath (Join-Path $target 'expect.json') -Raw | ConvertFrom-Json
        foreach ($path in @($expect.present)) {
            if (-not (Test-Path -LiteralPath (Join-Path $target $path))) { Add-Failure $consumer.Name "expected $path to be installed, and it is not" }
        }
        foreach ($path in @($expect.absent)) {
            if (Test-Path -LiteralPath (Join-Path $target $path)) { Add-Failure $consumer.Name "expected $path to be absent, and it is installed" }
        }

        $leaks = @(Get-ChildItem -LiteralPath (Join-Path $target '.claude') -Recurse -File -Include *.md |
            Select-String -Pattern 'apm_modules/' -SimpleMatch)
        foreach ($leak in $leaks) {
            $relLeak = [IO.Path]::GetRelativePath($target, $leak.Path).Replace('\', '/')
            Add-Failure $consumer.Name "$($relLeak):$($leak.LineNumber) links into apm_modules/, which a fresh clone does not have; link another skill as /.claude/skills/<skill>/..."
        }
        Remove-Item -LiteralPath (Join-Path $target 'apm_modules') -Recurse -Force -ErrorAction SilentlyContinue

        $scripts = Join-Path $target '.claude' 'skills' 'ai-sdlc-gates' 'scripts'
        & pwsh -NoProfile -File (Join-Path $scripts 'Sync-AgentsFile.ps1') -RepoRoot $target 2>&1 | Write-Host
        if ($LASTEXITCODE -ne 0) { Add-Failure $consumer.Name "Sync-AgentsFile.ps1 exited $LASTEXITCODE" }
        & pwsh -NoProfile -File (Join-Path $scripts 'Build-DocsIndex.ps1') -RepoRoot $target 2>&1 | Write-Host
        if ($LASTEXITCODE -ne 0) { Add-Failure $consumer.Name "Build-DocsIndex.ps1 exited $LASTEXITCODE" }

        Assert-FixtureRepo -Path $target
        git -C $target add -A *> $null
        $githooks = @(git -C $target ls-files '.claude/skills/ai-sdlc-hooks/githooks')
        if ($githooks.Count -gt 0) { git -C $target update-index --chmod=+x -- @githooks }
        Save-FixtureCommit -Path $target -Message install

        & pwsh -NoProfile -File (Join-Path $scripts 'Invoke-LocalGates.ps1') -RepoRoot $target -BlockingOnly -IncludeToolTests 2>&1 | Write-Host
        if ($LASTEXITCODE -ne 0) { Add-Failure $consumer.Name 'a blocking gate failed in the installed consumer (see the log above)' }

        & apm audit --ci 2>&1 | Write-Host
        if ($LASTEXITCODE -ne 0) { Add-Failure $consumer.Name "apm audit --ci exited $LASTEXITCODE" }
    }
    finally {
        Pop-Location
    }
}

$ranSetupScript = -not $Name -or 'setup-script' -in $Name
if ($ranSetupScript) {
    Write-Host ""
    Write-Host "===== Test consumer: setup-script (Add-AiSdlcConsumer.ps1 on an existing repository) =====" -ForegroundColor Cyan
    $consumerName = 'setup-script'
    $target = Join-Path $work $consumerName
    New-Item -ItemType Directory -Path (Join-Path $target 'docs' 'ops') -Force | Out-Null
    $emDash = [string][char]0x2014
    [IO.File]::WriteAllText((Join-Path $target 'main.bicep'), "param location string = 'westeurope'`n")
    New-Item -ItemType Directory -Path (Join-Path $target 'building-blocks' 'network') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $target 'building-blocks' 'network' 'main.bicep'), "@description('The name of the network.')`nparam name string`nresource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {`n  name: name`n  location: resourceGroup().location`n}`n")
    [IO.File]::WriteAllText((Join-Path $target 'docs' 'guide.md'), "This guide says how the app works $emDash and how to run it.`n")
    [IO.File]::WriteAllText((Join-Path $target 'docs' 'ops' 'runbook.md'), "# Runbook`n`nThe runbook says what to do when the app stops.`n")
    Push-Location $target
    try {
        Initialize-FixtureRepo -Path $target -Branch main
        Save-FixtureCommit -Path $target -Message existing
        & pwsh -NoProfile -File (Join-Path $RepoRoot 'tools' 'Add-AiSdlcConsumer.ps1') -TargetRepo $target -LocalSource $RepoRoot 2>&1 | Write-Host
        if ($LASTEXITCODE -ne 0) { Add-Failure $consumerName "Add-AiSdlcConsumer.ps1 exited $LASTEXITCODE" }
        else {
            $config = Get-Content -LiteralPath (Join-Path $target 'aisdlc.json') -Raw | ConvertFrom-Json
            if (-not $config.github.trunk) { Add-Failure $consumerName 'aisdlc.json has no github.trunk from the defaults' }
            if (-not (Test-Path -LiteralPath (Join-Path $target '.github' 'workflows' 'pr.yml'))) { Add-Failure $consumerName 'the starter workflow was not written' }
            $guide = Get-Content -LiteralPath (Join-Path $target 'docs' 'guide.md') -Raw
            if ($guide.Contains($emDash) -or $guide -notmatch '(?m)^## Related') { Add-Failure $consumerName 'Repair-DocsWiki.ps1 did not bring docs/guide.md up to the wiki rules' }
            Remove-Item -LiteralPath (Join-Path $target 'apm_modules') -Recurse -Force -ErrorAction SilentlyContinue
            $scripts = Join-Path $target '.claude' 'skills' 'ai-sdlc-gates' 'scripts'

            # The documentation route of adopt-docs: the coverage gate finds the building block
            # with no page, New-DocCandidate.ps1 collects its facts from the bicep pack into a facts file,
            # and a page with the unit in its front matter clears the gate. The draft itself is the work of
            # an agent, so the check stops at the facts and writes the page the way a person would.
            if (-not (Test-Path -LiteralPath (Join-Path $target 'docs-functional' 'glossary.md'))) { Add-Failure $consumerName 'the setup script wrote no functional layer' }
            $coverage = & pwsh -NoProfile -Command "& '$(Join-Path $scripts 'Check-DocCoverage.ps1')' -RepoRoot '$target' -AsObject | ConvertTo-Json -Depth 5" | Out-String | ConvertFrom-Json
            if (@($coverage.Missing | ForEach-Object Unit) -notcontains 'building-blocks/network') { Add-Failure $consumerName 'Check-DocCoverage.ps1 did not report building-blocks/network as a unit with no page' }
            $draft = & pwsh -NoProfile -File (Join-Path $target '.claude' 'skills' 'adopt-docs' 'scripts' 'New-DocCandidate.ps1') -Unit 'building-blocks/network' -RepoRoot $target 2>&1 | Out-String
            $draftCode = $LASTEXITCODE
            $candidates = Join-Path $target 'doc-candidates'
            if (Test-Path -LiteralPath $candidates) {
                $draft += (Get-ChildItem -LiteralPath $candidates -Recurse -File -Filter '*.facts.md' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
                Remove-Item -LiteralPath $candidates -Recurse -Force
            }
            if ($draftCode -ne 0 -or $draft -notmatch 'Get-BicepFacts\.ps1' -or $draft -notmatch 'param name: string') { Add-Failure $consumerName "New-DocCandidate.ps1 did not collect the facts of the building block through the bicep pack: $draft" }
            $page = Join-Path $target 'docs' 'building-blocks' 'network.md'
            New-Item -ItemType Directory -Path (Split-Path $page -Parent) -Force | Out-Null
            [IO.File]::WriteAllText($page, "---`nunits:`n  - building-blocks/network`n---`n# network`n`nThe network building block deploys one virtual network. The [guide](../guide.md) says how the app uses it.`n`n## Related`n`n- [Guide](../guide.md) - how the app works.`n- [Index](../index.md) - every page of this wiki.`n")
            [IO.File]::AppendAllText((Join-Path $target 'docs' 'guide.md'), "- [Network](building-blocks/network.md) - the network the app runs in.`n")
            & pwsh -NoProfile -File (Join-Path $scripts 'Build-DocsIndex.ps1') -RepoRoot $target 2>&1 | Write-Host
            & pwsh -NoProfile -File (Join-Path $scripts 'Check-DocCoverage.ps1') -RepoRoot $target 2>&1 | Write-Host
            if ($LASTEXITCODE -ne 0) { Add-Failure $consumerName 'Check-DocCoverage.ps1 still fails after the page for building-blocks/network was written' }

            Save-FixtureCommit -Path $target -Message install
            & pwsh -NoProfile -File (Join-Path $scripts 'Invoke-LocalGates.ps1') -RepoRoot $target -BlockingOnly 2>&1 | Write-Host
            if ($LASTEXITCODE -ne 0) { Add-Failure $consumerName 'a blocking gate failed after the setup script (see the log above)' }
            & apm audit --ci 2>&1 | Write-Host
            if ($LASTEXITCODE -ne 0) { Add-Failure $consumerName "apm audit --ci exited $LASTEXITCODE" }
        }
    }
    finally { Pop-Location }
}

if (-not $Keep) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
else { Write-Host "Kept the work folder: $work." }

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host ("{0} check(s) failed across {1} test consumer(s)." -f $failures.Count, ($consumers.Count + [int]$ranSetupScript)) -ForegroundColor Red
    exit 1
}
Write-Host ("All {0} test consumer(s) install and pass their gates." -f ($consumers.Count + [int]$ranSetupScript)) -ForegroundColor Green
exit 0
