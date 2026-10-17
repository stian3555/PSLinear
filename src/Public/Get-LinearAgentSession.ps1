function Get-LinearAgentSession {
    <#
    .SYNOPSIS
        Gets agent sessions: the work AI agents do on Linear issues.

    .DESCRIPTION
        Returns agent sessions, newest first, with the agent, its status (Pending, Active,
        AwaitingInput, Stopping, Complete, Error or Stale), the issue and a summary. A session
        starts when an issue is delegated to an agent or an agent is mentioned. This command
        only reads sessions; it does not start or stop agents.

        Use -Issue and -Status to filter, -First to get only the newest sessions, and -Id for
        specific sessions. Filters are applied to the sessions you can see, so with -Issue or
        -Status every session is fetched first.

    .PARAMETER Issue
        Only sessions on this issue: an identifier (ENG-123), UUID or URL.

    .PARAMETER Status
        Only sessions with these statuses: Pending, Active, AwaitingInput, Stopping, Complete,
        Error or Stale.

    .PARAMETER First
        Returns only this many sessions, the newest first.

    .PARAMETER IncludeArchived
        Also returns archived sessions.

    .PARAMETER Id
        One or more agent session ids.

    .EXAMPLE
        Get-LinearAgentSession -Status Active, AwaitingInput

        Lists the sessions that are running or waiting for input.

    .EXAMPLE
        Get-LinearAgentSession -Issue ENG-123 | Format-List Agent, Status, Summary, Url, ExternalLinks

        Shows what agents did on an issue.

    .INPUTS
        None

    .OUTPUTS
        PSLinear.AgentSession

    .LINK
        Get-LinearIssue
    #>
    [CmdletBinding(DefaultParameterSetName = 'List')]
    [OutputType('PSLinear.AgentSession')]
    param(
        [Parameter(ParameterSetName = 'List')]
        [ValidateNotNullOrEmpty()]
        [string] $Issue,

        [Parameter(ParameterSetName = 'List')]
        [ValidateSet('Pending', 'Active', 'AwaitingInput', 'Stopping', 'Complete', 'Error', 'Stale')]
        [string[]] $Status,

        [Parameter(ParameterSetName = 'List')]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $First,

        [Parameter(ParameterSetName = 'List')]
        [switch] $IncludeArchived,

        [Parameter(Mandatory, ParameterSetName = 'ById')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Id
    )

    if ($PSCmdlet.ParameterSetName -eq 'ById') {
        foreach ($sessionId in $Id) {
            $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'GetAgentSession') -Variables @{ id = $sessionId } -IncludeErrors
            $session = Get-LinearNestedValue -InputObject $result.Data -Name 'agentSession'
            if ($null -eq $session) {
                $message = Format-LinearFailureMessage -Message "Agent session '$sessionId' was not found." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.AgentSessionNotFound' -Category ObjectNotFound -TargetObject $sessionId))
                continue
            }
            ConvertTo-LinearAgentSession -InputObject $session
        }
        return
    }

    $query = Get-LinearGraphQLDocument -Name 'ListAgentSessions'
    $variables = @{ includeArchived = [bool]$IncludeArchived }
    if (-not $Issue -and -not $Status) {
        $limit = if ($First) { $First } else { 0 }
        Invoke-LinearPagedRequest -Query $query -ConnectionPath 'agentSessions' -Variables $variables -Limit $limit | ConvertTo-LinearAgentSession
        return
    }

    # The API cannot filter sessions, so filter here and apply -First afterwards.
    $identifier = if ($Issue) { ConvertTo-LinearIssueIdentifier -Value $Issue } else { $null }
    $sessions = @(Invoke-LinearPagedRequest -Query $query -ConnectionPath 'agentSessions' -Variables $variables -Limit 0 |
            ConvertTo-LinearAgentSession |
            Where-Object { $null -ne $_ -and (-not $identifier -or $_.Issue -eq $identifier -or $_.IssueId -eq $identifier) -and (-not $Status -or $_.Status -in $Status) })
    if ($First) { $sessions = @($sessions | Select-Object -First $First) }
    foreach ($session in $sessions) { $session }
}
