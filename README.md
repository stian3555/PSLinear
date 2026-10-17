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
Install-PSResource -Name PSLinear
# or, with PowerShellGet 2.x:
Install-Module -Name PSLinear -Scope CurrentUser
```

Preview versions are published as prereleases: add `-Prerelease` (`-AllowPrerelease` for
`Install-Module`) to get the latest one.

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
| Sign in through the browser (OAuth) | `Connect-Linear -Browser -ClientId <id> [-SecretName LinearSignIn]` |
| OAuth access token | `Connect-Linear -AccessToken $secureString` |

When `LINEAR_API_KEY` is set, every command connects implicitly, so pipelines need no
`Connect-Linear` call. Storing the key in a vault keeps it out of your scripts and history:

```powershell
Install-PSResource Microsoft.PowerShell.SecretManagement, Microsoft.PowerShell.SecretStore
Set-Secret -Name LinearApiKey -Secret (Read-Host -AsSecureString 'Linear API key')
Connect-Linear -SecretName LinearApiKey
```

### Signing in through the browser

`Connect-Linear -Browser` opens Linear's consent page and receives the result on a local
address, like the official Linear integrations do. It uses OAuth 2.0 with PKCE, so there is no
client secret to keep. You approve **PSL**, the project's public OAuth application, and the
tokens go straight to your PowerShell session; the project never sees them or your data.

```powershell
Connect-Linear -Browser -SecretName LinearSignIn
```

Access tokens last 24 hours and are renewed automatically. With `-SecretName`, the refresh
token is saved in your SecretManagement vault, so later sessions sign in without the browser.
`Disconnect-Linear -Revoke` revokes the tokens at Linear and removes the saved one. Use
`-Scope` to ask for other permissions (`read`, `write`, `issues:create`, `comments:create`,
`timeSchedule:write`, `admin`) and `-RedirectUri` to use another port.

To sign in through your own OAuth application instead, for example to control what the consent
page shows or to restrict sign-ins to your workspace:

1. In Linear, go to **Settings > API > OAuth applications** and create an application. Its
   name cannot contain the word "Linear".
2. Add these callback URLs:
   `http://localhost:47821/callback` and `http://127.0.0.1:47821/callback`.
3. Connect with its client id, or set `LINEAR_OAUTH_CLIENT_ID`:
   `Connect-Linear -Browser -ClientId 'your-client-id'`.

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
Get-LinearProject -Team ENG -Status started | Sort-Object TargetDate
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

# From a template, planned for the next cycle and a project milestone
New-LinearIssue -Team ENG -Title 'Payment fails on retry' -Template 'Bug report' -Cycle next -Project Checkout -Milestone Beta

# Move the unstarted issues of the current cycle to the next one
Get-LinearIssue -Team ENG -Cycle active -StateType Unstarted | Set-LinearIssue -Cycle next

# Start work on an issue: assign it to you, move it to In Progress and check out its git branch
Start-LinearIssue ENG-412

# Later, in the same repository: which issue is this branch for?
Get-LinearIssue -Current | Format-List Identifier, Title, State, Url

# Create a project for two teams, then start it and post a status update
New-LinearProject 'Checkout v2' -Team ENG, OPS -Lead me -TargetDate 2027-03-31 -Label Customer
Set-LinearProject 'Checkout v2' -Status started -AddMember 'grace@example.com'
New-LinearProjectUpdate -Project 'Checkout v2' 'Design approved; build starts Monday.' -Health OnTrack

# Projects in progress whose latest update is not on track
Get-LinearProject -Status started | Get-LinearProjectUpdate -First 1 | Where-Object Health -NE 'OnTrack'

# Group projects in an initiative and post its status
New-LinearInitiative 'Q1 growth' -Owner me -Status Active -TargetDate 2027-03-31 |
    Set-LinearInitiative -AddProject 'Checkout v2', Website
New-LinearInitiativeUpdate -Initiative 'Q1 growth' 'Checkout v2 is on track; Website slipped a week.' -Health AtRisk

# Set up a sub-team with its own label group and members
New-LinearTeam 'Mobile' -Key MOB -Parent ENG
New-LinearLabel Platform -Team MOB -IsGroup
New-LinearLabel iOS -Team MOB -Group Platform -Color '#5E6AD2'
Add-LinearTeamMember MOB -User me, 'grace@example.com'

# Write a project document from a Markdown file, then read it back
New-LinearDocument 'Launch plan' -Project 'Checkout v2' -Content (Get-Content ./launch-plan.md -Raw)
Get-LinearDocument -Project 'Checkout v2' -Title 'Launch plan' | Get-LinearDocument | Select-Object -ExpandProperty Content

# Remove the due date and take the issue out of its cycle
Set-LinearIssue ENG-412 -Clear DueDate, Cycle

