# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- `build.ps1` runs Analyze before Build by default, and retries the intermittent
  PSScriptAnalyzer crash up to five times.

### Added

- `Get-LinearComment`, `Add-LinearComment`, `Set-LinearComment` and `Remove-LinearComment`:
  list the comments on issues and projects thread by thread, comment and reply (a reply to a
  reply joins the same thread), edit comments, resolve or reopen threads (resolving through a
  reply records it as the resolution) and delete comments.
- `Get-LinearAttachment`, `Add-LinearAttachment`, `Set-LinearAttachment` and
  `Remove-LinearAttachment`: list an issue's attachments, upload files (wildcards allowed,
  private by default, `-Public` for images with a warning) or link URLs (with rich links for
  integrations such as GitHub), rename them and remove them. The issue is checked before
  anything is uploaded.
- `Add-LinearComment -Attachment` uploads files and adds them to the comment: images are shown
  in the comment, other files linked. `-Body` is optional when files are attached.
- `Get-LinearIssueRelation`, `Add-LinearIssueRelation` and `Remove-LinearIssueRelation`: list an
  issue's relations in both directions, seen from the issue (Blocks, BlockedBy, Related,
  DuplicateOf, DuplicatedBy, Similar), relate issues, and remove relations by id, by object or
  between two issues.
- `New-LinearIssue` and `Set-LinearIssue` take `-Cycle` (active, next, previous, +1/-1, a number,
  a name or an id), `-Milestone` (by name within the project) and `-Delegate` (an agent);
  `New-LinearIssue` also takes `-Template`. `Set-LinearIssue -Clear` can clear the milestone and
  delegate.
- `Get-LinearIssue` filters by `-Cycle`, `-Milestone` and `-Delegate`, and issues include their
  milestone and delegate.
- `Get-LinearTemplate` lists issue, project and document templates.
- `Get-LinearMilestone`, `New-LinearMilestone`, `Set-LinearMilestone` and
  `Remove-LinearMilestone`: list a project's (or every) milestone, create, rename, reschedule,
  reorder, move and delete milestones.
- Attachment metadata: `Add-LinearAttachment -Metadata` and `Set-LinearAttachment -Metadata` store
  a hashtable of string and number values on an attachment (other value types are refused), and
  attachments expose their `Metadata`, including what integrations store.
- `-Project` parameters also accept a project's slug id and URL.

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

[Unreleased]: https://github.com/stian3555/PSLinear/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/stian3555/PSLinear/compare/v0.1.0-preview1...v0.1.0
[0.1.0-preview1]: https://github.com/stian3555/PSLinear/releases/tag/v0.1.0-preview1
