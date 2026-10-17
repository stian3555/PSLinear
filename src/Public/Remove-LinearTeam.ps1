function Remove-LinearTeam {
    <#
    .SYNOPSIS
        Deletes Linear teams.

    .DESCRIPTION
        Deletes teams given by key, name or id, or piped in from Get-LinearTeam. Linear archives
        the team and schedules it, with its issues, for permanent deletion; it needs team owner
        or workspace admin rights. Until the deletion runs, it can be cancelled with:
        Invoke-LinearGraphQL -Query 'mutation($id: String!) { teamUnarchive(id: $id) { success } }' -Variables @{ id = '<team id>' }

        The command asks for confirmation for each team; use -Confirm:$false to skip that, or
        -WhatIf to see what would happen without sending anything. A team Linear refuses to
        delete writes a non-terminating error and the remaining teams are still processed. An
        unknown team stops the command with an error that lists the valid keys. Nothing is
        returned.

    .PARAMETER Team
        One or more team keys, names or ids.

    .PARAMETER InputObject
        PSLinear.Team objects, typically from Get-LinearTeam.

    .EXAMPLE
        Remove-LinearTeam OLD

        Deletes a team, after asking for confirmation.

    .INPUTS
        System.String
        PSLinear.Team

    .OUTPUTS
        None

    .LINK
        Get-LinearTeam

    .LINK
        New-LinearTeam
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByTeam', SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'ByTeam')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Team,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [PSTypeName('PSLinear.Team')]
        [object[]] $InputObject
    )

    process {
        $targets = if ($PSCmdlet.ParameterSetName -eq 'ByTeam') {
            foreach ($value in $Team) { [pscustomobject]@{ Id = $null; Reference = $value; Name = "team $value" } }
        }
        else {
            foreach ($object in $InputObject) {
                [pscustomobject]@{ Id = $object.Id; Reference = $object.Id; Name = "team $(Get-LinearNestedValue -InputObject $object -Name 'Key')" }
            }
        }

        foreach ($target in $targets) {
            if (-not $PSCmdlet.ShouldProcess($target.Name, 'Delete team and its issues (archived until Linear deletes it)')) {
                continue
            }

            try {
                $teamId = if ($target.Id) { $target.Id } else { Resolve-LinearTeamId -Team $target.Reference }
            }
            catch {
                $PSCmdlet.ThrowTerminatingError($_)
            }

            $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'DeleteTeam') -Variables @{ id = $teamId } -IncludeErrors
            if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'teamDelete.success')) {
                $message = Format-LinearFailureMessage -Message "Linear did not delete $($target.Name)." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.TeamDeleteFailed' -Category WriteError -TargetObject $target.Reference))
                continue
            }
            Reset-LinearTeamCache -TeamId $teamId
        }
    }
}
