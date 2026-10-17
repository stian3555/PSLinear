function Set-LinearIssue {
    <#
    .SYNOPSIS
        Changes properties of Linear issues.

    .DESCRIPTION
        Updates one or more issues, given by identifier (ENG-123), URL, or piped in from
        Get-LinearIssue. Only the properties you specify are changed. Nothing is returned
        unless you use -PassThru.

        Names are resolved to ids for you: workflow states and labels within the issue's
        team, and assignees and projects within the workspace. The lookups are cached for a
        few minutes. When you use -State or a label parameter with an identifier, the
        issue's team is looked up first; piped PSLinear.Issue objects already carry it.
        An unknown name stops the command with an error that lists the valid values.

        A missing issue, or a change Linear rejects, writes a non-terminating error and the
        remaining issues are still updated. With -WhatIf nothing is sent to Linear, not even
        the name lookups, so names are not checked.

    .PARAMETER Id
        One or more issue identifiers (ENG-123), UUIDs or issue URLs.

    .PARAMETER InputObject
        PSLinear.Issue objects to update, typically from Get-LinearIssue.

    .PARAMETER Team
        Moves the issue to this team (key, name or id). -State and labels are then resolved
        in the new team. Supports tab completion once connected.

    .PARAMETER Title
        The new title.

    .PARAMETER Description
        The new description, in Markdown. An empty string clears it.

    .PARAMETER State
        The workflow state name, such as 'Done' or 'In Progress', or its id. A state type
        (Backlog, Unstarted, Started, Completed, Canceled) picks the team's first state of
        that type, so one command works across teams whose states are named differently.

    .PARAMETER Assignee
        'me', an email address, a user id, or the user's full name or display name.

    .PARAMETER Unassign
        Removes the assignee.

    .PARAMETER Priority
        None, Urgent, High, Medium or Low, or the number 0 to 4 (0 None, 1 Urgent, 4 Low).

    .PARAMETER Label
        Replaces all labels on the issue with these label names or ids.

    .PARAMETER AddLabel
        Label names or ids to add, keeping the existing labels.

    .PARAMETER RemoveLabel
        Label names or ids to remove, keeping the other labels.

    .PARAMETER Project
        Project name or id.

    .PARAMETER Estimate
        The estimate, in the team's estimation scale (for example story points).

    .PARAMETER DueDate
        The due date. Only the date part is used.

    .PARAMETER Parent
        The parent issue's identifier (ENG-123), id or URL, which makes this a sub-issue.

    .PARAMETER PassThru
        Returns the updated issues.

    .EXAMPLE
        Set-LinearIssue ENG-123 -State 'In Progress' -Assignee me

        Starts work on an issue.

    .EXAMPLE
        Get-LinearIssue -Team ENG -Label Bug -Unassigned | Set-LinearIssue -Assignee 'grace@example.com' -AddLabel Triaged

        Assigns every unassigned bug and adds a label, keeping the existing labels.

    .EXAMPLE
        Get-LinearIssue -Assignee me -State 'In Review' | Set-LinearIssue -State Done -WhatIf

        Shows which issues would be moved to Done, without changing them.

    .EXAMPLE
        Set-LinearIssue ENG-123 -Team OPS -State Todo -PassThru

        Moves an issue to another team and returns it with its new identifier.

    .INPUTS
        System.String
        PSLinear.Issue

    .OUTPUTS
        PSLinear.Issue

    .LINK
        Get-LinearIssue

    .LINK
        New-LinearIssue

    .LINK
        Remove-LinearIssue
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById', SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType('PSLinear.Issue')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'ById')]
        [Alias('Identifier')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Id,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [PSTypeName('PSLinear.Issue')]
        [object[]] $InputObject,

        [ValidateNotNullOrEmpty()]
        [string] $Team,

        [ValidateNotNullOrEmpty()]
        [string] $Title,

        [string] $Description,

        [ValidateNotNullOrEmpty()]
        [string] $State,

        [ValidateNotNullOrEmpty()]
        [string] $Assignee,

        [switch] $Unassign,

        [ArgumentCompletions('None', 'Urgent', 'High', 'Medium', 'Low')]
        [ValidatePattern('^(?:None|Urgent|High|Medium|Low|[0-4])$', ErrorMessage = "'{0}' is not a priority. Use None, Urgent, High, Medium, Low, or 0 to 4.")]
        [string] $Priority,

        [ValidateNotNullOrEmpty()]
        [string[]] $Label,

        [ValidateNotNullOrEmpty()]
        [string[]] $AddLabel,

        [ValidateNotNullOrEmpty()]
        [string[]] $RemoveLabel,

        [ValidateNotNullOrEmpty()]
        [string] $Project,

        [ValidateRange(0, [int]::MaxValue)]
        [int] $Estimate,

        [datetime] $DueDate,

        [ValidateNotNullOrEmpty()]
        [string] $Parent,

        [switch] $PassThru
    )

    begin {
        $changeParameters = @(
            'Team', 'Title', 'Description', 'State', 'Assignee', 'Unassign', 'Priority'
            'Label', 'AddLabel', 'RemoveLabel', 'Project', 'Estimate', 'DueDate', 'Parent'
        )
        $changes = Format-LinearChangeList -BoundParameters $PSBoundParameters -Name $changeParameters

        $invalidMessage = if ($Assignee -and $Unassign) {
            'Use either -Assignee or -Unassign, not both.'
        }
        elseif ($Label -and ($AddLabel -or $RemoveLabel)) {
            'Use -Label to replace all labels, or -AddLabel and -RemoveLabel to change them, not both.'
        }
        elseif (-not $changes) {
            'Specify at least one property to change, such as -State, -Assignee or -Title.'
        }
        if ($invalidMessage) {
            $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord -Message $invalidMessage -ErrorId 'PSLinear.InvalidArgument' -Category InvalidArgument))
        }

        # Workflow states and labels belong to a team, so these need the issue's team id.
        $needsTeamId = [bool]($State -or $Label -or $AddLabel -or $RemoveLabel)
        $updateQuery = Get-LinearGraphQLDocument -Name 'UpdateIssue'
    }

    process {
        $targets = if ($PSCmdlet.ParameterSetName -eq 'ById') {
            Get-LinearIssueTarget -Id $Id
        }
        else {
            Get-LinearIssueTarget -InputObject $InputObject
        }

        foreach ($target in $targets) {
            if (-not $PSCmdlet.ShouldProcess($target.Name, "Update issue ($changes)")) {
                continue
            }

            $teamId = $target.TeamId
            if ($needsTeamId -and -not $Team -and -not $teamId) {
                $lookup = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'GetIssueTeam') -Variables @{ id = $target.Id } -IncludeErrors
                $teamId = Get-LinearNestedValue -InputObject $lookup.Data -Name 'issue.team.id'
                if ($null -eq $teamId) {
                    $message = Format-LinearFailureMessage -Message "Issue '$($target.Name)' was not found." -Errors $lookup.Errors
                    $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message `
                                -ErrorId 'PSLinear.IssueNotFound' -Category ObjectNotFound -TargetObject $target.Name))
                    continue
                }
            }

            try {
                $issueInput = @{}
                if ($Team) {
                    $teamId = Resolve-LinearTeamId -Team $Team
                    $issueInput['teamId'] = $teamId
                }
                if ($PSBoundParameters.ContainsKey('Title')) { $issueInput['title'] = $Title }
                if ($PSBoundParameters.ContainsKey('Description')) { $issueInput['description'] = $Description }
                if ($State) { $issueInput['stateId'] = Resolve-LinearWorkflowStateId -TeamId $teamId -State $State }
                if ($Unassign) { $issueInput['assigneeId'] = $null }
                elseif ($Assignee) { $issueInput['assigneeId'] = Resolve-LinearUserId -User $Assignee }
                if ($Priority) { $issueInput['priority'] = ConvertTo-LinearPriority -Priority $Priority }
                if ($Label) { $issueInput['labelIds'] = @(Resolve-LinearLabelId -TeamId $teamId -Label $Label) }
                if ($AddLabel) { $issueInput['addedLabelIds'] = @(Resolve-LinearLabelId -TeamId $teamId -Label $AddLabel) }
                if ($RemoveLabel) { $issueInput['removedLabelIds'] = @(Resolve-LinearLabelId -TeamId $teamId -Label $RemoveLabel) }
                if ($Project) { $issueInput['projectId'] = Resolve-LinearProjectId -Project $Project }
                if ($PSBoundParameters.ContainsKey('Estimate')) { $issueInput['estimate'] = $Estimate }
                if ($PSBoundParameters.ContainsKey('DueDate')) { $issueInput['dueDate'] = ConvertTo-LinearTimelessDate -Date $DueDate }
                if ($Parent) { $issueInput['parentId'] = ConvertTo-LinearIssueIdentifier -Value $Parent }
            }
            catch {
                $PSCmdlet.ThrowTerminatingError($_)
            }

            $result = Invoke-LinearRequest -Query $updateQuery -Variables @{ id = $target.Id; input = $issueInput } -IncludeErrors
            $issue = Get-LinearNestedValue -InputObject $result.Data -Name 'issueUpdate.issue'
            if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'issueUpdate.success') -or $null -eq $issue) {
                $message = Format-LinearFailureMessage -Message "Linear did not update issue '$($target.Name)'." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message `
                            -ErrorId 'PSLinear.IssueUpdateFailed' -Category WriteError -TargetObject $target.Name))
                continue
            }

            if ($PassThru) {
                ConvertTo-LinearIssue -InputObject $issue
            }
        }
    }
}
