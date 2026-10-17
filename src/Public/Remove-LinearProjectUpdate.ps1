function Remove-LinearProjectUpdate {
    <#
    .SYNOPSIS
        Removes project status updates.

    .DESCRIPTION
        Removes project updates given by id or piped in from Get-LinearProjectUpdate. Linear
        archives them, which takes them off the project's update feed; the API no longer offers
        a permanent delete. The command asks for confirmation for each update; use
        -Confirm:$false to skip that, or -WhatIf to see what would happen without sending
        anything.

        A missing update, or one Linear refuses to remove, writes a non-terminating error and
        the remaining updates are still processed. Nothing is returned.

    .PARAMETER Id
        One or more project update ids.

    .PARAMETER InputObject
        PSLinear.ProjectUpdate objects, typically from Get-LinearProjectUpdate.

    .EXAMPLE
        Get-LinearProjectUpdate -Project Website -First 1 | Remove-LinearProjectUpdate

        Removes a project's latest update, after asking.

    .INPUTS
        System.String
        PSLinear.ProjectUpdate

    .OUTPUTS
        None

    .LINK
        Get-LinearProjectUpdate

    .LINK
        New-LinearProjectUpdate
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById', SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'ById')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Id,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [PSTypeName('PSLinear.ProjectUpdate')]
        [object[]] $InputObject
    )

    process {
        $targets = if ($PSCmdlet.ParameterSetName -eq 'ById') {
            foreach ($updateId in $Id) { [pscustomobject]@{ Id = $updateId; Name = "project update $updateId" } }
        }
        else {
            foreach ($update in $InputObject) {
                $projectName = Get-LinearNestedValue -InputObject $update -Name 'Project'
                [pscustomobject]@{ Id = $update.Id; Name = "project update $($update.Id)$(if ($projectName) { " on $projectName" })" }
            }
        }

        foreach ($target in $targets) {
            if (-not $PSCmdlet.ShouldProcess($target.Name, 'Remove project update')) {
                continue
            }
            $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'ArchiveProjectUpdate') -Variables @{ id = $target.Id } -IncludeErrors
            if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'projectUpdateArchive.success')) {
                $message = Format-LinearFailureMessage -Message "Linear did not remove $($target.Name)." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.ProjectUpdateDeleteFailed' -Category WriteError -TargetObject $target.Id))
            }
        }
    }
}
