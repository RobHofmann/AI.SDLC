#Requires -Version 7
<#
.SYNOPSIS
    The fixture and the gate discovery that GateContract.Tests.ps1 needs.

.DESCRIPTION
    Get-ContractGate lists every gate the way a repository registers them: each gates.json under
    core/.apm/skills and packs/*/.apm/skills, and the repoGates of aisdlc.json in the AI.SDLC source
    root. A new gate is therefore in the list without anyone editing the test.

    New-EmptyContractFixture makes a git repository that holds only a minimal aisdlc.json, so a gate
    finds nothing to check there.

    Invoke-ContractGate runs one gate script in a child process with a clean environment: no GitHub
    Actions, pull request or SonarCloud variable is set. It returns the exit code, the output and what
    the process wrote to its error stream, which is where an unhandled error goes.

.PARAMETER SourceRoot
    The AI.SDLC source root: the folder that holds core, packs and aisdlc.json.

.EXAMPLE
    Import-Module ./GateContractTestHarness.psm1
    $root = New-EmptyContractFixture -Path (Join-Path $env:TEMP 'empty')
    Get-ContractGate -SourceRoot (Find-ContractSourceRoot -From .) | ForEach-Object { Invoke-ContractGate -Gate $_ -Fixture $root }
#>

$script:EnvironmentPrefixesToRemove = @('PR_', 'GITHUB_', 'RUNNER_', 'SONAR', 'AISDLC_SONAR', 'GIT_')
$script:EnvironmentNamesToRemove = @('CI', 'CHANGED_FILES', 'AISDLC_CHANGE_BASE', 'AISDLC_PRIVATE_TERMS')

function Find-ContractSourceRoot {
    <#
    .SYNOPSIS
        Finds the AI.SDLC source root above a folder, or returns null.
    .PARAMETER From
        The folder to start from.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$From)

    $dir = (Resolve-Path -LiteralPath $From).Path
    while ($dir) {
        if ((Test-Path -LiteralPath (Join-Path $dir 'core' '.apm' 'skills')) -and (Test-Path -LiteralPath (Join-Path $dir 'packs')) -and (Test-Path -LiteralPath (Join-Path $dir 'aisdlc.json'))) { return $dir }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

function Get-ContractGate {
    <#
    .SYNOPSIS
        Lists every gate of the core, the packs and the repoGates of the source root.
    .PARAMETER SourceRoot
        The AI.SDLC source root.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourceRoot)

    $gates = [System.Collections.Generic.List[object]]::new()
    $manifests = @(Get-ChildItem -Path (Join-Path $SourceRoot 'core' '.apm' 'skills' '*' 'gates.json'), (Join-Path $SourceRoot 'packs' '*' '.apm' 'skills' '*' 'gates.json') -File | Sort-Object FullName)
    foreach ($manifest in $manifests) {
        $data = Get-Content -LiteralPath $manifest.FullName -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        foreach ($entry in @($data.gates)) {
            if (-not $entry) { continue }
            $scriptPath = Join-Path $manifest.DirectoryName $entry.script
            $gates.Add([pscustomobject]@{
                    Id       = "$(Split-Path $scriptPath -Leaf) | $($entry.name)"
                    Leaf     = Split-Path $scriptPath -Leaf
                    Script   = $scriptPath
                    Args     = if ($entry.args) { $entry.args } else { @{} }
                    Requires = [string]$entry.requires
                    Source   = "$($data.package) gates.json"
                })
        }
    }
    $config = Get-Content -LiteralPath (Join-Path $SourceRoot 'aisdlc.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    foreach ($entry in @($config.repoGates)) {
        if (-not $entry) { continue }
        $scriptPath = Join-Path $SourceRoot $entry.script
        $gates.Add([pscustomobject]@{
                Id       = "$(Split-Path $scriptPath -Leaf) | $($entry.name)"
                Leaf     = Split-Path $scriptPath -Leaf
                Script   = $scriptPath
                Args     = if ($entry.args) { $entry.args } else { @{} }
                Requires = [string]$entry.requires
                Source   = 'repoGates'
            })
    }
    return @($gates)
}

function New-EmptyContractFixture {
    <#
    .SYNOPSIS
        Makes a git repository that holds only a minimal aisdlc.json.
    .PARAMETER Path
        The folder to make.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    git -C $Path init --quiet -b main
    git -C $Path config user.name 'Fixture Author'
    git -C $Path config user.email 'fixture@example.invalid'
    git -C $Path config core.autocrlf false
    [IO.File]::WriteAllText((Join-Path $Path 'aisdlc.json'), "{ `"repository`": `"Fixture`" }`n", [Text.UTF8Encoding]::new($false))
    return $Path
}

function Get-ContractGateArgument {
    param(
        [Parameter(Mandatory)][object]$Gate,
        [Parameter(Mandatory)][string]$Fixture
    )

    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in '-NoProfile', '-File', $Gate.Script, '-RepoRoot', $Fixture) { $arguments.Add($argument) }
    foreach ($key in $Gate.Args.Keys) {
        $value = $Gate.Args[$key]
        if ($value -is [bool]) {
            if ($value) { $arguments.Add("-$key") }
            continue
        }
        $arguments.Add("-$key")
        $arguments.Add((@($value) -join ','))
    }
    if ($Gate.Requires -eq 'CoverageFile') {
        $arguments.Add('-CoverageFile')
        $arguments.Add((Join-Path $Fixture 'coverage.xml'))
    }
    return , $arguments
}

function Test-PipelineEnvironmentName {
    param([Parameter(Mandatory)][string]$Name)

    if ($Name -in $script:EnvironmentNamesToRemove) { return $true }
    return [bool](@($script:EnvironmentPrefixesToRemove | Where-Object { $Name.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count)
}

function Invoke-ContractGate {
    <#
    .SYNOPSIS
        Runs one gate in a child process with no pipeline variables, and returns its code and output.
    .PARAMETER Gate
        A gate from Get-ContractGate, or an object with Script, Args and Requires.
    .PARAMETER Fixture
        The repository to run the gate in.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Gate,
        [Parameter(Mandatory)][string]$Fixture
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME ($IsWindows ? 'pwsh.exe' : 'pwsh')))
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.WorkingDirectory = $Fixture
    foreach ($argument in (Get-ContractGateArgument -Gate $Gate -Fixture $Fixture)) { $psi.ArgumentList.Add($argument) }
    foreach ($name in @($psi.Environment.Keys | Where-Object { Test-PipelineEnvironmentName -Name $_ })) { [void]$psi.Environment.Remove($name) }
    $process = [System.Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    return [pscustomobject]@{ Code = $process.ExitCode; Output = $stdout.Result; Error = $stderr.Result }
}

Export-ModuleMember -Function Find-ContractSourceRoot, Get-ContractGate, New-EmptyContractFixture, Invoke-ContractGate
