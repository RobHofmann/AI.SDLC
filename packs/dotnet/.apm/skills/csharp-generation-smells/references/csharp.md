# C# conventions

This page is the detailed C# reference of the dotnet pack. The short rules sit in the
[csharp-generation-smells skill](../SKILL.md), and the analyzer rules sit in [Clean Code rules](clean-code.md).
A repository can add its own C# rules on a page of its own, for example its logging method and its
exception types.

## Target framework and nullable

- Read the target framework and the `Nullable` setting in the project file before you copy a pattern.
  They are not always the same in every project of one solution.

## Package management

- **Central Package Management.** Every NuGet version is pinned in one file, `Directory.Packages.props`
  (`paths.packagesProps` in aisdlc.json). Do not give a version in a project file.
- **Package lock files.** `RestorePackagesWithLockFile` is on, and `packages.lock.json` is tracked in git.

## JSON serialization

- Use `System.Text.Json` with the shared settings of the repository. The default naming policy is
  PascalCase (clause DOTNET-01, see [the dotnet clauses](/.claude/skills/api-contract-conventions/references/clauses.md)).
- Use `[JsonPropertyName]` only when the wire name must differ from the property name. Examples are the
  Cosmos DB system fields `id` and `ttl`, and a partition key path. Do not add it when it is not needed.

## Logging

- Log through the logging method the repository names in its own rules. The repository page says which
  one, and a repository gate can check it.
- Pass an exception through the overload that takes one. If you put `ex.Message` into the message
  instead, the stack trace is lost.
- Put a value that an operator filters or alerts on into the log scope as a structured value, not only
  into the message text. Then it stays easy to query as well as easy to read.

## Validation and errors

- Report a validation failure through the error pipeline. Run the validator, check the result, and on a
  failure throw the typed validation exception the pipeline maps. Do not use a helper that throws an
  exception type the error formatter does not know.
- Throw a typed domain exception and let one central formatter map it to `ProblemDetails`. Controllers
  stay thin and do not catch. An exception the formatter does not know reaches the client as a 500.

## Visibility

- **Give a field the least visibility it needs.** A field that only its own class reads should be
  `private`. The same holds when outside code reaches it only through a member built from it, such as
  a list or a property.

## Control flow over closed sets

- **Follow local precedent first.** When similar classes in the same area already branch in one form,
  match them. One way across a codebase beats a one-off that is only locally the best.
- **Read the type before branching.** For a closed set (an enum, a discriminated union, or a sealed
  type hierarchy), list every member from its definition and handle each one. Do not list the members
  from memory.
- **First ask whether to branch at all.** Move a branch to polymorphism only when two things hold.
  The same switch on the same set appears in more than one place, and the arms select behaviour, not a
  value. Then put the behaviour on the types and keep one switch in the factory that builds them. That
  is the "one switch" rule of Clean Code. For one local branch, a switch is correct and lighter. The
  trigger is real duplication (the rule of three), not a guess about the future.
- **Choosing the branch form**, in this order:
  - **No switch for an open set.** When the value is an open type such as a `string` or a number, use
    `if` / `else if` or a lookup. Keep switches for finite sets.
  - **Three or more explicit cases that each return a value:** a `switch` expression.
  - **Two or fewer explicit cases:** `if` / `else if` / `else`.
  - **Three or more explicit cases whose arms do work, and the code stays easy to read:** a classic
    `switch` statement.
  - **Anything else:** stop and confirm the intent, instead of guessing the form.
- **Keep classic `switch` arms thin.** A few lines is fine. Better is one line that calls a method, or
  one line that prepares a value and a second line that passes it on.
- **Make the fallback arm match the intent.** When the branch must cover the whole closed set, a missing
  member is a bug, so the fallback fails loudly (for example with `ArgumentOutOfRangeException`). When
  "everything else" has a clear, correct meaning, a quiet fallback is right. Do not force a throw there.
- **Safety net, not a reason to pick a switch.** Make `CS8509` and `CS8524` build errors in
  `Directory.Build.props` in the folder of the solution (`paths.solution` in aisdlc.json). Then a
  `switch` expression over an enum that misses a member fails the build.

## Configuration

- Each library exposes a `ServiceCollectionExtensions` class with `Add*()` methods. Configuration
  follows the Options pattern (`IOptions<T>`).

## Dependency injection

- **A new constructor parameter on a container-built class changes every registration site.** The
  compiler sees only the class, so the build and the unit tests stay green, because each test builds
  the class by hand. The container fails at the first resolution. For a scoped client that is resolved
  late, that is a user's first click, not startup, and a health probe does not catch it.
- **An `Add*()` method registers every dependency the type it registers needs.** A caller builds a host
  from these methods and may expect each one to stand alone. Share a dependency with `TryAdd*`, so that
  calling several methods is safe.
- **Test the registration, not only the class.** A registration test applies each `Add*()` method to a
  bare `ServiceCollection`. It reads the constructor of each registered client and checks that a
  descriptor exists for every interface it needs. It reads descriptors and builds no provider, so it
  needs no cloud access. Add each new `Add*()` method to its data set.

## Testing

- **Framework:** xUnit with Moq for mocks and AutoFixture for test data.
- **Structure:** test projects mirror the source folder (`paths.sourceRoot`) under the test folder
  (`paths.testRoot`).
