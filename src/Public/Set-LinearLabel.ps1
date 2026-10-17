function Set-LinearLabel {
    <#
    .SYNOPSIS
        Changes issue labels.

    .DESCRIPTION
        Renames labels, changes their color, description or group, or retires and restores
        them. Give labels by name or id: names are looked up among the workspace labels, or
        among a team's own labels with -Team; a name can include its group (Area/Frontend). Or
        pipe in labels from Get-LinearLabel. Nothing is returned unless you use -PassThru.

        A retired label stays on the issues that have it, but cannot be applied to new ones.

        A missing label, or a change Linear rejects, writes a non-terminating error and the
        remaining labels are still processed. A name that matches no label stops the command
        with an error that lists the valid names. With -WhatIf nothing is sent.

    .PARAMETER Label
        One or more label names or ids.

    .PARAMETER Team
        Looks up -Label among this team's own labels (key, name or id) instead of the workspace
        labels. Supports tab completion once connected.

    .PARAMETER InputObject
        PSLinear.Label objects, typically from Get-LinearLabel.

    .PARAMETER Name
        The new name.

    .PARAMETER Color
        The new color as a hex value, such as #EB5757.

    .PARAMETER Description
        The new description. An empty string clears it.

    .PARAMETER Group
        Moves the labels into this label group, by name or id.

    .PARAMETER Retire
        Retires the labels: they stay on issues but cannot be applied to new ones.

    .PARAMETER Restore
        Restores retired labels.

    .PARAMETER Clear
        Removes values: Group (takes the labels out of their group).

    .PARAMETER PassThru
        Returns the updated labels.

    .EXAMPLE
        Set-LinearLabel Bug -Color '#EB5757' -Description 'Something is broken'

        Changes a workspace label's color and description.

    .EXAMPLE
        Set-LinearLabel Backend -Team ENG -Name 'Back end' -PassThru

        Renames a team label and returns it.

    .EXAMPLE
        Get-LinearLabel -Team ENG -Name 'Legacy*' | Set-LinearLabel -Retire

        Retires labels that should no longer be used.

    .INPUTS
        System.String
        PSLinear.Label

    .OUTPUTS
        PSLinear.Label

    .LINK
        Get-LinearLabel

    .LINK
        New-LinearLabel

    .LINK
        Remove-LinearLabel
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByLabel', SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType('PSLinear.Label')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'ByLabel')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Label,

        [Parameter(ParameterSetName = 'ByLabel')]
        [ValidateNotNullOrEmpty()]
        [string] $Team,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [PSTypeName('PSLinear.Label')]
        [object[]] $InputObject,

        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [ValidatePattern('^#[0-9a-fA-F]{6}$', ErrorMessage = "'{0}' is not a hex color. Use a value such as #EB5757.")]
        [string] $Color,

        [string] $Description,

        [ValidateNotNullOrEmpty()]
        [string] $Group,

        [switch] $Retire,

        [switch] $Restore,

        [ValidateSet('Group')]
        [string[]] $Clear,

        [switch] $PassThru
    )

    begin {
        $changes = Format-LinearChangeList -BoundParameters $PSBoundParameters -Name 'Name', 'Color', 'Description', 'Group', 'Retire', 'Restore', 'Clear'
        $invalidMessage = if ($Retire -and $Restore) {
            'Use either -Retire or -Restore, not both.'
        }
        elseif ($Clear -contains 'Group' -and $Group) {
            'Use either -Clear Group or -Group, not both.'
        }
        elseif (-not $changes) {
            'Specify at least one change, such as -Name, -Color or -Retire.'
        }
        if ($invalidMessage) {
            $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord -Message $invalidMessage -ErrorId 'PSLinear.InvalidArgument' -Category InvalidArgument))
        }
        $updateQuery = Get-LinearGraphQLDocument -Name 'UpdateIssueLabel'
    }

    process {
        $targets = if ($PSCmdlet.ParameterSetName -eq 'ByLabel') {
            foreach ($value in $Label) { [pscustomobject]@{ Id = $null; Reference = $value; TeamId = $null; Name = "label '$value'" } }
        }
        else {
            foreach ($object in $InputObject) {
                [pscustomobject]@{
                    Id        = $object.Id
                    Reference = $object.Id
                    TeamId    = Get-LinearNestedValue -InputObject $object -Name 'TeamId'
                    Name      = "label '$(Get-LinearNestedValue -InputObject $object -Name 'Name')'"
                }
            }
        }

        foreach ($target in $targets) {
            if (-not $PSCmdlet.ShouldProcess($target.Name, "Update label ($changes)")) {
                continue
            }

            try {
                $teamId = if ($target.Id) { $target.TeamId } elseif ($Team) { Resolve-LinearTeamId -Team $Team } else { $null }
                $labelId = if ($target.Id) { $target.Id } else { Resolve-LinearScopedLabelId -Label $target.Reference -TeamId $teamId }
                $labelInput = @{}
                if ($PSBoundParameters.ContainsKey('Name')) { $labelInput['name'] = $Name }
                if ($Color) { $labelInput['color'] = $Color }
                if ($PSBoundParameters.ContainsKey('Description')) { $labelInput['description'] = $Description }
                if ($Group) { $labelInput['parentId'] = Resolve-LinearScopedLabelId -Label $Group -TeamId $teamId -GroupOnly }
                if ($Clear -contains 'Group') { $labelInput['parentId'] = $null }
                if ($Retire) { $labelInput['retiredAt'] = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [cultureinfo]::InvariantCulture) }
                if ($Restore) { $labelInput['retiredAt'] = $null }
            }
            catch {
                $PSCmdlet.ThrowTerminatingError($_)
            }

            $result = Invoke-LinearRequest -Query $updateQuery -Variables @{ id = $labelId; input = $labelInput } -IncludeErrors
            $updated = Get-LinearNestedValue -InputObject $result.Data -Name 'issueLabelUpdate.issueLabel'
            if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'issueLabelUpdate.success') -or $null -eq $updated) {
                $message = Format-LinearFailureMessage -Message "Linear did not update $($target.Name)." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.LabelUpdateFailed' -Category WriteError -TargetObject $target.Reference))
                continue
            }
            Reset-LinearLabelCache
            if ($PassThru) {
                ConvertTo-LinearLabel -InputObject $updated
            }
        }
    }
}
