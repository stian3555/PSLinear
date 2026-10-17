function Remove-LinearProject {
    <#
    .SYNOPSIS
        Moves Linear projects to the trash.

    .DESCRIPTION
        Moves projects, given by name, slug id, URL or id or piped in from Get-LinearProject, to
        the trash, which is what deleting a project does in the Linear app. Trashed projects can
        be restored from the trash in Linear for 30 days, after which Linear deletes them for
        good. Linear archives the project's issues along with it; they stay in the project and
        are unarchived when the project is restored.

        The command asks for confirmation for each project; use -Confirm:$false to skip that, or
        -WhatIf to see what would happen without sending anything.

        A missing project, or one Linear refuses to remove, writes a non-terminating error and
        the remaining projects are still processed. A project name that matches no project stops
        the command with an error that lists the valid names. Nothing is returned.

        To restore a trashed project outside the Linear app, run:
        Invoke-LinearGraphQL -Query 'mutation($id: String!) { projectUnarchive(id: $id) { success } }' -Variables @{ id = '<project id>' }

    .PARAMETER Project
        One or more projects: names, slug ids (the hex suffix of a project URL), URLs or ids.

    .PARAMETER InputObject
        PSLinear.Project objects, typically from Get-LinearProject.

    .EXAMPLE
        Remove-LinearProject 'Old website'

        Moves a project to the trash, after asking for confirmation.

    .EXAMPLE
        Get-LinearProject -Status canceled | Remove-LinearProject -WhatIf

        Shows which canceled projects would be moved to the trash, without changing them.

    .INPUTS
        System.String
        PSLinear.Project

    .OUTPUTS
        None

    .LINK
        Get-LinearProject

    .LINK
        New-LinearProject
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByProject', SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'ByProject')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Project,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [PSTypeName('PSLinear.Project')]
        [object[]] $InputObject
    )

    process {
        $targets = Get-LinearProjectTarget -Project $Project -InputObject $InputObject

        foreach ($target in $targets) {
            if (-not $PSCmdlet.ShouldProcess($target.Name, 'Move project to the trash and archive its issues (restorable for 30 days)')) {
                continue
            }

            try {
                $projectId = if ($target.Id) { $target.Id } else { Resolve-LinearProjectId -Project $target.Reference }
            }
            catch {
                $PSCmdlet.ThrowTerminatingError($_)
            }

            $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'DeleteProject') -Variables @{ id = $projectId } -IncludeErrors
            if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'projectDelete.success')) {
                $message = Format-LinearFailureMessage -Message "Linear did not move $($target.Name) to the trash." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.ProjectDeleteFailed' -Category WriteError -TargetObject $target.Reference))
                continue
            }
            # So that -Project no longer finds the trashed project by name.
            Reset-LinearProjectCache
        }
    }
}
