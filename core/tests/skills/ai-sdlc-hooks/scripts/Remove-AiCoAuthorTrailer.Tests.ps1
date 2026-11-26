#requires -Version 7.4

BeforeAll { $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm' }

BeforeDiscovery {
    $sh = (Get-Command sh -ErrorAction SilentlyContinue).Source
    if (-not $sh -and $IsWindows) {
        $gitSh = Join-Path (Split-Path (Split-Path (Get-Command git).Source)) 'bin' 'sh.exe'
        if (Test-Path -LiteralPath $gitSh) { $sh = $gitSh }
    }
    $script:NoSh = -not $sh
}

Describe 'Remove-AiCoAuthorTrailer' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path $script:ScriptFolder 'Remove-AiCoAuthorTrailer.ps1'
        $script:Hook = Join-Path $script:ScriptFolder '..' 'githooks' 'commit-msg'

        function Invoke-Trailer {
            param([Parameter(Mandatory)][string]$Message)
            $file = Join-Path $TestDrive ([guid]::NewGuid().ToString('n') + '.txt')
            [System.IO.File]::WriteAllText($file, $Message)
            $err = & pwsh -NoProfile -File $script:ScriptUnderTest -MessageFile $file 2>&1 | Out-String
            [pscustomobject]@{ Text = [System.IO.File]::ReadAllText($file); ExitCode = $LASTEXITCODE; Err = $err }
        }
    }

    It 'removes the trailer of a coding tool and the blank line before it' -Tag '53' {
        $r = Invoke-Trailer "Fix the save (#1)`n`nCo-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`n"

        $r.Text | Should -Be "Fix the save (#1)`n"
        $r.ExitCode | Should -Be 0
        $r.Err | Should -Match 'removed'
    }

    It 'removes a trailer that names a tool or vendor, in any case: <Line>' -Tag '53' -ForEach @(
        @{ Line = 'Co-Authored-By: Claude <noreply@anthropic.com>' }
        @{ Line = 'co-authored-by: ChatGPT <bot@openai.com>' }
        @{ Line = 'Co-authored-by: AI assistant <bot@example.com>' }
        @{ Line = 'Co-authored-by: Gemini <bot@example.com>' }
    ) {
        $r = Invoke-Trailer "Change (#1)`n`n$Line`n"

        $r.Text | Should -Be "Change (#1)`n"
    }

    It 'keeps a trailer that names a person: <Name>' -Tag '53' -ForEach @(
        @{ Name = 'Kai Jansen <kai.jansen@example.com>' }
        @{ Name = 'Devin Sample <devin@example.com>' }
        @{ Name = 'Aida Fictus <aida@example.com>' }
        @{ Name = 'Claude Dupont <claude.dupont@example.com>' }
        @{ Name = 'Jan Smit <jan@contoso.ai>' }
        @{ Name = 'Priya Rao <priya@cursor.example.com>' }
        @{ Name = 'Ai Tanaka <ai@example.com>' }
    ) {
        $message = "Pair work (#1)`n`nCo-authored-by: $Name`n"

        $r = Invoke-Trailer $message

        $r.Text | Should -Be $message
        $r.Err | Should -BeNullOrEmpty
    }

    It 'keeps the rest of the message and its CRLF line endings' -Tag '53' {
        $r = Invoke-Trailer "Change (#1)`r`n`r`nBody line.`r`n`r`nCo-authored-by: Kai Jansen <kai@example.com>`r`nCo-authored-by: Copilot <c@example.com>`r`n"

        $r.Text | Should -Be "Change (#1)`r`n`r`nBody line.`r`n`r`nCo-authored-by: Kai Jansen <kai@example.com>`r`n"
    }

    It 'never touches a trailer-like line in the body, above the trailer block' -Tag '53' {
        $r = Invoke-Trailer "Explain the hook (#1)`n`nA tool adds a line like this one:`nCo-authored-by: AI assistant <bot@example.com>`nso the hook removes it.`n`nCo-authored-by: Copilot <c@example.com>`n"

        $r.Text | Should -Be "Explain the hook (#1)`n`nA tool adds a line like this one:`nCo-authored-by: AI assistant <bot@example.com>`nso the hook removes it.`n"
    }

    It 'leaves a message without a trailer block alone' -Tag '53' {
        $message = "Change (#1)`nCo-authored-by: Copilot <c@example.com>`n"

        $r = Invoke-Trailer $message

        $r.Text | Should -Be $message
    }

    It 'removes the trailer above the comment lines of a commit made in an editor, and keeps the comments' -Tag '53' {
        $r = Invoke-Trailer "Change (#1)`n`nCo-authored-by: Copilot <c@example.com>`n# Please enter the commit message.`n# Lines starting with '#' will be ignored.`n"

        $r.Text | Should -Be "Change (#1)`n`n# Please enter the commit message.`n# Lines starting with '#' will be ignored.`n"
    }

    It 'stops at the scissors line of a verbose commit' -Tag '53' {
        $r = Invoke-Trailer "Change (#1)`n`nCo-authored-by: Claude <noreply@anthropic.com>`n# ------------------------ >8 ------------------------`n# Do not modify or remove the line above.`ndiff --git a/x b/x`n"

        $r.Text | Should -Not -Match 'Co-authored-by'
        $r.Text | Should -Match 'diff --git a/x b/x'
    }

    It 'removes a trailer by its fixed bot address, whatever the name' -Tag '53' {
        $r = Invoke-Trailer "Change (#1)`n`nCo-authored-by: Some Bot <noreply@anthropic.com>`n"

        $r.Text | Should -Be "Change (#1)`n"
    }

    It 'leaves a missing message file alone and exits 0' -Tag '53' {
        & pwsh -NoProfile -File $script:ScriptUnderTest -MessageFile (Join-Path $TestDrive 'missing.txt') *> $null

        $LASTEXITCODE | Should -Be 0
    }

    It 'leaves an unreadable message file alone and exits 0' -Tag '53' {
        $folder = Join-Path $TestDrive 'a-folder'
        New-Item -ItemType Directory -Path $folder | Out-Null

        & pwsh -NoProfile -File $script:ScriptUnderTest -MessageFile $folder *> $null

        $LASTEXITCODE | Should -Be 0
    }

    It 'runs from the commit-msg hook with a path relative to the repository root' -Tag '53' -Skip:$script:NoSh {
        $sh = (Get-Command sh -ErrorAction SilentlyContinue).Source
        if (-not $sh) { $sh = Join-Path (Split-Path (Split-Path (Get-Command git).Source)) 'bin' 'sh.exe' }
        $root = Join-Path $TestDrive 'repo'
        $scripts = Join-Path $root '.claude' 'skills' 'ai-sdlc-hooks' 'scripts'
        New-Item -ItemType Directory -Path $scripts -Force | Out-Null
        Copy-Item -LiteralPath $script:ScriptUnderTest -Destination $scripts
        $hook = (Resolve-Path $script:Hook).Path -replace '\\', '/'
        $msg = Join-Path $root 'MSG'
        [System.IO.File]::WriteAllText($msg, "Change (#1)`n`nCo-authored-by: Copilot <c@example.com>`n")
        Push-Location $root
        try { & $sh $hook 'MSG' *> $null; $code = $LASTEXITCODE } finally { Pop-Location }

        $code | Should -Be 0
        [System.IO.File]::ReadAllText($msg) | Should -Be "Change (#1)`n"
    }

    It 'ships the commit-msg hook as an executable file with LF line endings' -Tag '53' {
        $relative = 'core/.apm/skills/ai-sdlc-hooks/githooks/commit-msg'
        $root = (git -C $script:ScriptFolder rev-parse --show-toplevel).Trim()
        if (-not (Test-Path -LiteralPath (Join-Path $root $relative))) { Set-ItResult -Skipped -Because 'this layout is not the AI.SDLC source'; return }

        $mode = ((git -C $root ls-files --stage -- $relative) -split '\s+')[0]

        $mode | Should -Be '100755'
        [System.IO.File]::ReadAllText((Join-Path $root $relative)) | Should -Not -Match "`r"
    }
}
