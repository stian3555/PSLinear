function New-LinearIssue {
    <#
    .SYNOPSIS
        Creates a Linear issue.

    .DESCRIPTION
        Creates an issue in a team and returns it. Only -Team and -Title are required.

        Names are resolved to ids for you: workflow states and labels within the issue's
        team, and assignees and projects within the workspace. The lookups are cached for a
        few minutes. An unknown name stops the command with an error that lists the valid
        values.

        With -WhatIf nothing is sent to Linear, not even the name lookups, so names are not
        checked.

    .PARAMETER Team
        The team key (ENG), name or id. Accepts PSLinear.Team objects from the pipeline, and
        objects with a Team or Key property. Supports tab completion once connected.

    .PARAMETER Title
        The issue title.

    .PARAMETER Description
        The issue description, in Markdown.

    .PARAMETER State
        The workflow state name, such as 'Todo' or 'In Progress', or its id. A state type
        (Backlog, Unstarted, Started, Completed, Canceled) picks the team's first state of
        that type. Defaults to the team's default state.

    .PARAMETER Assignee
        'me', an email address, a user id, or the user's full name or display name.

    .PARAMETER Priority
        None, Urgent, High, Medium or Low, or the number 0 to 4 (0 None, 1 Urgent, 4 Low).

    .PARAMETER Label
        Label names or ids. Workspace labels and the team's own labels can be used.

    .PARAMETER Project
        Project name or id.

    .PARAMETER Estimate
        The estimate, in the team's estimation scale (for example story points). Linear ignores
        it in teams that do not use estimates, and the command warns when that is the case.

    .PARAMETER DueDate
        The due date. Only the date part is used.

    .PARAMETER Parent
        The parent issue's identifier (ENG-123), id or URL, to create a sub-issue.

    .EXAMPLE
        New-LinearIssue -Team ENG -Title 'Retry webhook deliveries on 5xx'

        Creates an issue in the team's default state.

    .EXAMPLE
        New-LinearIssue -Team ENG -Title 'Login fails on Safari' -Label Bug -Priority High -Assignee me -State 'Todo'

        Creates a high-priority bug assigned to you.

    .EXAMPLE
        New-LinearIssue -Team ENG -Title 'Write tests for the retry logic' -Parent ENG-412 -Estimate 2 -DueDate (Get-Date).AddDays(7)

        Creates a sub-issue of ENG-412, due in a week.

    .EXAMPLE
        Get-LinearTeam -Name ENG, OPS | New-LinearIssue -Title 'Rotate the API keys' -WhatIf

        Shows the issues that would be created in two teams, without creating them.

    .INPUTS
        PSLinear.Team
        System.Management.Automation.PSObject

    .OUTPUTS
        PSLinear.Issue

    .LINK
        Set-LinearIssue

    .LINK
        Get-LinearIssue
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType('PSLinear.Issue')]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('Key')]
        [ValidateNotNullOrEmpty()]
        [string] $Team,

        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Title,

        [string] $Description,

        [ValidateNotNullOrEmpty()]
        [string] $State,

        [ValidateNotNullOrEmpty()]
        [string] $Assignee,

        [ArgumentCompletions('None', 'Urgent', 'High', 'Medium', 'Low')]
        [ValidatePattern('^(?:None|Urgent|High|Medium|Low|[0-4])$', ErrorMessage = "'{0}' is not a priority. Use None, Urgent, High, Medium, Low, or 0 to 4.")]
        [string] $Priority,

        [ValidateNotNullOrEmpty()]
        [string[]] $Label,

        [ValidateNotNullOrEmpty()]
        [string] $Project,

        [ValidateRange(0, [int]::MaxValue)]
        [int] $Estimate,

        [datetime] $DueDate,

        [ValidateNotNullOrEmpty()]
        [string] $Parent
    )

    process {
        $changes = Format-LinearChangeList -BoundParameters $PSBoundParameters `
            -Name 'Description', 'State', 'Assignee', 'Priority', 'Label', 'Project', 'Estimate', 'DueDate', 'Parent'
        $action = if ($changes) { "Create issue '$Title' ($changes)" } else { "Create issue '$Title'" }
        if (-not $PSCmdlet.ShouldProcess("team $Team", $action)) {
            return
        }

        try {
            $teamId = Resolve-LinearTeamId -Team $Team
            $issueInput = @{
                teamId = $teamId
                title  = $Title
            }
            if ($PSBoundParameters.ContainsKey('Description')) { $issueInput['description'] = $Description }
            if ($State) { $issueInput['stateId'] = Resolve-LinearWorkflowStateId -TeamId $teamId -State $State }
            if ($Assignee) { $issueInput['assigneeId'] = Resolve-LinearUserId -User $Assignee }
            if ($Priority) { $issueInput['priority'] = ConvertTo-LinearPriority -Priority $Priority }
            if ($Label) { $issueInput['labelIds'] = @(Resolve-LinearLabelId -TeamId $teamId -Label $Label) }
            if ($Project) { $issueInput['projectId'] = Resolve-LinearProjectId -Project $Project }
            if ($PSBoundParameters.ContainsKey('Estimate')) {
                if (-not (Test-LinearTeamUsesEstimate -TeamId $teamId)) {
                    Write-Warning "Team $(Get-LinearTeamKey -TeamId $teamId) does not use estimates, so Linear ignores -Estimate. Turn on estimates in the team's settings to use it."
                }
                $issueInput['estimate'] = $Estimate
            }
            if ($PSBoundParameters.ContainsKey('DueDate')) { $issueInput['dueDate'] = ConvertTo-LinearTimelessDate -Date $DueDate }
            if ($Parent) { $issueInput['parentId'] = ConvertTo-LinearIssueIdentifier -Value $Parent }
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }

        # Linear rejecting the issue (for example an estimate outside the team's scale) writes a
        # non-terminating error, so the remaining pipeline input is still processed.
        $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'CreateIssue') -Variables @{ input = $issueInput } -IncludeErrors
        $issue = Get-LinearNestedValue -InputObject $result.Data -Name 'issueCreate.issue'
        if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'issueCreate.success') -or $null -eq $issue) {
            $message = Format-LinearFailureMessage -Message "Linear did not create issue '$Title' in team $Team." -Errors $result.Errors
            $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.IssueCreateFailed' -Category WriteError -TargetObject $Title))
            return
        }
        ConvertTo-LinearIssue -InputObject $issue
    }
}
