#requires -Version 7.4

Describe 'Check-RazorAttributePlacement' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Check-RazorAttributePlacement.ps1'

        # A temp tree whose only component uses the correct multi-line attribute form.
        $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
        if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
        Import-Module (Join-Path $aiSdlcGates 'DocToolTestHarness.psm1') -Force
        $script:RepoRoot = Join-Path -Path $TestDrive -ChildPath 'repo'
        New-Item -ItemType Directory -Path $script:RepoRoot -Force | Out-Null
        Set-AiSdlcTestConfig -Root $script:RepoRoot
        $script:Shared = Join-Path -Path $script:RepoRoot -ChildPath 'Demo/src/Portal.Demo/Components/Shared'
        New-Item -ItemType Directory -Path $script:Shared -Force | Out-Null

        Set-Content -LiteralPath (Join-Path $script:Shared 'Good.razor') `
            -Value "<div>ok</div>`n@code {`n    [Parameter]`n    public string Title { get; set; }`n`n    [CascadingParameter]`n    private object State { get; set; }`n}"

        function Invoke-Gate {
            param([hashtable]$P = @{})
            if (-not $P.ContainsKey('RepoRoot')) { $P['RepoRoot'] = $script:RepoRoot }
            $out = & $script:ScriptUnderTest @P *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }
    }

    AfterEach {
        foreach ($name in @('Attr.razor', 'Attr.cs')) {
            Remove-Item -LiteralPath (Join-Path $script:Shared $name) -ErrorAction SilentlyContinue
        }
    }

    It 'passes when every attribute is on its own line (exit 0)' {
        $r = Invoke-Gate
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Attribute placement OK'
    }

    It 'does not flag the correct multi-line form' {
        $r = Invoke-Gate
        $r.Output | Should -Not -Match 'Good\.razor'
    }

    It 'flags an attribute sharing a line with the member in razor (exit 1)' {
        Set-Content -LiteralPath (Join-Path $script:Shared 'Attr.razor') `
            -Value "<div>x</div>`n@code {`n    [Parameter] public string Bad { get; set; }`n}"
        $r = Invoke-Gate
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Attr\.razor'
        $r.Output | Should -Match 'own line'
    }

    It 'flags the same shape in a C# file (exit 1)' {
        Set-Content -LiteralPath (Join-Path $script:Shared 'Attr.cs') `
            -Value "namespace X;`npublic class C`n{`n    [Inject] private object Service { get; set; }`n}"
        $r = Invoke-Gate
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Attr\.cs'
    }

    It 'does not flag an attribute alone on its line above a member' {
        Set-Content -LiteralPath (Join-Path $script:Shared 'Attr.razor') `
            -Value "<div>x</div>`n@code {`n    [Parameter]`n    public string Fine { get; set; }`n}"
        $r = Invoke-Gate
        $r.ExitCode | Should -Be 0
    }
}
