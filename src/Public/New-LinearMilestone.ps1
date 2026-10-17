function New-LinearMilestone {
    <#
    .SYNOPSIS
        Creates a milestone in a Linear project.

    .DESCRIPTION
        Creates a project milestone and returns it. New milestones are added after the existing
        ones unless -SortOrder places them elsewhere. With -WhatIf nothing is sent, not even the
        project lookup.

    .PARAMETER Project
        A project name, slug id, URL or id. Binds from the SlugId property of piped
        PSLinear.Project objects.

    .PARAMETER Name
        The milestone name.

    .PARAMETER Description
        The milestone description, in Markdown.

    .PARAMETER TargetDate
        The planned completion date. Only the date part is used.

    .PARAMETER SortOrder
        The position among the project's milestones; lower values come first. Compare with the
        SortOrder of the existing milestones from Get-LinearMilestone.

    .EXAMPLE
        New-LinearMilestone -Project Website -Name 'Beta' -TargetDate 2026-12-01

        Creates a milestone with a target date.

    .EXAMPLE
        Get-LinearProject -Name 'Website' | New-LinearMilestone -Name 'GA' -Description 'Public launch.'

        Creates a milestone in a piped project.

    .INPUTS
        PSLinear.Project

    .OUTPUTS
        PSLinear.Milestone

    .LINK
        Get-LinearMilestone

    .LINK
        Set-LinearMilestone
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType('PSLinear.Milestone')]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('SlugId')]
        [ValidateNotNullOrEmpty()]
        [string] $Project,

        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [string] $Description,

        [datetime] $TargetDate,

        [double] $SortOrder
    )

    process {
        $changes = Format-LinearChangeList -BoundParameters $PSBoundParameters -Name 'Description', 'TargetDate', 'SortOrder'
        $action = if ($changes) { "Create milestone '$Name' ($changes)" } else { "Create milestone '$Name'" }
        if (-not $PSCmdlet.ShouldProcess("project '$Project'", $action)) {
            return
        }

        try {
            $projectId = Resolve-LinearProjectId -Project $Project
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }

        $milestoneInput = @{ projectId = $projectId; name = $Name }
        if ($PSBoundParameters.ContainsKey('Description')) { $milestoneInput['description'] = $Description }
        if ($PSBoundParameters.ContainsKey('TargetDate')) { $milestoneInput['targetDate'] = ConvertTo-LinearTimelessDate -Date $TargetDate }
        if ($PSBoundParameters.ContainsKey('SortOrder')) { $milestoneInput['sortOrder'] = $SortOrder }

        $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'CreateProjectMilestone') -Variables @{ input = $milestoneInput } -IncludeErrors
        $milestone = Get-LinearNestedValue -InputObject $result.Data -Name 'projectMilestoneCreate.projectMilestone'
        if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'projectMilestoneCreate.success') -or $null -eq $milestone) {
            $message = Format-LinearFailureMessage -Message "Linear did not create milestone '$Name' in project '$Project'." -Errors $result.Errors
            $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.MilestoneCreateFailed' -Category WriteError -TargetObject $Name))
            return
        }
        # The project's milestone list changed, so -Milestone lookups must fetch it again.
        $script:LinearMilestoneCache.Remove($projectId)
        ConvertTo-LinearMilestone -InputObject $milestone
    }
}
