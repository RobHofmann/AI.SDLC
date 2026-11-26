#requires -Version 7.4

Describe 'Find-NearestExample' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Find-NearestExample.ps1'

        function New-DemoRepo {
            param([hashtable]$Extra = @{})
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $files = @{
                'aisdlc.json'                                                  = '{ "paths": { "sourceRoot": "src", "testRoot": "tests" } }'
                'src/Api.Demo/Api.Demo.csproj'                                 = '<Project />'
                'src/Api.Demo/OrderService.cs'                                 = "public class OrderService(IOrderClient client, TimeProvider time)`n{`n}"
                'src/Api.Demo/StockService.cs'                                 = "public sealed class StockService`n{`n    public StockService(ILogger<StockService> logger, TimeProvider timeProvider) { }`n}"
                'tests/Api.Demo.Tests/Api.Demo.Tests.csproj'                   = '<Project />'
                'tests/Api.Demo.Tests/OrderServiceTests.cs'                    = "public class OrderServiceTests`n{`n    [Fact]`n    public void Total_IsSum() { }`n}"
                'tests/Api.Demo.Tests/TestDoubles/FixedTimeProvider.cs'        = "public sealed class FixedTimeProvider(DateTimeOffset now) : TimeProvider`n{`n}"
                'tests/Api.Demo.Tests/Clients/OrderClientStub.cs'              = "internal class OrderClientStub : IOrderClient`n{`n}"
                'tests/Api.Demo.Tests/Other/ExportTests.cs'                    = "public class ExportTests`n{`n    private sealed class ManualTimeProvider : TimeProvider { }`n}"
                'tests/Worker.Demo.Tests/Worker.Demo.Tests.csproj'             = '<Project />'
                'tests/Worker.Demo.Tests/TestDoubles/WorkerTimeProvider.cs'    = "public class WorkerTimeProvider : TimeProvider`n{`n}"
            }
            foreach ($k in $Extra.Keys) { $files[$k] = $Extra[$k] }
            foreach ($rel in $files.Keys) {
                $full = Join-Path $root $rel
                New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
                Set-Content -LiteralPath $full -Value $files[$rel] -Encoding utf8
            }
            $root
        }

        function Invoke-Find {
            param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string[]]$Type, [string[]]$Dependency = @())
            $out = & $script:ScriptUnderTest -RepoRoot $Root -Type $Type -Dependency $Dependency *>&1 | Out-String
            [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }
    }

    It 'names the existing test class of a touched type' {
        $r = Invoke-Find -Root (New-DemoRepo) -Type 'OrderService'
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Test class: tests/Api.Demo.Tests/OrderServiceTests.cs :: OrderServiceTests'
    }

    It 'names the test doubles of its dependencies in the same test project, shared ones first' {
        $r = Invoke-Find -Root (New-DemoRepo) -Type 'OrderService'
        $lines = $r.Output -split '\r?\n'
        $fixed = [array]::FindIndex($lines, [Predicate[string]] { param($l) $l -match 'FixedTimeProvider' })
        $manual = [array]::FindIndex($lines, [Predicate[string]] { param($l) $l -match 'ManualTimeProvider' })
        $fixed | Should -BeGreaterThan -1
        $manual | Should -BeGreaterThan $fixed
        $lines[$fixed] | Should -Match 'shared'
        $lines[$manual] | Should -Match 'private'
        $r.Output | Should -Match 'OrderClientStub.cs :: OrderClientStub \(IOrderClient, shared\)'
        $r.Output | Should -Not -Match 'WorkerTimeProvider'
    }

    It 'reads the dependencies of a classic constructor' {
        $root = New-DemoRepo -Extra @{ 'tests/Api.Demo.Tests/StockServiceTests.cs' = "public class StockServiceTests`n{`n    [Fact]`n    public void Reads() { }`n}" }
        $r = Invoke-Find -Root $root -Type 'StockService'
        $r.Output | Should -Match 'FixedTimeProvider.cs :: FixedTimeProvider \(TimeProvider, shared\)'
    }

    It 'says "none found" and what it searched when a type has no test class' {
        $r = Invoke-Find -Root (New-DemoRepo) -Type 'StockService'
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Test class: none found \(searched tests for class StockServiceTests\)'
        $r.Output | Should -Not -Match 'Constructed in'
    }

    It 'names a test class that constructs the type on its own line, not as the test class' {
        $root = New-DemoRepo -Extra @{ 'tests/Api.Demo.Tests/StockFlowTests.cs' = "public class StockFlowTests`n{`n    [Fact]`n    public void Flows() { var s = new StockService(null, null); }`n}" }
        $r = Invoke-Find -Root $root -Type 'StockService'
        $r.Output | Should -Match 'Test class: none found'
        $r.Output | Should -Match 'Constructed in: tests/Api.Demo.Tests/StockFlowTests.cs :: StockFlowTests, a test of something else'
    }

    It 'names the class that holds the construction, not the first class of the file' {
        $flow = "public static class Builders`n{`n    public static int One() => 1;`n}`npublic class StockFlowTests`n{`n    [Fact]`n    public void Flows() { var s = new StockService(null, null); }`n}"
        $root = New-DemoRepo -Extra @{ 'tests/Api.Demo.Tests/StockFlowTests.cs' = $flow }
        $r = Invoke-Find -Root $root -Type 'StockService'
        $r.Output | Should -Match 'Constructed in: tests/Api.Demo.Tests/StockFlowTests.cs :: StockFlowTests, a test of something else'
    }

    It 'prefers the test class in the test project that mirrors the source project' {
        $root = New-DemoRepo -Extra @{
            'src/Worker.Demo/Worker.Demo.csproj'          = '<Project />'
            'src/Worker.Demo/Ledger.cs'                   = "public class Ledger`n{`n}"
            'tests/Api.Demo.Tests/Old/LedgerTests.cs'     = "public class LedgerTests`n{`n    [Fact]`n    public void Old() { }`n}"
            'tests/Worker.Demo.Tests/LedgerTests.cs'      = "public class LedgerTests`n{`n    [Fact]`n    public void Books() { }`n}"
        }
        $r = Invoke-Find -Root $root -Type 'Ledger'
        $r.Output | Should -Match 'Test class: tests/Worker.Demo.Tests/LedgerTests.cs :: LedgerTests'
    }

    It 'marks a nested test double without a modifier as private' {
        $root = New-DemoRepo -Extra @{ 'tests/Api.Demo.Tests/Other/ImportTests.cs' = "namespace Api.Demo.Tests;`npublic class ImportTests`n{`n    sealed class StepTimeProvider : TimeProvider { }`n}" }
        $r = Invoke-Find -Root $root -Type 'OrderService'
        $r.Output | Should -Match 'StepTimeProvider \(TimeProvider, private\)'
        $r.Output | Should -Match 'FixedTimeProvider \(TimeProvider, shared\)'
    }

    It 'finds the source type when only the source root is set' {
        $root = New-DemoRepo
        Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value '{ "paths": { "sourceRoot": "src" } }'
        $r = Invoke-Find -Root $root -Type 'OrderService'
        $r.Output | Should -Match 'OrderService \(src/Api.Demo/OrderService.cs\)'
    }

    It 'does not read a mocked type argument as a construction' {
        $root = New-DemoRepo -Extra @{ 'tests/Api.Demo.Tests/ControllerTests.cs' = "public class ControllerTests`n{`n    [Fact]`n    public void Gets() { var m = new Mock<StockService>(); }`n}" }
        $r = Invoke-Find -Root $root -Type 'StockService'
        $r.Output | Should -Not -Match 'Constructed in'
    }

    It 'reads a brace in a char literal as text, not as a scope' {
        $root = New-DemoRepo -Extra @{ 'tests/Api.Demo.Tests/Chars.cs' = "public static class Chars`n{`n    public static char Open = '{';`n}`npublic class ClockC : TimeProvider`n{`n}" }
        $r = Invoke-Find -Root $root -Type 'OrderService'
        $r.Output | Should -Match 'ClockC \(TimeProvider, shared\)'
    }

    It 'finds a record struct double and a double whose base is on the next line' {
        $root = New-DemoRepo -Extra @{ 'tests/Api.Demo.Tests/Clocks.cs' = "public record struct ClockA(int X) : TimeProvider;`npublic sealed class ClockB`n    : TimeProvider`n{`n}" }
        $r = Invoke-Find -Root $root -Type 'OrderService'
        $r.Output | Should -Match 'Clocks.cs :: ClockA \(TimeProvider, shared\)'
        $r.Output | Should -Match 'Clocks.cs :: ClockB \(TimeProvider, shared\)'
    }

    It 'reads the injected dependencies of a Razor component that has a code-behind file' {
        $root = New-DemoRepo -Extra @{ 'src/Api.Demo/Pages/Bar.razor' = "@inject TimeProvider Time`n<div />"; 'src/Api.Demo/Pages/Bar.razor.cs' = "public partial class Bar`n{`n}" }
        $r = Invoke-Find -Root $root -Type 'Bar'
        $r.Output | Should -Match 'FixedTimeProvider \(TimeProvider, shared\)'
    }

    It 'names a test class that constructs the type, not a helper class that does it first' {
        $flow = "public static class Builders`n{`n    public static StockService Make() => new StockService(null, null);`n}`npublic class StockFlowTests`n{`n    [Fact]`n    public void Flows() { var s = new StockService(null, null); }`n}"
        $root = New-DemoRepo -Extra @{ 'tests/Api.Demo.Tests/StockFlowTests.cs' = $flow }
        $r = Invoke-Find -Root $root -Type 'StockService'
        $r.Output | Should -Match 'Constructed in: tests/Api.Demo.Tests/StockFlowTests.cs :: StockFlowTests, a test of something else'
    }

    It 'lists only the doubles whose type arguments fit a generic dependency' {
        $root = New-DemoRepo -Extra @{
            'src/Api.Demo/Ledger.cs'                  = "public class Ledger(IRepository<Order> repo)`n{`n}"
            'tests/Api.Demo.Tests/Repositories.cs'    = "public class OrderRepositoryStub : IRepository<Order> { }`npublic class CustomerRepositoryStub : IRepository<Customer> { }`npublic class FakeRepository<T> : IRepository<T> { }"
        }
        $r = Invoke-Find -Root $root -Type 'Ledger'
        $r.Output | Should -Match 'OrderRepositoryStub \(IRepository<Order>, shared\)'
        $r.Output | Should -Match 'FakeRepository \(IRepository<Order>, shared\)'
        $r.Output | Should -Not -Match 'CustomerRepositoryStub'
    }

    It 'finds a record struct source type and reads its primary constructor' {
        $root = New-DemoRepo -Extra @{ 'src/Api.Demo/Money.cs' = "public readonly record struct Money(TimeProvider Clock);" }
        $r = Invoke-Find -Root $root -Type 'Money'
        $r.Output | Should -Match 'Money \(src/Api.Demo/Money.cs\)'
        $r.Output | Should -Match 'FixedTimeProvider \(TimeProvider, shared\)'
    }

    It 'does not take a test class name from a string or a comment' {
        $root = New-DemoRepo -Extra @{
            'tests/Api.Demo.Tests/A/Notes.cs'           = "public class Notes`n{`n    // class StockServiceTests was here`n    public string Old = `"class StockServiceTests`";`n}"
            'tests/Api.Demo.Tests/B/StockServiceTests.cs' = "public class StockServiceTests`n{`n    [Fact]`n    public void Works() { }`n}"
        }
        $r = Invoke-Find -Root $root -Type 'StockService'
        $r.Output | Should -Match 'Test class: tests/Api.Demo.Tests/B/StockServiceTests.cs :: StockServiceTests'
    }

    It 'reads a brace in a raw string or a block comment as text, not as a scope' {
        $fixture = "public class FixtureTests`n{`n    private const string Json = `"`"`"`n        { `"open`": 1`n        `"`"`";`n    /* { */`n}`npublic class ClockD : TimeProvider`n{`n}"
        $root = New-DemoRepo -Extra @{ 'tests/Api.Demo.Tests/FixtureTests.cs' = $fixture }
        $r = Invoke-Find -Root $root -Type 'OrderService'
        $r.Output | Should -Match 'ClockD \(TimeProvider, shared\)'
    }

    It 'does not take the source type from a comment in another file' {
        $root = New-DemoRepo -Extra @{
            'src/Api.Demo/A/Notes.cs'  = "public static class Notes`n{`n    // class Gadget(IFake fake) moved`n}"
            'src/Api.Demo/B/Gadget.cs' = "public class Gadget(TimeProvider time)`n{`n}"
        }
        $r = Invoke-Find -Root $root -Type 'Gadget'
        $r.Output | Should -Match 'Gadget \(src/Api.Demo/B/Gadget.cs\)'
    }

    It 'reads the dependencies from the real constructor, not from a comment or a string' {
        $root = New-DemoRepo -Extra @{ 'src/Api.Demo/Gizmo.cs' = "// old: class Gizmo(IFake fake)`npublic class Gizmo(TimeProvider time)`n{`n    private const string Doc = `"class Gizmo(IOther other)`";`n}" }
        $r = Invoke-Find -Root $root -Type 'Gizmo'
        $r.Output | Should -Match 'FixedTimeProvider \(TimeProvider, shared\)'
        $r.Output | Should -Not -Match 'IFake'
    }

    It 'finds a double whose base list starts on the line after the colon' {
        $root = New-DemoRepo -Extra @{ 'tests/Api.Demo.Tests/StubE.cs' = "public class StubE :`n    TimeProvider`n{`n}" }
        $r = Invoke-Find -Root $root -Type 'OrderService'
        $r.Output | Should -Match 'StubE \(TimeProvider, shared\)'
    }

    It 'finds a double whose dependency is a later item of a base list over several lines' {
        $root = New-DemoRepo -Extra @{ 'tests/Api.Demo.Tests/StubF.cs' = "public class StubF : IDisposable,`n    TimeProvider`n{`n}" }
        $r = Invoke-Find -Root $root -Type 'OrderService'
        $r.Output | Should -Match 'StubF \(TimeProvider, shared\)'
    }

    It 'does not read a declaration inside a string in an interpolation hole' {
        $root = New-DemoRepo -Extra @{
            'src/Api.Demo/A/Texts.cs'   = "public static class Texts`n{`n    public static string Show(string s) => `$`"{Wrap(`"class Widget(IFake f)`")}`";`n}"
            'src/Api.Demo/B/Widget.cs'  = "public class Widget(TimeProvider time)`n{`n}"
        }
        $r = Invoke-Find -Root $root -Type 'Widget'
        $r.Output | Should -Match 'Widget \(src/Api.Demo/B/Widget.cs\)'
    }

    It 'reads the classic constructor with the most parameters' {
        $root = New-DemoRepo -Extra @{ 'src/Api.Demo/Gauge.cs' = "public class Gauge`n{`n    public Gauge() { }`n    public Gauge(TimeProvider time, IOrderClient client) { }`n}" }
        $r = Invoke-Find -Root $root -Type 'Gauge'
        $r.Output | Should -Match 'FixedTimeProvider \(TimeProvider, shared\)'
        $r.Output | Should -Match 'OrderClientStub \(IOrderClient, shared\)'
    }

    It 'reads a constructor parameter after an attribute with arguments' {
        $root = New-DemoRepo -Extra @{ 'src/Api.Demo/Keyed.cs' = "public class Keyed([FromKeyedServices(`"orders`")] IOrderClient client, TimeProvider time)`n{`n}" }
        $r = Invoke-Find -Root $root -Type 'Keyed'
        $r.Output | Should -Match 'OrderClientStub \(IOrderClient, shared\)'
        $r.Output | Should -Match 'FixedTimeProvider \(TimeProvider, shared\)'
    }

    It 'marks a file-local test double as private' {
        $root = New-DemoRepo -Extra @{ 'tests/Api.Demo.Tests/Other/LocalTimeProvider.cs' = "file sealed class LocalTimeProvider : TimeProvider`n{`n}" }
        $r = Invoke-Find -Root $root -Type 'OrderService'
        $r.Output | Should -Match 'LocalTimeProvider \(TimeProvider, private\)'
        $r.Output | Should -Match 'FixedTimeProvider \(TimeProvider, shared\)'
    }

    It 'says "none found" for test doubles when no class implements a dependency' {
        $root = New-DemoRepo -Extra @{ 'src/Api.Demo/Mailer.cs' = "public class Mailer(ISmtp smtp)`n{`n}"; 'tests/Api.Demo.Tests/MailerTests.cs' = "public class MailerTests`n{`n    [Fact]`n    public void Sends() { }`n}" }
        $r = Invoke-Find -Root $root -Type 'Mailer'
        $r.Output | Should -Match 'Test doubles: none found \(searched tests/Api.Demo.Tests for a class that implements ISmtp\)'
    }

    It 'searches test doubles for a dependency the plan adds' {
        $root = New-DemoRepo -Extra @{ 'src/Api.Demo/Mailer.cs' = "public class Mailer(ISmtp smtp)`n{`n}"; 'tests/Api.Demo.Tests/MailerTests.cs' = "public class MailerTests`n{`n    [Fact]`n    public void Sends() { }`n}" }
        $r = Invoke-Find -Root $root -Type 'Mailer' -Dependency 'TimeProvider'
        $r.Output | Should -Match 'FixedTimeProvider.cs :: FixedTimeProvider \(TimeProvider, shared\)'
    }

    It 'reads a Razor component and its injected dependencies' {
        $root = New-DemoRepo -Extra @{ 'src/Api.Demo/Pages/SaveBar.razor' = "@inject TimeProvider Time`n<div />"; 'tests/Api.Demo.Tests/Pages/SaveBarTests.cs' = "public class SaveBarTests`n{`n    [Fact]`n    public void Shows() { }`n}" }
        $r = Invoke-Find -Root $root -Type 'SaveBar'
        $r.Output | Should -Match 'SaveBar \(src/Api.Demo/Pages/SaveBar.razor\)'
        $r.Output | Should -Match 'Test class: tests/Api.Demo.Tests/Pages/SaveBarTests.cs :: SaveBarTests'
        $r.Output | Should -Match 'FixedTimeProvider \(TimeProvider, shared\)'
    }

    It 'keeps a test project apart from one whose name starts the same' {
        $root = New-DemoRepo -Extra @{ 'tests/Api.Demo.Tests2/Api.Demo.Tests2.csproj' = '<Project />'; 'tests/Api.Demo.Tests2/OtherClient.cs' = "public class OtherClient : IOrderClient`n{`n}" }
        $r = Invoke-Find -Root $root -Type 'OrderService'
        $r.Output | Should -Not -Match 'OtherClient'
    }

    It 'says when the type itself is not found' {
        $r = Invoke-Find -Root (New-DemoRepo) -Type 'Missing'
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Missing: none found \(searched src for a class, record or struct named Missing, and for Missing.razor\)'
    }
}