- **Thin controller tests.** Mock the service and check the HTTP status and the body shape. Business
  logic tests belong in the service tests. Do not test a controller action that only passes a call on
  and has no HTTP behaviour of its own. Such an action has no status code choice, no response change,
  and no auth or rate limit attribute. When a controller test is needed, mock every constructor dependency and never pass
  `null`. Assert on the `ActionResult` type and the status code, not on the service call arguments.
- **Coverage** follows clause C04 of [the constitution](/.claude/skills/ai-sdlc-handbook/references/constitution.md).
- **Console tools and thin SDK wrappers.** A thin wrapper over a live client SDK, and the entry point,
  cannot be unit tested well. Put the logic worth testing in plain classes that the entry point calls,
  and test those. Do not mock a client SDK only to assert that it was called. Do not add
  `[ExcludeFromCodeCoverage]` to make a number look better; the reviewed exclusion list of the pipeline
  is the place for that decision. State the reason for a shortfall in the pull request.
- **Asserting on logging.** Check it with a Moq `Verify(logger => logger.Log(...))` expression. Switch
  off `CA1873` for test projects in `.editorconfig`: that lambda is an expression tree for matching and
  never runs. Do not add a suppression per file, and do not rewrite the assertion to please the rule.
- **Nullable is not the same in every project.** In a project with `<Nullable>enable</Nullable>`, a
  logging assertion copied from a project without it raises `CS8620` and `CS8602`. Write the annotated
  form, which works everywhere: `It.IsAny<Func<It.IsAnyType, Exception?, string>>()`, and
  `(state.ToString() ?? string.Empty).Contains(...)`.
- **A logging method may check `IsEnabled` first.** If it does, a bare `Mock<ILogger<T>>` returns false,
  the call never reaches `Log`, and the `Verify` fails. Set up `IsEnabled` for the level under test.
- **A `TheoryData` type argument must be serializable.** A delegate in theory data raises `xUnit1044` and
  stops Test Explorer from listing the rows. Pass a serializable key, such as a name, and look the
  delegate up inside the test.
- **A test class that implements `IDisposable` is `sealed`.** That answers `CA1816` properly instead of
  suppressing it.
- **A test carries one story trait.** `[Trait("Story","<work item key>")]` records which work item the
  test came from, and the dotnet gate `Check-StoryTraits.ps1` checks it. A class older than the rule
  carries `LEGACY-0`. There is no trait per acceptance criterion.
- **No reflection into the private members of your own class.** Do not use `BindingFlags.NonPublic`, or
  open up a member, to test your own private code. Test through the public API, and fake the result of
  the SDK dependency instead. Reflecting into a third-party framework to test that framework is a
  different case and is fine.
- **Faking an ARM SDK result for a client test.** Build a real `ArmClient` with a mocked
  `TokenCredential`, and point `ArmClientOptions.Transport` at a fake `HttpMessageHandler`. The fake
  returns the status, the response for that verb and route, and the ARM error body
  (`{ error: { code, message } }`). Then call the real public method. This runs the real request
  building, retry policy and error parsing of the SDK, and it holds across SDK versions. To stub only a
  resource's `.Data`, a `Mock<ResourceGroupResource>` is still the simpler tool.
- **Test layout (AAA).** Every test has `// Arrange`, `// Act` and `// Assert` markers. Keep the inputs,
  the one call under test, and the checks clearly apart. A test with nothing to act on may merge
  `// Arrange` and `// Act`. Clause C10 keeps these markers, see
  [comments](/.claude/skills/ai-sdlc-handbook/references/comments.md).

## Code quality (analyzers)

See [Clean Code rules](clean-code.md). `SonarAnalyzer.CSharp` checks the mechanical rules, with the
severities in `.editorconfig`. The rules that fail the build are the closed-set net above and `S2068`
(hardcoded credentials). The small-function rules (`S3776`, `S138`, `S107`, `S134`) run at warning, and
each one becomes an error once its backlog is zero.

## Comments

Every public or protected type and member carries an XML doc comment (`/// <summary>`). It says what
the member is for and what a caller must know: `<param>`, `<returns>` and `<exception>` where they add
something. Use `<inheritdoc/>` where a member only implements an interface member that is documented. A
Razor component with parameters starts with a summary of what it shows and what each parameter does.

Comments inside a body follow clause C10 of the [constitution](/.claude/skills/ai-sdlc-handbook/references/constitution.md), in full in
[comments](/.claude/skills/ai-sdlc-handbook/references/comments.md). `Check-CommentHygiene.ps1` blocks a breach in
the lines a change adds, and `Check-XmlDocs.ps1` reports a public declaration without a doc comment.

## Related

- [Clean Code rules](clean-code.md) - the analyzer-backed quality gate these conventions feed.
- [The csharp-generation-smells skill](../SKILL.md) - the short rules a build and a review check.
- [API conventions](/.claude/skills/api-contract-conventions/references/api.md) - the wire rules and thin controllers.
- [Comments](/.claude/skills/ai-sdlc-handbook/references/comments.md) - clause C10 in full.
- [Constitution](/.claude/skills/ai-sdlc-handbook/references/constitution.md) - clause C04 on tests and coverage.
