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
- `Get-LinearTeam` with wildcard filtering, and tab completion for `-Team`.
- `Get-LinearViewer` and `Get-LinearRateLimit`.
- `Invoke-LinearGraphQL` for any query or mutation; mutations support `-WhatIf` and `-Confirm`.
- Automatic retries with exponential backoff for rate limits, server errors and network failures.
- Formatting views for issues, teams, users, the connection and rate-limit status.
