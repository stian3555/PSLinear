function New-LinearLabel {
    <#
    .SYNOPSIS
        Creates an issue label.

    .DESCRIPTION
        Creates a workspace label, or a team label with -Team, and returns it. Put it in a label
        group with -Group, or create a group with -IsGroup. Linear picks a color when -Color is
        not given. With -WhatIf nothing is sent, not even the name lookups.

    .PARAMETER Name
        The label name.

    .PARAMETER Team
        Creates the label in this team (key, name or id) instead of the workspace. Supports tab
        completion once connected.

    .PARAMETER Color
        The label color as a hex value, such as #EB5757.

    .PARAMETER Description
        The label description.

    .PARAMETER Group
        The label group to put the label in, by name or id: a group of the same team, or a
        workspace group.

    .PARAMETER IsGroup
        Creates a label group, which holds other labels and cannot be applied to issues itself.

    .EXAMPLE
        New-LinearLabel 'Needs design' -Color '#F2994A'

        Creates a workspace label.

    .EXAMPLE
        New-LinearLabel Area -Team ENG -IsGroup; New-LinearLabel Backend -Team ENG -Group Area

        Creates a label group in a team and a label in it.

    .INPUTS
        None

    .OUTPUTS
        PSLinear.Label

    .LINK
        Get-LinearLabel

    .LINK
        Set-LinearLabel

    .LINK
        Remove-LinearLabel
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType('PSLinear.Label')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [ValidateNotNullOrEmpty()]
        [string] $Team,

        [ValidatePattern('^#[0-9a-fA-F]{6}$', ErrorMessage = "'{0}' is not a hex color. Use a value such as #EB5757.")]
        [string] $Color,

        [string] $Description,

        [ValidateNotNullOrEmpty()]
        [string] $Group,

        [switch] $IsGroup
    )

    $changes = Format-LinearChangeList -BoundParameters $PSBoundParameters -Name 'Color', 'Description', 'Group', 'IsGroup'
    $kind = if ($IsGroup) { 'label group' } else { 'label' }
    $action = if ($changes) { "Create $kind '$Name' ($changes)" } else { "Create $kind '$Name'" }
    $target = if ($Team) { "team $Team" } else { 'workspace' }
    if (-not $PSCmdlet.ShouldProcess($target, $action)) {
        return
    }

    try {
        $labelInput = @{ name = $Name }
        $teamId = if ($Team) { Resolve-LinearTeamId -Team $Team } else { $null }
        if ($teamId) { $labelInput['teamId'] = $teamId }
        if ($Color) { $labelInput['color'] = $Color }
        if ($PSBoundParameters.ContainsKey('Description')) { $labelInput['description'] = $Description }
        if ($Group) { $labelInput['parentId'] = Resolve-LinearScopedLabelId -Label $Group -TeamId $teamId -GroupOnly }
        if ($IsGroup) { $labelInput['isGroup'] = $true }
    }
    catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }

    $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'CreateIssueLabel') -Variables @{ input = $labelInput } -IncludeErrors
    $label = Get-LinearNestedValue -InputObject $result.Data -Name 'issueLabelCreate.issueLabel'
    if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'issueLabelCreate.success') -or $null -eq $label) {
        $message = Format-LinearFailureMessage -Message "Linear did not create $kind '$Name' in the $target." -Errors $result.Errors
        $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.LabelCreateFailed' -Category WriteError -TargetObject $Name))
        return
    }
    # So that -Label finds the new label right away.
    Reset-LinearLabelCache
    ConvertTo-LinearLabel -InputObject $label
}
