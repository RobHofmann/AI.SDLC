#requires -Version 7.4

Describe 'Invoke-DocGraphLink' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-DocGraphLink.ps1'

        $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
        if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
        Import-Module (Join-Path $aiSdlcGates 'DocToolTestHarness.psm1') -Force

        function New-Repo {
            param([hashtable]$Files)
            return New-DocToolRepo -Files $Files -Prefix 'dgl' -InitialiseGit
        }

        function New-Graph {
            param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$SourceFiles)
            $nodes = @()
            foreach ($f in $SourceFiles) {
                $nodes += [pscustomobject]@{
                    id          = ($f -replace '[^A-Za-z0-9]', '_').ToLowerInvariant()
                    label       = [System.IO.Path]::GetFileName($f)
                    source_file = $f
                }
            }
            [ordered]@{ nodes = $nodes; links = @() } | ConvertTo-Json -Depth 8 |
                Set-Content -LiteralPath $Path -Encoding utf8
        }

        function Invoke-Link {
            param([hashtable]$ScriptArgs)
            $out = & $script:ScriptUnderTest @ScriptArgs *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }
    }

    AfterAll {
        Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'dgl-*' -Directory -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'links a page to the source file it names' {
        $root = New-Repo -Files @{
            'src/Thing.cs'     = 'public class Thing {}'
            'docs/thing.md'    = "# Thing`n`nImplemented in ``Thing.cs``."
        }
        $graph = Join-Path $root 'graph.json'
        New-Graph -Path $graph -SourceFiles @('src/Thing.cs')

        $r = Invoke-Link -ScriptArgs @{ RepoRoot = $root; GraphPath = $graph; DocRoots = @('docs') }

        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Doc-to-code edges resolved  : 1'
        $g = Get-Content -LiteralPath $graph -Raw -Encoding utf8 | ConvertFrom-Json
        @($g.links | Where-Object { $_.relation -eq 'documents' }).Count | Should -Be 1
    }

    It 'reads the documentation roots from aisdlc.json when none are passed' {
        $root = New-Repo -Files @{
            'src/Thing.cs'                  = 'public class Thing {}'
            'docs-functional/thing.md'      = "# Thing`n`nImplemented in ``Thing.cs``."
        }
        $graph = Join-Path $root 'graph.json'
        New-Graph -Path $graph -SourceFiles @('src/Thing.cs')

        $r = Invoke-Link -ScriptArgs @{ RepoRoot = $root; GraphPath = $graph }

        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Doc-to-code edges resolved  : 1'
    }

    It '<Name>' -ForEach @(
        @{
            Name        = 'reads a multi-part file name whole, instead of taking the last two segments'
            Files       = @{
                'src/Thing.razor.cs' = 'public partial class Thing {}'
                'docs/thing.md'      = "# Thing`n`nImplemented in ``Thing.razor.cs``."
            }
            SourceFiles = @('src/Thing.razor.cs')
            Expected    = @('Doc-to-code edges resolved  : 1')
        }
        @{
            Name        = 'does not read a .cs file out of a .css or .csproj name'
            Files       = @{
                'src/Thing.cs'  = 'public class Thing {}'
                'docs/thing.md' = "# Thing`n`nStyled by ``theme.css`` and built by ``Portal.Demo.csproj``."
            }
            SourceFiles = @('src/Thing.cs')
            Expected    = @('Doc-to-code edges resolved  : 0')
        }
        @{
            Name        = 'refuses to guess when a file name matches more than one file'
            Files       = @{
                'a/Thing.cs'    = 'public class Thing {}'
                'b/Thing.cs'    = 'public class Thing {}'
                'docs/thing.md' = "# Thing`n`nSee ``Thing.cs``."
            }
            SourceFiles = @('a/Thing.cs', 'b/Thing.cs')
            Expected    = @('Skipped, name ambiguous     : 1', 'Doc-to-code edges resolved  : 0')
        }
        @{
            Name        = 'ignores an obvious placeholder stem, which illustrates a rule rather than citing a file'
            Files       = @{
                'src/Foo.razor' = '<div></div>'
                'src/Real.cs'   = 'public class Real {}'
                'docs/p.md'     = "# P`n`nA scoped stylesheet ``Foo.razor.css`` only reaches ``Foo.razor``. See ``Real.cs``."
            }
            SourceFiles = @('src/Foo.razor', 'src/Real.cs')
            Expected    = @('Doc-to-code edges resolved  : 1')
        }
        @{
            Name        = 'does not mistake an ordinary word for a placeholder, whatever its first letters'
            Files       = @{
                'src/Something.cs' = 'public class Something {}'
                'src/Mystery.cs'   = 'public class Mystery {}'
                'src/Thing.cs'     = 'public class Thing {}'
                'docs/p.md'        = "# P`n`nSee ``Something.cs``, ``Mystery.cs`` and ``Thing.cs``."
            }
            SourceFiles = @('src/Something.cs', 'src/Mystery.cs', 'src/Thing.cs')
            Expected    = @('Doc-to-code edges resolved  : 3')
        }
        @{
            Name        = 'ignores a name that is not a tracked source file'
            Files       = @{
                'src/Thing.cs'  = 'public class Thing {}'
                'docs/thing.md' = "# Thing`n`nOnce lived in ``Deleted.cs``."
            }
            SourceFiles = @('src/Thing.cs')
            Expected    = @('Skipped, name not tracked   : 1')
        }
    ) {
        $root = New-Repo -Files $Files
        $graph = Join-Path $root 'graph.json'
        New-Graph -Path $graph -SourceFiles $SourceFiles

        $r = Invoke-Link -ScriptArgs @{ RepoRoot = $root; GraphPath = $graph; DocRoots = @('docs') }

        @($Expected).Count | Should -BeGreaterThan 0
        foreach ($pattern in $Expected) { $r.Output | Should -Match $pattern }
    }

    It 'writes nothing when asked to report only' {
        $root = New-Repo -Files @{
            'src/Thing.cs'  = 'public class Thing {}'
            'docs/thing.md' = "# Thing`n`nSee ``Thing.cs``."
        }
        $graph = Join-Path $root 'graph.json'
        New-Graph -Path $graph -SourceFiles @('src/Thing.cs')
        $before = Get-Content -LiteralPath $graph -Raw -Encoding utf8

        $r = Invoke-Link -ScriptArgs @{ RepoRoot = $root; GraphPath = $graph; DocRoots = @('docs'); ReportOnly = $true }

        $r.Output | Should -Match 'Report only; nothing written'
        (Get-Content -LiteralPath $graph -Raw -Encoding utf8) | Should -Be $before
    }

    It 'is idempotent, so a second run adds nothing' {
        $root = New-Repo -Files @{
            'src/Thing.cs'  = 'public class Thing {}'
            'docs/thing.md' = "# Thing`n`nSee ``Thing.cs``."
        }
        $graph = Join-Path $root 'graph.json'
        New-Graph -Path $graph -SourceFiles @('src/Thing.cs')

        $null = Invoke-Link -ScriptArgs @{ RepoRoot = $root; GraphPath = $graph; DocRoots = @('docs') }
        $r = Invoke-Link -ScriptArgs @{ RepoRoot = $root; GraphPath = $graph; DocRoots = @('docs') }

        $r.Output | Should -Match 'already carries these edges'
        $g = Get-Content -LiteralPath $graph -Raw -Encoding utf8 | ConvertFrom-Json
        @($g.links | Where-Object { $_.relation -eq 'documents' }).Count | Should -Be 1
    }

    It 'fails when there is no graph to enrich' {
        $root = New-Repo -Files @{ 'docs/thing.md' = '# Thing' }

        $r = Invoke-Link -ScriptArgs @{ RepoRoot = $root; GraphPath = (Join-Path $root 'absent.json'); DocRoots = @('docs') }

        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'No graph at'
    }
}
