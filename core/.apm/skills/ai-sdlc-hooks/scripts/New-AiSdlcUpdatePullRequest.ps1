#Requires -Version 7
<#
.SYNOPSIS
    Takes a new release of the shared AI-SDLC on its own branch and opens one pull request for it, so a
    repository pulls each release itself.

.DESCRIPTION
    AI.SDLC does not know who installs it. Each consumer takes a release itself: a person through the
    update-ai-sdlc skill, or the scheduled workflow ai-sdlc-update.yml. Both run this script. It:

    1. reads the AI.SDLC source and the pinned refs from apm.yml, and picks the newest release tag on the
       source when -Ref is not given. When apm.yml already pins that tag, it says so and stops;
    2. stops when the working tree has changes, or when the branch ai-sdlc-<tag> is already on origin,
       so a second run never opens a second pull request;
    3. reads the tag message and CHANGELOG.md of that tag from the source, in a temporary bare clone of
       one commit. The first issue number in the tag message (#12) is the story key. It names an issue of
       the source, as owner/name#12, because the source is a GitHub URL. The consumer's PR-story check
       accepts it, because tracker.acceptedRepositories lists the source and a closed issue counts;
    4. makes the branch from origin/<trunk> (github.trunk in aisdlc.json, main by default), and runs the
       installed Update-AiSdlc.ps1 -Ref <tag> -NoGates, which moves the refs, installs and stages. The
       pull request workflow runs the gates, so this script does not;
    5. commits, with the story key in the title and Refs <key> in the body, never Fixes;
    6. builds the description. It runs the Find-RetiredSkillNames.ps1 that the new version installed and
       lists each line of this repository's own files that still uses an old skill name. A file whose name
       marks it as history is listed apart, with the paths.historyPaths entry to add instead. A "Before you
       merge" list names each step, with the "What a consumer does" text of each release in CHANGELOG.md
       after the pinned version, up to the tag. What does not fit in 4000 characters goes to a comment;
    7. pushes the branch to origin and opens the pull request with gh pr create --body-file;
    8. closes each open update pull request of an older release (branch ai-sdlc-v<older>), with a comment
       that names the new one. A release holds every earlier one.

    The script runs this repository's own installed scripts in its own clone, so it trusts them. A person
    reviews and merges the pull request (Checkpoint Bravo).

    In the workflow, git and gh sign in with the token of the checkout and GH_TOKEN: a GitHub App token, so
    the pull request starts the workflows that its required checks need. Locally it uses your git
    credential and gh auth login, and the pre-push hook runs the gates as for any push.

    Exit codes: 0 opened a pull request, or nothing to do; 1 a step failed; 2 could not start (changes in
    the working tree, or no gh).

.PARAMETER Ref
    The AI.SDLC tag to take, for example v1.2.0. Defaults to the newest tag without a suffix.

.PARAMETER IncludePreRelease
    With no -Ref, also consider tags with a suffix, such as v1.2.0-rc.1.

.PARAMETER RepoRoot
    The repository root. Defaults to the git root of the current folder.

.PARAMETER SkipPullRequestCreation
    Push the branch but do not call gh: no pull request, no comment, no closed pull request.

.PARAMETER DescriptionFolder
    Also write the pull request body to body.md, and the comment to comment.md, in this folder.

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-hooks/scripts/New-AiSdlcUpdatePullRequest.ps1 -WhatIf

.EXAMPLE
    pwsh .claude/skills/ai-sdlc-hooks/scripts/New-AiSdlcUpdatePullRequest.ps1 -Ref v1.2.0
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Ref,
    [switch]$IncludePreRelease,
    [string]$RepoRoot,
    [switch]$SkipPullRequestCreation,
    [string]$DescriptionFolder
)

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = (git rev-parse --show-toplevel).Trim() }
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
. (Join-Path $PSScriptRoot 'AiSdlcSetup.ps1')
Import-Module (Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts' 'AiSdlcConfig.psm1') -Force

$pin = Get-AiSdlcPin -RepoRoot $RepoRoot
if (-not $Ref) { $Ref = Get-AiSdlcReleaseTag -Url $pin.Url -IncludePreRelease:$IncludePreRelease }
if (@($pin.Current).Count -eq 1 -and $pin.Current[0] -eq $Ref -and $pin.AllPinned) {
    Write-Host "Already on $Ref; nothing to update."
    exit 0
}

$config = Get-AiSdlcConfig -RepoRoot $RepoRoot
$trunk = if ($config.github.trunk) { [string]$config.github.trunk } else { 'main' }
$branch = "ai-sdlc-$Ref"

if (git -C $RepoRoot status --porcelain) {
    Write-Host "Could not start: the working tree has changes. Commit or stash them, then run this again." -ForegroundColor Yellow
    exit 2
}
if (-not $SkipPullRequestCreation -and -not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Host 'Could not start: the GitHub CLI (gh) is missing, and it opens the pull request. Install it and run gh auth login, or pass -SkipPullRequestCreation.' -ForegroundColor Yellow
    exit 2
}
$onOrigin = git -C $RepoRoot ls-remote --heads origin $branch
if ($LASTEXITCODE -ne 0) { Write-Host 'git ls-remote on origin failed, so the script cannot tell whether the update branch exists.' -ForegroundColor Red; exit 1 }
if ($onOrigin) { Write-Host "The branch $branch is already on origin, so its pull request is open or merged; nothing to do."; exit 0 }

# The tag message and the changelog of the release, from a bare clone of that one commit.
$sourceCopy = Join-Path ([IO.Path]::GetTempPath()) ('ai-sdlc-release-' + [guid]::NewGuid().ToString('n'))
$changelog = Join-Path $sourceCopy 'CHANGELOG.md'
try {
    git init --quiet --bare $sourceCopy
    git -C $sourceCopy fetch --quiet --depth 1 $pin.Url "refs/tags/$($Ref):refs/tags/$Ref"
    if ($LASTEXITCODE -ne 0) { Write-Host "Could not fetch the tag $Ref from $($pin.Url)." -ForegroundColor Red; exit 1 }
    $message = (git -C $sourceCopy for-each-ref --format='%(contents)' "refs/tags/$Ref") -join "`n"
    $text = git -C $sourceCopy show "$($Ref):CHANGELOG.md" 2>$null
    if ($LASTEXITCODE -eq 0) { [IO.File]::WriteAllText($changelog, ($text -join "`n")) }
}
catch { Write-Host "Could not read the release $Ref from $($pin.Url): $_" -ForegroundColor Red; exit 1 }

$sourceRepository = [regex]::Match($pin.Url, '^https://github\.com/(?<name>[^/]+/[^/]+?)(\.git)?/?$').Groups['name'].Value
$issue = [regex]::Match($message, '(?<![\w&/#])#(\d+)\b').Groups[1].Value
$storyText = if ($issue -and $sourceRepository) { "$sourceRepository#$issue" } else { '' }
if (-not $storyText) { Write-Host "No story key: the message of tag $Ref names no issue (#<number>), or the source is not on GitHub. The pull request carries no key, so the PR-story check of this repository may fail." -ForegroundColor Yellow }
$title = "$(if ($storyText) { "${storyText}: " })take the shared AI-SDLC at $Ref"

if (-not $PSCmdlet.ShouldProcess($RepoRoot, "take $Ref on the branch $branch, push it and open a pull request to $trunk")) {
    Remove-Item -LiteralPath $sourceCopy -Recurse -Force -ErrorAction SilentlyContinue
    exit 0
}

# The release a ref names: v1.4.0 gives 1.4.0, and v1.0.0-rc.3 gives 1.0.0 as a pre-release. A branch gives $null.
function Get-ReleaseOfRef {
    param([string]$Value)
    if ($Value -match '^v(\d+\.\d+\.\d+)(-\S+)?$') { return [pscustomobject]@{ Name = $Value; Version = [version]$Matches[1]; PreRelease = [bool]$Matches[2] } }
    return $null
}

# The "What a consumer does" text of each release after $From, up to and including $To, as CHANGELOG.md
# writes it. A text runs to the first blank line that a list item or an indented line does not follow.
# A "- " bullet becomes "* ", so a step reads as one list in the description.
function Get-ConsumerStep {
    param([string]$Path, $From, $To)
    $steps = [System.Collections.Generic.List[pscustomobject]]::new()
    if (-not $From -or -not $To -or -not (Test-Path -LiteralPath $Path)) { return $steps }
    $lines = (Get-Content -LiteralPath $Path -Raw) -split "\r?\n"
    $release = $null
    $i = 0
    while ($i -lt $lines.Count) {
        if ($lines[$i] -match '^## v(\d+\.\d+\.\d+)(\S*)') {
            $version = [version]$Matches[1]
            $after = if ($From.PreRelease) { $version -ge $From.Version } else { $version -gt $From.Version }
            $release = if (-not $Matches[2] -and $after -and $version -le $To.Version) { "v$($Matches[1])" } else { $null }
        }
        elseif ($release -and $lines[$i] -match '^What a consumer does') {
            $block = [System.Collections.Generic.List[string]]::new()
            while ($i -lt $lines.Count -and $lines[$i] -notmatch '^#') {
                if (-not $lines[$i].Trim()) {
                    $next = if ($i + 1 -lt $lines.Count) { $lines[$i + 1] } else { '' }
                    if ($next -notmatch '^(\s*- |\s{2,}\S)') { break }
                }
                $block.Add(($lines[$i] -replace '^(\s*)- ', '$1* '))
                $i++
            }
            $steps.Add([pscustomobject]@{ Release = $release; Text = ($block -join "`n").TrimEnd() })
            continue
        }
        $i++
    }
    return $steps
}

# The description of the update pull request, and the comment for what does not fit in its 4000 characters.
function New-UpdateDescription {
    param([string]$From, [bool]$NamesChecked, [object[]]$Finding, [object[]]$Step)
    $intro = "Takes the shared AI-SDLC at $Ref$(if ($From) { ", from $From" }). The AI.SDLC changelog lists what changed. A person reviews and merges this pull request."
    $range = if ($From) { "from $From to $Ref" } else { "up to $Ref" }
    if ($NamesChecked -and $Finding.Count -eq 0 -and $Step.Count -eq 0) {
        return [pscustomobject]@{ Description = "$intro`n`nNo file of this repository uses an old skill name, and no release $range lists steps for a consumer."; Comment = $null }
    }

    $historyName = '(?i)(^|[-_. ])(changes?|changelog|history|release[-_]?notes|log)([-_. ]|$)'
    $history = @($Finding | Where-Object { (Split-Path $_.File -Leaf) -match $historyName })
    $living = @($Finding | Where-Object { (Split-Path $_.File -Leaf) -notmatch $historyName })
    $names = [System.Collections.Generic.List[string]]@('## Old skill names in this repository''s own files', '')
    $fullList = @(@($living) + @($history) | ForEach-Object { "* ``$($_.File):$($_.Line)`` $($_.Text)" })
    $perFile = @()
    if (-not $NamesChecked) { $names.Add("Old skill names were not checked: $Ref installed no Find-RetiredSkillNames.ps1 in this repository.") }
    elseif ($Finding.Count -eq 0) { $names.Add('No file of this repository uses an old skill name.') }
    else {
        $files = @($Finding | Group-Object File | Sort-Object @{ Expression = 'Count'; Descending = $true }, Name)
        $perFile = @($files | ForEach-Object { "* ``$($_.Name)``: $($_.Count) line(s)" })
        if ($living.Count -gt 0) {
            $livingFiles = @($living | Select-Object -ExpandProperty File -Unique)
            $names.Add("$($living.Count) line(s) in $($livingFiles.Count) file(s) still use a skill name that a release retired. An agent or a person that follows such a name finds no skill. Change each to the new name in this pull request.")
            $names.Add('')
        }
        if ($history.Count -gt 0) {
            $historyFiles = @($history | Select-Object -ExpandProperty File -Unique | Sort-Object)
            $shown = @($historyFiles | Select-Object -First 10 | ForEach-Object { """$_""" })
            $names.Add("$($history.Count) line(s) in $($historyFiles.Count) file(s) whose name marks them as history, such as a change list. Do not rename what a history file records. Add those files to paths.historyPaths in aisdlc.json in this pull request, so the scan leaves them out. A glob such as ``docs/changes/*.md`` covers many files in one entry. For example:")
            $names.Add('')
            $names.Add("    ""historyPaths"": [$($shown -join ', ')$(if ($historyFiles.Count -gt 10) { ', ...' })]")
            $names.Add('')
        }
    }

    $todo = [System.Collections.Generic.List[string]]::new()
    if ($living.Count -gt 0) { $todo.Add('* Rename the old skill names in the living files listed below.') }
    if ($history.Count -gt 0) { $todo.Add('* Add the history files listed below to paths.historyPaths in aisdlc.json.') }
    if ($Step.Count -gt 0) { $todo.Add('* Do the steps that the release asks of this repository, listed below.') }
    if ($todo.Count -gt 0) {
        $intro = (@($intro, '', '## Before you merge', '', 'Do these in this pull request. A step left for after the merge needs a second pull request.', '') + $todo) -join "`n"
    }

    $stepLines = [System.Collections.Generic.List[string]]@('## What the release asks of this repository', '')
    if ($Step.Count -eq 0) { $stepLines.Add("No release $range lists steps for a consumer.") }
    foreach ($release in @($Step | Group-Object Release)) {
        $stepLines.AddRange([string[]]@("From the AI.SDLC changelog, $($release.Name):", ''))
        foreach ($s in $release.Group) { $stepLines.AddRange([string[]]@($s.Text, '')) }
    }

    $join = { param([string[]]$Part) (($Part -join "`n").TrimEnd()) }
    $description = & $join (@($intro, '') + $names + $fullList + @('') + $stepLines)
    if ($description.Length -le 4000) { return [pscustomobject]@{ Description = $description; Comment = $null } }

    $comment = & $join (@('The full list of old skill names in this repository''s own files:', '') + $fullList)
    $listNote = @('', 'The full list is in a comment on this pull request.')
    $description = & $join (@($intro, '') + $names + $perFile + $listNote + @('') + $stepLines)
    if ($description.Length -le 4000) { return [pscustomobject]@{ Description = $description; Comment = $comment } }

    # Still too long: keep the files with the most lines in half the room, keep the steps that fit in
    # the rest, and put all the steps in the comment too.
    $keptFiles = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $perFile) {
        if (((& $join (@($intro, '') + $names + $keptFiles)).Length + $line.Length) -gt 2000) { break }
        $keptFiles.Add($line)
    }
    if ($keptFiles.Count -lt $perFile.Count) { $keptFiles.Add("* and $($perFile.Count - $keptFiles.Count) more file(s)") }
    $rest = "The rest of the steps is in the comment on this pull request, and in CHANGELOG.md of AI.SDLC at $Ref."
    $head = & $join (@($intro, '') + $names + $keptFiles + $listNote + @(''))
    $kept = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $stepLines) {
        if (($head.Length + (& $join $kept).Length + $line.Length + $rest.Length + 4) -gt 4000) { break }
        $kept.Add($line)
    }
    $comment = & $join (@($comment, '', 'The steps of each release, from the AI.SDLC changelog:', '') + @($stepLines | Select-Object -Skip 2))
    return [pscustomobject]@{ Description = (& $join (@($head) + $kept + @('', $rest))); Comment = $comment }
}

