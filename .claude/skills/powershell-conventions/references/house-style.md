# PowerShell house style

These are the PowerShell rules. Write new and changed PowerShell this way.

A rule holds for a new script and for the code a change adds. A change does not rewrite the rest of an
older script to the new rules. An older script with `Set-StrictMode -Version Latest` keeps it.

Each rule names its public source (clause C07). The examples use made-up names. The points that are not
decided are on [not-decided.md](not-decided.md).

## A help block that names the output

Comment-based help is a `<# ... #>` block at the top of a script or function, which `Get-Help` reads.
Every script has one, and so does every public function of a module. An inline helper function inside
a script has none: its name and typed parameters say enough. It holds:

- `.SYNOPSIS`, one line on what the script does;
- a short `.DESCRIPTION`, a few lines that point at the ADR or docs page for the reasons;
- a `.PARAMETER` for each parameter;
- an `.EXAMPLE`;
- `.OUTPUTS`, or `[OutputType()]` on the script, when it returns something. So a caller knows what
  comes back without reading the code.

```powershell
<#
.SYNOPSIS
    Gets the open orders of one customer.

.DESCRIPTION
    Reads the orders of the customer and returns the ones that are still open.

.PARAMETER CustomerId
    The customer whose orders are read.

.EXAMPLE
    ./Get-OpenOrder.ps1 -CustomerId 'C-1001'

.OUTPUTS
    System.Management.Automation.PSCustomObject for each open order.
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)]
    [string]$CustomerId
)
```

The help block is the doc comment that clause C10 asks for in a PowerShell file; the full rule is on
[comments.md](/.claude/skills/ai-sdlc-handbook/references/comments.md). After the help block, the script
starts as the next section shows.

Source: Microsoft
[about_Comment_Based_Help](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_comment_based_help)
and [about_Functions_OutputTypeAttribute](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_functions_outputtypeattribute).

## How a script starts

Every new script starts with `[CmdletBinding()]` and a `param` block, also a small script. Each
parameter has a type. A parameter is `Mandatory` only when it has no good default. Then the script sets
`Set-StrictMode -Version 3.0` and `$ErrorActionPreference = 'Stop'`.

- `[CmdletBinding()]` gives the script the common parameters, such as `-Verbose`.
- `Set-StrictMode -Version 3.0` throws on a variable that was never set, a property that does not exist
  and an index out of range. Without it, such a mistake gives `$null` and the script goes on. `3.0` is
  a fixed version; `Latest` can get stricter with a newer PowerShell.
- `$ErrorActionPreference = 'Stop'` makes every error of a cmdlet stop the script. It does not stop on a
  failed native call, so the exit-code check of the next section still holds.

```powershell
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$CustomerId,

    [ValidateRange(1, 365)]
    [int]$Days = 30
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
```

A gate script of AI.SDLC also starts with `#Requires -Version 7`, as `add-gate` says.

