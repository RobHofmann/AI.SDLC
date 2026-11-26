#requires -Version 7.4

Describe 'Deny-SharedFileEdit' {
    BeforeAll {
        $script:Hook = Join-Path $PSScriptRoot 'Deny-SharedFileEdit.ps1'
        Import-Module (Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts' 'DocToolTestHarness.psm1') -Force

        $script:Lock = @'
lockfile_version: '1'
apm_version: 0.31.0
dependencies:
- repo_url: contoso/demo-project/AI.SDLC
  name: ai-sdlc-core
  host: dev.azure.com
  resolved_commit: 0123456789abcdef
  resolved_ref: v1.0.0
  version: 1.0.0
  virtual_path: core
  is_virtual: true
  package_type: apm_package
  deployed_files:
  - .claude/agents/draft-reviewer.md
  - .claude/skills/guide-me
  - .claude/skills/guide-me/SKILL.md
  deployed_file_hashes:
    .claude/skills/guide-me/SKILL.md: sha256:00
  content_hash: sha256:11
- repo_url: contoso/demo-project/AI.SDLC
  name: ai-sdlc-bicep
  host: dev.azure.com
  resolved_ref: v1.0.0
  virtual_path: packs/bicep
  deployed_files:
  - .claude/skills/bicep-conventions/references/bicep.md
  content_hash: sha256:22
'@

        function New-LockRepo {
            param([switch]$NoLock)
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('dsfe-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            if (-not $NoLock) { Set-Content -LiteralPath (Join-Path $root 'apm.lock.yaml') -Value $script:Lock -Encoding utf8 }
            return (Resolve-Path $root).Path
        }

        function Invoke-Hook {
            param([string]$Root, [string]$Payload)
            # The hook reads stdin only when -Payload is not given, so the parameter carries the same input.
            $run = Invoke-ScriptInProcess -Path $script:Hook -Parameters @{ Payload = $Payload; RepoRoot = $Root }
            return [pscustomobject]@{ Code = $run.ExitCode; Output = $run.Output.Trim() }
        }
    }

    It 'denies an edit to an installed skill file and names the source path, the package and the ref' {
        $root = New-LockRepo

        $result = Invoke-Hook -Root $root -Payload '{"tool_name":"Edit","tool_input":{"file_path":".claude/skills/guide-me/SKILL.md"}}'

        $result.Code | Should -Be 0
        $decision = $result.Output | ConvertFrom-Json
        $decision.hookSpecificOutput.permissionDecision | Should -Be 'deny'
        $decision.permissionDecisionReason | Should -Match 'core/\.apm/skills/guide-me/SKILL\.md'
        $decision.permissionDecisionReason | Should -Match 'ai-sdlc-core at v1\.0\.0'
    }

    It 'maps an installed agent back to its .agent.md source' {
        $root = New-LockRepo

        $result = Invoke-Hook -Root $root -Payload '{"tool_input":{"file_path":".claude/agents/draft-reviewer.md"}}'

        ($result.Output | ConvertFrom-Json).permissionDecisionReason | Should -Match 'core/\.apm/agents/draft-reviewer\.agent\.md'
    }

    It 'denies an edit given as an absolute path inside the repository, in a pack' {
        $root = New-LockRepo
        $absolute = (Join-Path $root '.claude/skills/bicep-conventions/references/bicep.md').Replace('\', '\\')

        $result = Invoke-Hook -Root $root -Payload "{`"tool_input`":{`"file_path`":`"$absolute`"}}"

        ($result.Output | ConvertFrom-Json).permissionDecisionReason | Should -Match 'packs/bicep/\.apm/skills/bicep-conventions/references/bicep\.md'
    }

    It 'reads the Copilot CLI payload, where toolArgs is a JSON string' {
        $root = New-LockRepo

        $result = Invoke-Hook -Root $root -Payload '{"toolName":"edit","toolArgs":"{\"path\":\".claude/skills/guide-me/SKILL.md\"}"}'

        ($result.Output | ConvertFrom-Json).hookSpecificOutput.permissionDecision | Should -Be 'deny'
    }

    It 'denies an apply_patch edit of an installed file, the way a GPT model edits in Copilot CLI' {
        $root = New-LockRepo
        $payload = '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":"*** Begin Patch\n*** Update File: .claude/skills/guide-me/SKILL.md\n@@\n-# x\n+# y\n*** End Patch\n"}'

        $result = Invoke-Hook -Root $root -Payload $payload

        $result.Code | Should -Be 0
        $decision = $result.Output | ConvertFrom-Json
        $decision.permissionDecision | Should -Be 'deny'
        $decision.permissionDecisionReason | Should -Match 'core/\.apm/skills/guide-me/SKILL\.md'
    }

    It 'denies a patch that touches a repository file and an installed file, and names only the installed one' {
        $root = New-LockRepo
        $payload = '{"tool_name":"Edit","tool_input":"*** Begin Patch\n*** Update File: docs/architecture.md\n@@\n-a\n+b\n*** Update File: .claude/skills/bicep-conventions/references/bicep.md\n@@\n-a\n+b\n*** End Patch\n"}'

        $result = Invoke-Hook -Root $root -Payload $payload

        $reason = ($result.Output | ConvertFrom-Json).permissionDecisionReason
        $reason | Should -Match 'packs/bicep/\.apm/skills/bicep-conventions/references/bicep\.md'
        $reason | Should -Not -Match 'docs/architecture\.md'
    }

    It 'allows a patch that touches only repository files, in silence' {
        $root = New-LockRepo

        $result = Invoke-Hook -Root $root -Payload '{"tool_name":"Edit","tool_input":"*** Begin Patch\n*** Add File: docs/new.md\n+# New\n*** End Patch\n"}'

        $result.Code | Should -Be 0
        $result.Output | Should -BeNullOrEmpty
    }

    It 'derives the package folder from the package name when the lock file has no virtual path' {
        $root = New-LockRepo -NoLock
        Set-Content -LiteralPath (Join-Path $root 'apm.lock.yaml') -Encoding utf8 -Value @'
lockfile_version: '1'
dependencies:
- repo_url: _local/github-issues
  name: ai-sdlc-github-issues
  source: local
  deployed_files:
  - .claude/skills/write-story/SKILL.md
'@

        $result = Invoke-Hook -Root $root -Payload '{"tool_input":{"file_path":".claude/skills/write-story/SKILL.md"}}'

        ($result.Output | ConvertFrom-Json).permissionDecisionReason | Should -Match 'packs/github-issues/\.apm/skills/write-story/SKILL\.md'
    }

    It 'names the source file in the same repository when the repository installs its own packages' {
        $root = New-LockRepo -NoLock
        Set-Content -LiteralPath (Join-Path $root 'apm.lock.yaml') -Encoding utf8 -Value @'
lockfile_version: '1'
dependencies:
- repo_url: _local/github-issues
  name: ai-sdlc-github-issues
  deployed_files:
  - .claude/skills/write-story/SKILL.md
'@
        New-Item -ItemType Directory -Path (Join-Path $root 'packs/github-issues/.apm/skills/write-story') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'packs/github-issues/.apm/skills/write-story/SKILL.md') -Value 'source' -Encoding utf8

        $result = Invoke-Hook -Root $root -Payload '{"tool_input":{"file_path":".claude/skills/write-story/SKILL.md"}}'

        $decision = $result.Output | ConvertFrom-Json
        $decision.permissionDecision | Should -Be 'deny'
        $decision.permissionDecisionReason | Should -Match 'installed from packs/github-issues/\.apm/skills/write-story/SKILL\.md in this repository'
        $decision.permissionDecisionReason | Should -Match 'Update-SyncManifest\.ps1 and apm install'
        $decision.permissionDecisionReason | Should -Not -Match 'local clone'
    }

    It 'points to the handbook page on developing against a local clone' {
        $root = New-LockRepo

        $result = Invoke-Hook -Root $root -Payload '{"tool_input":{"file_path":".claude/skills/guide-me/SKILL.md"}}'

        ($result.Output | ConvertFrom-Json).permissionDecisionReason | Should -Match 'ai-sdlc-handbook/references/layout\.md'
    }

    It 'allows an edit to a file the lock file does not list, in silence' {
        $root = New-LockRepo

        $result = Invoke-Hook -Root $root -Payload '{"tool_input":{"file_path":"docs/architecture.md"}}'

        $result.Code | Should -Be 0
        $result.Output | Should -BeNullOrEmpty
    }

    It 'allows an edit to a repository skill next to the installed ones' {
        $root = New-LockRepo

        $result = Invoke-Hook -Root $root -Payload '{"tool_input":{"file_path":".claude/skills/repo-only/SKILL.md"}}'

        $result.Output | Should -BeNullOrEmpty
    }

    It 'allows every edit in a repository without apm.lock.yaml' {
        $root = New-LockRepo -NoLock

        $result = Invoke-Hook -Root $root -Payload '{"tool_input":{"file_path":".claude/skills/guide-me/SKILL.md"}}'

        $result.Output | Should -BeNullOrEmpty
    }

    It 'allows the edit in silence when the payload cannot be read' {
        $root = New-LockRepo

        $result = Invoke-Hook -Root $root -Payload 'not json'

        $result.Code | Should -Be 0
        $result.Output | Should -BeNullOrEmpty
    }
}
