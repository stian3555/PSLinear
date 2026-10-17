function Remove-LinearInitiativeUpdate {
    <#
    .SYNOPSIS
        Removes initiative status updates.

    .DESCRIPTION
        Removes initiative updates given by id or piped in from Get-LinearInitiativeUpdate.
        Linear archives them, which takes them off the initiative's update feed. The command asks
        for confirmation for each update; use -Confirm:$false to skip that, or -WhatIf to see
        what would happen without sending anything.

        A missing update, or one Linear refuses to remove, writes a non-terminating error and
        the remaining updates are still processed. Nothing is returned.

    .PARAMETER Id
        One or more initiative update ids.

    .PARAMETER InputObject
        PSLinear.InitiativeUpdate objects, typically from Get-LinearInitiativeUpdate.

    .EXAMPLE
        Get-LinearInitiativeUpdate -Initiative 'Q1 growth' -First 1 | Remove-LinearInitiativeUpdate

        Removes an initiative's latest update, after asking.

    .INPUTS
        System.String
        PSLinear.InitiativeUpdate

    .OUTPUTS
        None

    .LINK
        Get-LinearInitiativeUpdate

    .LINK
        New-LinearInitiativeUpdate
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById', SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'ById')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Id,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [PSTypeName('PSLinear.InitiativeUpdate')]
        [object[]] $InputObject
    )

    process {
        $targets = if ($PSCmdlet.ParameterSetName -eq 'ById') {
            foreach ($updateId in $Id) { [pscustomobject]@{ Id = $updateId; Name = "initiative update $updateId" } }
        }
        else {
            foreach ($update in $InputObject) {
                $initiativeName = Get-LinearNestedValue -InputObject $update -Name 'Initiative'
                [pscustomobject]@{ Id = $update.Id; Name = "initiative update $($update.Id)$(if ($initiativeName) { " on $initiativeName" })" }
            }
        }

        foreach ($target in $targets) {
            if (-not $PSCmdlet.ShouldProcess($target.Name, 'Remove initiative update')) {
                continue
            }
            $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'ArchiveInitiativeUpdate') -Variables @{ id = $target.Id } -IncludeErrors
            if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'initiativeUpdateArchive.success')) {
                $message = Format-LinearFailureMessage -Message "Linear did not remove $($target.Name)." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.InitiativeUpdateDeleteFailed' -Category WriteError -TargetObject $target.Id))
            }
        }
    }
}
