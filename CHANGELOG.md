# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/).

## [0.1.0-preview1] - Unreleased

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
  (`-Unassign`) or move an issue to another team. Returns the issues with `-PassThru`.
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
- `Invoke-LinearGraphQL` for any query or mutation; mutations support `-WhatIf` and `-Confirm`.
- Automatic retries with exponential backoff for rate limits, server errors and network failures.
- Formatting views for issues, teams, users, the connection and rate-limit status.
