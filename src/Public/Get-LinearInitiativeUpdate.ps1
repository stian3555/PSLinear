function Get-LinearInitiativeUpdate {
    <#
    .SYNOPSIS
        Gets initiative status updates.

    .DESCRIPTION
        Returns the status updates posted on an initiative, newest first, or the updates of every
        initiative in the workspace when -Initiative is not given. Each update has a health
        (OnTrack, AtRisk or OffTrack), an author and a Markdown body. Use -First to get only the
        newest updates, and -Id for specific updates.

        An initiative name that matches nothing stops the command with an error that lists the
        valid names. A missing update id writes a non-terminating error.

    .PARAMETER Initiative
        An initiative name, slug id, URL or id. Binds from the SlugId property of piped
        PSLinear.Initiative objects.

    .PARAMETER First
        Returns only this many updates, the newest first.

    .PARAMETER Id
        One or more initiative update ids.

    .EXAMPLE
        Get-LinearInitiativeUpdate -Initiative 'Q1 growth' -First 1

        Shows an initiative's latest status update.

    .EXAMPLE
        Get-LinearInitiative -Status Active | Get-LinearInitiativeUpdate -First 1 | Where-Object Health -NE 'OnTrack'

        Lists the active initiatives whose latest update is not on track.

    .INPUTS
        PSLinear.Initiative

    .OUTPUTS
        PSLinear.InitiativeUpdate

    .LINK
        New-LinearInitiativeUpdate

    .LINK
        Get-LinearInitiative
    #>
    [CmdletBinding(DefaultParameterSetName = 'List')]
    [OutputType('PSLinear.InitiativeUpdate')]
    param(
        [Parameter(Position = 0, ValueFromPipelineByPropertyName, ParameterSetName = 'List')]
        [Alias('SlugId')]
        [ValidateNotNullOrEmpty()]
        [string] $Initiative,

        [Parameter(ParameterSetName = 'List')]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $First,

        [Parameter(Mandatory, ParameterSetName = 'ById')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Id
    )

    process {
        if ($PSCmdlet.ParameterSetName -eq 'ById') {
            foreach ($updateId in $Id) {
                $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'GetInitiativeUpdate') -Variables @{ id = $updateId } -IncludeErrors
                $update = Get-LinearNestedValue -InputObject $result.Data -Name 'initiativeUpdate'
                if ($null -eq $update) {
                    $message = Format-LinearFailureMessage -Message "Initiative update '$updateId' was not found." -Errors $result.Errors
                    $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.InitiativeUpdateNotFound' -Category ObjectNotFound -TargetObject $updateId))
                    continue
                }
                ConvertTo-LinearInitiativeUpdate -InputObject $update
            }
            return
        }

        try {
            $variables = @{}
            if ($Initiative) { $variables['filter'] = @{ initiative = @{ id = @{ eq = (Resolve-LinearInitiativeId -Initiative $Initiative) } } } }
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }

        # Linear returns the newest updates first.
        $limit = if ($First) { $First } else { 0 }
        Invoke-LinearPagedRequest -Query (Get-LinearGraphQLDocument -Name 'ListInitiativeUpdates') -ConnectionPath 'initiativeUpdates' -Variables $variables -Limit $limit |
            ConvertTo-LinearInitiativeUpdate
    }
}
