function Get-LinearLabel {
    <#
    .SYNOPSIS
        Gets the issue labels in the Linear workspace.

    .DESCRIPTION
        Returns the labels that can be applied to issues, sorted by name. Without -Team, every
        label in the workspace is returned; with -Team, the workspace labels and that team's
        own labels. Label groups and retired labels are left out; a label in a group shows the
        group in its Group property.

        A name without wildcards that matches no label writes a non-terminating error.

    .PARAMETER Name
        One or more label names. Wildcards are supported.

    .PARAMETER Team
        The team key (ENG), name or id. Accepts PSLinear.Team objects from the pipeline.
        Supports tab completion once connected.

    .EXAMPLE
        Get-LinearLabel

        Lists every label in the workspace.

    .EXAMPLE
        Get-LinearLabel -Team ENG

        Lists the labels that can be used on ENG issues.

    .EXAMPLE
        Get-LinearLabel -Name 'needs-*' | Format-Table Name, Team, Id

        Lists the labels whose names start with 'needs-'.

    .INPUTS
        System.String
        PSLinear.Team

    .OUTPUTS
        PSLinear.Label

    .LINK
        Set-LinearIssue
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.Label')]
    param(
        [Parameter(Position = 0, ValueFromPipeline)]
        [SupportsWildcards()]
        [ValidateNotNullOrEmpty()]
        [string[]] $Name,

        [Parameter(ValueFromPipelineByPropertyName)]
        [Alias('Key')]
        [ValidateNotNullOrEmpty()]
        [string] $Team
    )

    begin {
        # Labels fetched by this call, keyed by team id ('' for the whole workspace), so names
        # piped in one by one do not fetch the list again.
        $fetched = @{}
    }

    process {
        try {
            $teamId = if ($Team) { Resolve-LinearTeamId -Team $Team } else { '' }
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }

        if (-not $fetched.ContainsKey($teamId)) {
            $fetched[$teamId] = if ($teamId) { @(Get-LinearLabelCache -TeamId $teamId -Refresh) } else { @(Get-LinearLabelList) }
        }
        $labels = $fetched[$teamId]
        if (-not $Name) {
            foreach ($label in $labels) { $label }
            return
        }

        $selection = Select-LinearObjectByName -InputObject $labels -Name $Name -Property 'Name'
        foreach ($missing in $selection.Missing) {
            $PSCmdlet.WriteError((New-LinearErrorRecord -Message "Label '$missing' was not found." `
                        -ErrorId 'PSLinear.LabelNotFound' -Category ObjectNotFound -TargetObject $missing))
        }
        foreach ($label in $selection.Selected) { $label }
    }
}
