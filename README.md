# PSLinear

[![CI](https://github.com/stian3555/PSLinear/actions/workflows/ci.yml/badge.svg)](https://github.com/stian3555/PSLinear/actions/workflows/ci.yml)
[![PowerShell Gallery](https://img.shields.io/powershellgallery/v/PSLinear?include_prereleases&label=PowerShell%20Gallery)](https://www.powershellgallery.com/packages/PSLinear)
[![Downloads](https://img.shields.io/powershellgallery/dt/PSLinear)](https://www.powershellgallery.com/packages/PSLinear)

A PowerShell module for [Linear](https://linear.app). Query, create and update issues with real
objects you can pipe, filter and format, and use any part of the Linear GraphQL API when there
is no dedicated cmdlet yet.

```powershell
Get-LinearIssue -Assignee me -StateType Unstarted, Started

Identifier   State            Priority    Assignee             Title
----------   -----            --------    --------             -----
ENG-412      In Progress      High        Ada Lovelace         Retry webhook deliveries on 5xx
ENG-398      Todo             Medium      Ada Lovelace         Document the deploy pipeline
```

> PSLinear is a community project and is not affiliated with or endorsed by Linear.

## Features

- **Pipeline-first.** Typed objects (`PSLinear.Issue`, `PSLinear.Team`, `PSLinear.Project`
  and more) with flattened properties for filtering and display, and the ids needed to chain
  commands.
- **Readable filters.** `-Team ENG -State 'In Progress' -Assignee me -Label Bug` instead of
  hand-written GraphQL filters, with a raw `-Filter` for everything else.
- **Names instead of ids.** Create and update issues with team keys, state, label, project
  and user names, or `me`. A state type such as `started` or `completed` picks the right state
  in every team, and issue URLs work wherever an identifier does. Lookups are cached, and an
  unknown name fails with a list of the valid values.
- **Safe changes.** `New-`, `Set-` and `Remove-LinearIssue` support `-WhatIf` (which sends
  nothing at all) and `-Confirm`. `Remove-LinearIssue` asks first and moves issues to the
  trash, where they can be restored for 30 days.
- **Automatic paging.** Results stream page by page. `-First` sets a limit; `-All` follows
  pagination to the end. Stopping early (`| Select-Object -First 5`) stops the requests too.
- **Handles the API's rules for you.** Retries rate-limited requests, server errors and
  network failures with backoff. Reports GraphQL errors even when they arrive with HTTP 200.
  Keeps queries well below Linear's complexity limits.
- **Safe credentials.** Tokens are kept as `SecureString` in memory only. Supports
  SecretManagement vaults and environment variables for CI.
- **Escape hatch.** `Invoke-LinearGraphQL` runs any query or mutation, with `-WhatIf` for
  mutations.
- **Cross-platform.** PowerShell 7.4+ on Windows, macOS and Linux.

## Installation

```powershell
Install-PSResource -Name PSLinear -Prerelease
# or, with PowerShellGet 2.x:
Install-Module -Name PSLinear -AllowPrerelease -Scope CurrentUser
```

## Quick start

1. Create a personal API key in Linear under **Settings > Security & access**.
2. Connect and start querying:

```powershell
Connect-Linear              # prompts for the API key without echoing it
Get-LinearViewer            # who am I?
Get-LinearTeam              # which teams can I see?
Get-LinearIssue ENG-123     # one issue
```

## Authentication

| Method | Command |
| --- | --- |
| Personal API key (prompt) | `Connect-Linear` |
| Personal API key (value) | `Connect-Linear -ApiKey $secureString` |
| SecretManagement vault | `Connect-Linear -SecretName LinearApiKey [-Vault MyVault]` |
| Environment variable | `Connect-Linear -FromEnvironment`, or just set `LINEAR_API_KEY` |
| OAuth access token | `Connect-Linear -AccessToken $secureString` |

When `LINEAR_API_KEY` is set, every command connects implicitly, so pipelines need no
`Connect-Linear` call. Storing the key in a vault keeps it out of your scripts and history:

```powershell
Install-PSResource Microsoft.PowerShell.SecretManagement, Microsoft.PowerShell.SecretStore
Set-Secret -Name LinearApiKey -Secret (Read-Host -AsSecureString 'Linear API key')
Connect-Linear -SecretName LinearApiKey
```

## Examples

```powershell
# My open work, oldest update first
Get-LinearIssue -Assignee me -StateType Unstarted, Started | Sort-Object UpdatedAt

# Urgent and high-priority issues in progress for a team (tab-complete -Team)
Get-LinearIssue -Team ENG -State 'In Progress' -Priority Urgent, High

# Every bug in a team, counted by state
Get-LinearIssue -Team ENG -Label Bug -All | Group-Object State -NoElement | Sort-Object Count -Descending

# Current cycle for several teams
Get-LinearTeam -Name ENG, OPS | Get-LinearIssue -CurrentCycle

# What can I use? States, labels, projects and cycles of a team
Get-LinearWorkflowState -Team ENG
Get-LinearLabel -Team ENG
Get-LinearProject | Where-Object Status -EQ 'In Progress' | Sort-Object TargetDate
Get-LinearCycle -Team ENG -Previous -Active -Next

# Unassigned issues that mention "login"
Get-LinearIssue -Unassigned -Search login

# Raw IssueFilter combined with regular parameters: overdue open issues
Get-LinearIssue -StateType Unstarted, Started -Filter @{ dueDate = @{ lt = (Get-Date -Format 'yyyy-MM-dd') } }

# Export to CSV
Get-LinearIssue -Team ENG -All |
    Select-Object Identifier, Title, State, Assignee, PriorityLabel, Labels, UpdatedAt |
    Export-Csv -Path eng-issues.csv -NoTypeInformation

# Create an issue; states, labels, projects and users are given by name
New-LinearIssue -Team ENG -Title 'Login fails on Safari' -Label Bug -Priority High -Assignee me -State Todo

# Create a sub-issue, due in a week
New-LinearIssue -Team ENG -Title 'Write tests for the retry logic' -Parent ENG-412 -DueDate (Get-Date).AddDays(7)

# Start work on an issue
Set-LinearIssue ENG-412 -State 'In Progress' -Assignee me

# Remove the due date and take the issue out of its cycle
Set-LinearIssue ENG-412 -Clear DueDate, Cycle

# Triage: assign every unassigned bug and add a label, keeping the existing labels
Get-LinearIssue -Team ENG -Label Bug -Unassigned | Set-LinearIssue -Assignee 'grace@example.com' -AddLabel Triaged

# Preview a bulk change without sending anything
Get-LinearIssue -Assignee me -State 'In Review' | Set-LinearIssue -State Done -WhatIf

# Close issues across teams whose done states have different names
Get-LinearIssue -Label Duplicate -StateType Unstarted -All | Set-LinearIssue -State completed

# Move issues to the trash (asks per issue unless -Confirm:$false); -Archive archives instead
Get-LinearIssue -Team ENG -Label Spam -All | Remove-LinearIssue

# Anything else: raw GraphQL, with -WhatIf for mutations
Invoke-LinearGraphQL -Query '{ viewer { assignedIssues(first: 5) { nodes { identifier title } } } }'
Invoke-LinearGraphQL -Query 'mutation($id: String!) { issueUnarchive(id: $id) { success } }' -Variables @{ id = 'ENG-1' } -WhatIf
```

## Commands

| Command | Description |
| --- | --- |
| `Connect-Linear` | Connect with an API key, OAuth token, vault secret or environment variable. |
| `Disconnect-Linear` | Forget the credential and cached data. |
| `Get-LinearViewer` | The authenticated user and organization. |
| `Get-LinearTeam` | Teams, filterable by key or name with wildcards. |
| `Get-LinearUser` | Users, filterable by name or email; `-IncludeDisabled` for deactivated users. |
| `Get-LinearWorkflowState` | Workflow states per team, in workflow order, filterable by name or type. |
| `Get-LinearLabel` | Labels in the workspace, or the labels a team can use. |
| `Get-LinearProject` | Projects with status, lead, target date and progress. |
| `Get-LinearCycle` | Cycles per team, with `-Active`, `-Next`, `-Previous` and `-Number`. |
| `Get-LinearIssue` | Issues by identifier or URL, or filtered lists with paging. |
| `New-LinearIssue` | Create an issue, with states, labels, projects and users given by name. |
| `Set-LinearIssue` | Change issues: state, assignee, labels (replace, add or remove), priority and more, or clear values with `-Clear`. |
| `Remove-LinearIssue` | Move issues to the trash, or archive them with `-Archive`. |
| `Get-LinearRateLimit` | Rate-limit status from the latest response. |
| `Invoke-LinearGraphQL` | Run any GraphQL query or mutation. |

Run `Get-Help <command> -Full` for parameters and more examples.

## How it works with the Linear API

- **Endpoint and auth.** All calls go to `https://api.linear.app/graphql`. Personal API keys
  are sent in the `Authorization` header as-is; OAuth tokens use `Bearer`.
- **Rate limits.** Linear limits requests and query complexity per hour, per user. PSLinear
  retries rate-limited calls with exponential backoff (3 times by default, set with
  `Connect-Linear -MaxRetries`). `Get-LinearRateLimit` shows the remaining budget.
- **Complexity.** Linear rejects any single query above 10,000 complexity points. Pages are
  capped at 100 issues so a page stays well below that limit.
- **Name lookups.** Team, workflow state, label, user and project names are resolved to ids
  with cached queries (10 minutes; states and labels per team). `Connect-Linear` and
  `Disconnect-Linear` clear the caches, and a name that is not found triggers one refresh.
- **Errors.** GraphQL errors are turned into PowerShell errors with the Linear error code in
  the message. A missing issue in `Get-LinearIssue`, `Set-LinearIssue` or
  `Remove-LinearIssue`, or a change Linear rejects, writes a non-terminating error so the rest
  of the pipeline continues. Unknown names and invalid parameter combinations stop the
  command.

## Development

```text
src/
  PSLinear.psd1 / .psm1     manifest and loader
  Public/                   one exported function per file
  Private/                  internal helpers
  GraphQL/                  operations (*.graphql) and Fragments/
tests/                      Pester 5 tests (network calls are mocked)
tools/validate-graphql.mjs  validates every operation against Linear's published schema
build.ps1                   Build, Analyze, Test and Publish tasks
```

```powershell
./build.ps1 -Bootstrap      # build, run PSScriptAnalyzer and the tests
Import-Module ./output/PSLinear/PSLinear.psd1 -Force
```

GraphQL operations live in `.graphql` files rather than strings in PowerShell code. That keeps
them readable and lets CI validate them against Linear's published schema on every push and
weekly, so a deprecated or removed field is caught before users hit it:

```bash
npm ci --prefix tools
node tools/validate-graphql.mjs
```

### Releasing

1. Update `ModuleVersion` (and `Prerelease`) in `src/PSLinear.psd1` and `CHANGELOG.md`.
2. Create a GitHub release with a matching tag, for example `v0.1.0-preview1`.
3. The `Publish` workflow builds, tests and publishes to the PowerShell Gallery.

Releases are immutable and `v*` tags cannot be moved or deleted, so check the version before you
publish. A mistake means a new version, not a re-tag.

## Roadmap

- Comments, issue relations, milestones and attachments
- `-Cycle`, `-Milestone` and `-Delegate` on `New-LinearIssue` and `Set-LinearIssue`
- Tab completion for `-State`, `-Label` and `-Assignee`
- Markdown help with platyPS and an online help URI

## Security

Please report vulnerabilities privately, as described in [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
