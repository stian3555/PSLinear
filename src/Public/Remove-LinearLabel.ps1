function Remove-LinearLabel {
    <#
    .SYNOPSIS
        Deletes issue labels.

    .DESCRIPTION
        Deletes labels given by name or id, or piped in from Get-LinearLabel. Names are looked
        up among the workspace labels, or among a team's own labels with -Team; a name can
        include its group (Area/Frontend). Linear removes a deleted label from every issue that
        has it, and deleting a label group also deletes the labels in it. To stop a label from
        being used without deleting it, use Set-LinearLabel -Retire instead.

        The command asks for confirmation for each label; use -Confirm:$false to skip that, or
        -WhatIf to see what would happen without sending anything. A missing label, or one
        Linear refuses to delete, writes a non-terminating error and the remaining labels are
        still processed. A name that matches no label stops the command with an error that
        lists the valid names. Nothing is returned.

    .PARAMETER Label
        One or more label names or ids.

    .PARAMETER Team
        Looks up -Label among this team's own labels (key, name or id) instead of the workspace
        labels. Supports tab completion once connected.

    .PARAMETER InputObject
        PSLinear.Label objects, typically from Get-LinearLabel.

    .EXAMPLE
        Remove-LinearLabel 'Needs design'

        Deletes a workspace label, after asking for confirmation.

    .EXAMPLE
        Get-LinearLabel -Team ENG -Name 'tmp-*' | Remove-LinearLabel -Confirm:$false

        Deletes a team's temporary labels without asking.

    .INPUTS
        System.String
        PSLinear.Label

    .OUTPUTS
        None

    .LINK
        Get-LinearLabel

    .LINK
        Set-LinearLabel
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByLabel', SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'ByLabel')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Label,

        [Parameter(ParameterSetName = 'ByLabel')]
        [ValidateNotNullOrEmpty()]
        [string] $Team,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [PSTypeName('PSLinear.Label')]
        [object[]] $InputObject
    )

    process {
        $targets = if ($PSCmdlet.ParameterSetName -eq 'ByLabel') {
            foreach ($value in $Label) { [pscustomobject]@{ Id = $null; Reference = $value; Name = "label '$value'" } }
        }
        else {
            foreach ($object in $InputObject) {
                [pscustomobject]@{ Id = $object.Id; Reference = $object.Id; Name = "label '$(Get-LinearNestedValue -InputObject $object -Name 'Name')'" }
            }
        }

        foreach ($target in $targets) {
            if (-not $PSCmdlet.ShouldProcess($target.Name, 'Delete label and remove it from its issues')) {
                continue
            }

            try {
                $labelId = if ($target.Id) {
                    $target.Id
                }
                else {
                    $teamId = if ($Team) { Resolve-LinearTeamId -Team $Team } else { $null }
                    Resolve-LinearScopedLabelId -Label $target.Reference -TeamId $teamId
                }
            }
            catch {
                $PSCmdlet.ThrowTerminatingError($_)
            }

            $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'DeleteIssueLabel') -Variables @{ id = $labelId } -IncludeErrors
            if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'issueLabelDelete.success')) {
                $message = Format-LinearFailureMessage -Message "Linear did not delete $($target.Name)." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.LabelDeleteFailed' -Category WriteError -TargetObject $target.Reference))
                continue
            }
            Reset-LinearLabelCache
        }
    }
}
