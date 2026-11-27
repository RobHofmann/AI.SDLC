#requires -Version 7.4

BeforeAll {
    $script:ScriptFolder = $PSScriptRoot -replace '(?<=[\\/])tests(?=[\\/]skills[\\/][^\\/]+[\\/]scripts$)', '.apm'
    $harnessFolder = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', 'ai-sdlc-gates', 'scripts'
    if (-not (Test-Path -LiteralPath $harnessFolder)) { $harnessFolder = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', '..', '..', '..', '..', 'core', 'tests', 'skills', 'ai-sdlc-gates', 'scripts' }
    Import-Module (Join-Path $harnessFolder 'DocToolTestHarness.psm1') -Force
    $script:SavedEnvironment = @{ CHANGED_FILES = $env:CHANGED_FILES; PR_TARGET_BRANCH = $env:PR_TARGET_BRANCH }
    $env:CHANGED_FILES = $null
    $env:PR_TARGET_BRANCH = $null
}

AfterAll {
    $env:CHANGED_FILES = $script:SavedEnvironment.CHANGED_FILES
    $env:PR_TARGET_BRANCH = $script:SavedEnvironment.PR_TARGET_BRANCH
}

Describe 'Check-SharedParts' {
    BeforeDiscovery {
        $script:WrappedReported = @(
            @{ Name = 'new HttpClient()'; Kind = 'HttpClient'; Statement = 'var c = new HttpClient();' }
            @{ Name = 'new HttpClient with an initializer'; Kind = 'HttpClient'; Statement = 'var c = new HttpClient { BaseAddress = null };' }
            @{ Name = 'new System.Net.Http.HttpClient(handler)'; Kind = 'HttpClient'; Statement = 'var c = new System.Net.Http.HttpClient(handler);' }
            @{ Name = 'new global::System.Net.Http.HttpClient()'; Kind = 'HttpClient'; Statement = 'var c = new global::System.Net.Http.HttpClient();' }
            @{ Name = 'a target-typed HttpClient'; Kind = 'HttpClient'; Statement = 'HttpClient c = new();' }
            @{ Name = 'new DefaultAzureCredential()'; Kind = 'credential'; Statement = 'var k = new DefaultAzureCredential();' }
            @{ Name = 'new ManagedIdentityCredential(id)'; Kind = 'credential'; Statement = 'var k = new ManagedIdentityCredential(id);' }
            @{ Name = 'a target-typed DefaultAzureCredential'; Kind = 'credential'; Statement = 'DefaultAzureCredential k = new();' }
            @{ Name = 'new Azure.Identity.ClientSecretCredential(a, b, c)'; Kind = 'credential'; Statement = 'var k = new Azure.Identity.ClientSecretCredential(a, b, c);' }
            @{ Name = 'new global::Azure.Identity.WorkloadIdentityCredential()'; Kind = 'credential'; Statement = 'var k = new global::Azure.Identity.WorkloadIdentityCredential();' }
            @{ Name = 'new HttpClient with the initializer on the next line'; Kind = 'HttpClient'; Statement = "var c = new HttpClient`n        {`n            BaseAddress = null`n        };" }
            @{ Name = 'new DefaultAzureCredential with the arguments on the next line'; Kind = 'credential'; Statement = "var k = new DefaultAzureCredential`n        ();" }
            @{ Name = 'new UsernamePasswordCredential(a, b, c, d)'; Kind = 'credential'; Statement = 'var k = new UsernamePasswordCredential(a, b, c, d);' }
            @{ Name = 'new SharedTokenCacheCredential()'; Kind = 'credential'; Statement = 'var k = new SharedTokenCacheCredential();' }
        )
        $script:WrappedClean = @(
            @{ Name = 'new HttpClientHandler()'; Statement = 'var h = new HttpClientHandler();' }
            @{ Name = 'new DefaultAzureCredentialOptions()'; Statement = 'var o = new DefaultAzureCredentialOptions();' }
            @{ Name = 'the text in a string'; Statement = 'var s = "new HttpClient() and new DefaultAzureCredential()";' }
            @{ Name = 'the text in a line comment'; Statement = '// var c = new HttpClient();' }
            @{ Name = 'the text in a doc comment'; Statement = '/// var c = new HttpClient();' }
            @{ Name = 'the text in a block comment'; Statement = '/* var c = new HttpClient(); */' }
            @{ Name = 'the text in a block comment over several lines'; Statement = "/*`n        var c = new HttpClient();`n        */" }
            @{ Name = 'the text in a verbatim string over several lines'; Statement = "var s = @`"`nvar c = new HttpClient();`nvar k = new DefaultAzureCredential();`n`";" }
        )
        $script:WholeReported = @(
            @{ Name = 'IConfiguration in a primary constructor'; Kind = 'settings'; Line = 1; Code = "public class OrderService(IConfiguration configuration)`n{`n}" }
            @{ Name = 'IConfiguration in a record'; Kind = 'settings'; Line = 1; Code = "public record Order(IConfiguration Configuration);" }
            @{ Name = 'IConfiguration on the second line of a constructor'; Kind = 'settings'; Line = 4; Code = "public class OrderService`n{`n    public OrderService(ILogger logger,`n        IConfiguration configuration)`n    {`n    }`n}" }
            @{ Name = 'a nullable IConfiguration in a constructor'; Kind = 'settings'; Line = 3; Code = "public class OrderService`n{`n    public OrderService(IConfiguration? configuration) { }`n}" }
            @{ Name = 'an exception that derives from Exception'; Kind = 'exception'; Line = 1; Code = "public class FooException : Exception`n{`n}" }
            @{ Name = 'an exception that derives from System.Exception'; Kind = 'exception'; Line = 1; Code = "public class FooException : System.Exception`n{`n}" }
            @{ Name = 'an exception that derives from global::System.Exception'; Kind = 'exception'; Line = 1; Code = "public class FooException : global::System.Exception`n{`n}" }
            @{ Name = 'an exception with a primary constructor'; Kind = 'exception'; Line = 1; Code = "public class FooException(string message) : Exception(message)`n{`n}" }
            @{ Name = 'an exception with the base on the next line'; Kind = 'exception'; Line = 2; Code = "public class FooException`n    : Exception`n{`n}" }
            @{ Name = 'a target-typed HttpClient property'; Kind = 'HttpClient'; Line = 3; Code = "public class A`n{`n    public HttpClient C { get; } = new();`n}" }
            @{ Name = 'a target-typed HttpClient field'; Kind = 'HttpClient'; Line = 3; Code = "public class A`n{`n    private readonly HttpClient _c = new();`n}" }
            @{ Name = 'a target-typed credential property'; Kind = 'credential'; Line = 3; Code = "public class A`n{`n    public DefaultAzureCredential K { get; } = new();`n}" }
            @{ Name = 'a constructor with an attribute on the same line'; Kind = 'settings'; Line = 3; Code = "public class A`n{`n    [ActivatorUtilitiesConstructor] public A(IConfiguration c) { }`n}" }
            @{ Name = 'a primary constructor with the opening parenthesis on the next line'; Kind = 'settings'; Line = 3; Code = "public class OrderService`n(`n    IConfiguration configuration)`n{`n}" }
            @{ Name = 'a constructor with the opening parenthesis on the next line'; Kind = 'settings'; Line = 5; Code = "public class OrderService`n{`n    public OrderService`n    (`n        IConfiguration configuration)`n    {`n    }`n}" }
            @{ Name = 'IConfiguration as the last of 45 constructor parameters'; Kind = 'settings'; Line = 49; Code = ("public class A`n{`n    public A(`n" + ((1..45 | ForEach-Object { "        int p$_," }) -join "`n") + "`n        IConfiguration c)`n    {`n    }`n}") }
            @{ Name = 'an exception whose base sits after line 12 of the declaration'; Kind = 'exception'; Line = 16; Code = ("public class FooException(`n" + ((1..13 | ForEach-Object { "    string p$_," }) -join "`n") + "`n    string last)`n    : Exception(last)`n{`n}") }
            @{ Name = 'IConfiguration in a record class'; Kind = 'settings'; Line = 1; Code = "public record class R(IConfiguration c);" }
            @{ Name = 'an exception with class and its name on separate lines'; Kind = 'exception'; Line = 2; Code = "public class`nFooException : Exception`n{`n}" }
            @{ Name = 'an exception whose primary constructor holds nested parentheses'; Kind = 'exception'; Line = 1; Code = "public class FooException(string message = nameof(FooException)) : Exception(message)`n{`n}" }
            @{ Name = 'new on its own line with HttpClient on the next line'; Kind = 'HttpClient'; Line = 6; Code = "public class A`n{`n    public void Run()`n    {`n        var c = new`n            HttpClient();`n    }`n}" }
            @{ Name = 'new on its own line with a credential on the next line'; Kind = 'credential'; Line = 6; Code = "public class A`n{`n    public void Run()`n    {`n        var k = new`n            DefaultAzureCredential();`n    }`n}" }
            @{ Name = 'a constructor of a class with class and its name on separate lines'; Kind = 'settings'; Line = 4; Code = "public class`nOrderService`n{`n    public OrderService(IConfiguration c) { }`n}" }
            @{ Name = 'an unsafe constructor'; Kind = 'settings'; Line = 3; Code = "public class OrderService`n{`n    public unsafe OrderService(IConfiguration configuration) { }`n}" }
            @{ Name = 'an extern constructor'; Kind = 'settings'; Line = 3; Code = "public class OrderService`n{`n    public extern OrderService(IConfiguration configuration);`n}" }
            @{ Name = 'IConfiguration in a generic class with a primary constructor'; Kind = 'settings'; Line = 1; Code = "public class A<T>(IConfiguration c)`n{`n}" }
            @{ Name = 'IConfiguration in the constructor of a nested class'; Kind = 'settings'; Line = 5; Code = "public class Outer`n{`n    public class Inner`n    {`n        public Inner(IConfiguration c) { }`n    }`n}" }
            @{ Name = 'IConfiguration in the second part of a partial class'; Kind = 'settings'; Line = 6; Code = "public partial class A`n{`n}`npublic partial class A`n{`n    public A(IConfiguration c) { }`n}" }
            @{ Name = 'an exception in a file-scoped namespace'; Kind = 'exception'; Line = 3; Code = "namespace Demo;`n`npublic class FooException : Exception`n{`n}" }
            @{ Name = 'a generic exception'; Kind = 'exception'; Line = 1; Code = "public class FooException<T> : Exception`n{`n}" }
        )
        $script:WholeClean = @(
            @{ Name = 'IConfigurationSection in a primary constructor'; Code = "public class OrderService(IConfigurationSection section)`n{`n}" }
            @{ Name = 'IConfigurationRoot in a constructor'; Code = "public class OrderService`n{`n    public OrderService(IConfigurationRoot root) { }`n}" }
            @{ Name = 'IOptions<T> in a constructor'; Code = "public class OrderService`n{`n    public OrderService(IOptions<OrderOptions> options) { }`n}" }
            @{ Name = 'IConfiguration in a method that is not a constructor'; Code = "public class OrderService`n{`n    public void Load(IConfiguration configuration) { }`n}" }
            @{ Name = 'an exception that derives from the shared base'; Code = "public class FooException : AppException`n{`n}" }
            @{ Name = 'the shared base exception itself'; Code = "public class AppException : Exception`n{`n}" }
            @{ Name = 'a class that does not end in Exception'; Code = "public class FooFailure : Exception`n{`n}" }
            @{ Name = 'IConfiguration in a struct with a primary constructor'; Code = "public struct S(IConfiguration c)`n{`n}" }
            @{ Name = 'IConfiguration in a record struct'; Code = "public record struct R(IConfiguration c);" }
            @{ Name = 'IConfiguration in the constructor of a struct'; Code = "public struct S`n{`n    public S(IConfiguration c) { }`n}" }
            @{ Name = 'an exception that derives from ApplicationException'; Code = "public class FooException : ApplicationException`n{`n}" }
            @{ Name = 'a record that derives from Exception'; Code = "public record FooException(string Message) : Exception(Message);" }
            @{ Name = 'exception text in a string'; Code = "public class A`n{`n    public string S = `"class FooException : Exception`";`n}" }
            @{ Name = 'exception text in a verbatim string over several lines'; Code = "public class A`n{`n    public string S = @`"`nclass FooException : Exception`n{`n}`n`";`n}" }
            @{ Name = 'exception text in a comment'; Code = "public class A`n{`n    // class FooException : Exception`n    /// class FooException : Exception`n    /* class FooException : Exception */`n}" }
        )
    }

    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $script:ScriptFolder -ChildPath 'Check-SharedParts.ps1'

        function Invoke-Git {
            param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$GitWords)
            git -C $Root @GitWords *> $null
            if ($LASTEXITCODE -ne 0) { throw "git $($GitWords -join ' ') failed with exit code $LASTEXITCODE" }
        }

        function Write-SharedPartsConfig {
            param(
                [Parameter(Mandatory)][string]$Root,
                [hashtable]$Paths = @{},
                [string]$Helper = 'CredentialFactory',
                [string]$Base = 'AppException'
            )
            Set-AiSdlcTestConfig -Root $Root -Paths $Paths
            $file = Join-Path $Root 'aisdlc.json'
            $config = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
            $config.dotnet.credentialHelper = $Helper
            $config.dotnet.baseException = $Base
            Set-Content -LiteralPath $file -Value ($config | ConvertTo-Json -Depth 6) -Encoding utf8
        }

        function Build-Root {
            param([hashtable]$Paths = @{}, [string]$Helper = 'CredentialFactory', [string]$Base = 'AppException')
            $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            Write-SharedPartsConfig -Root $root -Paths $Paths -Helper $Helper -Base $Base
            return $root
        }

        function Write-SourceFile {
            param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
            $full = Join-Path $Root $Path
            New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($full)) -Force | Out-Null
            Set-Content -LiteralPath $full -Value $Content -Encoding utf8
        }

        function Format-MethodSource {
            param([Parameter(Mandatory)][string]$Statement)
            return "public class OrderService`n{`n    public void Run()`n    {`n        $Statement`n    }`n}"
        }

        function Invoke-Gate {
            param([Parameter(Mandatory)][string]$Root, [string[]]$Changed)
            $gateArgs = @{ RepoRoot = $Root }
            if ($PSBoundParameters.ContainsKey('Changed')) { $gateArgs.ChangedFiles = $Changed }
            else {
                $gateArgs.ChangedFiles = @(Get-ChildItem -LiteralPath $Root -Recurse -Filter *.cs -File | ForEach-Object { [IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/') })
            }
            $out = & $script:ScriptUnderTest @gateArgs *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }

        function Invoke-GateInGit {
            param([Parameter(Mandatory)][string]$Root)
            $out = & $script:ScriptUnderTest -RepoRoot $Root *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }

        $script:GitTemplate = Join-Path -Path $TestDrive -ChildPath ('git-template-' + [guid]::NewGuid().ToString('N'))
        git init --quiet --template= -b main $script:GitTemplate *> $null
        if ($LASTEXITCODE -ne 0) { throw 'git init failed' }
        Invoke-Git -Root $script:GitTemplate -GitWords 'config', 'user.email', 't@t.local'
        Invoke-Git -Root $script:GitTemplate -GitWords 'config', 'user.name', 't'
        Invoke-Git -Root $script:GitTemplate -GitWords 'config', 'core.autocrlf', 'false'

        function Build-ChangeFixture {
            param([hashtable]$Before = @{}, [hashtable]$After = @{}, [hashtable]$Moved = @{}, [switch]$NoOrigin)
            $root = Build-Root
            Copy-Item -LiteralPath (Join-Path $script:GitTemplate '.git') -Destination (Join-Path $root '.git') -Recurse
            foreach ($name in $Before.Keys) { Write-SourceFile -Root $root -Path "Demo/src/Orders/$name" -Content $Before[$name] }
            Write-SourceFile -Root $root -Path 'Demo/src/Orders/Clean.cs' -Content "public class Clean`n{`n}"
            Invoke-Git -Root $root -GitWords 'add', '-A'
            Invoke-Git -Root $root -GitWords 'commit', '-m', 'base', '--quiet'
            if (-not $NoOrigin) { Invoke-Git -Root $root -GitWords 'update-ref', 'refs/remotes/origin/main', 'HEAD' }
            foreach ($name in $Moved.Keys) { Invoke-Git -Root $root -GitWords 'mv', "Demo/src/Orders/$name", "Demo/src/Orders/$($Moved[$name])" }
            foreach ($name in $After.Keys) { Write-SourceFile -Root $root -Path "Demo/src/Orders/$name" -Content $After[$name] }
            Invoke-Git -Root $root -GitWords 'add', '-A'
            Invoke-Git -Root $root -GitWords 'commit', '-m', 'change', '--quiet', '--allow-empty'
            return $root
        }
    }

    Context 'the four kinds (AC-1)' {
        It 'reports <Name> as <Kind> on the line of the statement' -Tag '#83' -ForEach $script:WrappedReported {
            $root = Build-Root
            Write-SourceFile -Root $root -Path 'Demo/src/Orders/OrderService.cs' -Content (Format-MethodSource -Statement $Statement)

            $r = Invoke-Gate -Root $root

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match ("Demo/src/Orders/OrderService\.cs:5\s+$Kind`:")
        }

        It 'does not report <Name>' -Tag '#83' -ForEach $script:WrappedClean {
            $root = Build-Root
            Write-SourceFile -Root $root -Path 'Demo/src/Orders/OrderService.cs' -Content (Format-MethodSource -Statement $Statement)

            $r = Invoke-Gate -Root $root

            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match 'Shared parts OK'
        }

        It 'reports <Name> as <Kind> on line <Line>' -Tag '#83' -ForEach $script:WholeReported {
            $root = Build-Root
            Write-SourceFile -Root $root -Path 'Demo/src/Orders/OrderService.cs' -Content $Code

            $r = Invoke-Gate -Root $root

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match ("Demo/src/Orders/OrderService\.cs:$Line\s+$Kind`:")
            ([regex]::Matches($r.Output, 'OrderService\.cs:\d+')).Count | Should -Be 1
        }

        It 'does not report <Name>' -Tag '#83' -ForEach $script:WholeClean {
            $root = Build-Root
            Write-SourceFile -Root $root -Path 'Demo/src/Orders/OrderService.cs' -Content $Code

            $r = Invoke-Gate -Root $root

            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match 'Shared parts OK'
        }

        It 'does not report a credential inside the helper class and reports it in a service' -Tag '#83' {
            $root = Build-Root
            Write-SourceFile -Root $root -Path 'Demo/src/Orders/CredentialFactory.cs' -Content "public class CredentialFactory`n{`n    public object Create()`n    {`n        DefaultAzureCredential k = new();`n        return new DefaultAzureCredential();`n    }`n}"
            Write-SourceFile -Root $root -Path 'Demo/src/Orders/OrderService.cs' -Content (Format-MethodSource -Statement 'var k = new DefaultAzureCredential();')

            $r = Invoke-Gate -Root $root

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'OrderService\.cs:5\s+credential:'
            $r.Output | Should -Not -Match 'CredentialFactory\.cs'
        }

        It 'does not report a credential inside a helper class whose name is on the next line' -Tag '#83' {
            $root = Build-Root
            Write-SourceFile -Root $root -Path 'Demo/src/Orders/CredentialFactory.cs' -Content "public class`nCredentialFactory`n{`n    public object Create() => new DefaultAzureCredential();`n}"

            $r = Invoke-Gate -Root $root

            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -Not -MatchExactly 'CredentialFactory\.cs:\d+'
        }

        It 'names the kind, the rule and the fix of a finding' -Tag '#83' {
            $root = Build-Root
            Write-SourceFile -Root $root -Path 'Demo/src/Orders/OrderService.cs' -Content (Format-MethodSource -Statement 'var c = new HttpClient();')

            $r = Invoke-Gate -Root $root

            $r.Output | Should -Match 'OrderService\.cs:5\s+HttpClient: Code does not create an HttpClient with new\. Fix: Register the client with AddHttpClient'
            $r.Output | Should -Match 'section "Shared parts"'
            $r.Output | Should -Match 'FIX: '
        }

        It 'names the helper and the base exception in the rule of a finding' -Tag '#83' {
            $root = Build-Root
            Write-SourceFile -Root $root -Path 'Demo/src/Orders/A.cs' -Content (Format-MethodSource -Statement 'var k = new DefaultAzureCredential();')
            Write-SourceFile -Root $root -Path 'Demo/src/Orders/B.cs' -Content "public class FooException : Exception`n{`n}"

            $r = Invoke-Gate -Root $root

            $r.Output | Should -Match 'credential: .*CredentialFactory'
            $r.Output | Should -Match 'exception: .*AppException'
        }
    }

    Context 'what the gate does not read (AC-2)' {
        It 'does not read a file under paths.testRoot' -Tag '#83' {
            $root = Build-Root -Paths @{ testRoot = 'Demo/src/Checks' }
            Write-SourceFile -Root $root -Path 'Demo/src/Checks/OrderTests.cs' -Content (Format-MethodSource -Statement 'var c = new HttpClient();')
            Write-SourceFile -Root $root -Path 'Demo/src/Orders/Clean.cs' -Content "public class Clean`n{`n}"

            $r = Invoke-Gate -Root $root

            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -Not -Match 'OrderTests\.cs'
        }

        It 'does not read a file of a test project and reads the same file of another project' -Tag '#83' {
            $root = Build-Root
            Write-SourceFile -Root $root -Path 'Demo/src/Orders.Checks/Orders.Checks.csproj' -Content '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><IsTestProject>true</IsTestProject></PropertyGroup></Project>'
            Write-SourceFile -Root $root -Path 'Demo/src/Orders.Checks/OrderChecks.cs' -Content (Format-MethodSource -Statement 'var c = new HttpClient();')
            Write-SourceFile -Root $root -Path 'Demo/src/Orders/Orders.csproj' -Content '<Project Sdk="Microsoft.NET.Sdk"></Project>'
            Write-SourceFile -Root $root -Path 'Demo/src/Orders/OrderService.cs' -Content (Format-MethodSource -Statement 'var c = new HttpClient();')

            $r = Invoke-Gate -Root $root

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'Orders/OrderService\.cs:5'
            $r.Output | Should -Not -Match 'OrderChecks\.cs'
        }

        It 'does not read <File>' -Tag '#83' -ForEach @(
            @{ File = 'Program.cs' }
            @{ File = 'Startup.cs' }
            @{ File = 'Api.g.cs' }
            @{ File = 'Form.Designer.cs' }
            @{ File = 'obj/Debug/Info.cs' }
        ) {
            $root = Build-Root
            Write-SourceFile -Root $root -Path "Demo/src/Orders/$File" -Content (Format-MethodSource -Statement 'var c = new HttpClient();')
            Write-SourceFile -Root $root -Path 'Demo/src/Orders/Clean.cs' -Content "public class Clean`n{`n}"

            $r = Invoke-Gate -Root $root

            $r.ExitCode | Should -Be 0 -Because $r.Output
        }

        It 'does not read the body of a static extension on <Builder>' -Tag '#83' -ForEach @(
            @{ Builder = 'IServiceCollection' }
            @{ Builder = 'IHostBuilder' }
            @{ Builder = 'IHostApplicationBuilder' }
            @{ Builder = 'HostApplicationBuilder' }
            @{ Builder = 'IWebHostBuilder' }
            @{ Builder = 'WebApplicationBuilder' }
            @{ Builder = 'IFunctionsWorkerApplicationBuilder' }
        ) {
            $root = Build-Root
            $code = "public static class OrderRegistration`n{`n    public static $Builder AddOrders(this $Builder services)`n    {`n        var c = new HttpClient();`n        var k = new DefaultAzureCredential();`n        return services;`n    }`n}"
            Write-SourceFile -Root $root -Path 'Demo/src/Orders/OrderRegistration.cs' -Content $code

            $r = Invoke-Gate -Root $root

            $r.ExitCode | Should -Be 0 -Because $r.Output
        }

        It 'does not read the body of a registration extension in the form <Name>' -Tag '#83' -ForEach @(
            @{ Name = 'a tuple return type'; Code = "public static class R`n{`n    public static (int, int) Add(this IServiceCollection s)`n    {`n        var c = new HttpClient();`n        return (1, 2);`n    }`n}" }
            @{ Name = 'a generic return type'; Code = "public static class R`n{`n    public static Task<List<int>> Add(this IServiceCollection s)`n    {`n        var c = new HttpClient();`n        return null;`n    }`n}" }
            @{ Name = 'an attribute before this'; Code = "public static class R`n{`n    public static IServiceCollection Add([NotNull] this IServiceCollection s)`n    {`n        var c = new HttpClient();`n        return s;`n    }`n}" }
            @{ Name = 'an expression body'; Code = "public static class R`n{`n    public static IServiceCollection Add(this IServiceCollection s) => s.AddSingleton(new HttpClient());`n}" }
            @{ Name = 'a long signature with this on line 11 and the brace on line 12'; Code = "public static class R`n{`n    [Obsolete]`n    public static IServiceCollection Add<`n        T1,`n        T2,`n        T3,`n        T4,`n        T5,`n        T6,`n        T7>(this IServiceCollection s)`n    {`n        var c = new HttpClient();`n        return s;`n    }`n}" }
            @{ Name = 'a generic method with a where clause'; Code = "public static class R`n{`n    public static IServiceCollection Add<T>(this IServiceCollection s)`n        where T : class`n    {`n        var c = new HttpClient();`n        return s;`n    }`n}" }
        ) {
            $root = Build-Root
            Write-SourceFile -Root $root -Path 'Demo/src/Orders/R.cs' -Content $Code

            $r = Invoke-Gate -Root $root

            $r.ExitCode | Should -Be 0 -Because $r.Output
        }
        It 'reads the same body in a static method that is not an extension' -Tag '#83' {
            $root = Build-Root
            $code = "public static class OrderRegistration`n{`n    public static IServiceCollection AddOrders(IServiceCollection services)`n    {`n        var c = new HttpClient();`n        return services;`n    }`n}"
            Write-SourceFile -Root $root -Path 'Demo/src/Orders/OrderRegistration.cs' -Content $code

            $r = Invoke-Gate -Root $root

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'OrderRegistration\.cs:5\s+HttpClient:'
        }

        It 'reads code after an extension method again' -Tag '#83' {
            $root = Build-Root
            $code = "public static class OrderRegistration`n{`n    public static IServiceCollection AddOrders(this IServiceCollection services)`n    {`n        return services;`n    }`n`n    public static void Run()`n    {`n        var c = new HttpClient();`n    }`n}"
            Write-SourceFile -Root $root -Path 'Demo/src/Orders/OrderRegistration.cs' -Content $code

            $r = Invoke-Gate -Root $root

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'OrderRegistration\.cs:10\s+HttpClient:'
        }
    }

    Context 'what the change adds (AC-3)' {
        BeforeEach {
            $script:SavedEnv = @{ CHANGED_FILES = $env:CHANGED_FILES; TARGET = $env:SYSTEM_PULLREQUEST_TARGETBRANCH }
            $env:CHANGED_FILES = $null
            $env:SYSTEM_PULLREQUEST_TARGETBRANCH = $null
        }

        AfterEach {
            $env:CHANGED_FILES = $script:SavedEnv.CHANGED_FILES
            $env:SYSTEM_PULLREQUEST_TARGETBRANCH = $script:SavedEnv.TARGET
        }

        It 'lists the break that the change adds above the older debt and exits 1' -Tag '#83' {
            $old = Format-MethodSource -Statement 'var c = new HttpClient();'
            $root = Build-ChangeFixture -Before @{ 'Old.cs' = $old } -After @{ 'New.cs' = (Format-MethodSource -Statement 'var k = new DefaultAzureCredential();') }

            $r = Invoke-GateInGit -Root $root

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $newAt = $r.Output.IndexOf('New.cs:5')
            $debtAt = $r.Output.IndexOf('Existing debt, not blocking: 1 finding')
            $oldAt = $r.Output.IndexOf('Old.cs:5')
            $newAt | Should -BeGreaterThan -1
            $debtAt | Should -BeGreaterThan $newAt
            $oldAt | Should -BeGreaterThan $debtAt
        }

        It 'lists only older debt as not blocking and exits 0' -Tag '#83' {
            $old = Format-MethodSource -Statement 'var c = new HttpClient();'
            $root = Build-ChangeFixture -Before @{ 'Old.cs' = $old } -After @{ 'Old.cs' = ($old + "`n// edited") }

            $r = Invoke-GateInGit -Root $root

            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match 'Shared parts OK'
            $r.Output | Should -Match 'Existing debt, not blocking: 1 finding'
            $r.Output | Should -Match 'Old\.cs:5'
        }

        It 'exits 0 and lists no debt when there is no break' -Tag '#83' {
            $root = Build-ChangeFixture -Before @{ 'Old.cs' = "public class Old`n{`n}" } -After @{ 'New.cs' = "public class New`n{`n}" }

            $r = Invoke-GateInGit -Root $root

            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -Not -Match 'Existing debt'
        }

        It 'counts IConfiguration that the change adds to an older constructor as new' -Tag '#83' {
            $before = "public class OrderService`n{`n    public OrderService(ILogger logger)`n    {`n    }`n}"
            $after = "public class OrderService`n{`n    public OrderService(ILogger logger, IConfiguration configuration)`n    {`n    }`n}"
            $root = Build-ChangeFixture -Before @{ 'OrderService.cs' = $before } -After @{ 'OrderService.cs' = $after }

            $r = Invoke-GateInGit -Root $root

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'OrderService\.cs:3\s+settings:'
            $r.Output | Should -Not -Match 'Existing debt'
        }

        It 'lists the debt of a file that the change only moves, and finds nothing new' -Tag '#83' {
            $old = Format-MethodSource -Statement 'var c = new HttpClient();'
            $root = Build-ChangeFixture -Before @{ 'Old.cs' = $old } -Moved @{ 'Old.cs' = 'Moved.cs' }

            $r = Invoke-GateInGit -Root $root

            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match 'Shared parts OK'
            $r.Output | Should -Match 'Existing debt, not blocking: 1 finding'
            $r.Output | Should -Match 'Moved\.cs:5'
        }

        It 'counts a target-typed initializer that the change adds to an older declaration as new' -Tag '#83' {
            $before = "public class A`n{`n    public HttpClient C { get; }`n}"
            $after = "public class A`n{`n    public HttpClient C { get; }`n        = new();`n}"
            $root = Build-ChangeFixture -Before @{ 'A.cs' = $before } -After @{ 'A.cs' = $after }

            $r = Invoke-GateInGit -Root $root

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'A\.cs:4\s+HttpClient:'
            $r.Output | Should -Not -Match 'Existing debt'
        }

        It 'counts an HttpClient type that the change puts after an older new line as new' -Tag '#83' {
            $before = "public class A`n{`n    public void Run()`n    {`n        var c = new`n            OtherClient();`n    }`n}"
            $after = "public class A`n{`n    public void Run()`n    {`n        var c = new`n            HttpClient();`n    }`n}"
            $root = Build-ChangeFixture -Before @{ 'A.cs' = $before } -After @{ 'A.cs' = $after }

            $r = Invoke-GateInGit -Root $root

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'A\.cs:6\s+HttpClient:'
            $r.Output | Should -Not -Match 'Existing debt'
        }

        It 'exits 2 with a FIX line when there is no base branch and no list of files' -Tag '#83' {
            $root = Build-ChangeFixture -Before @{ 'Old.cs' = "public class Old`n{`n}" } -After @{} -NoOrigin

            $r = Invoke-GateInGit -Root $root

            $r.ExitCode | Should -Be 2 -Because $r.Output
            $r.Output | Should -Match 'FIX: '
            $r.Output | Should -Match 'NOTHING WAS CHECKED'
        }
    }

    Context 'the two names in aisdlc.json (AC-4)' {
        BeforeAll {
            $script:Both = "public class OrderService`n{`n    public void Run()`n    {`n        var k = new DefaultAzureCredential();`n        var c = new HttpClient();`n    }`n}`npublic class FooException : Exception`n{`n}"
        }

        It 'skips the credential kind and says so when no helper is named' -Tag '#83' {
            $root = Build-Root -Helper ''
            Write-SourceFile -Root $root -Path 'Demo/src/Orders/OrderService.cs' -Content $script:Both

            $r = Invoke-Gate -Root $root

            $r.Output | Should -Match 'Credential kind skipped: aisdlc\.json names no dotnet\.credentialHelper\.'
            $r.Output | Should -Not -Match 'Exception kind skipped'
            $r.Output | Should -Not -MatchExactly 'OrderService\.cs:5\s+credential:'
            $r.Output | Should -Match 'OrderService\.cs:6\s+HttpClient:'
            $r.Output | Should -Match 'OrderService\.cs:9\s+exception:'
        }

        It 'skips the exception kind and says so when no base exception is named' -Tag '#83' {
            $root = Build-Root -Base ''
            Write-SourceFile -Root $root -Path 'Demo/src/Orders/OrderService.cs' -Content $script:Both

            $r = Invoke-Gate -Root $root

            $r.Output | Should -Match 'Exception kind skipped: aisdlc\.json names no dotnet\.baseException\.'
            $r.Output | Should -Not -Match 'Credential kind skipped'
            $r.Output | Should -Not -MatchExactly '\.cs:\d+\s+exception:'
            $r.Output | Should -Match 'OrderService\.cs:5\s+credential:'
        }

        It 'skips nothing and says nothing when both names are set' -Tag '#83' {
            $root = Build-Root
            Write-SourceFile -Root $root -Path 'Demo/src/Orders/OrderService.cs' -Content $script:Both

            $r = Invoke-Gate -Root $root

            $r.Output | Should -Not -Match 'kind skipped'
            $r.Output | Should -MatchExactly '\.cs:\d+\s+credential:'
            $r.Output | Should -MatchExactly '\.cs:\d+\s+exception:'
        }

        It 'skips both kinds when aisdlc.json has no dotnet section for them' -Tag '#83' {
            $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            Set-AiSdlcTestConfig -Root $root
            Write-SourceFile -Root $root -Path 'Demo/src/Orders/OrderService.cs' -Content $script:Both

            $r = Invoke-Gate -Root $root

            $r.Output | Should -Match 'Credential kind skipped'
            $r.Output | Should -Match 'Exception kind skipped'
            $r.Output | Should -Match 'OrderService\.cs:6\s+HttpClient:'
        }
    }

    Context 'a file written to stall the gate' {
        It 'reads 1200 lines of <Shape> within 10 seconds' -Tag '#83' -ForEach @(
            @{ Shape = 'static lines with an open parenthesis'; Line = '    static void M{0}(' }
            @{ Shape = 'class lines with an open parenthesis'; Line = '    class C{0} (' }
            @{ Shape = 'class lines with no brace'; Line = '    class C{0}' }
            @{ Shape = 'exception class lines with an open parenthesis'; Line = '    class C{0}Exception (' }
        ) {
            $root = Build-Root
            $body = (1..1200 | ForEach-Object { $Line -f $_ }) -join "`n"
            Write-SourceFile -Root $root -Path 'Demo/src/Orders/Hostile.cs' -Content $body

            $clock = [Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-Gate -Root $root
            $clock.Stop()

            $r.ExitCode | Should -BeIn @(0, 1) -Because $r.Output
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 10
        }
    }

    Context 'content and settings a pull request author controls' {
        It 'exits 2 and reads nothing when paths.sourceRoot leaves the repository' -Tag '#83' {
            $root = Build-Root -Paths @{ sourceRoot = '../outside' }
            $outside = Join-Path -Path (Split-Path $root -Parent) -ChildPath 'outside'
            Write-SourceFile -Root (Split-Path $outside -Parent) -Path 'outside/Leak.cs' -Content (Format-MethodSource -Statement 'var h = new HttpClient();')

            $r = Invoke-Gate -Root $root -Changed @()

            $r.ExitCode | Should -Be 2 -Because $r.Output
            $r.Output | Should -Match 'outside the repository'
            $r.Output | Should -Match 'FIX: '
            $r.Output | Should -Not -Match 'Leak\.cs'
        }

        It 'skips a .cs file over 1 MB with a note, and does not read it' -Tag '#83' {
            $root = Build-Root
            $padding = ('// ' + ('p' * 1000) + "`n") * 1100
            Write-SourceFile -Root $root -Path 'Demo/src/Orders/Huge.cs' -Content ((Format-MethodSource -Statement 'var h = new HttpClient();') + "`n" + $padding)
            Write-SourceFile -Root $root -Path 'Demo/src/Orders/Small.cs' -Content (Format-MethodSource -Statement 'var x = 1;')

            $r = Invoke-Gate -Root $root

            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match 'Huge\.cs.*over 1 MB'
            $r.Output | Should -Not -Match 'HttpClient:'
        }

        It 'skips a .cs file that is a link, and does not read it' -Tag '#83' {
            $root = Build-Root
            $target = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N') + '.cs')
            Set-Content -LiteralPath $target -Value (Format-MethodSource -Statement 'var h = new HttpClient();')
            Write-SourceFile -Root $root -Path 'Demo/src/Orders/Small.cs' -Content (Format-MethodSource -Statement 'var x = 1;')
            $link = Join-Path -Path $root -ChildPath 'Demo/src/Orders/Linked.cs'
            try { New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction Stop | Out-Null }
            catch { Set-ItResult -Skipped -Because 'this machine cannot create a symbolic link without admin rights' }

            $r = Invoke-Gate -Root $root

            $r.Output | Should -Match 'Linked\.cs.*link'
            $r.Output | Should -Not -Match 'HttpClient:'
        }

        It 'exits 2 when <Key> is not a type name' -Tag '#83' -ForEach @(
            @{ Key = 'credentialHelper'; Helper = 'Credential Factory'; Base = 'AppException' }
            @{ Key = 'credentialHelper'; Helper = 'X(.*)+'; Base = 'AppException' }
            @{ Key = 'baseException'; Helper = 'CredentialFactory'; Base = '::error::x' }
        ) {
            $root = Build-Root -Helper $Helper -Base $Base
            Write-SourceFile -Root $root -Path 'Demo/src/Orders/OrderService.cs' -Content (Format-MethodSource -Statement 'var x = 1;')

            $r = Invoke-Gate -Root $root

            $r.ExitCode | Should -Be 2 -Because $r.Output
            $r.Output | Should -Match "dotnet\.$Key"
            $r.Output | Should -Match 'FIX: '
            $r.Output | Should -Not -Match '(?m)^\s*::'
        }

        It 'accepts a type name with a namespace' -Tag '#83' {
            $root = Build-Root -Helper 'Shared.Security.CredentialFactory' -Base 'Shared.AppException'
            Write-SourceFile -Root $root -Path 'Demo/src/Orders/OrderService.cs' -Content (Format-MethodSource -Statement 'var x = 1;')

            $r = Invoke-Gate -Root $root

            $r.ExitCode | Should -Be 0 -Because $r.Output
        }

        It 'does not print a workflow command that a file name holds' -Tag '#83' -Skip:$IsWindows {
            $root = Build-Root
            Write-SourceFile -Root $root -Path 'Demo/src/Orders/::error::x.cs' -Content (Format-MethodSource -Statement 'var h = new HttpClient();')

            $r = Invoke-Gate -Root $root

            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -Match 'HttpClient:'
            $r.Output | Should -Not -Match '(?m)^\s*::'
            $r.Output | Should -Not -Match '::error::'
        }
    }
    Context 'the exit codes' {
        It 'exits 2 with a FIX line when aisdlc.json names no paths.sourceRoot' -Tag '#83' {
            $root = Build-Root -Paths @{ sourceRoot = '' }

            $r = Invoke-Gate -Root $root -Changed @()

            $r.ExitCode | Should -Be 2 -Because $r.Output
            $r.Output | Should -Match 'FIX: Set paths\.sourceRoot'
        }

        It 'exits 3 when the source folder is missing' -Tag '#83' {
            $root = Build-Root

            $r = Invoke-Gate -Root $root -Changed @()

            $r.ExitCode | Should -Be 3 -Because $r.Output
            $r.Output | Should -Match 'does not exist'
        }

        It 'exits 3 when every file is skipped' -Tag '#83' {
            $root = Build-Root
            Write-SourceFile -Root $root -Path 'Demo/src/Orders/Program.cs' -Content (Format-MethodSource -Statement 'var c = new HttpClient();')

            $r = Invoke-Gate -Root $root

            $r.ExitCode | Should -Be 3 -Because $r.Output
        }
    }
}
