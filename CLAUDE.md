# PSLinear

PowerShell module for the Linear (linear.app) GraphQL API, published to the PowerShell Gallery.
PowerShell 7.4+ only (`CompatiblePSEditions = Core`), cross-platform.

## Commands

- `./build.ps1 -Bootstrap` builds `output/PSLinear`, runs PSScriptAnalyzer, then Pester against the built module. It must pass before you finish a task.
- `./build.ps1 -Task Build, Test` skips the analyzer for a quicker loop.
- `Invoke-Pester ./tests` tests the source in `src/` directly (no build needed).
- `npm ci --prefix tools && node tools/validate-graphql.mjs` validates every operation in `src/GraphQL` against Linear's latest published schema. Run it after adding or changing any `.graphql` file.
- The schema lives at https://raw.githubusercontent.com/linear/linear/master/packages/sdk/src/schema.graphql. Download it and grep it to check input type field names (for example `IssueCreateInput`, `IssueUpdateInput`, `IssueFilter`) instead of guessing.

## Layout

- `src/Public/<Verb-Noun>.ps1`: one exported function per file. Add every new one to `FunctionsToExport` in `src/PSLinear.psd1`; a test enforces that the two match.
- `src/Private/*.ps1`: helpers, grouped by concern (`Request.ps1`, `Context.ps1`, `Convert.ps1`, `Errors.ps1`, `Teams.ps1`).
- `src/GraphQL/<OperationName>.graphql`: one operation per file, and the operation name must equal the file name. Reusable fragments go in `src/GraphQL/Fragments/<FragmentName>.graphql`. Load them with `Get-LinearGraphQLDocument -Name <OperationName>`, which appends the fragments automatically. Never inline GraphQL strings in PowerShell code.
- `src/PSLinear.Format.ps1xml`: default views for each `PSLinear.*` type.
- `tests/*.Tests.ps1`: Pester 5. Shared helpers are in `tests/TestHelpers.ps1`.
- `build.ps1` merges Private and Public into a single psm1 by replacing the `#region Functions` block in `src/PSLinear.psm1`.

## Rules that are easy to get wrong

**Strict mode.**
- The module runs `Set-StrictMode -Version Latest`, where even `$null.Property` throws.
- Read anything that may be missing or null with `Get-LinearNestedValue -InputObject $obj -Name 'a.b.c'`.
- Pipe-filter collections with `Where-Object { $null -ne $_ -and ... }`.

**HTTP goes through one place.**
- Use `Invoke-LinearRequest` for single requests and `Invoke-LinearPagedRequest` for Relay connections.
- They handle auth, GraphQL errors that arrive with HTTP 200, `RATELIMITED` (HTTP 400), 5xx retries and backoff.
- Do not call `Invoke-RestMethod` anywhere else.

**Errors.**
- Build errors with `New-LinearErrorRecord -ErrorId 'PSLinear.<Name>'` and throw them via `$PSCmdlet.ThrowTerminatingError(...)`.
- For expected per-item failures (such as not found), call `Invoke-LinearRequest -IncludeErrors` and `$PSCmdlet.WriteError(...)` once. Catching a nested terminating error would also add it to the caller's `-ErrorVariable`, giving duplicates.

**Pipelines.**
- Never wrap code that emits pipeline output in `try/catch`. It breaks `Select-Object -First` stopping the upstream command.
- Wrap only the setup, such as filter building or name resolution.

**Pipeline binding.**
- Issues and teams both have an `Id` property, so do not put `ValueFromPipelineByPropertyName` on an `Id` parameter.
- Use `[string[]] $Id` with `ValueFromPipeline` for identifiers.
- Use a separate `[PSTypeName('PSLinear.Issue')] [object[]] $InputObject` parameter set for objects (see `Get-LinearIssue`).

**Mutations.**
- Every state-changing command uses `SupportsShouldProcess`: ConfirmImpact `Low` for New, `Medium` for Set, `High` for Remove/archive.
- `-WhatIf` must send no request; test that explicitly.
- `Set-*` returns nothing unless `-PassThru` is given.

**Output objects.**
- Return `[pscustomobject]` with `PSTypeName = 'PSLinear.<Type>'`, built by a `ConvertTo-Linear<Type>` helper in `Private/Convert.ps1`.
- Flatten names for display (`State`, `Assignee`, `Team`) and keep the matching ids (`StateId`, `AssigneeId`, `TeamId`).
- Add a table view to the format file for new types.

**Friendly parameters.**
- Accept names, keys or ids, and resolve them to ids with cached private helpers (see `Resolve-LinearTeamId` and `Get-LinearTeamCache`).
- Clear caches in `Clear-LinearCache`.
- Errors for unknown names should list the valid values.

**API limits.**
- Linear rejects any single query above 10,000 complexity points. Each connection multiplies its children's points by the page size.
- Pages are capped at `$script:MaxPageSize` (100), and nested connections inside fragments need a small explicit `first:`.

**Priority values.** 0 None, 1 Urgent, 2 High, 3 Medium, 4 Low (`$script:PriorityMap`).

**Auth headers.** Personal API keys are sent as `Authorization: <key>` (no Bearer); OAuth tokens as `Bearer <token>`.

## Testing

- Never call the real Linear API from tests.
- Mock the network boundary only: `Mock -ModuleName PSLinear Send-LinearHttpRequest { New-LinearTestResponse -Data @{ ... } }`. Assert on the request with `Should -Invoke ... -ParameterFilter { (Get-RequestBody $Body).variables... }`.
- Mock bodies run in the test file's scope, so `$script:` there means the test file, not the module. Use `InModuleScope PSLinear { ... }` to read or set module state.
- Mock `Start-Sleep` in retry tests.
- Each public command needs comment-based help: synopsis, description, every parameter, at least one example, and an `[OutputType()]`. `tests/Module.Tests.ps1` enforces this.

## Style

- 4-space indentation and opening braces on the same line.
- `else`, `elseif`, `catch` and `finally` start on a new line after the closing brace.
- Full cmdlet names, no aliases. Approved verbs only, singular nouns with the `Linear` prefix.
- Keep source files ASCII-only: no em dashes or smart quotes. PSScriptAnalyzer flags non-ASCII files without a BOM.
- Code, comments, help and commit messages in English.
- Add user-visible changes to `CHANGELOG.md` under the unreleased version, and update the README command table and roadmap.

## Releasing

- Bump `ModuleVersion` and `Prerelease` in `src/PSLinear.psd1` and the CHANGELOG.
- Publish a GitHub release tagged `v<version>[-<prerelease>]`. `.github/workflows/publish.yml` verifies that the tag matches the manifest and publishes the module.
- `build.ps1 -Task Publish` refuses to run while the manifest still contains the `OWNER` placeholder.
