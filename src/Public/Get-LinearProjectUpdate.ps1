function Get-LinearProjectUpdate {
    <#
    .SYNOPSIS
        Gets project status updates.

    .DESCRIPTION
        Returns the status updates posted on a project, newest first, or the updates of every
        project in the workspace when -Project is not given. Each update has a health (OnTrack,
        AtRisk or OffTrack), an author and a Markdown body. Use -First to get only the newest
        updates, and -Id for specific updates.

        A project name that matches no project stops the command with an error that lists the
        valid names. A missing update id writes a non-terminating error.

    .PARAMETER Project
        A project name, slug id, URL or id. Binds from the SlugId property of piped
        PSLinear.Project objects and the Project property of piped issues.

    .PARAMETER First
        Returns only this many updates, the newest first.

    .PARAMETER Id
        One or more project update ids.

    .EXAMPLE
        Get-LinearProjectUpdate -Project Website -First 1

        Shows a project's latest status update.

    .EXAMPLE
        Get-LinearProject -Status started | Get-LinearProjectUpdate -First 1 | Where-Object Health -NE 'OnTrack'

        Lists the projects in progress whose latest update is not on track.

    .EXAMPLE
        Get-LinearProjectUpdate -Project Website | Format-List CreatedAt, Author, Health, Body

        Shows the full text of a project's updates.

    .INPUTS
        PSLinear.Project
        PSLinear.Issue

    .OUTPUTS
        PSLinear.ProjectUpdate

    .LINK
        New-LinearProjectUpdate

    .LINK
        Get-LinearProject
    #>
    [CmdletBinding(DefaultParameterSetName = 'List')]
    [OutputType('PSLinear.ProjectUpdate')]
    param(
        [Parameter(Position = 0, ValueFromPipelineByPropertyName, ParameterSetName = 'List')]
        [Alias('SlugId')]
        [ValidateNotNullOrEmpty()]
        [string] $Project,

        [Parameter(ParameterSetName = 'List')]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $First,

        [Parameter(Mandatory, ParameterSetName = 'ById')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Id
    )

    process {
        if ($PSCmdlet.ParameterSetName -eq 'ById') {
            foreach ($updateId in $Id) {
                $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'GetProjectUpdate') -Variables @{ id = $updateId } -IncludeErrors
                $update = Get-LinearNestedValue -InputObject $result.Data -Name 'projectUpdate'
                if ($null -eq $update) {
                    $message = Format-LinearFailureMessage -Message "Project update '$updateId' was not found." -Errors $result.Errors
                    $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.ProjectUpdateNotFound' -Category ObjectNotFound -TargetObject $updateId))
                    continue
                }
                ConvertTo-LinearProjectUpdate -InputObject $update
            }
            return
        }

        try {
            $variables = @{}
            if ($Project) { $variables['filter'] = @{ project = @{ id = @{ eq = (Resolve-LinearProjectId -Project $Project) } } } }
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }

        # Linear returns the newest updates first.
        $limit = if ($First) { $First } else { 0 }
        Invoke-LinearPagedRequest -Query (Get-LinearGraphQLDocument -Name 'ListProjectUpdates') -ConnectionPath 'projectUpdates' -Variables $variables -Limit $limit |
            ConvertTo-LinearProjectUpdate
    }
}