function Close-SupersededUpdatePullRequest {
    param([string]$NewId)
    $refVersion = (Get-ReleaseOfRef $Ref).Version
    if (-not $refVersion -or (Get-ReleaseOfRef $Ref).PreRelease) { return }
    $json = gh pr list --state open --base $trunk --json number,headRefName
    if ($LASTEXITCODE -ne 0) { $script:failed.Add('gh pr list failed, so older update pull requests stay open'); return }
    foreach ($pr in @(if ($json) { ($json -join "`n") | ConvertFrom-Json })) {
        if ("$($pr.number)" -eq "$NewId" -or $pr.headRefName -notmatch '^ai-sdlc-v(\d+\.\d+\.\d+)$') { continue }
        if ([version]$Matches[1] -ge $refVersion) { continue }
        gh pr close $pr.number --comment "Superseded by pull request #$NewId, which takes $Ref. A release holds every earlier one, so this pull request is closed." | Out-Null
        if ($LASTEXITCODE -ne 0) { $script:failed.Add("could not close pull request #$($pr.number), superseded by #$NewId"); continue }
        Write-Host "Closed pull request #$($pr.number) ($($pr.headRefName)), superseded by #$NewId."
    }
}

$script:failed = [System.Collections.Generic.List[string]]::new()
Push-Location $RepoRoot
try {
    git fetch --quiet origin $trunk
    if ($LASTEXITCODE -ne 0) { Write-Host "git fetch origin $trunk failed." -ForegroundColor Red; exit 1 }
    git switch --quiet --no-track -c $branch "origin/$trunk"
    if ($LASTEXITCODE -ne 0) { Write-Host "Could not make the branch $branch from origin/$trunk." -ForegroundColor Red; exit 1 }

    # The update script of the version this repository has now; it moves the refs, installs and stages.
    try { & (Join-Path $PSScriptRoot 'Update-AiSdlc.ps1') -RepoRoot $RepoRoot -Ref $Ref -NoGates }
    catch { Write-Host "Update-AiSdlc.ps1 stopped: $_" -ForegroundColor Red; $global:LASTEXITCODE = 1 }
    if ($LASTEXITCODE -ne 0) { Write-Host "Update-AiSdlc.ps1 exited $LASTEXITCODE; the branch $branch holds the staged files, and nothing is pushed." -ForegroundColor Red; exit 1 }
    git commit --quiet -m $title -m "Moves every AI.SDLC ref to $Ref and installs it. The pull request workflow of this repository runs the gates.$(if ($storyText) { "`n`nRefs $storyText" })"
    if ($LASTEXITCODE -ne 0) { Write-Host 'Nothing to commit after the update.' -ForegroundColor Red; exit 1 }

    # The oldest release this repository pinned is where the steps of the changelog start.
    $from = @($pin.Current | ForEach-Object { Get-ReleaseOfRef $_ } | Where-Object { $_ } | Sort-Object Version, @{ Expression = { -not $_.PreRelease } })[0]
    $find = Join-Path $RepoRoot '.claude' 'skills' 'ai-sdlc-hooks' 'scripts' 'Find-RetiredSkillNames.ps1'
    $namesChecked = Test-Path -LiteralPath $find
    $pattern = '^\s+(?<file>.+?):(?<line>\d+)\s+(?<text>\S+ -> .+)$'
    $findings = @(if ($namesChecked) {
            pwsh -NoProfile -File $find -RepoRoot $RepoRoot 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match $pattern } | ForEach-Object {
                $null = $_ -match $pattern
                [pscustomobject]@{ File = $Matches.file; Line = $Matches.line; Text = $Matches.text.Trim() }
            }
        })
    $steps = @(Get-ConsumerStep -Path $changelog -From $from -To (Get-ReleaseOfRef $Ref))
    $text = New-UpdateDescription -From $from.Name -NamesChecked $namesChecked -Finding $findings -Step $steps
    $body = if ($storyText) { "Refs $storyText`n`n$($text.Description)" } else { $text.Description }
    if ($DescriptionFolder) {
        New-Item -ItemType Directory -Path $DescriptionFolder -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $DescriptionFolder 'body.md'), $body)
        if ($text.Comment) { [IO.File]::WriteAllText((Join-Path $DescriptionFolder 'comment.md'), $text.Comment) }
    }

    git push --quiet --set-upstream origin $branch
    if ($LASTEXITCODE -ne 0) { Write-Host "Pushing $branch to origin failed; the commit is on the local branch." -ForegroundColor Red; exit 1 }
    if ($SkipPullRequestCreation) { Write-Host "Pushed $branch; no pull request opened (-SkipPullRequestCreation)."; exit 0 }

    $bodyFile = Join-Path $sourceCopy 'body.md'
    [IO.File]::WriteAllText($bodyFile, $body, [Text.UTF8Encoding]::new($false))
    $url = gh pr create --head $branch --base $trunk --title $title --body-file $bodyFile
    if ($LASTEXITCODE -ne 0) { Write-Host "gh pr create failed; the branch $branch is pushed. Open the pull request by hand." -ForegroundColor Red; exit 1 }
    $newId = [regex]::Match("$url", '/pull/(\d+)').Groups[1].Value
    Write-Host "Opened pull request #$newId from ${branch}: $url"
    if ($text.Comment) {
        $commentFile = Join-Path $sourceCopy 'comment.md'
        [IO.File]::WriteAllText($commentFile, $text.Comment, [Text.UTF8Encoding]::new($false))
        gh pr comment $newId --body-file $commentFile | Out-Null
        if ($LASTEXITCODE -ne 0) { $script:failed.Add("the comment with the full list of old skill names failed on pull request #$newId") }
    }
    Close-SupersededUpdatePullRequest -NewId $newId
}
finally {
    Pop-Location
    Remove-Item -LiteralPath $sourceCopy -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failed.Count -gt 0) {
    $script:failed | ForEach-Object { Write-Host "FAILED $_" -ForegroundColor Red }
    exit 1
}
exit 0
