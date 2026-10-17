function Remove-LinearMilestone {
    <#
    .SYNOPSIS
        Deletes Linear project milestones.

    .DESCRIPTION
        Deletes milestones given by id or piped in from Get-LinearMilestone. Their issues stay in
        the project, without a milestone. The command asks for confirmation for each milestone;
        use -Confirm:$false to skip that, or -WhatIf to see what would happen without sending
        anything.

        A missing milestone, or one Linear refuses to delete, writes a non-terminating error and
        the remaining milestones are still processed. Nothing is returned.

    .PARAMETER Id
        One or more milestone ids.

    .PARAMETER InputObject
        PSLinear.Milestone objects, typically from Get-LinearMilestone.

    .EXAMPLE
        Get-LinearMilestone -Project Website -Name 'Old beta' | Remove-LinearMilestone

        Deletes a milestone, after asking.

    .INPUTS
        System.String
        PSLinear.Milestone

    .OUTPUTS
        None

    .LINK
        Get-LinearMilestone
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById', SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'ById')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Id,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [PSTypeName('PSLinear.Milestone')]
        [object[]] $InputObject
    )

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
            if (-not $PSCmdlet.ShouldProcess($target.Name, 'Delete milestone')) {
                continue
            }
            $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'DeleteProjectMilestone') -Variables @{ id = $target.Id } -IncludeErrors
            if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'projectMilestoneDelete.success')) {
                $message = Format-LinearFailureMessage -Message "Linear did not delete $($target.Name)." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.MilestoneDeleteFailed' -Category WriteError -TargetObject $target.Id))
                continue
            }
            # Without the project id (a milestone given by id), clear every cached project.
            if ($target.ProjectId) { $script:LinearMilestoneCache.Remove($target.ProjectId) } else { $script:LinearMilestoneCache.Clear() }
        }
    }
}
