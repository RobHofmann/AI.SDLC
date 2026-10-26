# Build Job Patterns

`build-and-test.yml` is a reusable workflow (`on: workflow_call`). The pull request workflow and the
release workflow both call it, so they build the same way.

## .NET Backend Build

```yaml
backend:
  runs-on: ubuntu-24.04
  steps:
    - uses: actions/checkout@<full commit SHA> # v4
    - uses: actions/setup-dotnet@<full commit SHA> # v4
      with:
        dotnet-version: "9.0.x"
        cache: true
        cache-dependency-path: "**/packages.lock.json"
    - run: dotnet restore src/Contoso.Portal.sln --locked-mode
    - run: dotnet build src/Contoso.Portal.sln --no-restore --configuration Release
    - run: >-
        dotnet test src/Contoso.Portal.sln --no-build --configuration Release
        --settings tests/coverage.runsettings --logger trx --results-directory TestResults
```

`--settings` takes the file in `paths.runSettings` of aisdlc.json, so the coverage rules match the
pre-flight.

## Frontend build with npm

```yaml
frontend:
  runs-on: ubuntu-24.04
  defaults:
    run:
      working-directory: src/contoso-portal-web
  steps:
    - uses: actions/checkout@<full commit SHA> # v4
    - uses: actions/setup-node@<full commit SHA> # v4
      with:
        node-version: "22"
        cache: npm
        cache-dependency-path: src/contoso-portal-web/package-lock.json
    - run: npm ci
    - run: npm run lint
    - run: npm test -- --watch=false
    - run: npm run build -- --configuration production
```

Use `npm ci`, never `npm install`: it installs exactly the lock file and fails when the lock file is out of date.

## Combined full-stack build (parallel jobs and one package)

The backend and the frontend run as parallel jobs. A `package` job needs both and uploads one artifact
that every deploy job downloads:

```yaml
package:
  if: ${{ inputs.upload-package }}
  needs: [backend, frontend]
  runs-on: ubuntu-24.04
  steps:
    - uses: actions/download-artifact@<full commit SHA> # v4
      with:
        path: package
        pattern: "{api,web}"
    - uses: actions/upload-artifact@<full commit SHA> # v4
      with:
        name: package
        path: package
```

The pull request workflow calls the build without `upload-package`, so it packs nothing.

## Function or worker app build

The same as the backend build, with `dotnet publish` of the function project into `out/func` and an
upload of that folder. The deploy job deploys the folder; it never builds.

## Template validation (infrastructure only)

```yaml
validate:
  runs-on: ubuntu-24.04
  steps:
    - uses: actions/checkout@<full commit SHA> # v4
    - shell: pwsh
      run: ./deploy/Test-Templates.ps1 -Path infra
```

The script runs the linter of the template language. For Bicep, follow `bicep-conventions`.

## Test results and coverage

### .NET (TRX) and coverage

```yaml
- name: merge coverage
  run: |
    dotnet tool install --global dotnet-coverage
    dotnet-coverage merge "TestResults/**/*.coverage" --output coverage/coverage.xml --output-format xml
- uses: actions/upload-artifact@<full commit SHA> # v4
  with:
    name: coverage
    path: coverage/coverage.xml
    if-no-files-found: error
- uses: actions/upload-artifact@<full commit SHA> # v4
  if: ${{ !cancelled() }}
  with:
    name: test-results-backend
    path: TestResults/**/*.trx
```

The `coverage` artifact is what the `ai-sdlc` job of the pull request workflow downloads and passes in
`coverage-file` (see [pr-validation-patterns.md](pr-validation-patterns.md)).

### JavaScript (JUnit XML)

Write the report to a file with the JUnit reporter of the test runner. Upload it with
`if: ${{ !cancelled() }}`, so a failed run still keeps the results.

## NuGet and npm caching

`actions/setup-dotnet` and `actions/setup-node` cache the packages when you set `cache:`. Key the NuGet
cache on the committed lock files (`packages.lock.json`, with `RestorePackagesWithLockFile` on), and the
npm cache on `package-lock.json`. Do not cache build output: a cache is for downloads, the artifact is
for the build.
