#requires -Version 7.4

BeforeAll { $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm' }

Describe 'Set-SonarMcpToken' -Tag '84' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $script:ScriptFolder -ChildPath 'Set-SonarMcpToken.ps1'
        $script:Fake = 'fake-sonar-token-84'
        . $script:ScriptUnderTest
        $script:RealCurrentUser = ${function:Invoke-SonarCurrentUser}

        function Get-FakeToken { ConvertTo-SecureString $script:Fake -AsPlainText -Force }

        function Invoke-Run {
            $all = @(Invoke-SetSonarMcpToken *>&1)
            $code = $all | Where-Object { $_ -is [int] } | Select-Object -Last 1
            $text = ($all | Where-Object { $_ -isnot [int] } | Out-String)
            return [pscustomobject]@{ Code = $code; Text = $text; All = $all }
        }
    }

    BeforeEach {
        $script:SavedXdg = $env:XDG_CONFIG_HOME
        $env:XDG_CONFIG_HOME = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        Mock Test-InputRedirected { $false }
        Mock Test-IsWindows { $true }
        Mock Test-TokenStored { $false }
        Mock Read-TokenInput { Get-FakeToken }
        Mock Read-ReplaceAnswer { 'n' }
        Mock Invoke-SonarCurrentUser { [pscustomobject]@{ StatusCode = 200; IsLoggedIn = $true } }
        Mock Invoke-RestMethod { throw 'a unit test must not call the SonarCloud API' }
    }

    AfterEach { $env:XDG_CONFIG_HOME = $script:SavedXdg }

    Context 'Invoke-SetSonarMcpToken, in the order of the plan' {
        BeforeEach { Mock Set-StoredToken { } }

        It 'stops with exit 1 and says to run it in your own terminal when input is redirected' {
            Mock Test-InputRedirected { $true }

            $r = Invoke-Run

            $r.Code | Should -Be 1
            $r.Text | Should -Match 'run this in your own terminal'
            Should -Invoke Read-ReplaceAnswer -Times 0 -Exactly
            Should -Invoke Read-TokenInput -Times 0 -Exactly
            Should -Invoke Set-StoredToken -Times 0 -Exactly
        }

        It 'asks before it replaces a stored token, and keeps it with exit 0 when the answer is empty' {
            Mock Test-TokenStored { $true }
            Mock Read-ReplaceAnswer { '' }

            $r = Invoke-Run

            $r.Code | Should -Be 0
            $r.Text | Should -Match 'kept'
            Should -Invoke Read-TokenInput -Times 0 -Exactly
            Should -Invoke Set-StoredToken -Times 0 -Exactly
        }

        It 'keeps the stored token when the answer is "<answer>"' -ForEach @(
            @{ Answer = 'n' }, @{ Answer = 'no' }, @{ Answer = 'yep' }, @{ Answer = 'x' }, @{ Answer = $null }
        ) {
            $given = $Answer
            Mock Test-TokenStored { $true }
            Mock Read-ReplaceAnswer { $given }.GetNewClosure()

            $r = Invoke-Run

            $r.Code | Should -Be 0
            Should -Invoke Read-TokenInput -Times 0 -Exactly
            Should -Invoke Set-StoredToken -Times 0 -Exactly
        }

        It 'replaces the stored token when the answer is "<answer>"' -ForEach @(
            @{ Answer = 'y' }, @{ Answer = 'Y' }, @{ Answer = 'yes' }, @{ Answer = ' YES ' }
        ) {
            $given = $Answer
            Mock Test-TokenStored { $true }
            Mock Read-ReplaceAnswer { $given }.GetNewClosure()

            $r = Invoke-Run

            $r.Code | Should -Be 0
            Should -Invoke Set-StoredToken -Times 1 -Exactly
        }

        It 'does not ask to replace when no token is stored' {
            Invoke-Run | Out-Null

            Should -Invoke Read-ReplaceAnswer -Times 0 -Exactly
        }

        It 'exits 1 and stores nothing when the token is empty' {
            Mock Read-TokenInput { [System.Security.SecureString]::new() }

            $r = Invoke-Run

            $r.Code | Should -Be 1
            Should -Invoke Invoke-SonarCurrentUser -Times 0 -Exactly
            Should -Invoke Set-StoredToken -Times 0 -Exactly
        }

        It 'exits 1 and stores nothing when no token comes back' {
            Mock Read-TokenInput { $null }

            (Invoke-Run).Code | Should -Be 1
            Should -Invoke Set-StoredToken -Times 0 -Exactly
        }

        It 'exits 1 with the HTTP code and stores nothing when SonarCloud rejects the token' {
            Mock Invoke-SonarCurrentUser { [pscustomobject]@{ StatusCode = 401; IsLoggedIn = $false } }

            $r = Invoke-Run

            $r.Code | Should -Be 1
            $r.Text | Should -Match 'HTTP 401; nothing stored'
            Should -Invoke Set-StoredToken -Times 0 -Exactly
        }

        It 'exits 1 when SonarCloud answers 200 but the token is not logged in' {
            Mock Invoke-SonarCurrentUser { [pscustomobject]@{ StatusCode = 200; IsLoggedIn = $false } }

            $r = Invoke-Run

            $r.Code | Should -Be 1
            $r.Text | Should -Match 'HTTP 200; nothing stored'
            Should -Invoke Set-StoredToken -Times 0 -Exactly
        }

        It 'exits 1 and says SonarCloud could not be reached when the call fails before an answer' {
            Mock Invoke-SonarCurrentUser { [pscustomobject]@{ StatusCode = 0; IsLoggedIn = $false } }

            $r = Invoke-Run

            $r.Code | Should -Be 1
            $r.Text | Should -Match 'Could not reach SonarCloud; nothing stored'
            $r.Text | Should -Not -Match 'HTTP 0'
            Should -Invoke Set-StoredToken -Times 0 -Exactly
        }

        It 'on Windows, stores a token that SonarCloud accepts once, exits 0 and names the user variable and the restart' {
            $r = Invoke-Run

            $r.Code | Should -Be 0
            $r.Text | Should -Match 'user variable AISDLC_SONAR_MCP_TOKEN'
            $r.Text | Should -Match 'restart your terminal and Claude Code or VS Code'
            Should -Invoke Set-StoredToken -Times 1 -Exactly
            Should -Invoke Invoke-SonarCurrentUser -Times 1 -Exactly
        }

        It 'hands the secure string, never plain text, to the check and the store' {
            Invoke-Run | Out-Null

            Should -Invoke Invoke-SonarCurrentUser -Times 1 -Exactly -ParameterFilter { $Token -is [System.Security.SecureString] }
            Should -Invoke Set-StoredToken -Times 1 -Exactly -ParameterFilter { $Token -is [System.Security.SecureString] }
        }
    }

    Context 'storing off Windows, where a file holds the token' {
        BeforeEach {
            Mock Test-IsWindows { $false }
            $script:TokenFile = Join-Path $env:XDG_CONFIG_HOME 'ai-sdlc' 'sonar-mcp-token'
        }

        It 'writes the accepted token to the token file under XDG_CONFIG_HOME, exits 0 and prints the profile line' {
            $r = Invoke-Run

            $r.Code | Should -Be 0
            Get-Content -LiteralPath $script:TokenFile -Raw | Should -BeExactly $script:Fake
            $r.Text | Should -Match ([regex]::Escape($script:TokenFile))
            $r.Text | Should -Match 'export AISDLC_SONAR_MCP_TOKEN='
            $r.Text | Should -Match 'shell profile'
            Should -Invoke Invoke-SonarCurrentUser -Times 1 -Exactly
        }

        It 'gives the token file mode 600 and its folder mode 700' -Skip:$IsWindows {
            Invoke-Run | Out-Null

            (Get-Item -LiteralPath $script:TokenFile).UnixFileMode.ToString() | Should -BeExactly 'UserRead, UserWrite'
            (Get-Item -LiteralPath (Split-Path $script:TokenFile)).UnixFileMode.ToString() | Should -BeExactly 'UserRead, UserWrite, UserExecute'
        }

        It 'replaces the old file content, also when the old token was longer, and keeps mode 600' {
            New-Item -ItemType Directory -Path (Split-Path $script:TokenFile) -Force | Out-Null
            Set-Content -LiteralPath $script:TokenFile -Value ('old-' * 30) -NoNewline
            Mock Test-TokenStored { $true }
            Mock Read-ReplaceAnswer { 'y' }

            $r = Invoke-Run

            $r.Code | Should -Be 0
            Get-Content -LiteralPath $script:TokenFile -Raw | Should -BeExactly $script:Fake
            if (-not $IsWindows) { (Get-Item -LiteralPath $script:TokenFile).UnixFileMode.ToString() | Should -BeExactly 'UserRead, UserWrite' }
        }

        It 'keeps the old file content when the answer to the replace question is n' {
            New-Item -ItemType Directory -Path (Split-Path $script:TokenFile) -Force | Out-Null
            Set-Content -LiteralPath $script:TokenFile -Value 'old-token-84' -NoNewline
            Mock Test-TokenStored { $true }

            $r = Invoke-Run

            $r.Code | Should -Be 0
            Get-Content -LiteralPath $script:TokenFile -Raw | Should -BeExactly 'old-token-84'
        }

        It 'creates no file when SonarCloud rejects the token' {
            Mock Invoke-SonarCurrentUser { [pscustomobject]@{ StatusCode = 401; IsLoggedIn = $false } }

            (Invoke-Run).Code | Should -Be 1
            Test-Path -LiteralPath $script:TokenFile | Should -BeFalse
        }

        It 'creates no file when SonarCloud cannot be reached' {
            Mock Invoke-SonarCurrentUser { [pscustomobject]@{ StatusCode = 0; IsLoggedIn = $false } }

            (Invoke-Run).Code | Should -Be 1
            Test-Path -LiteralPath $script:TokenFile | Should -BeFalse
        }

        It 'puts the token value in no output stream when the file is written' {
            $r = Invoke-Run

            $r.Text | Should -Match 'The token is stored in'
            ($r.All | Out-String) | Should -Not -Match $script:Fake
        }
    }

    Context 'no token value in any output stream' {
        BeforeEach { Mock Set-StoredToken { } }

        It 'says why, and shows no value, when input is redirected' {
            Mock Test-InputRedirected { $true }

            $r = Invoke-Run

            $r.Text | Should -Match 'run this in your own terminal'
            ($r.All | Out-String) | Should -Not -Match $script:Fake
        }

        It 'says why, and shows no value, when the token is empty' {
            Mock Read-TokenInput { [System.Security.SecureString]::new() }

            $r = Invoke-Run

            $r.Text | Should -Match 'No token was entered'
            ($r.All | Out-String) | Should -Not -Match $script:Fake
        }

        It 'says why, and shows no value, when SonarCloud rejects the token' {
            Mock Invoke-SonarCurrentUser { [pscustomobject]@{ StatusCode = 401; IsLoggedIn = $false } }

            $r = Invoke-Run

            $r.Text | Should -Match 'HTTP 401; nothing stored'
            ($r.All | Out-String) | Should -Not -Match $script:Fake
        }

        It 'says why, and shows no value, when the network fails' {
            Mock Invoke-SonarCurrentUser { [pscustomobject]@{ StatusCode = 0; IsLoggedIn = $false } }

            $r = Invoke-Run

            $r.Text | Should -Match 'Could not reach SonarCloud; nothing stored'
            ($r.All | Out-String) | Should -Not -Match $script:Fake
        }

        It 'shows no value when the token is stored on Windows' {
            $r = Invoke-Run

            $r.Text | Should -Match 'The token is stored'
            ($r.All | Out-String) | Should -Not -Match $script:Fake
        }
    }

    Context 'Invoke-SonarCurrentUser' {
        BeforeEach {
            Mock Invoke-RestMethod {
                $name = $args[[array]::IndexOf($args, '-StatusCodeVariable:') + 1]
                foreach ($depth in 1..5) { try { Set-Variable -Name $name -Value $script:FakeStatus -Scope $depth } catch { $null = $_ } }
                return $script:FakeBody
            }
        }

        It 'calls the current-user endpoint with a bearer SecureString, tolerating an HTTP error' {
            $script:FakeStatus = 200
            $script:FakeBody = [pscustomobject]@{ isLoggedIn = $true }

            & $script:RealCurrentUser -Token (Get-FakeToken) | Out-Null

            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://sonarcloud.io/api/users/current' -and $Authentication -eq 'Bearer' -and $Token -is [System.Security.SecureString] -and $SkipHttpErrorCheck
            }
        }

        It 'gives the call a timeout of 15 seconds, so it cannot hang' {
            $script:FakeStatus = 200
            $script:FakeBody = [pscustomobject]@{ isLoggedIn = $true }

            & $script:RealCurrentUser -Token (Get-FakeToken) | Out-Null

            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $TimeoutSec -eq 15 }
        }

        It 'reports 200 and logged in for a good token' {
            $script:FakeStatus = 200
            $script:FakeBody = [pscustomobject]@{ isLoggedIn = $true }

            $r = & $script:RealCurrentUser -Token (Get-FakeToken)

            $r.StatusCode | Should -Be 200
            $r.IsLoggedIn | Should -BeTrue
        }

        It 'reports 200 and not logged in for an answer without a login' {
            $script:FakeStatus = 200
            $script:FakeBody = [pscustomobject]@{ isLoggedIn = $false }

            $r = & $script:RealCurrentUser -Token (Get-FakeToken)

            $r.StatusCode | Should -Be 200
            $r.IsLoggedIn | Should -BeFalse
        }

        It 'reports 401 and not logged in for a rejected token, whatever the body is' {
            $script:FakeStatus = 401
            $script:FakeBody = 'Unauthorized'

            $r = & $script:RealCurrentUser -Token (Get-FakeToken)

            $r.StatusCode | Should -Be 401
            $r.IsLoggedIn | Should -BeFalse
        }

        It 'reports status 0 on an exception, and the result holds no token and no error text' {
            Mock Invoke-RestMethod { throw "network down $script:Fake" }

            $r = & $script:RealCurrentUser -Token (Get-FakeToken)

            $r.StatusCode | Should -Be 0
            $r.IsLoggedIn | Should -BeFalse
            ($r | Out-String) | Should -Not -Match $script:Fake
            ($r | Out-String) | Should -Not -Match 'network down'
        }
    }

    Context 'the script text' {
        BeforeAll {
            $tokens = $null
            $errors = $null
            $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptUnderTest, [ref]$tokens, [ref]$errors)
            $script:ParseErrors = $errors
        }

        It 'parses without error' {
            $script:ParseErrors | Should -BeNullOrEmpty
        }

        It 'has no parameter besides the common ones, so a token never arrives on a command line' {
            $script:Ast.ParamBlock | Should -Not -BeNullOrEmpty
            $script:Ast.ParamBlock.Parameters.Count | Should -Be 0
        }

        It 'prompts for a secret in one place only: Read-TokenInput' {
            $reads = $script:Ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Read-Host'
                }, $true)
            $secure = @($reads | Where-Object {
                    @($_.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'AsSecureString' }).Count -gt 0
                })
            $secure.Count | Should -Be 1
            $function = $secure[0].Parent
            while ($function -and $function -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $function = $function.Parent }
            $function.Name | Should -BeExactly 'Read-TokenInput'
        }

        It 'writes the user scope in one place only: Set-StoredToken' {
            $writes = $script:Ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -eq 'SetEnvironmentVariable'
                }, $true)
            $writes.Count | Should -Be 1
            $writes[0].Arguments[0].Extent.Text | Should -BeIn @('$script:Variable', "'AISDLC_SONAR_MCP_TOKEN'")
            $writes[0].Arguments[2].Extent.Text | Should -BeExactly "'User'"
            $function = $writes[0].Parent
            while ($function -and $function -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $function = $function.Parent }
            $function.Name | Should -BeExactly 'Set-StoredToken'
        }

        It 'ends with the dot-source guard and an exit that returns the main function result' {
            $text = Get-Content -LiteralPath $script:ScriptUnderTest -Raw
            $text | Should -Match "(?s)if \(\`$MyInvocation\.InvocationName -eq '\.'\) \{ return \}\s+exit \(Invoke-SetSonarMcpToken\)\s*$"
        }
    }

    Context 'run in a child process with redirected, open input' {
        It 'does not hang on a prompt: it exits 1 and says to run it in your own terminal' {
            $psi = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
            foreach ($argument in '-NoProfile', '-File', $script:ScriptUnderTest) { $psi.ArgumentList.Add($argument) }
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            foreach ($name in 'AISDLC_SONAR_MCP_TOKEN', 'SONAR_TOKEN', 'SONARCLOUD_TOKEN') { $null = $psi.Environment.Remove($name) }
            $psi.Environment['XDG_CONFIG_HOME'] = Join-Path $TestDrive 'child-config'

            $process = [System.Diagnostics.Process]::Start($psi)
            try {
                $stdout = $process.StandardOutput.ReadToEndAsync()
                $stderr = $process.StandardError.ReadToEndAsync()
                $exited = $process.WaitForExit(30000)
                if (-not $exited) { $process.Kill($true) }
                $exited | Should -BeTrue -Because 'a prompt on redirected input hangs, and the script must check first'
                $process.ExitCode | Should -Be 1
                ($stdout.Result + $stderr.Result) | Should -Match 'run this in your own terminal'
                Test-Path -LiteralPath (Join-Path $TestDrive 'child-config') | Should -BeFalse
            }
            finally {
                if (-not $process.HasExited) { $process.Kill($true) }
                $process.Dispose()
            }
        }
    }
}