Source: Microsoft
[about_Functions_CmdletBindingAttribute](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_functions_cmdletbindingattribute),
[Set-StrictMode](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/set-strictmode#-version)
and [about_Preference_Variables](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_preference_variables).

## Check the exit code after each native call

A native command is a program outside PowerShell, such as `git`, `gh` or `dotnet`. When it fails, the
script goes on: `$ErrorActionPreference = 'Stop'` does not stop it. PowerShell puts its exit code in
`$LASTEXITCODE`, where 0 means success. So the script checks `$LASTEXITCODE` right after each native
call and throws when it is not 0. A tool that did not start leaves `$LASTEXITCODE` as it was, often 0.
So the check also reads `$?`, which is false when the call failed or did not run. This is the
PowerShell form of the shared rule "branch on the exit code, not the output" of
[code-conventions](/.claude/skills/code-conventions/SKILL.md).

Do:

```powershell
$issueJson = gh issue view $IssueNumber --json title,state
if (-not $? -or $LASTEXITCODE -ne 0) {
    throw "gh issue view failed or did not run, exit code $LASTEXITCODE"
}
$issue = $issueJson | ConvertFrom-Json
```

Not:

```powershell
$issueJson = gh issue view $IssueNumber --json title,state
$issue = $issueJson | ConvertFrom-Json
```

A gate that cannot check because a tool did not run exits with the code for "could not check" that
`add-gate` names, instead of a throw.

Source: Microsoft
[about_Automatic_Variables](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_automatic_variables),
the part on `$LASTEXITCODE`, and
[about_Preference_Variables](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_preference_variables).

## A main function with helper functions

A script has one main function that calls internal helper functions, and the last line of the script
calls the main function. Each helper does one step that has a name. A function of one line,
or one that only wraps one cmdlet, is not a helper: write its line where it is used.
A test still replaces the cmdlet with Pester `Mock`, not with a wrapper function.

Do:

```powershell
function Get-OpenOrder {
    param([string]$CustomerId)
    $orders = Get-Content -LiteralPath "orders/$CustomerId.json" -Raw | ConvertFrom-Json
    return @($orders | Where-Object { $_.Status -eq 'Open' })
}

function Invoke-OrderReport {
    $openOrders = Get-OpenOrder -CustomerId $CustomerId
    Write-Host "Customer $CustomerId has $($openOrders.Count) open orders"
}

Invoke-OrderReport
```

Not:

```powershell
function Read-Answer {
    param([string]$Prompt)
    return Read-Host -Prompt $Prompt
}
```

A helper function that more than one script uses goes into a `.psm1` module named after what it
holds, and each script loads it with `Import-Module`. It never goes into a dot-sourced helper file. An
existing dot-sourced file stays until a change needs to touch it. In AI.SDLC, `AiSdlcConfig.psm1` is
such a module.

Source: Microsoft
[about_Modules](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_modules)
and the
[PowerShell Practice and Style guide, Function Structure](https://poshcode.gitbook.io/powershell-practice-and-style/style-guide/function-structure).

## Fail loudly, and handle the other case

A script throws as soon as an input or a result is wrong. It uses no default value that
hides a missing one. A `catch` names the error it expects and handles only that one. A `switch` or an
`if` chain over a fixed set of values ends with a default that throws. So a new value fails
at once, and never takes the wrong path in silence.

Do:

```powershell
$region = switch ($Environment) {
    'dev' { 'westeurope' }
    'prd' { 'northeurope' }
    default { throw "Unknown environment '$Environment'" }
}

try {
    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
}
catch [System.Management.Automation.ItemNotFoundException] {
    throw "The settings file $settingsPath does not exist."
}
```

Not:

```powershell
$region = if ($Environment -eq 'prd') { 'northeurope' } else { 'westeurope' }
try { $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json } catch { $settings = @{} }
```

A closed set is still listed in full, as [code-conventions](/.claude/skills/code-conventions/SKILL.md)
says; the default that throws comes on top.

Source: Microsoft
[about_Try_Catch_Finally](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_try_catch_finally)
and [about_Switch](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_switch).

## Which output stream

A message to the person who runs the script uses `Write-Host`. Detail for a person who looks for a
fault uses `Write-Verbose`. Data that a caller uses is `Write-Output` or a plain value.

In a GitHub Actions run, where `GITHUB_ACTIONS` is `true`, a script reports through workflow commands
that it writes to the output:

- `::error file=<path>,line=<n>::<text>` and `::warning ...::` for a finding, so it shows on the run
  summary and next to the file in the pull request;
- `::group::<title>` and `::endgroup::` around a long block of output;
- a line added to the file that `GITHUB_STEP_SUMMARY` names, for a table on the run summary.

Outside GitHub Actions the same script writes plain text. Keep the check of `GITHUB_ACTIONS` in one
helper, so the rest of the script does not branch on it.

```powershell
function Write-Finding {
    param(
        [string]$Path,
        [int]$Line,
        [string]$Message
    )
    if ($env:GITHUB_ACTIONS -eq 'true') {
        Write-Host "::warning file=$Path,line=$Line::$Message"
    }
    else {
        Write-Host "  ${Path}:$Line  $Message"
    }
}
```

The helper takes every value as a parameter, so it reads no variable it did not set. Such a read
throws under `Set-StrictMode`.

A `Get-*` function returns data and writes nothing. Do not `Write-Host` the reason a lookup failed,
and do not `Write-Output` it, because that breaks the return value. Keep the reason in a
script-scoped variable and let the caller report it, or give the function a verb that says it writes.

Source: GitHub
[Workflow commands for GitHub Actions](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands)
and Microsoft
[about_Output_Streams](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_output_streams).

## A pinned module version

Every module a script needs is pinned to a version. Write it in a `#Requires -Modules` line,
or in the requirements file of the repository where it has one. An unpinned module can change under
the script with no change in the repository.

```powershell
#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
```

Which module a script uses for a cloud service, such as a PowerShell module or a command line tool, is
a team choice. Read it from the repository's own pages, or follow the scripts next to the one you
edit.

Source: Microsoft
[about_Requires](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_requires).

## A Pester test per script

Pester is the test framework for PowerShell. Every script that a workflow or a gate runs has a test
file named `<Script>.Tests.ps1`. A file that only defines functions is dot-sourced in `BeforeAll`, and
the test calls its functions. A script that does its work when it runs is called inside the `It`, with
`& $scriptPath` and its parameters, because dot-sourcing would run it during setup. Each test checks
with `Describe`, `It` and `Should`. Tests of the same case are one test, not several copies with a
small change. A test proves the logic of the script, not PowerShell or a module it calls (clause C04).
It replaces a cmdlet with Pester `Mock`, so no product code is added only for the test.

In a consumer repository the test sits where the repository keeps its Pester tests: next to the script,
or in its test folder. A new test follows the tests next to it.

```powershell
Describe 'Get-OrderTotal' {
    BeforeAll {
        . "$PSScriptRoot/OrderFunctions.ps1"
    }

    It 'adds the price of each line' {
        Get-OrderTotal -Lines @(2, 3) | Should -Be 5
    }
}

Describe 'Publish-Order.ps1' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot/Publish-Order.ps1"
    }

    It 'stops when the order file is missing' {
        { & $scriptPath -OrderFile 'missing.json' } | Should -Throw
    }
}
```

In AI.SDLC a shared script keeps its test outside the installed package; see the last section.

Source: [Pester quick start](https://pester.dev/docs/quick-start) and
[Pester Mock](https://pester.dev/docs/usage/mocking).

## The opening brace stays on the same line

The `{` that opens a block stays at the end of the line with the `if`, `foreach` or `function`
that owns it. The closing `}` goes on its own line, and `else` or `catch` starts the line after it.
A `param(` block opens with a bracket, not a brace, so this rule does not cover it.

Do:

```powershell
if ($order.Status -eq 'Open') {
    Write-Host "Order $($order.Id) is open"
}
else {
    Write-Host "Order $($order.Id) is closed"
}
```

Not:

```powershell
if ($order.Status -eq 'Open')
{
    Write-Host "Order $($order.Id) is open"
}
```

Source: the
[PowerShell Practice and Style guide, Code Layout and Formatting](https://poshcode.gitbook.io/powershell-practice-and-style/style-guide/code-layout-and-formatting)
and the [PSScriptAnalyzer rule PlaceOpenBrace](https://learn.microsoft.com/en-us/powershell/utility-modules/psscriptanalyzer/rules/placeopenbrace).

## 4 spaces at the start of a line

Each level of a block starts 4 spaces further in, made with spaces, never with a tab. A line has no
extra spaces at the start beyond its level.

```powershell
foreach ($order in $orders) {
    if ($order.Total -gt 0) {
        Write-Host $order.Id
    }
}
```

Source: the
[PowerShell Practice and Style guide, Code Layout and Formatting](https://poshcode.gitbook.io/powershell-practice-and-style/style-guide/code-layout-and-formatting)
and the [PSScriptAnalyzer rule UseConsistentIndentation](https://learn.microsoft.com/en-us/powershell/utility-modules/psscriptanalyzer/rules/useconsistentindentation).

## Function names use an approved verb

A function or script name has the form Verb-Noun, such as `Get-OrderReport`. The verb comes from the
list that `Get-Verb` prints, such as `Get`, `Set`, `New`, `Remove`, `Start` and `Test`. An approved verb
tells the reader what kind of action the command takes.

Do: `Get-OrderReport`, `New-OrderInvoice`. Not: `Fetch-OrderReport`, `Ensure-OrderInvoice`.

Source: Microsoft
[Approved verbs for PowerShell commands](https://learn.microsoft.com/en-us/powershell/scripting/developer/cmdlet/approved-verbs-for-windows-powershell-commands)
and the [PSScriptAnalyzer rule UseApprovedVerbs](https://learn.microsoft.com/en-us/powershell/utility-modules/psscriptanalyzer/rules/useapprovedverbs).

## Full cmdlet names, no aliases

An alias is a short name for a cmdlet, such as `%` or `foreach` for `ForEach-Object`, `?` or `where`
for `Where-Object`, and `gci` for `Get-ChildItem`. A reader must know them, and they can differ between
platforms. A script writes the full cmdlet name.

Do:

```powershell
$openOrders = Get-ChildItem -Path $orderFolder | Where-Object { $_.Length -gt 0 } |
    ForEach-Object { $_.BaseName }
```

Not:

```powershell
$openOrders = gci $orderFolder | ? { $_.Length -gt 0 } | % { $_.BaseName }
```

Source: [PSScriptAnalyzer rule AvoidUsingCmdletAliases](https://learn.microsoft.com/en-us/powershell/utility-modules/psscriptanalyzer/rules/avoidusingcmdletaliases)
and the
[PowerShell Practice and Style guide, Code Layout and Formatting](https://poshcode.gitbook.io/powershell-practice-and-style/style-guide/code-layout-and-formatting).

## Quotes and names of variables

A string is in single quotes, unless it expands a variable or an expression. A local variable
is camelCase, such as `$orderTotal`. A parameter is PascalCase, such as `$CustomerId`.

Do:

```powershell
$folder = 'orders'
Write-Host "Reading $folder for customer $CustomerId"
```

Not:

```powershell
$Folder = "orders"
```

Source: the
[PowerShell Practice and Style guide, Code Layout and Formatting](https://poshcode.gitbook.io/powershell-practice-and-style/style-guide/code-layout-and-formatting)
and Microsoft
[about_Quoting_Rules](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_quoting_rules).

## Splatting, never a backtick line break

A command too long for one line passes its parameters in a hashtable with `@`, which is called
splatting. A backtick at the end of a line is never written: one space after it breaks the
command.

Do:

```powershell
$exportArgs = @{
    Path     = $reportPath
    Encoding = 'utf8'
    Force    = $true
}
$orders | Export-Csv @exportArgs
```

Not:

```powershell
$orders | Export-Csv -Path $reportPath `
    -Encoding utf8 -Force
```

Source: Microsoft [about_Splatting](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_splatting)
and
[Bye Bye Backtick: Natural Line Continuations](https://get-powershellblog.blogspot.com/2017/07/bye-bye-backtick-natural-line.html).

## Put $null on the left of a comparison

Write `$null -eq $value`, never `$value -eq $null`. When the value is an array, the second form
filters the array and returns the items that are `$null`, instead of testing the value. The first
form always tests it.

Do:

```powershell
if ($null -eq $order) {
    throw 'No order found.'
}
```

Not:

```powershell
if ($order -eq $null)
```

Source: the
[PSScriptAnalyzer rule PossibleIncorrectComparisonWithNull](https://learn.microsoft.com/en-us/powershell/utility-modules/psscriptanalyzer/rules/possibleincorrectcomparisonwithnull)
and Microsoft
[about_Comparison_Operators](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_comparison_operators).

## A comment says why

Clause C10 holds in every language. The help block is the doc comment of a script, and directives
such as `#Requires` are not comments. Inside a body, a comment says why: a hard limit, a workaround
with its issue or link, or a decision that is not obvious. It never says what the next line does, and
it is never commented-out code. A comment that is already there stays.

Source: [comments.md](/.claude/skills/ai-sdlc-handbook/references/comments.md).

## A shared script in AI.SDLC

These rules hold only in AI.SDLC, for a script that a package delivers. A consumer repository does not
follow them; it keeps its scripts and tests where it already keeps them.

- **The script lives in the `scripts/` folder of its skill**, such as
  `core/.apm/skills/<skill>/scripts/Get-OrderTotal.ps1`. APM installs the whole skill folder, so the
  script reaches every consumer with its skill.
- **Its test lives at the mirrored path under `tests/`**, such as
  `core/tests/skills/<skill>/scripts/Get-OrderTotal.Tests.ps1` (ADR 0015). APM installs only `.apm/`,
  so no consumer gets the test. The test finds its script by swapping the `tests` folder in
  `$PSScriptRoot` for `.apm`.
- **A gate follows the shape of [add-gate](/.claude/skills/add-gate/SKILL.md)**: `#Requires -Version 7`,
  a `param` block, the exit codes that `add-gate` names and a `FIX:` line.

## Related

- [The powershell-conventions skill](../SKILL.md) - the short rules.
- [Not decided](not-decided.md) - the PowerShell points that are not decided.
- [Code conventions](/.claude/skills/code-conventions/SKILL.md) - the rules for every language.
