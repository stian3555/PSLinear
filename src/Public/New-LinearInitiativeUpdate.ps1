function New-LinearInitiativeUpdate {
    <#
    .SYNOPSIS
        Posts a status update on a Linear initiative.

    .DESCRIPTION
        Posts an initiative update with a health (OnTrack, AtRisk or OffTrack) and a Markdown
        body, and returns it. The initiative's health in Linear follows its latest update. Give
        -Body, -Health or both; without -Body, the update has no text. With -WhatIf nothing is
        sent, not even the initiative lookup.

    .PARAMETER Initiative
        An initiative name, slug id, URL or id. Binds from the SlugId property of piped
        PSLinear.Initiative objects.

    .PARAMETER Body
        The update text, in Markdown.

    .PARAMETER Health
        The initiative's health: OnTrack, AtRisk or OffTrack.

    .EXAMPLE
        New-LinearInitiativeUpdate -Initiative 'Q1 growth' 'Two of three projects shipped.' -Health OnTrack

        Posts an on-track update.

    .EXAMPLE
        Get-LinearInitiative 'Q1 growth' | New-LinearInitiativeUpdate -Health AtRisk -Body (Get-Content ./status.md -Raw)

        Posts an update from a Markdown file.

    .INPUTS
        PSLinear.Initiative

    .OUTPUTS
        PSLinear.InitiativeUpdate

    .LINK
        Get-LinearInitiativeUpdate

    .LINK
        Set-LinearInitiativeUpdate
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType('PSLinear.InitiativeUpdate')]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('SlugId')]
        [ValidateNotNullOrEmpty()]
        [string] $Initiative,

        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Body,

        [ValidateSet('OnTrack', 'AtRisk', 'OffTrack')]
        [string] $Health
    )

    begin {
        if (-not $Body -and -not $Health) {
            $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord -Message 'Specify -Body, -Health or both.' -ErrorId 'PSLinear.InvalidArgument' -Category InvalidArgument))
        }
        $action = if ($Health) { "Post initiative update (health $Health)" } else { 'Post initiative update' }
    }

    process {
        if (-not $PSCmdlet.ShouldProcess("initiative '$Initiative'", $action)) {
            return
        }

        try {
            $initiativeId = Resolve-LinearInitiativeId -Initiative $Initiative
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }

        # Linear rejects a project update without a body; initiative updates are sent the same way.
        $updateInput = @{ initiativeId = $initiativeId; body = $(if ($Body) { $Body } else { '' }) }
        if ($Health) { $updateInput['health'] = $script:HealthMap[$Health] }

        $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'CreateInitiativeUpdate') -Variables @{ input = $updateInput } -IncludeErrors
        $update = Get-LinearNestedValue -InputObject $result.Data -Name 'initiativeUpdateCreate.initiativeUpdate'
        if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'initiativeUpdateCreate.success') -or $null -eq $update) {
            $message = Format-LinearFailureMessage -Message "Linear did not post the update on initiative '$Initiative'." -Errors $result.Errors
            $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.InitiativeUpdateCreateFailed' -Category WriteError -TargetObject $Initiative))
            return
        }
        ConvertTo-LinearInitiativeUpdate -InputObject $update
    }
}
