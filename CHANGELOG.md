# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `Connect-Linear -ClientCredential` signs in as an OAuth application with the client
  credentials grant, for automation that runs without a person: issues and comments are
  created by the application instead of the owner of an API key. The client id and secret are
  given as a PSCredential and the secret is kept as a SecureString. PSLinear requests a new
  token with the same `-Scope` before the 30-day token expires, and once more when Linear
  rejects it. Token requests are retried after network and server errors.
- `Add-LinearAttachment -Url -NoRichLink` creates a link attachment with exactly the title,
  subtitle and metadata given, in one request and without integrations. Linear identifies the
  attachment by its URL, so running the same command again updates the attachment instead of
  adding another one.
- `Add-LinearAttachment -Url` takes `-Subtitle`.
- `Set-LinearAttachment -AddMetadata` and `-RemoveMetadata` change some metadata values and keep
  the others, including what integrations store.

### Changed

- Attachment metadata can hold boolean values as well as strings and numbers.

- Mutations are no longer sent again after a server error (HTTP 5xx) or after a connection that
  failed during the request, because Linear may already have made the change and a second
  attempt could create a second issue or comment. They stop with
  `PSLinear.MutationOutcomeUnknown` instead, so automation can check the result before it
  retries. Mutations are still retried when they never reached Linear (the host name did not
  resolve or the connection could not be made) and when Linear refused them because of the
  rate limit. Queries are retried as before.
- A server error (HTTP 5xx) always stops the command, also where a missing item is reported as
  a non-terminating error, so it can no longer be mistaken for an item that does not exist.

### Fixed

- `Invoke-LinearGraphQL` recognizes a mutation that comes after a fragment definition, so
  `-WhatIf` and `-Confirm` apply to it.

## [0.2.0] - 2026-10-18

### Added

**Signing in**

- `Connect-Linear -Browser` signs in through Linear's consent page in the browser (OAuth 2.0
  with PKCE and a local callback). It uses PSL, the project's public OAuth application, unless
  `-ClientId` or `LINEAR_OAUTH_CLIENT_ID` names your own; `-Scope`, `-RedirectUri` and
  `-TimeoutSeconds` adjust the sign-in. Access tokens are renewed automatically before they
  expire, and `-SecretName` saves the refresh token in a SecretManagement vault so later
  sessions sign in without the browser.
- `Disconnect-Linear -Revoke` revokes an OAuth sign-in at Linear and removes the saved refresh
  token.

**Issues and git**

- `Start-LinearIssue` assigns an issue to you, moves it to the team's first started state if
  it has not started yet (or to `-State`), and checks out its git branch, creating it from the
  current commit or `-From` when needed. `-NoBranch` skips git, for example to start several
  issues at once.
- `Get-LinearIssue -Current` returns the issue whose identifier is in the name of the
  checked-out git branch.
- `New-LinearIssue` and `Set-LinearIssue` take `-Cycle` (active, next, previous, +1/-1, a number,
  a name or an id), `-Milestone` (by name within the project) and `-Delegate` (an agent);
  `New-LinearIssue` also takes `-Template`. `Set-LinearIssue -Clear` can clear the milestone and
  delegate.
- `Get-LinearIssue` filters by `-Cycle`, `-Milestone` and `-Delegate`, and issues include their
  milestone and delegate.

**Comments, attachments and relations**

- `Get-LinearComment`, `Add-LinearComment`, `Set-LinearComment` and `Remove-LinearComment`:
  list the comments on issues, projects, initiatives and documents thread by thread, comment
  and reply (a reply to a reply joins the same thread), edit comments, resolve or reopen
  threads (resolving through a reply records it as the resolution) and delete comments.
  Comments include the id of what they belong to.
- `Get-LinearAttachment`, `Add-LinearAttachment`, `Set-LinearAttachment` and
  `Remove-LinearAttachment`: list an issue's attachments, upload files (wildcards allowed,
  private by default, `-Public` for images with a warning) or link URLs (with rich links for
  integrations such as GitHub), rename them and remove them. The issue is checked before
  anything is uploaded.
- `Add-LinearAttachment -Metadata` and `Set-LinearAttachment -Metadata` store a hashtable of
  string and number values on an attachment (other value types are refused), and attachments
  expose their `Metadata`, including what integrations store.
- `Add-LinearComment -Attachment` uploads files and adds them to the comment: images are shown
  in the comment, other files linked. `-Body` is optional when files are attached.
- `Get-LinearIssueRelation`, `Add-LinearIssueRelation` and `Remove-LinearIssueRelation`: list an
  issue's relations in both directions, seen from the issue (Blocks, BlockedBy, Related,
  DuplicateOf, DuplicatedBy, Similar), relate issues, and remove relations by id, by object or
  between two issues.

**Projects and milestones**

- `New-LinearProject`, `Set-LinearProject` and `Remove-LinearProject`: create projects for one or
  more teams, change their name, summary, content, lead, status (by name or type), priority,
  dates, teams, labels and members (replace, add or remove), clear values, and move projects
  to the trash (Linear archives their issues until the project is restored). Teams, users,
  project statuses, project labels and project templates are given by name.
- `Get-LinearProject` filters by `-Team` and `-Status`, and `-Id` (or piped projects) returns the
  full project with its content, members and initiatives. Projects include their health,
  priority, teams and labels.
- `Get-LinearProjectUpdate`, `New-LinearProjectUpdate`, `Set-LinearProjectUpdate` and
  `Remove-LinearProjectUpdate`: list a project's status updates newest first, post updates with
  a health, edit them and remove them.
- `Get-LinearMilestone`, `New-LinearMilestone`, `Set-LinearMilestone` and
  `Remove-LinearMilestone`: list a project's (or every) milestone, create, rename, reschedule,
  reorder, move and delete milestones.
