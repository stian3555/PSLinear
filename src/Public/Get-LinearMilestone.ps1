function Get-LinearMilestone {
    <#
    .SYNOPSIS
        Gets project milestones.

    .DESCRIPTION
        Returns the milestones of a project in their order in the project, or every milestone in
        the workspace when -Project is not given. Each milestone has a status (Unstarted, Next,
        Overdue or Done), a target date and progress. Use -Name to filter; wildcards are
        supported. A name without wildcards that matches no milestone writes a non-terminating
        error. Use -Id for specific milestones.

        To list a milestone's issues, use Get-LinearIssue -Milestone.

    .PARAMETER Project
        A project name, slug id, URL or id. Binds from the Project property of piped issues and
        the SlugId property of piped PSLinear.Project objects.

    .PARAMETER Name
        One or more milestone names. Wildcards are supported.

    .PARAMETER Id
        One or more milestone ids.

    .EXAMPLE
        Get-LinearMilestone -Project Website

        Lists a project's milestones.

    .EXAMPLE
        Get-LinearProject | Get-LinearMilestone | Where-Object Status -EQ 'Overdue'

        Lists the overdue milestones of every project.

    .EXAMPLE
        Get-LinearMilestone -Project Website -Name Beta | ForEach-Object { Get-LinearIssue -Milestone $_.Id -All }

        Lists every issue in a milestone.

    .INPUTS
        PSLinear.Project
        PSLinear.Issue

    .OUTPUTS
        PSLinear.Milestone

    .LINK
        New-LinearMilestone

    .LINK
        Get-LinearIssue
    #>
    [CmdletBinding(DefaultParameterSetName = 'List')]
    [OutputType('PSLinear.Milestone')]
    param(
        [Parameter(Position = 0, ValueFromPipelineByPropertyName, ParameterSetName = 'List')]
        [Alias('SlugId')]
        [ValidateNotNullOrEmpty()]
        [string] $Project,

        [Parameter(ParameterSetName = 'List')]
        [SupportsWildcards()]
        [ValidateNotNullOrEmpty()]
        [string[]] $Name,

        [Parameter(Mandatory, ParameterSetName = 'ById')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Id
    )

    process {
        if ($PSCmdlet.ParameterSetName -eq 'ById') {
            foreach ($milestoneId in $Id) {
                $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'GetProjectMilestone') -Variables @{ id = $milestoneId } -IncludeErrors
                $milestone = Get-LinearNestedValue -InputObject $result.Data -Name 'projectMilestone'
                if ($null -eq $milestone) {
                    $message = Format-LinearFailureMessage -Message "Milestone '$milestoneId' was not found." -Errors $result.Errors
                    $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.MilestoneNotFound' -Category ObjectNotFound -TargetObject $milestoneId))
                    continue
                }
                ConvertTo-LinearMilestone -InputObject $milestone
            }
            return
        }

        try {
            $projectId = if ($Project) { Resolve-LinearProjectId -Project $Project } else { $null }
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }

        $milestones = if ($projectId) {
            @(Get-LinearMilestoneCache -ProjectId $projectId -Refresh)
        }
        else {
            @(Invoke-LinearPagedRequest -Query (Get-LinearGraphQLDocument -Name 'ListProjectMilestones') -ConnectionPath 'projectMilestones' -Limit 0 |
                    ConvertTo-LinearMilestone |
                    Sort-Object -Property Project, SortOrder)
        }

        if (-not $Name) {
            foreach ($milestone in $milestones) { $milestone }
            return
        }
        $selection = Select-LinearObjectByName -InputObject $milestones -Name $Name -Property 'Name'
        foreach ($missing in $selection.Missing) {
            $PSCmdlet.WriteError((New-LinearErrorRecord -Message "Milestone '$missing' was not found." `
                        -ErrorId 'PSLinear.MilestoneNotFound' -Category ObjectNotFound -TargetObject $missing))
        }
        foreach ($milestone in $selection.Selected) { $milestone }
    }
}
