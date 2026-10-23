function Get-LinearIssue {
    <#
    .SYNOPSIS
        Gets Linear issues by identifier, or lists issues that match a filter.

    .DESCRIPTION
        With -Id, returns specific issues by their identifier (ENG-123), UUID or URL. With
        -Current, returns the issue whose identifier is in the name of the git branch checked out
        in the current location, such as ada/eng-123-fix-login.

        Without -Id, lists issues that match the filter parameters. Parameters are combined
        with AND; values within one parameter (for example several states) are combined
        with OR. Text matching for states, labels, projects and assignee names is
        case-insensitive.

        Results are streamed page by page and sorted by most recently updated first. By
        default the first 50 matching issues are returned; use -First to change that or
        -All to return every match.

    .PARAMETER Id
        One or more issue identifiers (ENG-123), UUIDs or issue URLs.

    .PARAMETER InputObject
        PSLinear.Issue objects to refresh, typically from the pipeline.

    .PARAMETER Current
        Returns the issue of the current git branch. The branch name must contain an identifier
        with the key of one of your teams.

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

    .PARAMETER Delegate
        Issues delegated to this agent: an email address, a user id, or the agent's name or
        display name.

    .PARAMETER Label
        Label names. Matches issues that have any of the labels.

    .PARAMETER Project
        Project name or id.

    .PARAMETER Milestone
        Project milestone name or id.

    .PARAMETER Priority
        Priority levels: None, Urgent, High, Medium or Low, or the numbers 0 to 4.

    .PARAMETER Search
        Text to search for in the title, description and comments.

    .PARAMETER CurrentCycle
        Only issues in an active cycle. The same as -Cycle active.

    .PARAMETER Cycle
        Only issues in this cycle: active (or current), next, previous, a cycle number, a cycle
        name or an id. Numbers and names apply to every team unless -Team is given.

    .PARAMETER AttachmentUrl
        Only issues with an attachment whose URL matches one of these values. A value matches the
        whole URL; end it with * to match every URL that starts with it, as in
        'https://monitor.example/alerts/*', start it with * to match the end, or both to match
        any part. Only * is special, so URLs with ? and [ can be given as they are.

    .PARAMETER Filter
        A raw Linear IssueFilter as a hashtable, combined with the other filter parameters
        using AND. See https://linear.app/developers/filtering.

    .PARAMETER IncludeAttachment
        Adds each issue's attachments, with their metadata, as an Attachments property, read in
        the same requests as the issues. Issues come 50 per request instead of 100 to stay within
        Linear's query complexity limit, and an issue with more than 20 attachments takes one
        extra request.

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
        Get-LinearIssue -Current | Format-List Identifier, Title, State, Url

        Shows the issue you are working on, from the name of the checked-out git branch.

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
        Get-LinearIssue -Team ENG -Cycle next -Milestone 'Beta'

        Issues planned for the team's next cycle in the Beta milestone.

    .EXAMPLE
        Get-LinearIssue -Filter @{ dueDate = @{ lt = (Get-Date).ToString('yyyy-MM-dd') } } -StateType Unstarted, Started

        Combines a raw IssueFilter (overdue issues) with regular parameters.

    .EXAMPLE
        Get-LinearIssue -Team OPS -AttachmentUrl 'https://monitor.example/alerts/*' -IncludeAttachment -IncludeArchived -All

        Every issue of the team with an attachment that links to the monitoring system, in any
        state and also archived, with the attachments and their metadata. A sync job can compare
        these with the alerts it knows about, without a request per issue.

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

        [Parameter(Mandatory, ParameterSetName = 'Current')]
        [switch] $Current,

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
        [string] $Delegate,

        [Parameter(ParameterSetName = 'List')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Label,

        [Parameter(ParameterSetName = 'List')]
        [ValidateNotNullOrEmpty()]
        [string] $Project,

        [Parameter(ParameterSetName = 'List')]
        [ArgumentCompletions('None', 'Urgent', 'High', 'Medium', 'Low')]
        [ValidatePattern('^(?:None|Urgent|High|Medium|Low|[0-4])$', ErrorMessage = "'{0}' is not a priority. Use None, Urgent, High, Medium, Low, or 0 to 4.")]
        [string[]] $Priority,

        [Parameter(ParameterSetName = 'List')]
        [ValidateNotNullOrEmpty()]
        [string] $Search,

        [Parameter(ParameterSetName = 'List')]
        [switch] $CurrentCycle,

        [Parameter(ParameterSetName = 'List')]
        [ValidateNotNullOrEmpty()]
        [string] $Cycle,

        [Parameter(ParameterSetName = 'List')]
        [ValidateNotNullOrEmpty()]
        [string] $Milestone,

        [Parameter(ParameterSetName = 'List')]
        [ValidateNotNullOrEmpty()]
        [string[]] $AttachmentUrl,

        [Parameter(ParameterSetName = 'List')]
        [ValidateNotNull()]
        [hashtable] $Filter,

        [Parameter(ParameterSetName = 'List')]
        [switch] $IncludeAttachment,

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
        if ($Current -or $PSCmdlet.ParameterSetName -in 'ById', 'ByObject') {
            $identifiers = switch ($PSCmdlet.ParameterSetName) {
                'ById' { foreach ($value in $Id) { ConvertTo-LinearIssueIdentifier -Value $value } }
                'ByObject' { $InputObject | ForEach-Object Id }
                'Current' {
                    try {
                        $branch = Get-LinearGitBranch
                        $identifier = Find-LinearIssueIdentifier -Branch $branch
                        if (-not $identifier) {
                            $keys = Format-LinearValueList -Value (Get-LinearTeamCache | Where-Object { $null -ne $_ } | ForEach-Object Key)
                            throw (New-LinearErrorRecord -Message "The branch '$branch' does not contain an issue identifier with a team key ($keys)." `
                                    -ErrorId 'PSLinear.NoIssueInBranch' -Category ObjectNotFound -TargetObject $branch)
                        }
                    }
                    catch {
                        $PSCmdlet.ThrowTerminatingError($_)
                    }
                    $identifier
                }
            }
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
        if ($CurrentCycle -and $Cycle) {
            $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord -Message 'Use either -CurrentCycle or -Cycle, not both.' `
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
                $issueFilter['assignee'] = ConvertTo-LinearUserFilter -User $Assignee
            }

            if ($Delegate) {
                $issueFilter['delegate'] = ConvertTo-LinearUserFilter -User $Delegate
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
                $issueFilter['priority'] = @{ in = @(foreach ($level in $Priority) { ConvertTo-LinearPriority -Priority $level }) }
            }

            if ($Search) {
                $issueFilter['searchableContent'] = @{ contains = $Search }
            }

            if ($CurrentCycle) {
                $issueFilter['cycle'] = @{ isActive = @{ eq = $true } }
            }
            elseif ($Cycle) {
                $issueFilter['cycle'] = switch -Regex ($Cycle) {
                    '^(active|current)$' { @{ isActive = @{ eq = $true } } }
                    '^next$' { @{ isNext = @{ eq = $true } } }
                    '^previous$' { @{ isPrevious = @{ eq = $true } } }
                    '^\d+$' { @{ number = @{ eq = [int]$Cycle } } }
                    default {
                        if (Test-LinearGuid -Value $Cycle) { @{ id = @{ eq = $Cycle } } } else { @{ name = @{ eqIgnoreCase = $Cycle } } }
                    }
                }
            }

            if ($Milestone) {
                $issueFilter['projectMilestone'] = if (Test-LinearGuid -Value $Milestone) {
                    @{ id = @{ eq = $Milestone } }
                }
                else {
                    @{ name = @{ eqIgnoreCase = $Milestone } }
                }
            }

            if ($AttachmentUrl) {
                $issueFilter['attachments'] = @{ some = @{ or = @(foreach ($url in $AttachmentUrl) { @{ url = ConvertTo-LinearUrlComparator -Url $url } }) } }
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
        if ($IncludeAttachment) {
            Invoke-LinearPagedRequest -Query (Get-LinearGraphQLDocument -Name 'ListIssuesWithAttachments') -ConnectionPath 'issues' -Variables $variables `
                -Limit $limit -PageSize $script:IssueWithAttachmentsPageSize |
                Complete-LinearIssueAttachment |
                ConvertTo-LinearIssue
        }
        else {
            Invoke-LinearPagedRequest -Query (Get-LinearGraphQLDocument -Name 'ListIssues') -ConnectionPath 'issues' -Variables $variables -Limit $limit |
                ConvertTo-LinearIssue
        }
    }
}
