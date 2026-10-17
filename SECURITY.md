# Security policy

## Supported versions

Only the latest release on the PowerShell Gallery receives security fixes. Fixes ship in a new
release; older versions do not get backports.

| Version        | Supported |
| -------------- | --------- |
| Latest release | Yes       |
| Older releases | No        |

## Reporting a vulnerability

Please do not report security problems in public issues, discussions or pull requests.

Report them privately through GitHub instead:

1. Open the [Security tab](https://github.com/stian3555/PSLinear/security) of this repository.
2. Select **Report a vulnerability**.

Or go straight to <https://github.com/stian3555/PSLinear/security/advisories/new>.

Please include:

- the PSLinear version (`Get-InstalledPSResource -Name PSLinear`), PowerShell version and operating system
- steps to reproduce, or a proof of concept
- what an attacker could achieve

Never put a real Linear API key or OAuth token in a report. If a key may have been exposed,
revoke it in your Linear account settings.

You will get an answer in the private advisory. Once a fix is released, the advisory is published
and you are credited, unless you prefer to stay anonymous.

## Scope

In scope, for example:

- API keys or OAuth tokens leaking into output, the verbose or debug streams, error records or files
- requests sent to any host other than the Linear API
- unsafe handling of data returned by the API
- weaknesses in the build or release pipeline that could let someone publish a tampered module

Out of scope:

- vulnerabilities in Linear itself; report those to Linear
- attacks that require control of your machine or PowerShell session already