- `-Project` parameters also accept a project's slug id and URL.

**Initiatives**

- `Get-LinearInitiative`, `New-LinearInitiative`, `Set-LinearInitiative` and
  `Remove-LinearInitiative`: list initiatives (filter by status, or get one in full with its
  content and sub-initiatives), create and change them with the owner, lead team and labels
  given by name, add projects to them or take projects out, and move them to the trash or
  archive them.
- `Get-LinearInitiativeUpdate`, `New-LinearInitiativeUpdate`, `Set-LinearInitiativeUpdate` and
  `Remove-LinearInitiativeUpdate`: list, post, edit and remove initiative status updates.

**Documents**

- `Get-LinearDocument`, `New-LinearDocument`, `Set-LinearDocument` and `Remove-LinearDocument`:
  list documents (all, or of an issue, project, initiative or team; filter by title), get one
  with its Markdown content, create documents in an issue, project, initiative or team, rename
  them, replace their content, change or clear the owner, move them to another container, and
  move them to the trash.

**Teams, labels and more**

- `New-LinearTeam`, `Set-LinearTeam` and `Remove-LinearTeam`: create teams and sub-teams, change
  their name, key, description, time zone or parent, and delete them.
- `Get-LinearTeamMember`, `Add-LinearTeamMember` and `Remove-LinearTeamMember`: list team members
  with their ownership, and add or remove users.
- `New-LinearLabel`, `Set-LinearLabel` and `Remove-LinearLabel`: create workspace or team labels
  and label groups, rename and recolor labels, move them in and out of groups, retire and
  restore them, and delete them. Labels are found by name (optionally `Group/Name`) among the
  workspace labels, or a team's own labels with `-Team`.
- `Get-LinearLabel -IncludeGroups -IncludeRetired` also returns label groups and retired labels,
  and labels include their `GroupId`.
- `Get-LinearTemplate` lists issue, project and document templates.
- `Get-LinearAgentSession` lists agent sessions (newest first, filter by issue and status) and
  gets them by id. It is read-only.

### Changed

- `Disconnect-Linear` supports `-WhatIf` and `-Confirm`.
- The project table view shows each project's health.
- `build.ps1` runs Analyze before Build by default, and retries the intermittent
  PSScriptAnalyzer crash up to five times.
- PSLinear has a logo, shown in the README and, through the manifest's `IconUri`, on the
  PowerShell Gallery.

## [0.1.0] - 2026-10-17

First stable release. It includes everything in 0.1.0-preview1, plus the changes below.

### Added

- `New-LinearIssue` and `Set-LinearIssue` warn when `-Estimate` is used in a team that does not
  use estimates, because Linear ignores the value there.
- `Get-LinearTeam` output includes the parent team (`Parent`, `ParentId`) and the team's
  estimation settings (`EstimationType`, `InheritEstimation`).

### Fixed

- Labels in sub-teams: labels of parent teams can be used, and a sub-team's inherited copy of
  a workspace or parent-team label is used instead of the original, so the name is no longer
  reported as ambiguous.

## [0.1.0-preview1] - 2026-10-17

### Added

- `Connect-Linear` and `Disconnect-Linear`: personal API key (secure prompt), OAuth access
  token, SecretManagement vault or the `LINEAR_API_KEY` environment variable. Commands also
  connect implicitly when `LINEAR_API_KEY` is set.
- `Get-LinearIssue`: get issues by identifier or UUID, or list them with filters for team,
  state, state type, assignee, labels, project, priority, text search and current cycle, plus
  a raw `-Filter` for anything else. Streams results with automatic paging (`-First`, `-All`).
- `New-LinearIssue`: create an issue in a team with a title, and optionally a description,
  state, assignee, priority, labels, project, estimate, due date and parent issue.
- `Set-LinearIssue`: change the same fields on issues given by identifier or piped in from
  `Get-LinearIssue`, add or remove labels (`-AddLabel`, `-RemoveLabel`), remove the assignee
  (`-Unassign`), clear the estimate, due date, parent, project, cycle or labels (`-Clear`), or
  move an issue to another team. Returns the issues with `-PassThru`.
- `Remove-LinearIssue`: move issues to the trash, like deleting in the Linear app (restorable
  for 30 days), or archive them with `-Archive`. Asks for confirmation by default.
- The write commands accept names for teams, workflow states, labels, projects and users
  (`me`, email, name or display name). Lookups are cached, and an unknown name fails with a
  list of the valid values. `-WhatIf` sends no requests at all.
- `-State` also accepts a state type (`started`, `completed`, ...), which picks the team's
  first state of that type. Issue commands accept issue URLs as well as identifiers, and
  `-Priority` accepts the numbers 0 to 4 as well as names.
- `Get-LinearTeam` with wildcard filtering, and tab completion for `-Team`.
- `Get-LinearViewer` and `Get-LinearRateLimit`.
- `Get-LinearUser`, `Get-LinearWorkflowState`, `Get-LinearLabel`, `Get-LinearProject` and
  `Get-LinearCycle` list the values the issue commands accept, with wildcard filtering and tab
  completion for `-Team`.
- `Invoke-LinearGraphQL` for any query or mutation; mutations support `-WhatIf` and `-Confirm`.
- Automatic retries with exponential backoff for rate limits, server errors and network failures.
- Formatting views for issues, teams, users, workflow states, labels, projects, cycles, the
  connection and rate-limit status.

[Unreleased]: https://github.com/stian3555/PSLinear/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/stian3555/PSLinear/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/stian3555/PSLinear/compare/v0.1.0-preview1...v0.1.0
[0.1.0-preview1]: https://github.com/stian3555/PSLinear/releases/tag/v0.1.0-preview1
