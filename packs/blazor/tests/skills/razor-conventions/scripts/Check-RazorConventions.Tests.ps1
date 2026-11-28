#requires -Version 7.4

BeforeAll { $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm' }

Describe 'Check-RazorConventions' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $script:ScriptFolder -ChildPath 'Check-RazorConventions.ps1'

        # A temp tree that is clean: the correct multi-line attribute form, a state class with no
        # interface, and the one file allowed to declare a document root.
        $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
        if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' 'tests' 'skills' 'ai-sdlc-gates' 'scripts' }
        Import-Module (Join-Path $aiSdlcGates 'DocToolTestHarness.psm1') -Force
        $script:RepoRoot = Join-Path -Path $TestDrive -ChildPath 'repo'
        New-Item -ItemType Directory -Path $script:RepoRoot -Force | Out-Null
        Set-AiSdlcTestConfig -Root $script:RepoRoot
        $script:Components = Join-Path -Path $script:RepoRoot -ChildPath 'Demo/src/Portal.Demo/Components'
        $script:Shared = Join-Path -Path $script:Components -ChildPath 'Shared'
        $script:Services = Join-Path -Path $script:RepoRoot -ChildPath 'Demo/src/Shared.Demo/Services'
        New-Item -ItemType Directory -Path $script:Shared -Force | Out-Null
        New-Item -ItemType Directory -Path $script:Services -Force | Out-Null

        Set-Content -LiteralPath (Join-Path $script:Components 'App.razor') `
            -Value "<!DOCTYPE html>`n<html lang=`"en`"><head></head><body></body></html>"
        Set-Content -LiteralPath (Join-Path $script:Shared 'Good.razor') `
            -Value "<div>ok</div>`n@code {`n    [Parameter]`n    public string Title { get; set; }`n}"
        Set-Content -LiteralPath (Join-Path $script:Services 'ThemeState.cs') `
            -Value "namespace X;`npublic sealed class ThemeState { public int Value; }"

        function Invoke-Gate {
            param([hashtable]$P = @{})
            if (-not $P.ContainsKey('RepoRoot')) { $P['RepoRoot'] = $script:RepoRoot }
            $out = & $script:ScriptUnderTest @P *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }
    }

    AfterEach {
        foreach ($name in @('IThemeState.cs')) {
            Remove-Item -LiteralPath (Join-Path $script:Services $name) -ErrorAction SilentlyContinue
        }
        foreach ($name in @('Styled.razor', 'Doc.razor', 'Attr.razor', 'Attr.cs')) {
            Remove-Item -LiteralPath (Join-Path $script:Shared $name) -ErrorAction SilentlyContinue
        }
    }

    It 'passes on a clean tree (exit 0)' {
        $r = Invoke-Gate
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Component conventions OK'
    }

    It 'exits 3 when the source folder does not exist' {
        $empty = Join-Path $TestDrive 'no-source'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        Set-AiSdlcTestConfig -Root $empty -Paths @{ sourceRoot = 'missing-src' }

        $r = Invoke-Gate -P @{ RepoRoot = $empty }

        $r.ExitCode | Should -Be 3 -Because $r.Output
        $r.Output | Should -Match '(?m)^Not applicable: missing-src/ does not exist'
        $r.Output | Should -Not -Match 'Component conventions OK'
    }

    It 'exits 3 when the source folder holds no .razor and no .cs file' {
        $bare = Join-Path $TestDrive 'bare-source'
        New-Item -ItemType Directory -Path (Join-Path $bare 'src') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $bare 'src' 'notes.txt') -Value 'x'
        Set-AiSdlcTestConfig -Root $bare -Paths @{ sourceRoot = 'src' }

        $r = Invoke-Gate -P @{ RepoRoot = $bare }

        $r.ExitCode | Should -Be 3 -Because $r.Output
    }

    It 'keeps the document root exempt from the DOCTYPE rule' {
        $r = Invoke-Gate
        $r.Output | Should -Not -Match 'App\.razor'
    }

    It 'flags an interface over a state class (exit 1)' {
        Set-Content -LiteralPath (Join-Path $script:Services 'IThemeState.cs') `
            -Value "namespace X;`npublic interface IThemeState { int Value { get; } }"
        $r = Invoke-Gate
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'IThemeState\.cs'
        $r.Output | Should -Match 'no interface over a state class'
    }

    It 'flags an inline style block in a razor component (exit 1)' {
        Set-Content -LiteralPath (Join-Path $script:Shared 'Styled.razor') `
            -Value "<div>x</div>`n<style>`n  .a { color: red; }`n</style>"
        $r = Invoke-Gate
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Styled\.razor'
        $r.Output | Should -Match 'inline <style>'
    }

    It 'flags a DOCTYPE in a page component (exit 1)' {
        Set-Content -LiteralPath (Join-Path $script:Shared 'Doc.razor') `
            -Value "<!DOCTYPE html>`n<html><body>page</body></html>"
        $r = Invoke-Gate
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Doc\.razor'
        $r.Output | Should -Match 'no <!DOCTYPE in a page component'
    }

    Context 'the app component setting' {
        BeforeAll {
            # Builds a repo with the harness config, then swaps the dotnet keys for the ones a test names.
            function New-DocTypeRepo {
                param([string]$Name, [hashtable]$Dotnet)
                $root = Join-Path $TestDrive $Name
                New-Item -ItemType Directory -Path (Join-Path $root 'Demo/src/Portal.Demo/Components') -Force | Out-Null
                Set-AiSdlcTestConfig -Root $root
                $file = Join-Path $root 'aisdlc.json'
                $json = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
                $json.dotnet.Remove('appComponent')
                foreach ($key in $Dotnet.Keys) { $json.dotnet[$key] = $Dotnet[$key] }
                Set-Content -LiteralPath $file -Value ($json | ConvertTo-Json -Depth 6) -Encoding utf8
                return $root
            }
        }

        It 'exits 2 and names both keys while the old key is set' -Tag '#105' {
            $root = New-DocTypeRepo -Name 'old-key' -Dotnet @{ portalAppComponent = 'Demo/src/Portal.Demo/Components/App.razor' }
            Set-Content -LiteralPath (Join-Path $root 'Demo/src/Portal.Demo/Components/App.razor') -Value '<!DOCTYPE html>'

            $r = Invoke-Gate -P @{ RepoRoot = $root }

            $r.ExitCode | Should -Be 2 -Because $r.Output
            $r.Output | Should -Match 'Could not check'
            $r.Output | Should -Match '(?m)^FIX: .*dotnet\.portalAppComponent.*dotnet\.appComponent'
        }

        It 'lets the file named in dotnet.appComponent hold a DOCTYPE (exit 0)' -Tag '#105' {
            $root = New-DocTypeRepo -Name 'new-key' -Dotnet @{ appComponent = 'Demo/src/Portal.Demo/Components/Root.razor' }
            Set-Content -LiteralPath (Join-Path $root 'Demo/src/Portal.Demo/Components/Root.razor') -Value '<!DOCTYPE html>'

            $r = Invoke-Gate -P @{ RepoRoot = $root }

            $r.ExitCode | Should -Be 0 -Because $r.Output
        }

        It 'flags App.razor when dotnet.appComponent names another file (exit 1)' -Tag '#105' {
            $root = New-DocTypeRepo -Name 'other-root' -Dotnet @{ appComponent = 'Demo/src/Portal.Demo/Components/Root.razor' }
            Set-Content -LiteralPath (Join-Path $root 'Demo/src/Portal.Demo/Components/App.razor') -Value '<!DOCTYPE html>'

            $r = Invoke-Gate -P @{ RepoRoot = $root }

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'App\.razor'
        }

        It 'lets only App.razor hold a DOCTYPE when no key is set' -Tag '#105' {
            $root = New-DocTypeRepo -Name 'no-key' -Dotnet @{}
            $components = Join-Path $root 'Demo/src/Portal.Demo/Components'
            Set-Content -LiteralPath (Join-Path $components 'App.razor') -Value '<!DOCTYPE html>'
            $clean = Invoke-Gate -P @{ RepoRoot = $root }
            Set-Content -LiteralPath (Join-Path $components 'Page.razor') -Value '<!DOCTYPE html>'

            $r = Invoke-Gate -P @{ RepoRoot = $root }

            $clean.ExitCode | Should -Be 0 -Because $clean.Output
            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'Page\.razor'
            $r.Output | Should -Not -Match 'App\.razor'
        }
    }

    Context 'attribute placement' {
        It 'flags an attribute that shares a line with its member in razor (exit 1)' -Tag '#105' {
            Set-Content -LiteralPath (Join-Path $script:Shared 'Attr.razor') `
                -Value "<div>x</div>`n@code {`n    [Parameter] public string Bad { get; set; }`n}"

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'Attr\.razor:3\s+\[Parameter\] public string Bad'
            $r.Output | Should -Match 'a component attribute goes on its own line above its member'
            $r.Output | Should -Match '(?m)^FIX: .*I\*State.*style.*DOCTYPE.*own line'
        }

        It 'flags the same shape in a C# file (exit 1)' -Tag '#105' {
            Set-Content -LiteralPath (Join-Path $script:Shared 'Attr.cs') `
                -Value "namespace X;`npublic class C`n{`n    [Inject] private object Service { get; set; }`n}"

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'Attr\.cs'
        }

        It 'does not flag an attribute alone on its line above a member' -Tag '#105' {
            Set-Content -LiteralPath (Join-Path $script:Shared 'Attr.razor') `
                -Value "<div>x</div>`n@code {`n    [Parameter]`n    public string Fine { get; set; }`n}"

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 0 -Because $r.Output
        }

        It 'does not flag two attributes on one line with the member below' -Tag '#105' {
            Set-Content -LiteralPath (Join-Path $script:Shared 'Attr.razor') `
                -Value "<div>x</div>`n@code {`n    [Parameter] [EditorRequired]`n    public string Fine { get; set; }`n}"

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 0 -Because $r.Output
        }

        It 'flags <Name> that shares a line with its attribute (exit 1)' -Tag '#105' -ForEach @(
            @{ Name = 'a member with no modifier'; Member = '[Parameter] string Bad { get; set; }' }
            @{ Name = 'a required member'; Member = '[Parameter] required string Bad { get; set; }' }
            @{ Name = 'a public required member'; Member = '[Parameter] public required string Bad { get; set; }' }
            @{ Name = 'a generic member'; Member = '[Parameter] public EventCallback<string> Bad { get; set; }' }
            @{ Name = 'a nullable member'; Member = '[Parameter] public RenderFragment? Bad { get; set; }' }
            @{ Name = 'a combined attribute'; Member = '[Parameter, EditorRequired] public string Bad { get; set; }' }
        ) {
            Set-Content -LiteralPath (Join-Path $script:Shared 'Attr.razor') `
                -Value "<div>x</div>`n@code {`n    $Member`n}"

            $r = Invoke-Gate

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'Attr\.razor:3'
        }

        It 'prints an OK line that counts the files and names every rule' -Tag '#105' {
            $r = Invoke-Gate

            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'Component conventions OK: 2 \.razor and 1 \.cs file\(s\) under Demo/src/ hold no I\*State interface, inline style, stray <!DOCTYPE or attribute that shares a line with its member\.'
        }
    }

    It 'exits 2 when aisdlc.json names no source root' -Tag '#105' {
        $none = Join-Path $TestDrive 'no-root'
        New-Item -ItemType Directory -Path $none -Force | Out-Null
        Set-AiSdlcTestConfig -Root $none -Paths @{ sourceRoot = '' }

        $r = Invoke-Gate -P @{ RepoRoot = $none }

        $r.ExitCode | Should -Be 2 -Because $r.Output
        $r.Output | Should -Match 'Could not check'
    }
}
