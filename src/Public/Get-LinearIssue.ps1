function Get-LinearIssue {
    <#
    .SYNOPSIS
        Gets Linear issues by identifier, or lists issues that match a filter.

    .DESCRIPTION
        With -Id, returns specific issues by their identifier (ENG-123) or UUID.

        Without -Id, lists issues that match the filter parameters. Parameters are combined
        with AND; values within one parameter (for example several states) are combined
        with OR. Text matching for states, labels, projects and assignee names is
        case-insensitive.

        Results are streamed page by page and sorted by most recently updated first. By
        default the first 50 matching issues are returned; use -First to change that or
        -All to return every match.

    .PARAMETER Id
        One or more issue identifiers (ENG-123) or UUIDs.

    .PARAMETER InputObject
        PSLinear.Issue objects to refresh, typically from the pipeline.

    .PARAMETER Team
        The team key (ENG), name or id. Accepts PSLinear.Team objects from the pipeline.
        Supports tab completion once connected.

    .PARAMETER State
        Workflow state names, such as 'Todo' or 'In Progress'.

    .PARAMETER StateType
        Workflow state categories: Triage, Backlog, Unstarted, Started, Completed or Canceled.

    .PARAMETER Assignee
        'me', an email address, a user id, or the user's full name or display name.

    .PARAMETER Unassigned
        Only issues without an assignee.

    .PARAMETER Label
        Label names. Matches issues that have any of the labels.

    .PARAMETER Project
        Project name or id.

    .PARAMETER Priority
        Priority levels: None, Urgent, High, Medium or Low.

    .PARAMETER Search
        Text to search for in the title, description and comments.

    .PARAMETER CurrentCycle
        Only issues in an active cycle.

    .PARAMETER Filter
        A raw Linear IssueFilter as a hashtable, combined with the other filter parameters
        using AND. See https://linear.app/developers/filtering.

    .PARAMETER OrderBy
        UpdatedAt (default) or CreatedAt. Results are returned newest first.

    .PARAMETER IncludeArchived
        Also returns archived issues.

    .PARAMETER First
        Maximum number of issues to return. Defaults to 50.

    .PARAMETER All
        Returns every matching issue, following pagination until the end.

    .EXAMPLE
        Get-LinearIssue ENG-123

        Gets one issue.

    .EXAMPLE
        Get-LinearIssue -Assignee me -StateType Unstarted, Started

        Lists your open issues.

    .EXAMPLE
        Get-LinearIssue -Team ENG -State 'In Progress' -Priority Urgent, High | Format-Table Identifier, Title, Assignee

        Urgent and high-priority issues in progress for the ENG team.

    .EXAMPLE
        Get-LinearIssue -Team ENG -Label Bug -All | Group-Object State | Sort-Object Count -Descending

        Counts every bug in the team by state.

    .EXAMPLE
        Get-LinearTeam -Name ENG, OPS | Get-LinearIssue -CurrentCycle

        Issues in the current cycle for two teams.

    .EXAMPLE
        Get-LinearIssue -Filter @{ dueDate = @{ lt = (Get-Date).ToString('yyyy-MM-dd') } } -StateType Unstarted, Started

        Combines a raw IssueFilter (overdue issues) with regular parameters.

    .INPUTS
        System.String
        PSLinear.Issue
        PSLinear.Team

    .OUTPUTS
        PSLinear.Issue

    .LINK
        Get-LinearTeam

    .LINK
        https://linear.app/developers/filtering
    #>
    [CmdletBinding(DefaultParameterSetName = 'List')]
    [OutputType('PSLinear.Issue')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'ById')]
        [Alias('Identifier')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Id,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [PSTypeName('PSLinear.Issue')]
        [object[]] $InputObject,

        [Parameter(ParameterSetName = 'List', ValueFromPipelineByPropertyName)]
        [Alias('Key')]
        [ValidateNotNullOrEmpty()]
        [string] $Team,

        [Parameter(ParameterSetName = 'List')]
        [ValidateNotNullOrEmpty()]
        [string[]] $State,

        [Parameter(ParameterSetName = 'List')]
        [ValidateSet('Triage', 'Backlog', 'Unstarted', 'Started', 'Completed', 'Canceled')]
        [string[]] $StateType,

        [Parameter(ParameterSetName = 'List')]
        [ValidateNotNullOrEmpty()]
        [string] $Assignee,

        [Parameter(ParameterSetName = 'List')]
        [switch] $Unassigned,

        [Parameter(ParameterSetName = 'List')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Label,

        [Parameter(ParameterSetName = 'List')]
        [ValidateNotNullOrEmpty()]
        [string] $Project,

        [Parameter(ParameterSetName = 'List')]
        [ValidateSet('None', 'Urgent', 'High', 'Medium', 'Low')]
        [string[]] $Priority,

        [Parameter(ParameterSetName = 'List')]
        [ValidateNotNullOrEmpty()]
        [string] $Search,

        [Parameter(ParameterSetName = 'List')]
        [switch] $CurrentCycle,

        [Parameter(ParameterSetName = 'List')]
        [ValidateNotNull()]
        [hashtable] $Filter,

        [Parameter(ParameterSetName = 'List')]
        [ValidateSet('UpdatedAt', 'CreatedAt')]
        [string] $OrderBy = 'UpdatedAt',

        [Parameter(ParameterSetName = 'List')]
        [switch] $IncludeArchived,

        [Parameter(ParameterSetName = 'List')]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $First = 50,

        [Parameter(ParameterSetName = 'List')]
        [switch] $All
    )

    process {
        if ($PSCmdlet.ParameterSetName -in 'ById', 'ByObject') {
            $identifiers = if ($PSCmdlet.ParameterSetName -eq 'ById') { $Id } else { $InputObject | ForEach-Object Id }
            $query = Get-LinearGraphQLDocument -Name 'GetIssue'

            foreach ($identifier in $identifiers) {
                # A missing issue writes a non-terminating error and the pipeline continues.
                # Authentication, rate-limit and network failures still stop the command.
                $result = Invoke-LinearRequest -Query $query -Variables @{ id = $identifier } -IncludeErrors
                $issue = Get-LinearNestedValue -InputObject $result.Data -Name 'issue'
                if ($null -eq $issue) {
                    $message = if ($result.Errors.Count -gt 0) {
                        "Issue '$identifier' was not found. $(Format-LinearErrorMessage -Errors $result.Errors)"
                    }
                    else {
                        "Issue '$identifier' was not found."
                    }
                    $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message `
                                -ErrorId 'PSLinear.IssueNotFound' -Category ObjectNotFound -TargetObject $identifier))
                    continue
                }
                ConvertTo-LinearIssue -InputObject $issue
            }
            return
        }

        if ($Assignee -and $Unassigned) {
            $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord -Message 'Use either -Assignee or -Unassigned, not both.' `
                        -ErrorId 'PSLinear.InvalidArgument' -Category InvalidArgument))
        }

        try {
            $issueFilter = @{}

            if ($Team) {
                $issueFilter['team'] = @{ id = @{ eq = (Resolve-LinearTeamId -Team $Team) } }
            }

            if ($State -or $StateType) {
                $stateFilter = @{}
                if ($State) {
                    $stateFilter['or'] = @(foreach ($name in $State) { @{ name = @{ eqIgnoreCase = $name } } })
                }
                if ($StateType) {
                    $stateFilter['type'] = @{ in = @(foreach ($type in $StateType) { $type.ToLowerInvariant() }) }
                }
                $issueFilter['state'] = $stateFilter
            }

            if ($Unassigned) {
                $issueFilter['assignee'] = @{ null = $true }
            }
            elseif ($Assignee) {
                $parsedGuid = [guid]::Empty
                $issueFilter['assignee'] = if ($Assignee -eq 'me') {
                    @{ isMe = @{ eq = $true } }
                }
                elseif ($Assignee -match '@') {
                    @{ email = @{ eqIgnoreCase = $Assignee } }
                }
                elseif ([guid]::TryParse($Assignee, [ref]$parsedGuid)) {
                    @{ id = @{ eq = $Assignee } }
                }
                else {
                    @{ or = @(@{ name = @{ eqIgnoreCase = $Assignee } }, @{ displayName = @{ eqIgnoreCase = $Assignee } }) }
                }
            }

            if ($Label) {
                $issueFilter['labels'] = @{ some = @{ or = @(foreach ($name in $Label) { @{ name = @{ eqIgnoreCase = $name } } }) } }
            }

            if ($Project) {
                $parsedGuid = [guid]::Empty
                $issueFilter['project'] = if ([guid]::TryParse($Project, [ref]$parsedGuid)) {
                    @{ id = @{ eq = $Project } }
                }
                else {
                    @{ name = @{ eqIgnoreCase = $Project } }
                }
            }

            if ($Priority) {
                $issueFilter['priority'] = @{ in = @(foreach ($level in $Priority) { $script:PriorityMap[$level] }) }
            }

            if ($Search) {
                $issueFilter['searchableContent'] = @{ contains = $Search }
            }

            if ($CurrentCycle) {
                $issueFilter['cycle'] = @{ isActive = @{ eq = $true } }
            }

            if ($Filter) {
                $issueFilter = if ($issueFilter.Count -gt 0) { @{ and = @($issueFilter, $Filter) } } else { $Filter }
            }
        }
        catch {
            $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord -Message $_.Exception.Message `
                        -ErrorId 'PSLinear.InvalidFilter' -Category InvalidArgument -TargetObject $_.TargetObject))
        }

        $variables = @{
            orderBy         = if ($OrderBy -eq 'CreatedAt') { 'createdAt' } else { 'updatedAt' }
            includeArchived = [bool]$IncludeArchived
        }
        if ($issueFilter.Count -gt 0) { $variables['filter'] = $issueFilter }

        $limit = if ($All) { 0 } else { $First }
        Invoke-LinearPagedRequest -Query (Get-LinearGraphQLDocument -Name 'ListIssues') -ConnectionPath 'issues' -Variables $variables -Limit $limit |
            ConvertTo-LinearIssue
    }
}
