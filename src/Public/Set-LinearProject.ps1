function Set-LinearProject {
    <#
    .SYNOPSIS
        Changes Linear projects.

    .DESCRIPTION
        Updates projects given by name, slug id, URL or id, or piped in from Get-LinearProject.
        Only the properties you specify are changed. Nothing is returned unless you use
        -PassThru.

        Names are resolved to ids for you: teams, the lead and members, the status and project
        labels. An unknown name stops the command with an error that lists the valid values.
        The -Add and -Remove parameters fetch the project's current teams, labels or members
        first and change only those you give.

        A missing project, or a change Linear rejects, writes a non-terminating error and the
        remaining projects are still processed. With -WhatIf nothing is sent, not even the name
        lookups.

    .PARAMETER Project
        One or more projects: names, slug ids (the hex suffix of a project URL), URLs or ids.

    .PARAMETER InputObject
        PSLinear.Project objects, typically from Get-LinearProject.

    .PARAMETER Name
        The new name.

    .PARAMETER Description
        The new short summary. An empty string clears it.

    .PARAMETER Content
        The new content, in Markdown. An empty string clears it.

    .PARAMETER Lead
        The project lead: 'me', an email address, a user id, or the user's full name or display
        name.

    .PARAMETER Status
        The project status: a status name (In Progress), a status type (backlog, planned,
        started, paused, completed, canceled) that picks the first status of that type, or a
        status id.

    .PARAMETER Priority
        None, Urgent, High, Medium or Low, or the number 0 to 4 (0 None, 1 Urgent, 4 Low).

    .PARAMETER StartDate
        The planned start date. Only the date part is used.

    .PARAMETER TargetDate
        The planned completion date. Only the date part is used.

    .PARAMETER Team
        Replaces the project's teams with these team keys, names or ids. Supports tab completion
        once connected.

    .PARAMETER AddTeam
        Teams to add, keeping the existing ones.

    .PARAMETER RemoveTeam
        Teams to remove, keeping the others. A project needs at least one team.

    .PARAMETER Label
        Replaces the project's labels with these project label names or ids.

    .PARAMETER AddLabel
        Project labels to add, keeping the existing ones.

    .PARAMETER RemoveLabel
        Project labels to remove, keeping the others.

    .PARAMETER Member
        Replaces the project's members with these users, given like -Lead. Linear always keeps
        the project lead as a member.

    .PARAMETER AddMember
        Members to add, keeping the existing ones.

    .PARAMETER RemoveMember
        Members to remove, keeping the others. The project lead stays a member; remove or change
        the lead first.

    .PARAMETER Clear
        Removes values: Lead, StartDate, TargetDate, Labels (all labels) or Members (every member
        except the lead, whom Linear keeps). Use -Description '' or -Content '' to clear those.

    .PARAMETER PassThru
        Returns the updated projects.

    .EXAMPLE
        Set-LinearProject Website -Status started -Lead me

        Starts a project and makes you its lead.

    .EXAMPLE
        Get-LinearProject -Team ENG -Status planned | Set-LinearProject -TargetDate 2027-03-31 -WhatIf

        Shows which planned projects would get a new target date, without changing them.

    .EXAMPLE
        Set-LinearProject Website -AddTeam OPS -AddMember 'grace@example.com' -RemoveLabel Experimental -PassThru

        Shares a project with another team, adds a member, removes a label and returns the
        project.

    .EXAMPLE
        Set-LinearProject Website -Clear TargetDate, Lead

        Removes a project's target date and lead.

    .INPUTS
        System.String
        PSLinear.Project

    .OUTPUTS
        PSLinear.Project

    .LINK
        Get-LinearProject

    .LINK
        New-LinearProject

    .LINK
        Remove-LinearProject
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByProject', SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType('PSLinear.Project')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'ByProject')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Project,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [PSTypeName('PSLinear.Project')]
        [object[]] $InputObject,

        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [string] $Description,

        [string] $Content,

        [ValidateNotNullOrEmpty()]
        [string] $Lead,

        [ValidateNotNullOrEmpty()]
        [string] $Status,

        [ArgumentCompletions('None', 'Urgent', 'High', 'Medium', 'Low')]
        [ValidatePattern('^(?:None|Urgent|High|Medium|Low|[0-4])$', ErrorMessage = "'{0}' is not a priority. Use None, Urgent, High, Medium, Low, or 0 to 4.")]
        [string] $Priority,

        [datetime] $StartDate,

        [datetime] $TargetDate,

        [ValidateNotNullOrEmpty()]
        [string[]] $Team,

        [ValidateNotNullOrEmpty()]
        [string[]] $AddTeam,

        [ValidateNotNullOrEmpty()]
        [string[]] $RemoveTeam,

        [ValidateNotNullOrEmpty()]
        [string[]] $Label,

        [ValidateNotNullOrEmpty()]
        [string[]] $AddLabel,

        [ValidateNotNullOrEmpty()]
        [string[]] $RemoveLabel,

        [ValidateNotNullOrEmpty()]
        [string[]] $Member,

        [ValidateNotNullOrEmpty()]
        [string[]] $AddMember,

        [ValidateNotNullOrEmpty()]
        [string[]] $RemoveMember,

        [ValidateSet('Lead', 'StartDate', 'TargetDate', 'Labels', 'Members')]
        [string[]] $Clear,

        [switch] $PassThru
    )

    begin {
        $changeParameters = @(
            'Name', 'Description', 'Content', 'Lead', 'Status', 'Priority', 'StartDate', 'TargetDate'
            'Team', 'AddTeam', 'RemoveTeam', 'Label', 'AddLabel', 'RemoveLabel', 'Member', 'AddMember', 'RemoveMember', 'Clear'
        )
        $changes = Format-LinearChangeList -BoundParameters $PSBoundParameters -Name $changeParameters

        # ProjectUpdateInput fields that -Clear sets to null. Labels and Members are cleared with an empty list.
        $clearFields = @{
            Lead       = 'leadId'
            StartDate  = 'startDate'
            TargetDate = 'targetDate'
        }
        $clearConflicts = @(foreach ($field in $Clear) {
                $parameters = switch ($field) {
                    'Labels' { 'Label', 'AddLabel', 'RemoveLabel' }
                    'Members' { 'Member', 'AddMember', 'RemoveMember' }
                    default { $field }
                }
                foreach ($parameter in $parameters) {
                    if ($PSBoundParameters.ContainsKey($parameter)) { "Use either -Clear $field or -$parameter, not both." }
                }
            })
        $listConflicts = @(foreach ($kind in 'Team', 'Label', 'Member') {
                if ($PSBoundParameters.ContainsKey($kind) -and ($PSBoundParameters.ContainsKey("Add$kind") -or $PSBoundParameters.ContainsKey("Remove$kind"))) {
                    "Use -$kind to replace all $($kind.ToLowerInvariant())s, or -Add$kind and -Remove$kind to change them, not both."
                }
            })

        $invalidMessage = if ($listConflicts.Count -gt 0) {
            $listConflicts[0]
        }
        elseif ($clearConflicts.Count -gt 0) {
            $clearConflicts[0]
        }
        elseif (-not $changes) {
            'Specify at least one property to change, such as -Status, -Lead or -TargetDate.'
        }
        if ($invalidMessage) {
            $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord -Message $invalidMessage -ErrorId 'PSLinear.InvalidArgument' -Category InvalidArgument))
        }

        $needsCurrent = [bool]($AddTeam -or $RemoveTeam -or $AddLabel -or $RemoveLabel -or $AddMember -or $RemoveMember)
        $updateQuery = Get-LinearGraphQLDocument -Name 'UpdateProject'
    }

    process {
        $targets = Get-LinearProjectTarget -Project $Project -InputObject $InputObject

        foreach ($target in $targets) {
            if (-not $PSCmdlet.ShouldProcess($target.Name, "Update project ($changes)")) {
                continue
            }

            try {
                $projectId = if ($target.Id) { $target.Id } else { Resolve-LinearProjectId -Project $target.Reference }
                $projectInput = @{}
                if ($PSBoundParameters.ContainsKey('Name')) { $projectInput['name'] = $Name }
                if ($PSBoundParameters.ContainsKey('Description')) { $projectInput['description'] = $Description }
                if ($PSBoundParameters.ContainsKey('Content')) { $projectInput['content'] = $Content }
                if ($Lead) { $projectInput['leadId'] = Resolve-LinearUserId -User $Lead }
                if ($Status) { $projectInput['statusId'] = Resolve-LinearProjectStatusId -Status $Status }
                if ($Priority) { $projectInput['priority'] = ConvertTo-LinearPriority -Priority $Priority }
                if ($PSBoundParameters.ContainsKey('StartDate')) { $projectInput['startDate'] = ConvertTo-LinearTimelessDate -Date $StartDate }
                if ($PSBoundParameters.ContainsKey('TargetDate')) { $projectInput['targetDate'] = ConvertTo-LinearTimelessDate -Date $TargetDate }
                if ($Team) { $projectInput['teamIds'] = @(foreach ($value in $Team) { Resolve-LinearTeamId -Team $value }) }
                if ($Label) { $projectInput['labelIds'] = @(Resolve-LinearProjectLabelId -Label $Label) }
                if ($Member) { $projectInput['memberIds'] = @(foreach ($user in $Member) { Resolve-LinearUserId -User $user }) }
                $teamsToAdd = @(foreach ($value in $AddTeam) { Resolve-LinearTeamId -Team $value })
                $teamsToRemove = @(foreach ($value in $RemoveTeam) { Resolve-LinearTeamId -Team $value })
                $labelsToAdd = @(if ($AddLabel) { Resolve-LinearProjectLabelId -Label $AddLabel })
                $labelsToRemove = @(if ($RemoveLabel) { Resolve-LinearProjectLabelId -Label $RemoveLabel })
                $membersToAdd = @(foreach ($user in $AddMember) { Resolve-LinearUserId -User $user })
                $membersToRemove = @(foreach ($user in $RemoveMember) { Resolve-LinearUserId -User $user })
                foreach ($field in $Clear) {
                    switch ($field) {
                        'Labels' { $projectInput['labelIds'] = @() }
                        'Members' { $projectInput['memberIds'] = @() }
                        default { $projectInput[$clearFields[$field]] = $null }
                    }
                }
            }
            catch {
                $PSCmdlet.ThrowTerminatingError($_)
            }

            if ($needsCurrent) {
                # ProjectUpdateInput only takes complete lists, so merge the changes into the current ones.
                $detail = Get-LinearProjectDetail -Id $projectId
                if ($null -eq $detail.Project) {
                    $message = Format-LinearFailureMessage -Message "Project '$($target.Reference)' was not found." -Errors $detail.Errors
                    $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.ProjectNotFound' -Category ObjectNotFound -TargetObject $target.Reference))
                    continue
                }
                $current = ConvertTo-LinearProject -InputObject $detail.Project
                if ($AddTeam -or $RemoveTeam) {
                    $teamIds = @(@($current.TeamIds) + $teamsToAdd | Select-Object -Unique | Where-Object { $_ -notin $teamsToRemove })
                    if ($teamIds.Count -eq 0) {
                        $PSCmdlet.WriteError((New-LinearErrorRecord -Message "A project needs at least one team, so -RemoveTeam cannot remove every team of $($target.Name)." `
                                    -ErrorId 'PSLinear.InvalidArgument' -Category InvalidArgument -TargetObject $target.Reference))
                        continue
                    }
                    $projectInput['teamIds'] = $teamIds
                }
                if ($AddLabel -or $RemoveLabel) {
                    $projectInput['labelIds'] = @(@($current.LabelIds) + $labelsToAdd | Select-Object -Unique | Where-Object { $_ -notin $labelsToRemove })
                }
                if ($AddMember -or $RemoveMember) {
                    $projectInput['memberIds'] = @(@($current.MemberIds) + $membersToAdd | Select-Object -Unique | Where-Object { $_ -notin $membersToRemove })
                }
            }

            $result = Invoke-LinearRequest -Query $updateQuery -Variables @{ id = $projectId; input = $projectInput } -IncludeErrors
            $updated = Get-LinearNestedValue -InputObject $result.Data -Name 'projectUpdate.project'
            if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'projectUpdate.success') -or $null -eq $updated) {
                $message = Format-LinearFailureMessage -Message "Linear did not update $($target.Name)." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.ProjectUpdateFailed' -Category WriteError -TargetObject $target.Reference))
                continue
            }

            # So that -Project finds a renamed project by its new name right away.
            if ($PSBoundParameters.ContainsKey('Name')) { Reset-LinearProjectCache }
            if ($PassThru) {
                ConvertTo-LinearProject -InputObject $updated
            }
        }
    }
}
