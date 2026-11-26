#requires -Version 7.4

Describe 'Check-RazorConventions' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Check-RazorConventions.ps1'

        # A temp tree that is clean: the correct multi-line attribute form, a state class with no
        # interface, and the one file allowed to declare a document root.
        $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
        if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
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
        foreach ($name in @('Styled.razor', 'Doc.razor', 'Attr.razor')) {
            Remove-Item -LiteralPath (Join-Path $script:Shared $name) -ErrorAction SilentlyContinue
        }
    }

    It 'passes on a clean tree (exit 0)' {
        $r = Invoke-Gate
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Portal component conventions OK'
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
}
