# Contributing to PSLinear

Thanks for your interest in PSLinear. Bug reports, ideas and pull requests are all welcome.

- **Questions and ideas:** open an issue.
- **Bugs:** open an issue with the PSLinear version (`Get-InstalledPSResource PSLinear`), your
  PowerShell version and operating system, and the command you ran. Never paste an API key or
  token.
- **Security problems:** report them privately, as described in [SECURITY.md](SECURITY.md).

## Getting started

You need PowerShell 7.4 or later. `build.ps1 -Bootstrap` installs the other tools it needs
(Pester 5 and PSScriptAnalyzer) for the current user.

```powershell
git clone https://github.com/stian3555/PSLinear.git
cd PSLinear
./build.ps1 -Bootstrap                          # analyze, build and test
Import-Module ./output/PSLinear/PSLinear.psd1 -Force
```

`./build.ps1 -Task Build, Test` skips the analyzer for a quicker loop, and `Invoke-Pester
./tests` tests the source in `src/` without building.

If you change a `.graphql` file, validate it against Linear's published schema (needs Node.js):

```bash
npm ci --prefix tools
node tools/validate-graphql.mjs
```

## How the module is put together

- `src/Public/` has one exported cmdlet per file. `src/Private/` has the helpers, one file per
  concern: HTTP and retries (`Request.ps1`), the connection and caches (`Context.ps1`), the
  browser sign-in (`OAuth.ps1`), git (`Git.ps1`), and name resolution per entity
  (`Teams.ps1`, `Projects.ps1`, ...).
- Every GraphQL operation is a `.graphql` file in `src/GraphQL/`, named after the operation,
  with shared fragments in `src/GraphQL/Fragments/`. There are no GraphQL strings in the
  PowerShell code; `Get-LinearGraphQLDocument` loads an operation with its fragments.
- All requests go through `Invoke-LinearRequest` and `Invoke-LinearPagedRequest`, which handle
  authentication, errors, rate limits and retries. git runs only through `Invoke-LinearGit`.
- Commands return typed objects (`PSLinear.Issue`, `PSLinear.Project`, ...) built by the
  `ConvertTo-Linear<Type>` helpers in `Private/Convert.ps1`, with table views in
  `src/PSLinear.Format.ps1xml`.

## Conventions

The full rules are in [CLAUDE.md](CLAUDE.md), which AI coding assistants read as well. The ones
that matter most:

- **Strict mode.** The module runs under `Set-StrictMode -Version Latest`. Read values that may
  be missing with `Get-LinearNestedValue`.
- **Changes are safe to preview.** Every command that changes something supports `-WhatIf`,
  which must send no request at all, and `-Confirm` (ConfirmImpact Low for New and Add, Medium
  for Set and Start, High for Remove). `Set-*` commands return nothing unless `-PassThru` is
  given.
- **Friendly parameters.** Accept names, keys, URLs and ids, resolve them with cached private
  helpers, and list the valid values when a name is unknown.
- **Errors.** Expected per-item failures, such as a missing issue, write one non-terminating
  error and the pipeline goes on. Invalid input stops the command before anything is sent.
- **Pipelines.** Never wrap code that writes pipeline output in `try`/`catch`; wrap only the
  setup.
- **Help.** Every public command has comment-based help with a synopsis, a description, every
  parameter, at least one example and an `[OutputType()]`. A test enforces it.
- **Style.** Four spaces, opening braces on the same line, full cmdlet names, approved verbs,
  ASCII-only source files. PSScriptAnalyzer runs with `PSScriptAnalyzerSettings.psd1`.

## Tests

- Tests use Pester 5 and never call the real Linear API. They mock the network boundary
  (`Send-LinearHttpRequest`) and assert on the request that was sent. Shared fixtures are in
  `tests/TestHelpers.ps1`.
- Run them under strict mode, as the build does. Read request variables with
  `Get-RequestVariable`, which returns `$null` for a missing key instead of throwing.
- Trying a change against Linear is welcome, but use a workspace of your own, give everything
  you create a name that says it is safe to delete, and remove it afterwards.

## Adding a command

1. Add `src/Public/<Verb>-Linear<Noun>.ps1` and list it in `FunctionsToExport` in
   `src/PSLinear.psd1` (a test checks that the two match).
2. Put its GraphQL operations in `src/GraphQL/` and run the schema validation.
3. Return objects from a `ConvertTo-Linear<Type>` helper, and add a table view for a new type.
4. Write tests for the request it sends, name lookups, `-WhatIf`, pipeline input and errors.
5. Add it to the command table in the README and to `CHANGELOG.md` under `Unreleased`.

## Pull requests

- Work on a branch and keep each pull request focused on one change.
- `./build.ps1 -Bootstrap` must pass. CI runs the tests on Windows, macOS and Linux and checks
  every GraphQL operation against Linear's latest schema.
- Pull requests are squash-merged, so the title becomes the commit message on `main`. Write it
  in the imperative, such as "Add document commands".
