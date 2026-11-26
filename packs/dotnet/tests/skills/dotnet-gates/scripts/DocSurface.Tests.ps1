#requires -Version 7.4

Describe 'DocSurface' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'DocSurface.psm1') -Force
        $script:Family = @(
            [pscustomobject]@{ Folder = 'docs/libraries/'; Prefix = 'Shared.' }
            [pscustomobject]@{ Folder = 'docs/handlers/'; Prefix = 'Workers.' }
        )
    }

    AfterAll {
        Remove-Module DocSurface -Force -ErrorAction SilentlyContinue
    }

    Context 'reading the files a page cites' {
        It 'reads <Expected> out of <Text>' -ForEach @(
            @{ Text = 'See `Thing.cs`.'; Expected = 'Thing.cs' }
            @{ Text = 'See `.claude/skills/dotnet-gates/scripts/Check-DocDrift.Tests.ps1`.'; Expected = 'Check-DocDrift.Tests.ps1' }
            @{ Text = 'See `Foo.razor.cs` no wait, `Widget.razor.cs`.'; Expected = 'Widget.razor.cs' }
            @{ Text = 'Templates live in `main.bicep`.'; Expected = 'main.bicep' }
        ) {
            $names = @(Get-NamedSourceFile -Text $Text)

            $names | Should -Contain $Expected
        }

        It 'reads nothing out of <Text>, which names no source file' -ForEach @(
            @{ Text = 'Styled by `theme.css`.' }
            @{ Text = 'Built by `Portal.Demo.csproj`.' }
            @{ Text = 'A scoped stylesheet `Foo.razor.css` only reaches `Foo.razor`.' }
            @{ Text = 'Put it in `MyService.cs` to follow the rule.' }
        ) {
            $names = @(Get-NamedSourceFile -Text $Text)

            $names.Count | Should -Be 0
        }

        It 'ignores a fenced block, which is sample code rather than a citation' {
            $text = @(
                '```bicep'
                "module webAppModule 'webApp.bicep' = {"
                '}'
                '```'
                ''
                'See `Real.cs`.'
            ) -join [Environment]::NewLine

            $names = @(Get-NamedSourceFile -Text $text)

            $names | Should -Be @('Real.cs')
        }

        It 'keeps an ordinary word that merely starts like a placeholder' {
            $names = @(Get-NamedSourceFile -Text 'See `Something.cs`, `Anything.cs`, `Mystery.cs` and `Thing.cs`.')

            $names.Count | Should -Be 4
        }
    }

    Context 'reading a file name that is not a citation' {
        It 'does not read a source file name out of a link to another repository' {
            $text = 'See https://github.com/Azure/AppConfiguration-DotnetProvider/blob/main/src/AzureAppConfigurationProvider.cs for the upstream behaviour.'

            $names = Get-NamedSourceFile -Text $text

            $names.Count | Should -Be 0
        }

        It 'still reads a file name the page cites in its own prose beside a link' {
            $text = 'See https://example.com/x/Other.cs upstream. Ours is `AlphaService.cs`.'

            $names = Get-NamedSourceFile -Text $text

            @($names) | Should -Be @('AlphaService.cs')
        }
    }

    Context 'reading the symbols a page names' {
        It 'reads every identifier inside one backticked span, not only the first' {
            $names = @(Get-NamedSymbol -Text '- `AddCosmosClient() / AddNotificationServices()` registers data access')

            $names | Should -Contain 'AddCosmosClient'
            $names | Should -Contain 'AddNotificationServices'
        }

        It 'does not read a shorter name out of the middle of a longer one' {
            $names = @(Get-NamedSymbol -Text '- `StockLevelSyncHandlerService` syncs stock levels')

            $names | Should -Be @('StockLevelSyncHandlerService')
        }

        It 'does not read a symbol out of a camelCase identifier that merely contains one' {
            $names = @(Get-NamedSymbol -Text '- the `orderWorkflowService` variable, and the `_cachedTokenProvider` field')

            $names.Count | Should -Be 0
        }

        It 'does not read a file path as a symbol reference' {
            $names = @(Get-NamedSymbol -Text 'Source: `Shared.Demo/Setup/OrderQueueExtensions.cs`.')

            $names.Count | Should -Be 0
        }

        It 'ignores an identifier that is only prose' {
            $names = @(Get-NamedSymbol -Text 'The GhostService idea was rejected.')

            $names.Count | Should -Be 0
        }

        It 'ignores a fenced code block' {
            $text = @(
                '```csharp'
                'services.AddGhostServices();'
                '```'
                ''
                'Call `AddRealServices()`.'
            ) -join [Environment]::NewLine

            $names = @(Get-NamedSymbol -Text $text)

            $names | Should -Be @('AddRealServices')
        }
    }

    Context 'reading what a source file declares' {
        It 'finds public constants and static readonly fields' {
            $source = 'public static class P { public const string Alpha = "a"; public static readonly TimeSpan Beta = TimeSpan.Zero; private const string Gamma = "g"; }'

            $names = @(Get-PublicMemberName -Source $source)

            $names | Should -Contain 'Alpha'
            $names | Should -Contain 'Beta'
            $names | Should -Not -Contain 'Gamma'
        }

        It 'finds public types and skips private ones' {
            $source = "public sealed class Alpha`n{`n}`ninternal class Beta`n{`n}`npublic interface IGamma`n{`n}"

            $names = @(Get-PublicTypeName -Source $source)

            $names | Should -Contain 'Alpha'
            $names | Should -Contain 'IGamma'
            $names | Should -Not -Contain 'Beta'
        }
    }

    Context 'deciding what is a service' {
        It '<TypeName> in <SourceFile> is service-shaped: <Expected>' -ForEach @(
            @{ TypeName = 'AlphaService'; SourceFile = 'src/P/Services/AlphaService.cs'; Expected = $true }
            @{ TypeName = 'IAlphaClient'; SourceFile = 'src/P/Contracts/IAlphaClient.cs'; Expected = $true }
            @{ TypeName = 'Helper'; SourceFile = 'src/P/Services/Helper.cs'; Expected = $true }
            @{ TypeName = 'MockAlphaService'; SourceFile = 'src/P/Services/MockAlphaService.cs'; Expected = $false }
            @{ TypeName = 'ResourceProvider'; SourceFile = 'src/P/Common/Models/Azure/ResourceProvider.cs'; Expected = $false }
            @{ TypeName = 'OrderLine'; SourceFile = 'src/P/Common/Models/OrderLine.cs'; Expected = $false }
            @{ TypeName = 'PaymentFailedException'; SourceFile = 'src/P/Services/Clients/PaymentClient.cs'; Expected = $false }
        ) {
            $result = Test-ServiceShaped -TypeName $TypeName -SourceFile $SourceFile

            $result | Should -Be $Expected
        }
    }

    Context 'attributing a page by citation count' {
        It 'counts only files under Demo/src, by project' {
            $vote = Get-CitedProjectVote -CitedFile @(
                'Demo/src/Shared.Thing/A.cs'
                'Demo/src/Shared.Thing/B.cs'
                'Demo/src/Shared.Other/C.cs'
                'docs/libraries/thing.md'
                'Demo/tests/Thing.Tests/D.cs'
            ) -SourceRoot 'Demo/src'

            $vote['Shared.Thing'] | Should -Be 2
            $vote['Shared.Other'] | Should -Be 1
            $vote.ContainsKey('Thing.Tests') | Should -BeFalse
        }

        It 'returns nothing for a page that cites no source file' {
            $vote = Get-CitedProjectVote -CitedFile @('docs/libraries/thing.md')

            $vote.Count | Should -Be 0
        }

        It 'takes the top project only when it clears the threshold' {
            $clears = Resolve-TopProject -Vote @{ 'Shared.Thing' = 2; 'Shared.Other' = 1 }
            $short = Resolve-TopProject -Vote @{ 'Shared.Thing' = 1; 'Shared.Other' = 1 }
            $raised = Resolve-TopProject -Vote @{ 'Shared.Thing' = 2 } -MinimumVotes 3

            $clears | Should -Be 'Shared.Thing'
            $short | Should -BeNullOrEmpty
            $raised | Should -BeNullOrEmpty
        }

        It 'returns nothing for an empty vote, rather than guessing' {
            $result = Resolve-TopProject -Vote @{}

            $result | Should -BeNullOrEmpty
        }
    }

    Context 'reading the project families from aisdlc.json' {
        It 'takes a family from each source prefix that ends in a dot, and skips a single project' {
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('dsf-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            $config = @{ paths = @{ sourceRoot = 'Demo/src'; sourceDocMap = @(
                        @{ source = 'Demo/src/Portal.Demo/'; docs = @('docs/portal/') }
                        @{ source = 'Demo/src/Shared.'; docs = @('docs/libraries/') }
                        @{ source = 'Demo/src/Workers.'; docs = @('docs/handlers/', 'docs/overview.md') }
                    ) } }
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value ($config | ConvertTo-Json -Depth 5) -Encoding utf8

            $family = Get-ProjectFamily -RepoRoot $root

            ($family | ForEach-Object { "$($_.Folder)=$($_.Prefix)" }) -join ',' | Should -Be 'docs/libraries/=Shared.,docs/handlers/=Workers.'
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }

    Context 'deciding which project a page documents' {
        It 'matches <DocPath> to <Expected>' -ForEach @(
            @{ DocPath = 'docs/libraries/stock-level.md'; Expected = 'Shared.StockLevel' }
            @{ DocPath = 'docs/libraries/demo-data.md'; Expected = 'Shared.Demo.Data' }
            @{ DocPath = 'docs/libraries/ledger.md'; Expected = 'Shared.Ledger' }
            @{ DocPath = 'docs/handlers/ledger.md'; Expected = $null }
            @{ DocPath = 'docs/api/order-runs.md'; Expected = $null }
            @{ DocPath = 'docs/libraries/demo-communications.md'; Expected = $null }
        ) {
            $projects = @('Shared.Ledger', 'Shared.StockLevel', 'Shared.Demo.Data', 'Shared.Demo', 'Workers.LedgerHandler')

            $result = Resolve-ProjectByPageName -DocPath $DocPath -ProjectName $projects -Family $script:Family

            $result | Should -Be $Expected
        }

        It 'reads a Windows path the same way as a posix one' {
            $result = Resolve-ProjectByPageName -DocPath ('docs' + [char]92 + 'libraries' + [char]92 + 'ledger.md') -ProjectName @('Shared.Ledger') -Family $script:Family

            $result | Should -Be 'Shared.Ledger'
        }
    }
}
