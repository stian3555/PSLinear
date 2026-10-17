function Set-LinearInitiative {
    <#
    .SYNOPSIS
        Changes Linear initiatives and the projects in them.

    .DESCRIPTION
        Updates initiatives given by name, slug id, URL or id, or piped in from
        Get-LinearInitiative. Only the properties you specify are changed. -AddProject and
        -RemoveProject add projects to the initiative or take them out. Nothing is returned
        unless you use -PassThru.

        Names are resolved to ids for you: the owner, the lead team, initiative labels and
        projects. An unknown name stops the command with an error that lists the valid values.
        The -Add and -Remove parameters fetch the initiative's current labels and projects
        first; adding a project that is already in the initiative, or removing one that is not,
        does nothing.

        A missing initiative, or a change Linear rejects, writes a non-terminating error and the
        remaining initiatives (and projects) are still processed. With -WhatIf nothing is sent,
        not even the name lookups.

    .PARAMETER Initiative
        One or more initiatives: names, slug ids (the hex suffix of an initiative URL), URLs or
        ids.

    .PARAMETER InputObject
        PSLinear.Initiative objects, typically from Get-LinearInitiative.

    .PARAMETER Name
        The new name.

    .PARAMETER Description
        The new short summary. An empty string clears it.

    .PARAMETER Content
        The new content, in Markdown. An empty string clears it.

    .PARAMETER Owner
        The owner: 'me', an email address, a user id, or the user's full name or display name.

    .PARAMETER LeadTeam
        The team that leads the initiative: a team key, name or id. Supports tab completion once
        connected.

    .PARAMETER Status
        Proposed, Planned, Active, Completed or Canceled.

    .PARAMETER Priority
        None, Urgent, High, Medium or Low, or the number 0 to 4 (0 None, 1 Urgent, 4 Low).

    .PARAMETER TargetDate
        The planned completion date. Only the date part is used.

    .PARAMETER Label
        Replaces the initiative's labels with these initiative label names or ids.

    .PARAMETER AddLabel
        Initiative labels to add, keeping the existing ones.

    .PARAMETER RemoveLabel
        Initiative labels to remove, keeping the others.

    .PARAMETER AddProject
        Projects to add to the initiative: names, slug ids, URLs or ids.

    .PARAMETER RemoveProject
        Projects to take out of the initiative. The projects themselves are not changed.

    .PARAMETER Clear
        Removes values: Owner, LeadTeam, TargetDate or Labels (all labels). Use -Description ''
        or -Content '' to clear those.

    .PARAMETER PassThru
        Returns the updated initiatives.

    .EXAMPLE
        Set-LinearInitiative 'Q1 growth' -Status Active -Owner me

        Activates an initiative and makes you its owner.

    .EXAMPLE
        Set-LinearInitiative 'Q1 growth' -AddProject Website, 'Mobile App' -RemoveProject Legacy -PassThru

        Changes which projects are in an initiative and returns it.

    .EXAMPLE
        Get-LinearInitiative -Status Planned | Set-LinearInitiative -TargetDate 2027-06-30 -WhatIf

        Shows which planned initiatives would get a new target date, without changing them.

    .INPUTS
        System.String
        PSLinear.Initiative

    .OUTPUTS
        PSLinear.Initiative

    .LINK
        Get-LinearInitiative

    .LINK
        New-LinearInitiative

    .LINK
        Remove-LinearInitiative
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByInitiative', SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType('PSLinear.Initiative')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'ByInitiative')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Initiative,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [PSTypeName('PSLinear.Initiative')]
        [object[]] $InputObject,

        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [string] $Description,

        [string] $Content,

        [ValidateNotNullOrEmpty()]
        [string] $Owner,

        [ValidateNotNullOrEmpty()]
        [string] $LeadTeam,

        [ValidateSet('Proposed', 'Planned', 'Active', 'Completed', 'Canceled')]
        [string] $Status,

        [ArgumentCompletions('None', 'Urgent', 'High', 'Medium', 'Low')]
        [ValidatePattern('^(?:None|Urgent|High|Medium|Low|[0-4])$', ErrorMessage = "'{0}' is not a priority. Use None, Urgent, High, Medium, Low, or 0 to 4.")]
        [string] $Priority,

        [datetime] $TargetDate,

        [ValidateNotNullOrEmpty()]
        [string[]] $Label,

        [ValidateNotNullOrEmpty()]
        [string[]] $AddLabel,

        [ValidateNotNullOrEmpty()]
        [string[]] $RemoveLabel,

        [ValidateNotNullOrEmpty()]
        [string[]] $AddProject,

        [ValidateNotNullOrEmpty()]
        [string[]] $RemoveProject,

        [ValidateSet('Owner', 'LeadTeam', 'TargetDate', 'Labels')]
        [string[]] $Clear,

        [switch] $PassThru
    )

    begin {
        $changeParameters = @(
            'Name', 'Description', 'Content', 'Owner', 'LeadTeam', 'Status', 'Priority', 'TargetDate'
            'Label', 'AddLabel', 'RemoveLabel', 'AddProject', 'RemoveProject', 'Clear'
        )
        $changes = Format-LinearChangeList -BoundParameters $PSBoundParameters -Name $changeParameters

        # InitiativeUpdateInput fields that -Clear sets to null. Labels is cleared with an empty list.
        $clearFields = @{
            Owner      = 'ownerId'
            LeadTeam   = 'leadTeamId'
            TargetDate = 'targetDate'
        }
        $clearConflicts = @(foreach ($field in $Clear) {
                $parameters = if ($field -eq 'Labels') { 'Label', 'AddLabel', 'RemoveLabel' } else { $field }
                foreach ($parameter in $parameters) {
                    if ($PSBoundParameters.ContainsKey($parameter)) { "Use either -Clear $field or -$parameter, not both." }
                }
            })

        $invalidMessage = if ($Label -and ($AddLabel -or $RemoveLabel)) {
            'Use -Label to replace all labels, or -AddLabel and -RemoveLabel to change them, not both.'
        }
        elseif ($clearConflicts.Count -gt 0) {
            $clearConflicts[0]
        }
        elseif (-not $changes) {
            'Specify at least one property to change, such as -Status, -Owner or -AddProject.'
        }
        if ($invalidMessage) {
            $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord -Message $invalidMessage -ErrorId 'PSLinear.InvalidArgument' -Category InvalidArgument))
        }

        $needsCurrent = [bool]($AddLabel -or $RemoveLabel -or $AddProject -or $RemoveProject)
        $updateQuery = Get-LinearGraphQLDocument -Name 'UpdateInitiative'
    }

    process {
        $targets = Get-LinearInitiativeTarget -Initiative $Initiative -InputObject $InputObject

        foreach ($target in $targets) {
            if (-not $PSCmdlet.ShouldProcess($target.Name, "Update initiative ($changes)")) {
                continue
            }

            try {
                $initiativeId = if ($target.Id) { $target.Id } else { Resolve-LinearInitiativeId -Initiative $target.Reference }
                $initiativeInput = @{}
                if ($PSBoundParameters.ContainsKey('Name')) { $initiativeInput['name'] = $Name }
                if ($PSBoundParameters.ContainsKey('Description')) { $initiativeInput['description'] = $Description }
                if ($PSBoundParameters.ContainsKey('Content')) { $initiativeInput['content'] = $Content }
                if ($Owner) { $initiativeInput['ownerId'] = Resolve-LinearUserId -User $Owner }
                if ($LeadTeam) { $initiativeInput['leadTeamId'] = Resolve-LinearTeamId -Team $LeadTeam }
                if ($Status) { $initiativeInput['status'] = $Status }
                if ($Priority) { $initiativeInput['priority'] = ConvertTo-LinearPriority -Priority $Priority }
                if ($PSBoundParameters.ContainsKey('TargetDate')) { $initiativeInput['targetDate'] = ConvertTo-LinearTimelessDate -Date $TargetDate }
                if ($Label) { $initiativeInput['labelIds'] = @(Resolve-LinearInitiativeLabelId -Label $Label) }
                $labelsToAdd = @(if ($AddLabel) { Resolve-LinearInitiativeLabelId -Label $AddLabel })
                $labelsToRemove = @(if ($RemoveLabel) { Resolve-LinearInitiativeLabelId -Label $RemoveLabel })
                $projectsToAdd = @(foreach ($value in $AddProject) { Resolve-LinearProjectId -Project $value })
                $projectsToRemove = @(foreach ($value in $RemoveProject) { Resolve-LinearProjectId -Project $value })
                foreach ($field in $Clear) {
                    if ($field -eq 'Labels') { $initiativeInput['labelIds'] = @() }
                    else { $initiativeInput[$clearFields[$field]] = $null }
                }
            }
            catch {
                $PSCmdlet.ThrowTerminatingError($_)
            }

            if ($needsCurrent) {
                $detail = Get-LinearInitiativeDetail -Id $initiativeId
                if ($null -eq $detail.Initiative) {
                    $message = Format-LinearFailureMessage -Message "Initiative '$($target.Reference)' was not found." -Errors $detail.Errors
                    $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.InitiativeNotFound' -Category ObjectNotFound -TargetObject $target.Reference))
                    continue
                }
                $current = ConvertTo-LinearInitiative -InputObject $detail.Initiative
                if ($AddLabel -or $RemoveLabel) {
                    # InitiativeUpdateInput only takes the complete list, so merge the changes into the current one.
                    $initiativeInput['labelIds'] = @(@($current.LabelIds) + $labelsToAdd | Select-Object -Unique | Where-Object { $_ -notin $labelsToRemove })
                }
                $projectsToAdd = @($projectsToAdd | Select-Object -Unique | Where-Object { $_ -notin $current.ProjectIds })
                $projectsToRemove = @($projectsToRemove | Select-Object -Unique | Where-Object { $_ -in $current.ProjectIds })
            }

            $updated = $null
            if ($initiativeInput.Count -gt 0) {
                $result = Invoke-LinearRequest -Query $updateQuery -Variables @{ id = $initiativeId; input = $initiativeInput } -IncludeErrors
                $updated = Get-LinearNestedValue -InputObject $result.Data -Name 'initiativeUpdate.initiative'
                if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'initiativeUpdate.success') -or $null -eq $updated) {
                    $message = Format-LinearFailureMessage -Message "Linear did not update $($target.Name)." -Errors $result.Errors
                    $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.InitiativeUpdateFailed' -Category WriteError -TargetObject $target.Reference))
                    continue
                }
                # So that -Initiative finds a renamed initiative by its new name right away.
                if ($PSBoundParameters.ContainsKey('Name')) { Reset-LinearInitiativeCache }
            }

            $linksChanged = $false
            foreach ($projectId in $projectsToAdd) {
                $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'CreateInitiativeToProject') `
                    -Variables @{ input = @{ initiativeId = $initiativeId; projectId = $projectId } } -IncludeErrors
                if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'initiativeToProjectCreate.success')) {
                    $message = Format-LinearFailureMessage -Message "Linear did not add project $projectId to $($target.Name)." -Errors $result.Errors
                    $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.InitiativeProjectAddFailed' -Category WriteError -TargetObject $projectId))
                    continue
                }
                $linksChanged = $true
            }
            foreach ($projectId in $projectsToRemove) {
                # The link between an initiative and a project has its own id; find it from the project.
                $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'ListProjectInitiativeLinks') -Variables @{ id = $projectId } -IncludeErrors
                $link = @(Get-LinearNestedValue -InputObject $result.Data -Name 'project.initiativeToProjects.nodes') |
                    Where-Object { $null -ne $_ -and (Get-LinearNestedValue -InputObject $_ -Name 'initiative.id') -eq $initiativeId } |
                    Select-Object -First 1
                if ($null -eq $link) {
                    if ($result.Errors.Count -gt 0) {
                        $message = Format-LinearFailureMessage -Message "Could not look up project $projectId in $($target.Name)." -Errors $result.Errors
                        $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.InitiativeProjectRemoveFailed' -Category ReadError -TargetObject $projectId))
                    }
                    continue
                }
                $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'DeleteInitiativeToProject') -Variables @{ id = $link.id } -IncludeErrors
                if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'initiativeToProjectDelete.success')) {
                    $message = Format-LinearFailureMessage -Message "Linear did not remove project $projectId from $($target.Name)." -Errors $result.Errors
                    $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.InitiativeProjectRemoveFailed' -Category WriteError -TargetObject $projectId))
                    continue
                }
                $linksChanged = $true
            }

            if ($PassThru) {
                if ($linksChanged -or $null -eq $updated) {
                    # The update result predates the project changes, so fetch the initiative again.
                    $fresh = Get-LinearInitiativeDetail -Id $initiativeId
                    if ($null -ne $fresh.Initiative) { ConvertTo-LinearInitiative -InputObject $fresh.Initiative }
                }
                else {
                    ConvertTo-LinearInitiative -InputObject $updated
                }
            }
        }
    }
}