# Triage: assign every unassigned bug and add a label, keeping the existing labels
Get-LinearIssue -Team ENG -Label Bug -Unassigned | Set-LinearIssue -Assignee 'grace@example.com' -AddLabel Triaged

# Preview a bulk change without sending anything
Get-LinearIssue -Assignee me -State 'In Review' | Set-LinearIssue -State Done -WhatIf

# Close issues across teams whose done states have different names
Get-LinearIssue -Label Duplicate -StateType Unstarted -All | Set-LinearIssue -State completed

# Comment, reply and resolve
Add-LinearComment ENG-412 'Deployed to staging.'
Get-LinearComment ENG-412 | Select-Object -Last 1 | Add-LinearComment -Body 'Thanks, fixed.'
Get-LinearComment ENG-412 | Where-Object { -not $_.IsReply -and -not $_.Resolved } | Set-LinearComment -Resolved $true

# Upload files, link a pull request, and show a screenshot in a comment
Add-LinearAttachment ENG-412 ./logs/*.log -Comment 'Logs from the failed run.'
Add-LinearAttachment ENG-412 -Url https://github.com/acme/app/pull/42
Add-LinearComment ENG-412 'After the fix:' -Attachment ./after.png

# Relations: what blocks my open work, and mark a duplicate
Get-LinearIssue -Assignee me -StateType Unstarted, Started | Get-LinearIssueRelation -Type BlockedBy
Add-LinearIssueRelation ENG-412 DuplicateOf ENG-398

# Move issues to the trash (asks per issue unless -Confirm:$false); -Archive archives instead
Get-LinearIssue -Team ENG -Label Spam -All | Remove-LinearIssue

# Anything else: raw GraphQL, with -WhatIf for mutations
Invoke-LinearGraphQL -Query '{ viewer { assignedIssues(first: 5) { nodes { identifier title } } } }'
Invoke-LinearGraphQL -Query 'mutation($id: String!) { issueUnarchive(id: $id) { success } }' -Variables @{ id = 'ENG-1' } -WhatIf
```

## Commands

| Command | Description |
| --- | --- |
| `Connect-Linear` | Connect with an API key, a browser sign-in (OAuth with PKCE), an OAuth token, a vault secret or an environment variable. |
| `Disconnect-Linear` | Forget the credential and cached data; `-Revoke` also revokes an OAuth sign-in. |
| `Get-LinearViewer` | The authenticated user and organization. |
| `Get-LinearTeam` | Teams, filterable by key or name with wildcards. |
| `New-LinearTeam` | Create a team or sub-team. |
| `Set-LinearTeam` | Rename a team, change its key, description, time zone or parent. |
| `Remove-LinearTeam` | Delete teams (archived until Linear deletes them with their issues). |
| `Get-LinearTeamMember` | Members of teams, with team ownership. |
| `Add-LinearTeamMember` | Add users to a team. |
| `Remove-LinearTeamMember` | Remove users from a team. |
| `Get-LinearUser` | Users, filterable by name or email; `-IncludeDisabled` for deactivated users. |
| `Get-LinearWorkflowState` | Workflow states per team, in workflow order, filterable by name or type. |
| `Get-LinearLabel` | Labels in the workspace, or the labels a team can use; `-IncludeGroups` and `-IncludeRetired` for the rest. |
| `New-LinearLabel` | Create a workspace or team label, or a label group. |
| `Set-LinearLabel` | Rename, recolor, regroup, retire or restore labels. |
| `Remove-LinearLabel` | Delete labels (Linear removes them from their issues). |
| `Get-LinearProject` | Projects with status, health, lead, teams, labels, dates and progress, filterable by team and status; `-Id` for the full project with content and members. |
| `New-LinearProject` | Create a project, with teams, lead, members, status, labels and template given by name. |
| `Set-LinearProject` | Change projects: status, lead, dates, priority, teams, labels and members (replace, add or remove), or clear values. |
| `Remove-LinearProject` | Move projects to the trash; Linear archives their issues until the project is restored. |
| `Get-LinearProjectUpdate` | Status updates of a project, or of every project, newest first. |
| `New-LinearProjectUpdate` | Post a project status update with a health (OnTrack, AtRisk, OffTrack). |
| `Set-LinearProjectUpdate` | Edit a status update's text or health. |
| `Remove-LinearProjectUpdate` | Remove status updates. |
| `Get-LinearInitiative` | Initiatives with status, health, owner, projects and labels; `-Id` for the full initiative with content and sub-initiatives. |
| `New-LinearInitiative` | Create an initiative, with owner, lead team and labels given by name. |
| `Set-LinearInitiative` | Change initiatives (status, owner, dates, labels) and add or remove their projects. |
| `Remove-LinearInitiative` | Move initiatives to the trash, or archive them with `-Archive`. |
| `Get-LinearInitiativeUpdate` | Status updates of an initiative, or of every initiative, newest first. |
| `New-LinearInitiativeUpdate` | Post an initiative status update with a health. |
| `Set-LinearInitiativeUpdate` | Edit an initiative status update's text or health. |
| `Remove-LinearInitiativeUpdate` | Remove initiative status updates. |
| `Get-LinearDocument` | Documents of an issue, project, initiative or team, or all of them, most recently updated first; `-Id` for the content. |
| `New-LinearDocument` | Create a document in an issue, project, initiative or team. |
| `Set-LinearDocument` | Rename a document, replace its content, change its owner or move it. |
| `Remove-LinearDocument` | Move documents to the trash. |
| `Get-LinearCycle` | Cycles per team, with `-Active`, `-Next`, `-Previous` and `-Number`. |
| `Get-LinearTemplate` | Issue, project and document templates, optionally those a team can use. |
| `Get-LinearMilestone` | Milestones of a project, or of every project, with status, target date and progress. |
| `New-LinearMilestone` | Create a project milestone. |
| `Set-LinearMilestone` | Rename, reschedule, reorder or move milestones. |
| `Remove-LinearMilestone` | Delete milestones; their issues stay in the project. |
| `Get-LinearIssue` | Issues by identifier or URL, the issue of the current git branch (`-Current`), or filtered lists with paging. |
| `Start-LinearIssue` | Start an issue: assign it to you, move it to a started state and check out its git branch. |
| `New-LinearIssue` | Create an issue, with states, labels, projects, milestones, cycles, users and templates given by name. |
| `Set-LinearIssue` | Change issues: state, assignee, labels (replace, add or remove), priority and more, or clear values with `-Clear`. |
| `Remove-LinearIssue` | Move issues to the trash, or archive them with `-Archive`. |
| `Get-LinearComment` | Comments on an issue, project, initiative or document, thread by thread. |
| `Add-LinearComment` | Comment on an issue, project, initiative or document, or reply to a comment. |
| `Set-LinearComment` | Edit a comment, or resolve or reopen its thread. |
| `Remove-LinearComment` | Delete comments. |
| `Get-LinearAttachment` | Attachments of issues: uploaded files, links and integration links. |
| `Add-LinearAttachment` | Upload files to an issue (private by default) or link a URL to it, with optional metadata. |
| `Set-LinearAttachment` | Change an attachment's title, subtitle or metadata. |
| `Remove-LinearAttachment` | Remove attachments from issues. |
| `Get-LinearIssueRelation` | Relations of an issue, seen from it: Blocks, BlockedBy, Related, DuplicateOf, DuplicatedBy. |
| `Add-LinearIssueRelation` | Relate issues: blocks, blocked by, related or duplicate. |
| `Remove-LinearIssueRelation` | Remove relations, by id or between two issues. |
| `Get-LinearAgentSession` | Agent sessions (AI agents working on issues), with status and summary; read-only. |
| `Get-LinearRateLimit` | Rate-limit status from the latest response. |
| `Invoke-LinearGraphQL` | Run any GraphQL query or mutation. |

Run `Get-Help <command> -Full` for parameters and more examples.

## How it works with the Linear API

- **Endpoint and auth.** All calls go to `https://api.linear.app/graphql`. Personal API keys
  are sent in the `Authorization` header as-is; OAuth tokens use `Bearer`, and tokens from a
  browser sign-in are renewed shortly before they expire (or once, when Linear rejects one).
- **Rate limits.** Linear limits requests and query complexity per hour, per user. PSLinear
  retries rate-limited calls with exponential backoff (3 times by default, set with
  `Connect-Linear -MaxRetries`). `Get-LinearRateLimit` shows the remaining budget.
- **Complexity.** Linear rejects any single query above 10,000 complexity points. Pages are
  capped at 100 issues so a page stays well below that limit.
- **Name lookups.** Team, workflow state, label, user, project, project status, project label,
  initiative and initiative label names are resolved to ids with cached queries (10 minutes;
  states and labels per team). `Connect-Linear` and
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

1. On a branch, set `ModuleVersion` in `src/PSLinear.psd1`. For a preview, also set
   `Prerelease` (for example `preview2`); for a stable version, leave `Prerelease` out.
2. In `CHANGELOG.md`, move the `Unreleased` entries under the new version and date, and update
   the links at the bottom.
3. Open a pull request and squash-merge it once CI passes.
4. Create a GitHub release from `main` with the matching tag, for example `v0.2.0` or
   `v0.2.0-preview1`, and mark previews as pre-releases.
5. The `Publish` workflow checks that the tag matches the manifest, then builds, tests and
   publishes to the PowerShell Gallery.

Releases are immutable and `v*` tags cannot be moved or deleted, so check the version before you
publish. A mistake means a new version, not a re-tag.

## Roadmap

- Tab completion for `-State`, `-Label` and `-Assignee`
- Markdown help with platyPS and an online help URI

## Security

Please report vulnerabilities privately, as described in [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
