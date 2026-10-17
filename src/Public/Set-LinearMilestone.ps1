function Set-LinearMilestone {
    <#
    .SYNOPSIS
        Changes Linear project milestones.

    .DESCRIPTION
        Updates milestones given by id or piped in from Get-LinearMilestone: name, description,
        target date and position, or moves them to another project with -Project. Nothing is
        returned unless you use -PassThru.

        A missing milestone, or a change Linear rejects, writes a non-terminating error and the
        remaining milestones are still processed. With -WhatIf nothing is sent.

    .PARAMETER Id
        One or more milestone ids.

    .PARAMETER InputObject
        PSLinear.Milestone objects, typically from Get-LinearMilestone.

    .PARAMETER Name
        The new name.

    .PARAMETER Description
        The new description, in Markdown. An empty string clears it.

    .PARAMETER TargetDate
        The new target date. Only the date part is used.

    .PARAMETER SortOrder
        The new position among the project's milestones; lower values come first.

    .PARAMETER Project
        Moves the milestones to this project: a project name, slug id, URL or id.

    .PARAMETER Clear
        Removes values: TargetDate.

    .PARAMETER PassThru
        Returns the updated milestones.

    .EXAMPLE
        Get-LinearMilestone -Project Website -Name Beta | Set-LinearMilestone -TargetDate (Get-Date).AddDays(14)

        Moves a milestone's target date two weeks out.

    .EXAMPLE
        Set-LinearMilestone -Id 3f2a9c1e-0000-4000-8000-000000000000 -Name 'Public beta' -Clear TargetDate -PassThru

        Renames a milestone, removes its target date and returns it.

    .INPUTS
        System.String
        PSLinear.Milestone

    .OUTPUTS
        PSLinear.Milestone

    .LINK
        Get-LinearMilestone

    .LINK
        Remove-LinearMilestone
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById', SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType('PSLinear.Milestone')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'ById')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Id,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [PSTypeName('PSLinear.Milestone')]
        [object[]] $InputObject,

        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [string] $Description,

        [datetime] $TargetDate,

        [double] $SortOrder,

        [ValidateNotNullOrEmpty()]
        [string] $Project,

        [ValidateSet('TargetDate')]
        [string[]] $Clear,

        [switch] $PassThru
    )

    begin {
        $changes = Format-LinearChangeList -BoundParameters $PSBoundParameters -Name 'Name', 'Description', 'TargetDate', 'SortOrder', 'Project', 'Clear'
        $invalidMessage = if ($Clear -contains 'TargetDate' -and $PSBoundParameters.ContainsKey('TargetDate')) {
            'Use either -Clear TargetDate or -TargetDate, not both.'
        }
        elseif (-not $changes) {
            'Specify at least one change, such as -Name, -TargetDate or -Project.'
        }
        if ($invalidMessage) {
            $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord -Message $invalidMessage -ErrorId 'PSLinear.InvalidArgument' -Category InvalidArgument))
        }
        $updateQuery = Get-LinearGraphQLDocument -Name 'UpdateProjectMilestone'
    }

    process {
        $targets = if ($PSCmdlet.ParameterSetName -eq 'ById') {
            foreach ($milestoneId in $Id) { [pscustomobject]@{ Id = $milestoneId; Name = "milestone $milestoneId"; ProjectId = $null } }
        }
        else {
            foreach ($milestone in $InputObject) {
                $milestoneName = Get-LinearNestedValue -InputObject $milestone -Name 'Name'
                $projectName = Get-LinearNestedValue -InputObject $milestone -Name 'Project'
                [pscustomobject]@{
                    Id        = $milestone.Id
                    Name      = "milestone '$milestoneName'$(if ($projectName) { " in $projectName" })"
                    ProjectId = Get-LinearNestedValue -InputObject $milestone -Name 'ProjectId'
                }
            }
        }

        foreach ($target in $targets) {
            if (-not $PSCmdlet.ShouldProcess($target.Name, "Update milestone ($changes)")) {
                continue
            }

            try {
                $milestoneInput = @{}
                if ($PSBoundParameters.ContainsKey('Name')) { $milestoneInput['name'] = $Name }
                if ($PSBoundParameters.ContainsKey('Description')) { $milestoneInput['description'] = $Description }
                if ($PSBoundParameters.ContainsKey('TargetDate')) { $milestoneInput['targetDate'] = ConvertTo-LinearTimelessDate -Date $TargetDate }
                if ($Clear -contains 'TargetDate') { $milestoneInput['targetDate'] = $null }
                if ($PSBoundParameters.ContainsKey('SortOrder')) { $milestoneInput['sortOrder'] = $SortOrder }
                if ($Project) { $milestoneInput['projectId'] = Resolve-LinearProjectId -Project $Project }
            }
            catch {
                $PSCmdlet.ThrowTerminatingError($_)
            }

            $result = Invoke-LinearRequest -Query $updateQuery -Variables @{ id = $target.Id; input = $milestoneInput } -IncludeErrors
            $updated = Get-LinearNestedValue -InputObject $result.Data -Name 'projectMilestoneUpdate.projectMilestone'
            if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'projectMilestoneUpdate.success') -or $null -eq $updated) {
                $message = Format-LinearFailureMessage -Message "Linear did not update $($target.Name)." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.MilestoneUpdateFailed' -Category WriteError -TargetObject $target.Id))
                continue
            }

            # Names, order or project changed, so -Milestone lookups must fetch these projects again.
            # A milestone given by id and moved came from a project we do not know: clear them all.
            if ($Project -and -not $target.ProjectId) {
                $script:LinearMilestoneCache.Clear()
            }
            foreach ($changedProject in @($target.ProjectId, (Get-LinearNestedValue -InputObject $updated -Name 'project.id'))) {
                if ($changedProject) { $script:LinearMilestoneCache.Remove($changedProject) }
            }
            if ($PassThru) {
                ConvertTo-LinearMilestone -InputObject $updated
            }
        }
    }
}
