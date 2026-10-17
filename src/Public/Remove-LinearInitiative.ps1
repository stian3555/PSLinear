function Remove-LinearInitiative {
    <#
    .SYNOPSIS
        Moves Linear initiatives to the trash, or archives them with -Archive.

    .DESCRIPTION
        By default, moves initiatives to the trash, which is what deleting an initiative does in
        the Linear app; they can be restored from the trash in Linear. With -Archive, the
        initiatives are archived instead: they disappear from lists, and Get-LinearInitiative
        -IncludeArchived still returns them.

        Initiatives are given by name, slug id, URL or id, or piped in from Get-LinearInitiative.
        The command asks for confirmation for each initiative; use -Confirm:$false to skip that,
        or -WhatIf to see what would happen without sending anything.

        A missing initiative, or one Linear refuses to remove, writes a non-terminating error and
        the remaining initiatives are still processed. An initiative name that matches nothing
        stops the command with an error that lists the valid names. Nothing is returned.

        To restore an archived initiative outside the Linear app, run:
        Invoke-LinearGraphQL -Query 'mutation($id: String!) { initiativeUnarchive(id: $id) { success } }' -Variables @{ id = '<initiative id>' }

    .PARAMETER Initiative
        One or more initiatives: names, slug ids (the hex suffix of an initiative URL), URLs or
        ids.

    .PARAMETER InputObject
        PSLinear.Initiative objects, typically from Get-LinearInitiative.

    .PARAMETER Archive
        Archives the initiatives instead of moving them to the trash.

    .EXAMPLE
        Remove-LinearInitiative 'Old goals'

        Moves an initiative to the trash, after asking for confirmation.

    .EXAMPLE
        Get-LinearInitiative -Status Completed | Remove-LinearInitiative -Archive -Confirm:$false

        Archives every completed initiative without asking.

    .INPUTS
        System.String
        PSLinear.Initiative

    .OUTPUTS
        None

    .LINK
        Get-LinearInitiative

    .LINK
        New-LinearInitiative
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByInitiative', SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'ByInitiative')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Initiative,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [PSTypeName('PSLinear.Initiative')]
        [object[]] $InputObject,

        [switch] $Archive
    )

    begin {
        $operation, $field, $action = if ($Archive) {
            'ArchiveInitiative', 'initiativeArchive', 'Archive initiative'
        }
        else {
            'DeleteInitiative', 'initiativeDelete', 'Move initiative to the trash'
        }
    }

    process {
        $targets = Get-LinearInitiativeTarget -Initiative $Initiative -InputObject $InputObject

        foreach ($target in $targets) {
            if (-not $PSCmdlet.ShouldProcess($target.Name, $action)) {
                continue
            }

            try {
                $initiativeId = if ($target.Id) { $target.Id } else { Resolve-LinearInitiativeId -Initiative $target.Reference }
            }
            catch {
                $PSCmdlet.ThrowTerminatingError($_)
            }

            $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name $operation) -Variables @{ id = $initiativeId } -IncludeErrors
            if (-not (Get-LinearNestedValue -InputObject $result.Data -Name "$field.success")) {
                $verb = if ($Archive) { 'archive' } else { 'move' }
                $message = Format-LinearFailureMessage -Message "Linear did not $verb $($target.Name)$(if (-not $Archive) { ' to the trash' })." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.InitiativeDeleteFailed' -Category WriteError -TargetObject $target.Reference))
                continue
            }
            # So that -Initiative no longer finds it by name.
            Reset-LinearInitiativeCache
        }
    }
}
